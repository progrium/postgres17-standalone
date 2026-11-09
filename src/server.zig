//! The server process: the one process that runs Postgres for a .pgdb.
//!
//! It holds the .pgdb's lock for its whole life, runs Postgres in an h9
//! machine through the image's docker-entrypoint.sh (which initializes the
//! cluster on first start), and serves the control socket. Postgres binds
//! the host port itself. A monitor thread waits for Postgres to accept a
//! login, then counts client connections through pg_stat_activity, and, with
//! an idle timeout, stops the server once none are left for that long.

const std = @import("std");
const h9 = @import("h9");
const Ctx = @import("ctx.zig").Ctx;
const pgdb_mod = @import("pgdb.zig");
const paths = @import("paths.zig");
const control = @import("control.zig");
const host = @import("host.zig");
const logwin = @import("logwin.zig");
const pgwire = @import("pgwire.zig");
const roots = @import("roots.zig");
const vm = @import("vm.zig");
const net = @import("net.zig");
const sys = @import("sys.zig");

const Pgdb = pgdb_mod.Pgdb;

pub const Options = struct {
    /// A port to use instead of the stored one; no fallback if it's taken.
    port: ?u16 = null,
    /// Postgres's listen_addresses.
    listen: []const u8 = "127.0.0.1",
    /// Where the full log goes, instead of the default log file.
    log_file: ?[]const u8 = null,
    trust: bool = false,
    /// More arguments for postgres, such as `-c name=value`.
    postgres_args: []const []const u8 = &.{},
    /// Echo the log to stdout (serve in the foreground).
    foreground: bool = true,
    /// Seconds without clients before stopping; 0 never stops.
    idle_timeout: i64 = 0,
};

const State = enum(u8) { starting, ready, stopping };

const Server = struct {
    ctx: Ctx,
    pgdb: Pgdb,
    opts: Options,
    port: u16,
    root: roots.Root,
    log: *logwin.Log,
    sig: *host.Signals,
    started: i64,
    state: std.atomic.Value(State) = .init(.starting),
    clients: std.atomic.Value(i64) = .init(-1),
    /// Control connections holding the server open (minipg run).
    holds: std.atomic.Value(i64) = .init(0),
    /// Set when the machine has exited.
    done: std.atomic.Value(bool) = .init(false),
    /// Set by the monitor once Postgres has accepted a login.
    was_ready: std.atomic.Value(bool) = .init(false),
    backend: []const u8 = "",

    /// Records the Postgres version that last opened the .pgdb, and the
    /// root and arch for a .pgdb that has none yet.
    fn recordOpened(s: *Server) void {
        recordOpenedImpl(s) catch |err| s.log.note("updating minipg.toml: {t}", .{err});
    }

    fn connectHost(s: *Server) []const u8 {
        return net.dialHost(s.opts.listen);
    }

    fn status(s: *Server, arena: std.mem.Allocator) control.Status {
        return .{
            .state = @tagName(s.state.load(.acquire)),
            .pid = sys.pid(),
            .port = s.port,
            .listen = s.opts.listen,
            .clients = s.clients.load(.acquire),
            .pg_version = s.root.meta.version,
            .backend = s.backend,
            .started = s.started,
            .idle_timeout = s.opts.idle_timeout,
            .version = s.ctx.version,
            .pgdb = arena.dupe(u8, s.pgdb.path) catch s.pgdb.path,
        };
    }
};

pub fn serve(ctx: Ctx, p: Pgdb, opts: Options) !u8 {
    const arena = ctx.arena;
    const io = ctx.io;

    const lock = (try pgdb_mod.tryLock(arena, io, p)) orelse {
        return ctx.fail("a server is already running for {s} (minipg status {s})", .{ p.path, p.path });
    };
    defer lock.close(io);

    const root = roots.forPgdb(ctx, p) catch |err| switch (err) {
        error.NoRoot => return 1,
        else => return err,
    };

    // Runtime directory and log file.
    const key = try paths.key(arena, p.path);
    const runtime = try ctx.dirs.runtimeFor(arena, key);
    try paths.makePrivateDir(io, arena, runtime);
    const log_path = opts.log_file orelse blk: {
        try paths.makePrivateDir(io, arena, ctx.dirs.logs);
        break :blk try ctx.dirs.logFor(arena, key);
    };
    // In the arena: the control and monitor threads use it until the process exits.
    const log = try logwin.Log.init(arena, io, logwin.default_size);
    log.file = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch |err|
        return ctx.fail("log file {s}: {t}", .{ log_path, err });
    if (opts.foreground) log.echo = std.Io.File.stdout();

    // The port: the one asked for, else the stored one if it's free, else
    // any free one, so saved URLs usually keep working.
    const port = if (opts.port) |pp| pp else blk: {
        if (p.config.port != 0 and net.portFree(opts.listen, p.config.port)) break :blk p.config.port;
        const free = net.freePort() catch return ctx.fail("no free port", .{});
        if (p.config.port != 0) log.note("port {d} is taken; using {d} instead", .{ p.config.port, free });
        break :blk free;
    };
    if (opts.port != null and !net.portFree(opts.listen, port))
        return ctx.fail("port {d} is in use", .{port});

    if (!std.mem.eql(u8, p.config.pg_arch, roots.host_arch) and p.config.pg_arch.len > 0)
        log.note("warning: {s} was created on {s} and this host is {s}; Postgres doesn't promise its data files carry across", .{ p.name(), p.config.pg_arch, roots.host_arch });

    var sig: host.Signals = undefined;
    try sig.init(io, .server, &log.interface);
    defer sig.deinit();

    // The supervisor's stdin: a pipe the stop hook writes "stop" to.
    var stop_pipe = try host.Pipe.init();
    defer stop_pipe.close();
    var in_buf: [256]u8 = undefined;
    var stop_in: host.Stdin = undefined;
    stop_in.initFd(stop_pipe.r, &in_buf);
    sig.stop_hook = .{ .ctx = &stop_pipe, .func = writeStop };

    var s: Server = .{
        .ctx = ctx,
        .pgdb = p,
        .opts = opts,
        .port = port,
        .root = root,
        .log = log,
        .sig = &sig,
        .started = std.Io.Clock.real.now(io).toSeconds(),
        .backend = @tagName(h9.vmm.BackendKind.auto),
    };

    // The control socket, then run.json, which points at it.
    const sock_path = try control.socketPath(arena, runtime);
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};
    const ua = std.Io.net.UnixAddress.init(sock_path) catch return ctx.fail("control socket path too long: {s}", .{sock_path});
    var listener = ua.listen(io, .{}) catch |err| return ctx.fail("control socket {s}: {t}", .{ sock_path, err });
    defer {
        listener.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};
    }
    try control.writeRunInfo(arena, io, runtime, .{
        .pid = sys.pid(),
        .port = port,
        .listen = opts.listen,
        .control = sock_path,
        .protocol = control.protocol,
        .version = ctx.version,
        .pgdb = p.path,
    });
    const run_json = try control.runJsonPath(arena, runtime);
    defer std.Io.Dir.cwd().deleteFile(io, run_json) catch {};

    (try std.Thread.spawn(.{}, acceptLoop, .{ &s, &listener })).detach();
    const monitor_thread = try std.Thread.spawn(.{}, monitor, .{&s});

    // The machine's environment and Postgres's command line.
    const initializing = !p.initialized(arena, io);
    if (initializing) {
        log.note("initializing a Postgres {s} cluster in {s}", .{ root.meta.version, p.path });
    } else {
        const data_major = p.dataMajor(arena, io) catch 0;
        if (data_major != root.meta.major)
            return ctx.fail("{s} holds Postgres {d} data but its root is Postgres {d}", .{ p.path, data_major, root.meta.major });
    }
    const extra = try machineEnv(ctx, p, root, port, initializing);
    const env = try vm.environment(arena, root.meta, extra);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "bash",                                                                "-c",
        supervisor,                                                            "minipg-server",
        "postgres",                                                            "-c",
        try std.fmt.allocPrint(arena, "listen_addresses={s}", .{opts.listen}), "-c",
        try std.fmt.allocPrint(arena, "port={d}", .{port}),
        // The trimmed root has no LLVM, so JIT is never available.
                           "-c",
        "jit=off",
    });
    const trust_hba = try p.sub(arena, ".trust_hba.conf");
    if (opts.trust) {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = trust_hba,
            .data = "# Written by minipg serve --trust; removed when it stops.\nlocal all all trust\nhost all all 127.0.0.1/32 trust\nhost all all ::1/128 trust\n",
        });
        try argv.appendSlice(arena, &.{ "-c", "hba_file=" ++ vm.guest_pgdb ++ "/.trust_hba.conf" });
    }
    defer if (opts.trust) std.Io.Dir.cwd().deleteFile(io, trust_hba) catch {};
    try argv.appendSlice(arena, opts.postgres_args);

    log.note("starting Postgres {s} for {s} on {s}:{d}", .{ root.meta.version, p.path, opts.listen, port });
    const result = vm.runServer(ctx.gpa, io, arena, .{
        .root = root,
        .pgdb = p.path,
        .env = env,
        .prog = "/bin/bash",
        .argv = argv.items,
        .log = &log.interface,
        .signals = &sig.machine,
        .in = &stop_in.interface,
        .in_cancel = stop_in.cancelHook(),
    });
    s.done.store(true, .release);
    s.state.store(.stopping, .release);
    monitor_thread.join();
    if (result.stuck) std.process.exit(1);
    const st = result.status orelse {
        log.note("{s}", .{result.err_msg});
        if (!opts.foreground) ctx.warn("{s}", .{result.err_msg});
        return 1;
    };
    const code = vm.exitCode(st);
    const stopping = sig.stopping.load(.acquire);
    if (!s.was_ready.load(.acquire) and !stopping) {
        log.note("Postgres exited before it was ready (exit {d}); see {s}", .{ code, log_path });
        return if (code == 0) 1 else code;
    }
    if (sig.forced.load(.acquire)) return 1;
    // A fast shutdown ends with exit 0; anything else is worth saying.
    if (code != 0 and !stopping) log.note("Postgres exited with status {d}", .{code});
    log.note("stopped", .{});
    return if (stopping) 0 else code;
}

/// The server machine's first process: it runs docker-entrypoint.sh with
/// Postgres's arguments, and on a `stop` line on its stdin sends SIGINT (a
/// fast shutdown) to the postmaster alone. h9's `interrupt` note would
/// reach every process in the machine, as a terminal's Ctrl-C reaches its
/// whole process group, and Postgres's children act on SIGINT themselves:
/// the checkpointer, for one, then writes its shutdown checkpoint before
/// the postmaster expects it, and the postmaster waits forever.
const supervisor =
    \\exec 3<&0
    \\docker-entrypoint.sh "$@" </dev/null 3<&- &
    \\pg=$!
    \\# A background job's stdin is /dev/null, so read the console as fd 3.
    \\{ while read -r cmd <&3; do if [ "$cmd" = stop ]; then kill -INT "$pg"; fi; done; } &
    \\wait "$pg"
;

/// Asks the supervisor to stop Postgres. `ctx` is the stop pipe.
fn writeStop(ctx: *anyopaque) void {
    const pipe: *host.Pipe = @ptrCast(@alignCast(ctx));
    pipe.write("stop\n");
}

/// The server machine's environment beyond the image's: PGDATA and PGPORT,
/// and for a cluster that isn't initialized yet, what docker-entrypoint.sh
/// initializes it with.
fn machineEnv(ctx: Ctx, p: Pgdb, root: roots.Root, port: u16, initializing: bool) ![]const h9.EnvVar {
    const arena = ctx.arena;
    var extra: std.ArrayList(h9.EnvVar) = .empty;
    try extra.appendSlice(arena, &.{
        .{ .name = "PGDATA", .value = vm.guest_pgdata },
        .{ .name = "PGPORT", .value = try std.fmt.allocPrint(arena, "{d}", .{port}) },
    });
    if (ctx.getenv("TZ")) |tz| try extra.append(arena, .{ .name = "TZ", .value = tz });
    if (!initializing) return extra.items;
    var initdb_args: []const u8 = ctx.getenv("POSTGRES_INITDB_ARGS") orelse "";
    // The builtin C.UTF-8 locale (Postgres 17 and later) sorts the same on
    // every libc and never changes, so collations can't drift.
    if (root.meta.major >= 17 and std.mem.indexOf(u8, initdb_args, "locale") == null)
        initdb_args = try std.fmt.allocPrint(arena, "--locale-provider=builtin --builtin-locale=C.UTF-8 {s}", .{initdb_args});
    // initdb trusts loopback by default, and host connections reach the
    // guest over loopback, so without this the password guards nothing.
    // The unix socket is only reachable inside the machine.
    if (std.mem.indexOf(u8, initdb_args, "--auth") == null)
        initdb_args = try std.fmt.allocPrint(arena, "--auth-host=scram-sha-256 --auth-local=trust {s}", .{initdb_args});
    try extra.appendSlice(arena, &.{
        .{ .name = "POSTGRES_USER", .value = p.config.user },
        .{ .name = "POSTGRES_PASSWORD", .value = p.config.password },
        .{ .name = "POSTGRES_DB", .value = p.config.database },
        .{ .name = "POSTGRES_INITDB_ARGS", .value = initdb_args },
    });
    if (ctx.getenv("POSTGRES_INITDB_WALDIR")) |v| try extra.append(arena, .{ .name = "POSTGRES_INITDB_WALDIR", .value = v });
    return extra.items;
}

/// The initialization half of docker-entrypoint.sh's _main, without
/// starting the real server after it: initdb, pg_hba.conf, and a temporary
/// server (on a unix socket only) that creates the database and runs any
/// init scripts.
const init_script =
    \\set -Eeo pipefail
    \\source /usr/local/bin/docker-entrypoint.sh
    \\docker_setup_env
    \\docker_create_db_directories
    \\if [ "$(id -u)" = 0 ]; then exec gosu postgres bash -c "$MINIPG_INIT" minipg-init; fi
    \\docker_verify_minimum_env
    \\docker_init_database_dir
    \\pg_setup_hba_conf postgres
    \\export PGPASSWORD="${PGPASSWORD:-$POSTGRES_PASSWORD}"
    \\docker_temp_server_start postgres
    \\docker_setup_db
    \\docker_process_init_files /docker-entrypoint-initdb.d/*
    \\docker_temp_server_stop
;

/// Initializes a .pgdb's cluster without serving it (init). Returns the
/// exit code; the log goes to the .pgdb's log file.
pub fn initialize(ctx: Ctx, p: Pgdb) !u8 {
    const arena = ctx.arena;
    const io = ctx.io;
    const lock = (try pgdb_mod.tryLock(arena, io, p)) orelse return ctx.fail("{s} is in use by a running server", .{p.path});
    defer lock.close(io);
    const root = roots.forPgdb(ctx, p) catch |err| switch (err) {
        error.NoRoot => return 1,
        else => return err,
    };
    const key = try paths.key(arena, p.path);
    try paths.makePrivateDir(io, arena, ctx.dirs.logs);
    const log_path = try ctx.dirs.logFor(arena, key);
    const log = try logwin.Log.init(arena, io, 64 << 10);
    log.file = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch |err|
        return ctx.fail("log file {s}: {t}", .{ log_path, err });
    log.note("initializing a Postgres {s} cluster in {s}", .{ root.meta.version, p.path });

    var extra: std.ArrayList(h9.EnvVar) = .empty;
    try extra.appendSlice(arena, try machineEnv(ctx, p, root, 5432, true));
    try extra.append(arena, .{ .name = "MINIPG_INIT", .value = init_script });
    const env = try vm.environment(arena, root.meta, extra.items);

    var sig: host.Signals = undefined;
    try sig.init(io, .server, &log.interface);
    defer sig.deinit();
    const result = vm.runServer(ctx.gpa, io, arena, .{
        .root = root,
        .pgdb = p.path,
        .env = env,
        .prog = "/bin/bash",
        .argv = &.{ "bash", "-c", init_script, "minipg-init" },
        .log = &log.interface,
        .signals = &sig.machine,
    });
    if (result.stuck) std.process.exit(1);
    const st = result.status orelse {
        log.note("{s}", .{result.err_msg});
        return 1;
    };
    const code = vm.exitCode(st);
    if (code != 0) return code;
    var s: Server = .{ .ctx = ctx, .pgdb = p, .opts = .{}, .port = 0, .root = root, .log = log, .sig = &sig, .started = 0 };
    s.recordOpened();
    return 0;
}

/// Waits for Postgres to accept a login, then counts clients once a second
/// and stops the server when it has been idle too long.
fn monitor(s: *Server) void {
    const ctx = s.ctx;
    const io = ctx.io;
    var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena_state.deinit();
    var opts: pgwire.Options = .{
        .host = s.connectHost(),
        .port = s.port,
        .user = s.pgdb.config.user,
        .password = s.pgdb.config.password,
        .database = "postgres",
        .application_name = "minipg monitor",
    };
    var conn: ?*pgwire.Conn = null;
    defer if (conn) |c| c.close();

    // Ready: a login succeeds.
    while (!s.done.load(.acquire)) {
        conn = pgwire.Conn.connect(ctx.gpa, io, opts) catch null;
        if (conn != null) break;
        io.sleep(.fromMilliseconds(100), .awake) catch return;
    }
    if (s.done.load(.acquire)) return;
    s.was_ready.store(true, .release);
    if (s.state.cmpxchgStrong(.starting, .ready, .acq_rel, .acquire) == null) {
        s.log.note("ready on {s}:{d}", .{ s.opts.listen, s.port });
        s.recordOpened();
        if (conn) |c| checkCollations(s, c, arena_state.allocator());
    }

    var idle_since: ?i64 = null;
    const sql = "select count(*) from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid()";
    while (!s.done.load(.acquire)) {
        _ = arena_state.reset(.retain_capacity);
        const c = conn orelse blk: {
            conn = pgwire.Conn.connect(ctx.gpa, io, opts) catch null;
            if (conn == null) {
                // passwd may have rotated the password.
                if (pgdb_mod.open(s.ctx.arena, io, s.pgdb.path)) |fresh| opts.password = fresh.config.password else |_| {}
            }
            break :blk conn;
        };
        if (c) |cc| {
            if (cc.scalar(arena_state.allocator(), sql)) |v| {
                const n = std.fmt.parseInt(i64, v orelse "0", 10) catch 0;
                s.clients.store(n, .release);
            } else |_| {
                cc.close();
                conn = null;
            }
        }
        const now = std.Io.Clock.awake.now(io).toSeconds();
        if (s.opts.idle_timeout > 0 and s.state.load(.acquire) == .ready) {
            if (s.clients.load(.acquire) == 0 and s.holds.load(.acquire) == 0) {
                const since = idle_since orelse now;
                idle_since = since;
                if (now - since >= s.opts.idle_timeout) {
                    s.log.note("no clients for {d}s; stopping", .{s.opts.idle_timeout});
                    s.state.store(.stopping, .release);
                    s.sig.request();
                    return;
                }
            } else idle_since = null;
        }
        // A second, but notice the machine's exit sooner.
        for (0..10) |_| {
            if (s.done.load(.acquire)) return;
            io.sleep(.fromMilliseconds(100), .awake) catch return;
        }
    }
}

/// Warns about databases whose collation version no longer matches the
/// library's, which happens when a minor upgrade brings a new libc or ICU
/// to a cluster that doesn't use the builtin provider: indexes on text may
/// then be out of order until rebuilt.
fn checkCollations(s: *Server, c: *pgwire.Conn, arena: std.mem.Allocator) void {
    const rows = c.query(arena,
        \\select datname, datcollversion, pg_database_collation_actual_version(oid)
        \\from pg_database
        \\where datallowconn and datcollversion is distinct from pg_database_collation_actual_version(oid)
    ) catch return;
    for (rows) |row| {
        s.log.note("warning: database {s} was created with collation version {s}, and this Postgres has {s}; run REINDEX DATABASE and ALTER DATABASE ... REFRESH COLLATION VERSION in it", .{ row[0] orelse "?", row[1] orelse "(none)", row[2] orelse "(none)" });
    }
}

fn recordOpenedImpl(s: *Server) !void {
    var arena_state: std.heap.ArenaAllocator = .init(s.ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Re-read, so nothing written since the server started is lost.
    var p = try pgdb_mod.open(arena, s.ctx.io, s.pgdb.path);
    var changed = false;
    if (!std.mem.eql(u8, p.config.pg_last_opened, s.root.meta.version)) {
        p.config.pg_last_opened = s.root.meta.version;
        changed = true;
    }
    if (p.config.pg_digest.len == 0) {
        p.config.pg_digest = s.root.meta.digest;
        changed = true;
    }
    if (p.config.pg_arch.len == 0) {
        p.config.pg_arch = roots.host_arch;
        changed = true;
    }
    if (changed) try p.save(arena, s.ctx.io);
}

fn acceptLoop(s: *Server, listener: *std.Io.net.Server) void {
    while (!s.done.load(.acquire)) {
        const conn = listener.accept(s.ctx.io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                s.ctx.io.sleep(.fromMilliseconds(50), .awake) catch return;
                continue;
            },
        };
        const t = std.Thread.spawn(.{}, handle, .{ s, conn }) catch {
            conn.close(s.ctx.io);
            continue;
        };
        t.detach();
    }
}

fn handle(s: *Server, conn: std.Io.net.Stream) void {
    const io = s.ctx.io;
    defer conn.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(s.ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rbuf: [1024]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    var wbuf: [8192]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    const out = &w.interface;
    const line = (r.interface.takeDelimiter('\n') catch return) orelse return;
    handleRequest(s, arena, line, &r.interface, out) catch {};
    out.flush() catch {};
}

fn handleRequest(s: *Server, arena: std.mem.Allocator, line: []const u8, in: *std.Io.Reader, out: *std.Io.Writer) !void {
    const io = s.ctx.io;
    const req = control.parseRequest(line) orelse return out.writeAll("error malformed request\n");
    if (req.version != control.protocol)
        return out.print("error protocol mismatch: this server (minipg {s}) speaks control protocol {d}, the client speaks {d}\n", .{ s.ctx.version, control.protocol, req.version });
    var words = std.mem.tokenizeScalar(u8, req.command, ' ');
    const cmd = words.next() orelse "";
    if (std.mem.eql(u8, cmd, "status")) {
        try out.print("ok\n{f}\n", .{std.json.fmt(s.status(arena), .{})});
    } else if (std.mem.eql(u8, cmd, "stop")) {
        try out.writeAll("ok\n");
        try out.flush();
        s.log.note("stop requested", .{});
        s.state.store(.stopping, .release);
        s.sig.request();
    } else if (std.mem.eql(u8, cmd, "hold")) {
        _ = s.holds.fetchAdd(1, .acq_rel);
        defer _ = s.holds.fetchSub(1, .acq_rel);
        try out.writeAll("ok\n");
        try out.flush();
        // Until the client hangs up.
        while (true) _ = in.takeByte() catch break;
    } else if (std.mem.eql(u8, cmd, "clients")) {
        try out.print("ok\n{d}\n", .{s.clients.load(.acquire)});
    } else if (std.mem.eql(u8, cmd, "logs")) {
        const follow = if (words.next()) |a| std.mem.eql(u8, a, "follow") else false;
        try out.writeAll("ok\n");
        var buf: std.ArrayList(u8) = .empty;
        var pos = try s.log.readSince(arena, 0, &buf);
        try out.writeAll(buf.items);
        try out.flush();
        while (follow and !s.done.load(.acquire)) {
            io.sleep(.fromMilliseconds(200), .awake) catch return;
            buf.clearRetainingCapacity();
            pos = try s.log.readSince(arena, pos, &buf);
            if (buf.items.len > 0) {
                try out.writeAll(buf.items);
                try out.flush();
            }
        }
        // Whatever the last moments wrote.
        buf.clearRetainingCapacity();
        _ = try s.log.readSince(arena, pos, &buf);
        try out.writeAll(buf.items);
    } else {
        try out.print("error unknown command {s}\n", .{cmd});
    }
}
