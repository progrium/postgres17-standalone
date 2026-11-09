//! The commands.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const native = @import("build_options").native;
const Ctx = @import("ctx.zig").Ctx;
const cli = @import("cli.zig");
const pgdb_mod = @import("pgdb.zig");
const client = @import("client.zig");
const control = @import("control.zig");
const server = @import("server.zig");
const roots = @import("roots.zig");
const vm = @import("vm.zig");
const net = @import("net.zig");
const paths = @import("paths.zig");
const pgwire = @import("pgwire.zig");
const host = @import("host.zig");

const Pgdb = pgdb_mod.Pgdb;

pub fn usageError(ctx: Ctx, comptime fmt: []const u8, args: anytype) u8 {
    ctx.warn(fmt, args);
    std.debug.print("Run minipg --help for usage.\n", .{});
    return 2;
}

/// Opens the .pgdb named on the command line, explaining a failure.
fn openPgdb(ctx: Ctx, path: []const u8) ?Pgdb {
    return pgdb_mod.open(ctx.arena, ctx.io, path) catch |err| {
        switch (err) {
            error.NotFound => ctx.warn("{s} doesn't exist (minipg init {s} creates it)", .{ path, path }),
            error.NotPgdb => ctx.warn("{s} isn't a .pgdb: it has no minipg.toml", .{path}),
            error.BadConfig => ctx.warn("{s}/minipg.toml is unreadable or malformed", .{path}),
            error.NewerFormat => ctx.warn("{s} was made by a newer minipg (its format is newer than {d}); upgrade minipg to open it", .{ path, @import("config.zig").format_version }),
            error.OutOfMemory => ctx.warn("out of memory", .{}),
        }
        return null;
    };
}

/// The settings for a new .pgdb at `path`.
fn newConfig(ctx: Ctx, args: cli.Args, path: []const u8) !pgdb_mod.Config {
    const meta = try roots.embeddedMeta(ctx.arena);
    const port = if (args.flag(&.{"port"})) |v|
        std.fmt.parseInt(u16, v, 10) catch return error.BadPort
    else if (native)
        // Without TCP (h9's web host), the port only names the socket.
        net.freePort() catch 5432
    else
        try net.freePort();
    return .{
        .pg_major = meta.major,
        .pg_arch = roots.host_arch,
        .pg_digest = meta.digest,
        .user = args.flag(&.{"user"}) orelse ctx.getenv("POSTGRES_USER") orelse "postgres",
        .password = ctx.getenv("POSTGRES_PASSWORD") orelse try pgdb_mod.generatePassword(ctx.arena, ctx.io),
        .database = ctx.getenv("POSTGRES_DB") orelse pgdb_mod.defaultDatabase(path),
        .port = port,
    };
}

/// Opens the .pgdb, creating it if it's missing (shell, url, run and the
/// bare form). A new one's cluster is initialized by its first server.
fn openOrCreate(ctx: Ctx, args: cli.Args, path: []const u8) ?Pgdb {
    if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| {
        return openPgdb(ctx, path);
    } else |_| {}
    const c = newConfig(ctx, args, path) catch |err| {
        ctx.warn("creating {s}: {t}", .{ path, err });
        return null;
    };
    const p = pgdb_mod.create(ctx.arena, ctx.io, path, c) catch |err| {
        ctx.warn("creating {s}: {t}", .{ path, err });
        return null;
    };
    ctx.warn("creating {s}", .{path});
    return p;
}

pub fn init(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "init needs a .pgdb path", .{});
    if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| return ctx.fail("{s} already exists", .{path}) else |_| {}
    var c = newConfig(ctx, args, path) catch |err| switch (err) {
        error.BadPort => return usageError(ctx, "--port takes a port number", .{}),
        else => return err,
    };
    // --pg MAJOR: the newest root for that major, downloaded if need be.
    if (args.flag(&.{"pg"})) |m| {
        const major = std.fmt.parseInt(u32, m, 10) catch return usageError(ctx, "--pg takes a Postgres major, such as 17", .{});
        const r = roots.forMajor(ctx, major, .{}) catch |err| switch (err) {
            error.NoRoot => return 1,
            else => return err,
        };
        c.pg_major = major;
        c.pg_digest = r.meta.digest;
    }
    const p = try pgdb_mod.create(ctx.arena, ctx.io, path, c);
    const code = server.initialize(ctx, p) catch |err| blk: {
        ctx.warn("{t}", .{err});
        break :blk 1;
    };
    if (code != 0 or !p.initialized(ctx.arena, ctx.io)) {
        ctx.warn("initializing {s} failed; its log ends:", .{path});
        client.printLogTail(ctx, p, 20);
        std.Io.Dir.cwd().deleteTree(ctx.io, p.path) catch {};
        return 1;
    }
    const opened = (pgdb_mod.open(ctx.arena, ctx.io, p.path) catch p).config.pg_last_opened;
    var buf: [256]u8 = undefined;
    var out = ctx.stdout(&buf);
    try out.interface.print("created {s} (Postgres {s}, database {s})\n", .{ path, opened, c.database });
    try out.interface.flush();
    return 0;
}

pub fn serve(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "serve needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    var opts: server.Options = .{
        .listen = args.flag(&.{"listen"}) orelse if (native and !net.tcpAvailable()) "none" else "127.0.0.1",
        .log_file = args.flag(&.{"log"}),
        .trust = args.has(&.{"trust"}),
        .foreground = !args.has(&.{"background"}),
        .postgres_args = args.rest,
    };
    if (args.flag(&.{ "p", "port" })) |v| opts.port = std.fmt.parseInt(u16, v, 10) catch return usageError(ctx, "-p takes a port number", .{});
    if (args.flag(&.{"idle"})) |v| opts.idle_timeout = std.fmt.parseInt(i64, v, 10) catch return usageError(ctx, "--idle takes seconds", .{});
    if (net.socketOnly(opts.listen) and !native)
        return ctx.fail("--listen none needs the Linux build of minipg, whose Postgres socket is on this host", .{});
    if (opts.trust and !net.socketOnly(opts.listen) and !net.isLoopback(opts.listen))
        return ctx.fail("--trust lets anyone who can reach the port in without a password, so it only works with a loopback --listen", .{});
    if (opts.log_file) |l| opts.log_file = try pgdb_mod.absolute(ctx.arena, ctx.io, l);
    return server.serve(ctx, p, opts);
}

pub fn stop(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "stop needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    const r = try client.find(ctx, p) orelse {
        ctx.warn("no server is running for {s}", .{path});
        return 0;
    };
    client.stop(ctx, p, r) catch |err| return ctx.fail("stopping {s}: {t}", .{ path, err });
    return 0;
}

/// Exit code for `status` when no server is running.
pub const exit_stopped = 3;

pub fn status(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "status needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    var buf: [1024]u8 = undefined;
    var out = ctx.stdout(&buf);
    const w = &out.interface;
    defer w.flush() catch {};
    const r = try client.find(ctx, p) orelse {
        try w.print("{s}: stopped\n", .{path});
        try w.print("  postgres  {d} ({s})\n", .{ p.config.pg_major, if (p.config.pg_last_opened.len > 0) p.config.pg_last_opened else "never started" });
        try w.print("  port      {d} (preferred)\n", .{p.config.port});
        return exit_stopped;
    };
    const st = client.status(ctx, r) catch |err| return ctx.fail("asking the server: {t}", .{err});
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    try w.print("{s}: {s}\n", .{ path, if (std.mem.eql(u8, st.state, "ready")) "running" else st.state });
    try w.print("  postgres  {s}\n", .{st.pg_version});
    if (net.socketOnly(st.listen))
        try w.print("  listen    {s}/.s.PGSQL.{d}\n", .{ st.socket, st.port })
    else
        try w.print("  listen    {s}:{d}\n", .{ st.listen, st.port });
    try w.print("  pid       {d}\n", .{st.pid});
    if (st.clients >= 0) try w.print("  clients   {d}\n", .{st.clients});
    try w.print("  uptime    {d}s\n", .{now - st.started});
    if (st.idle_timeout > 0) try w.print("  idle stop after {d}s without clients\n", .{st.idle_timeout}) else try w.print("  idle stop never (foreground)\n", .{});
    try w.print("  minipg    {s}\n", .{st.version});
    return 0;
}

/// Percent-encodes a URL component.
fn escape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null) {
            try out.append(arena, ch);
        } else try out.print(arena, "%{X:0>2}", .{ch});
    }
    return out.items;
}

const Conn = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,

    fn url(c: Conn, arena: std.mem.Allocator) ![]const u8 {
        // A unix socket's directory goes in the query, as libpq takes it.
        if (c.host.len > 0 and c.host[0] == '/')
            return std.fmt.allocPrint(arena, "postgres://{s}:{s}@/{s}?host={s}&port={d}", .{
                try escape(arena, c.user), try escape(arena, c.password), try escape(arena, c.database), try escape(arena, c.host), c.port,
            });
        const h = if (std.mem.indexOfScalar(u8, c.host, ':') != null) try std.fmt.allocPrint(arena, "[{s}]", .{c.host}) else c.host;
        return std.fmt.allocPrint(arena, "postgres://{s}:{s}@{s}:{d}/{s}", .{
            try escape(arena, c.user), try escape(arena, c.password), h, c.port, try escape(arena, c.database),
        });
    }

    fn pgEnv(c: Conn, arena: std.mem.Allocator) ![]const h9.EnvVar {
        return arena.dupe(h9.EnvVar, &.{
            .{ .name = "PGHOST", .value = c.host },
            .{ .name = "PGPORT", .value = try std.fmt.allocPrint(arena, "{d}", .{c.port}) },
            .{ .name = "PGUSER", .value = c.user },
            .{ .name = "PGPASSWORD", .value = c.password },
            .{ .name = "PGDATABASE", .value = c.database },
        });
    }
};

/// Connection details for a .pgdb: the running server's port, or the
/// stored one.
fn connFor(args: cli.Args, p: Pgdb, r: ?client.Running) Conn {
    return .{
        .host = if (r) |rr| net.clientHost(rr.info.listen, rr.info.socket) else "127.0.0.1",
        .port = if (r) |rr| rr.info.port else p.config.port,
        .user = p.config.user,
        .password = p.config.password,
        .database = args.flag(&.{ "d", "db" }) orelse p.config.database,
    };
}

pub fn url(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "url needs a .pgdb path", .{});
    const p = openOrCreate(ctx, args, path) orelse return 1;
    const r = try client.find(ctx, p);
    var buf: [512]u8 = undefined;
    var out = ctx.stdout(&buf);
    try out.interface.print("{s}\n", .{try connFor(args, p, r).url(ctx.arena)});
    try out.interface.flush();
    return 0;
}

pub fn logs(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "logs needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    const follow = args.has(&.{ "f", "follow" });
    var buf: [4096]u8 = undefined;
    var out = ctx.stdout(&buf);
    if (try client.find(ctx, p)) |r| {
        if (try control.stream(ctx.arena, ctx.io, r.info.control, if (follow) "logs follow" else "logs", &out.interface)) |msg|
            return ctx.fail("server: {s}", .{msg});
        return 0;
    }
    // No server: the last one's log file.
    const key = try paths.key(ctx.arena, p.path);
    const log_path = try ctx.dirs.logFor(ctx.arena, key);
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, log_path, ctx.arena, .limited(1 << 30)) catch {
        ctx.warn("no server is running for {s}, and it has no log yet", .{path});
        return 0;
    };
    try out.interface.writeAll(text);
    try out.interface.flush();
    return 0;
}

/// The caller's working directory, for a tool machine's cwd.
fn hostCwd(ctx: Ctx) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", ctx.arena);
}

/// Runs `argv` in a tool machine connected to the .pgdb's server.
fn runToolOn(ctx: Ctx, args: cli.Args, p: Pgdb, argv: []const []const u8) !u8 {
    return runToolOnWith(ctx, args, p, argv, null, null);
}

/// The same, with the tool's stdin read from `in` instead of the caller's,
/// and its cwd `cwd` instead of the caller's.
fn runToolOnWith(ctx: Ctx, args: cli.Args, p: Pgdb, argv: []const []const u8, in: ?*host.Stdin, cwd: ?[]const u8) !u8 {
    const root = roots.forPgdb(ctx, p) catch |err| switch (err) {
        error.NoRoot => return 1,
        else => return err,
    };
    const r = client.ensure(ctx, p, .{ .idle_timeout = idleTimeout(ctx) }) catch |err| switch (err) {
        error.ServerFailed => return 1,
        else => return ctx.fail("starting the server for {s}: {t}", .{ p.path, err }),
    };
    const conn = connFor(args, p, r);
    const env = try vm.environment(ctx.arena, root.meta, try conn.pgEnv(ctx.arena));
    return vm.runTool(ctx.gpa, ctx.io, ctx.env, .{ .root = root, .cwd = cwd orelse try hostCwd(ctx), .env = env, .argv = argv, .in = in });
}

/// MINIPG_IDLE, in seconds.
pub fn idleTimeout(ctx: Ctx) i64 {
    const v = ctx.getenv("MINIPG_IDLE") orelse return client.default_idle;
    return std.fmt.parseInt(i64, v, 10) catch client.default_idle;
}

pub fn shell(ctx: Ctx, args: cli.Args) !u8 {
    const target = args.pgdb() orelse return usageError(ctx, "shell needs a .pgdb path or a postgres:// URL", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "psql");
    if (std.mem.startsWith(u8, target, "postgres://") or std.mem.startsWith(u8, target, "postgresql://")) {
        // A URL: psql on it, from a tool machine on the embedded root.
        const root = try roots.embedded(ctx.gpa, ctx.arena, ctx.io, ctx.dirs.roots);
        try argv.append(ctx.arena, target);
        for (args.positional[1..]) |sql| try argv.appendSlice(ctx.arena, &.{ "-c", sql });
        try argv.appendSlice(ctx.arena, args.rest);
        const env = try vm.environment(ctx.arena, root.meta, &.{});
        return vm.runTool(ctx.gpa, ctx.io, ctx.env, .{ .root = root, .cwd = try hostCwd(ctx), .env = env, .argv = argv.items });
    }
    const p = openOrCreate(ctx, args, target) orelse return 1;
    for (args.positional[1..]) |sql| try argv.appendSlice(ctx.arena, &.{ "-c", sql });
    try argv.appendSlice(ctx.arena, args.rest);
    return runToolOn(ctx, args, p, argv.items);
}

pub fn exec(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "exec needs a .pgdb path", .{});
    if (args.rest.len == 0) return usageError(ctx, "exec needs a tool: minipg exec {s} -- TOOL [args]", .{path});
    const p = openPgdb(ctx, path) orelse return 1;
    return runToolOn(ctx, args, p, args.rest);
}

/// A host-side admin connection to the .pgdb's server, as its superuser.
fn admin(ctx: Ctx, p: Pgdb, r: client.Running, database: []const u8) !*pgwire.Conn {
    return pgwire.Conn.connect(ctx.gpa, ctx.io, .{
        .host = net.clientHost(r.info.listen, r.info.socket),
        .port = r.info.port,
        .user = p.config.user,
        .password = p.config.password,
        .database = database,
    }) catch |err| {
        ctx.warn("connecting to {s}: {s}", .{ p.path, if (pgwire.lastConnectError().len > 0) pgwire.lastConnectError() else @errorName(err) });
        return error.Reported;
    };
}

/// The server for a command that needs one: started if need be.
fn ensureServer(ctx: Ctx, p: Pgdb) !client.Running {
    _ = roots.forPgdb(ctx, p) catch |err| switch (err) {
        error.NoRoot => return error.Reported,
        else => return err,
    };
    return client.ensure(ctx, p, .{ .idle_timeout = idleTimeout(ctx) }) catch |err| switch (err) {
        error.ServerFailed => error.Reported,
        else => {
            ctx.warn("starting the server for {s}: {t}", .{ p.path, err });
            return error.Reported;
        },
    };
}

/// Quotes an SQL identifier.
fn ident(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (name) |ch| {
        if (ch == '"') try out.append(arena, '"');
        try out.append(arena, ch);
    }
    try out.append(arena, '"');
    return out.items;
}

/// Quotes an SQL string literal.
fn literal(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.append(arena, '\'');
        try out.append(arena, ch);
    }
    try out.append(arena, '\'');
    return out.items;
}

/// Shell-quotes a value for `env`'s exports: for sh, or on Windows for
/// PowerShell, where a quote inside single quotes is doubled.
fn shellQuote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const quote = if (builtin.os.tag == .windows) "''" else "'\\''";
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(arena, quote) else try out.append(arena, ch);
    }
    try out.append(arena, '\'');
    return out.items;
}

pub fn envCmd(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "env needs a .pgdb path", .{});
    const p = openOrCreate(ctx, args, path) orelse return 1;
    const conn = connFor(args, p, try client.find(ctx, p));
    var buf: [1024]u8 = undefined;
    var out = ctx.stdout(&buf);
    const w = &out.interface;
    // PowerShell's syntax on Windows: minipg env app.pgdb | Invoke-Expression.
    const fmt = if (builtin.os.tag == .windows) "$env:{s} = {s}\n" else "export {s}={s}\n";
    try w.print(fmt, .{ "DATABASE_URL", try shellQuote(ctx.arena, try conn.url(ctx.arena)) });
    for (try conn.pgEnv(ctx.arena)) |v| try w.print(fmt, .{ v.name, try shellQuote(ctx.arena, v.value) });
    try w.flush();
    return 0;
}

pub fn run(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "run needs a .pgdb path", .{});
    const argv = if (args.rest.len > 0) args.rest else if (args.positional.len > 1) args.positional[1..] else return usageError(ctx, "run needs a command: minipg run {s} -- CMD [args]", .{path});
    const p = openOrCreate(ctx, args, path) orelse return 1;
    const r = ensureServer(ctx, p) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    // Hold the server open while the command runs, whether or not it has
    // connected yet.
    const hold = control.hold(ctx.io, r.info.control) catch null;
    defer if (hold) |h| h.close(ctx.io);

    const conn = connFor(args, p, r);
    var env_map = try ctx.env.clone(ctx.arena);
    try env_map.put("DATABASE_URL", try conn.url(ctx.arena));
    for (try conn.pgEnv(ctx.arena)) |v| try env_map.put(v.name, v.value);
    var child = std.process.spawn(ctx.io, .{ .argv = argv, .environ_map = &env_map }) catch |err|
        return ctx.fail("{s}: {t}", .{ argv[0], err });
    const term = try child.wait(ctx.io);
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 +| @as(u8, @truncate(@intFromEnum(sig))),
        else => 1,
    };
}

pub fn dump(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "dump needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "pg_dump");
    try argv.appendSlice(ctx.arena, args.positional[1..]);
    try argv.appendSlice(ctx.arena, args.rest);
    return runToolOn(ctx, args, p, argv.items);
}

pub fn restore(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "restore needs a .pgdb path", .{});
    const p = openOrCreate(ctx, args, path) orelse return 1;
    const db = args.flag(&.{ "d", "db" }) orelse p.config.database;
    var file: ?[]const u8 = if (args.positional.len > 1) try pgdb_mod.absolute(ctx.arena, ctx.io, args.positional[1]) else null;
    var fd: host.Handle = host.stdinHandle();
    if (file) |f| {
        const h = std.Io.Dir.cwd().openFile(ctx.io, f, .{}) catch |err| return ctx.fail("{s}: {t}", .{ f, err });
        fd = h.handle;
    }
    var in_buf: [64 << 10]u8 = undefined;
    var in: host.Stdin = undefined;
    in.initFd(fd, &in_buf);
    // pg_dump's custom format starts with PGDMP; anything else is SQL.
    const head = in.interface.peek(5) catch "";
    if (!std.mem.eql(u8, head, "PGDMP")) {
        // SQL through psql's stdin; query results are dropped, errors stop it.
        return runToolOnWith(ctx, args, p, &.{ "psql", "-X", "-q", "-o", "/dev/null", "-v", "ON_ERROR_STOP=1", "-d", db }, &in, null);
    }
    // pg_restore reads an archive from a file: in h9 it misreads one from
    // stdin. A dump on stdin goes to a temporary file first.
    var tmp_dir: ?[]const u8 = null;
    defer if (tmp_dir) |t| std.Io.Dir.cwd().deleteTree(ctx.io, t) catch {};
    if (file == null) {
        var rnd: [8]u8 = undefined;
        ctx.io.random(&rnd);
        const tmp_root = if (builtin.os.tag == .windows)
            ctx.getenv("TEMP") orelse ctx.getenv("TMP") orelse return ctx.fail("TEMP isn't set", .{})
        else
            ctx.getenv("TMPDIR") orelse "/tmp";
        const t = try std.fs.path.join(ctx.arena, &.{ tmp_root, try std.fmt.allocPrint(ctx.arena, "minipg-restore-{x}", .{&rnd}) });
        try paths.makePrivateDir(ctx.io, ctx.arena, t);
        tmp_dir = t;
        const f = try std.fs.path.join(ctx.arena, &.{ t, "dump" });
        var out = try std.Io.Dir.cwd().createFile(ctx.io, f, .{});
        defer out.close(ctx.io);
        var wbuf: [64 << 10]u8 = undefined;
        var w = out.writer(ctx.io, &wbuf);
        _ = try in.interface.streamRemaining(&w.interface);
        try w.interface.flush();
        file = f;
    }
    // The tool's cwd is the dump's directory, so the dump can be anywhere.
    const dir = std.fs.path.dirname(file.?) orelse ".";
    const argv: []const []const u8 = &.{ "pg_restore", "--no-owner", "--no-acl", "--exit-on-error", "-d", db, std.fs.path.basename(file.?) };
    return runToolOnWith(ctx, args, p, argv, null, dir);
}

pub fn dbs(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "dbs needs a .pgdb path", .{});
    const p = openPgdb(ctx, path) orelse return 1;
    const r = ensureServer(ctx, p) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    const c = admin(ctx, p, r, "postgres") catch return 1;
    defer c.close();
    const rows = c.query(ctx.arena, "select datname, pg_size_pretty(pg_database_size(oid)) from pg_database where not datistemplate order by 1") catch
        return ctx.fail("{s}", .{c.err_msg});
    var buf: [1024]u8 = undefined;
    var out = ctx.stdout(&buf);
    for (rows) |row| {
        const name = row[0] orelse "";
        try out.interface.print("{s} {s:<24} {s}\n", .{ if (std.mem.eql(u8, name, p.config.database)) "*" else " ", name, row[1] orelse "" });
    }
    try out.interface.flush();
    return 0;
}

fn nameArg(ctx: Ctx, args: cli.Args, what: []const u8) ?[]const u8 {
    if (args.positional.len < 2) {
        _ = usageError(ctx, "{s} needs a database name: minipg {s} <pgdb> NAME", .{ what, what });
        return null;
    }
    return args.positional[1];
}

pub fn create(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "create needs a .pgdb path", .{});
    const name = nameArg(ctx, args, "create") orelse return 2;
    const p = openPgdb(ctx, path) orelse return 1;
    const r = ensureServer(ctx, p) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    const c = admin(ctx, p, r, "postgres") catch return 1;
    defer c.close();
    _ = c.query(ctx.arena, try std.fmt.allocPrint(ctx.arena, "create database {s}", .{try ident(ctx.arena, name)})) catch
        return ctx.fail("{s}", .{c.err_msg});
    return 0;
}

pub fn drop(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "drop needs a .pgdb path", .{});
    const name = nameArg(ctx, args, "drop") orelse return 2;
    const p = openPgdb(ctx, path) orelse return 1;
    if (std.mem.eql(u8, name, p.config.database))
        return ctx.fail("{s} is the default database; make another the default first (minipg default {s} NAME)", .{ name, path });
    const r = ensureServer(ctx, p) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    const c = admin(ctx, p, r, "postgres") catch return 1;
    defer c.close();
    _ = c.query(ctx.arena, try std.fmt.allocPrint(ctx.arena, "drop database {s}", .{try ident(ctx.arena, name)})) catch
        return ctx.fail("{s}", .{c.err_msg});
    return 0;
}

pub fn default(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "default needs a .pgdb path", .{});
    var p = openPgdb(ctx, path) orelse return 1;
    if (args.positional.len < 2) {
        var buf: [256]u8 = undefined;
        var out = ctx.stdout(&buf);
        try out.interface.print("{s}\n", .{p.config.database});
        try out.interface.flush();
        return 0;
    }
    const name = args.positional[1];
    const r = ensureServer(ctx, p) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    const c = admin(ctx, p, r, "postgres") catch return 1;
    defer c.close();
    const n = (c.scalar(ctx.arena, try std.fmt.allocPrint(ctx.arena, "select count(*) from pg_database where datname = {s}", .{try literal(ctx.arena, name)})) catch
        return ctx.fail("{s}", .{c.err_msg})) orelse "0";
    if (std.mem.eql(u8, n, "0")) return ctx.fail("{s} has no database {s} (minipg create {s} {s})", .{ path, name, path, name });
    p.config.database = name;
    try p.save(ctx.arena, ctx.io);
    return 0;
}

pub fn passwd(ctx: Ctx, args: cli.Args) !u8 {
    const path = args.pgdb() orelse return usageError(ctx, "passwd needs a .pgdb path", .{});
    var p = openPgdb(ctx, path) orelse return 1;
    const r = ensureServer(ctx, p) catch |err| switch (err) {
        error.Reported => return 1,
        else => return err,
    };
    const c = admin(ctx, p, r, "postgres") catch return 1;
    defer c.close();
    const pw = ctx.getenv("POSTGRES_PASSWORD") orelse try pgdb_mod.generatePassword(ctx.arena, ctx.io);
    // Postgres hashes it with SCRAM before storing it (password_encryption).
    _ = c.query(ctx.arena, try std.fmt.allocPrint(ctx.arena, "alter role {s} password {s}", .{ try ident(ctx.arena, p.config.user), try literal(ctx.arena, pw) })) catch
        return ctx.fail("{s}", .{c.err_msg});
    p.config.password = pw;
    p.save(ctx.arena, ctx.io) catch |err| {
        // The role has the new password now; say it, so it isn't lost.
        ctx.warn("the password changed, but saving minipg.toml failed ({t}); the new password is {s}", .{ err, pw });
        return 1;
    };
    // The server's monitor logs in with the old one; it reconnects with
    // the new one after a restart. Existing sessions keep working.
    ctx.warn("password rotated; apps need the new URL (minipg url {s})", .{path});
    return 0;
}

pub fn versions(ctx: Ctx, args: cli.Args) !u8 {
    _ = args;
    const meta = try roots.embeddedMeta(ctx.arena);
    var buf: [1024]u8 = undefined;
    var out = ctx.stdout(&buf);
    const w = &out.interface;
    if (native) {
        try w.print("installed {s:<8} {s}\n", .{ meta.version, meta.digest });
        try w.flush();
        return 0;
    }
    try w.print("embedded  {s:<8} {s}\n", .{ meta.version, meta.digest });
    for (try roots.list(ctx)) |r| {
        if (std.mem.eql(u8, r.meta.digest, meta.digest)) continue;
        try w.print("cached    {s:<8} {s}\n", .{ r.meta.version, r.meta.digest });
    }
    try w.print("Other majors download on demand, or with minipg fetch MAJOR ({s}).\n", .{if (ctx.getenv("MINIPG_OFFLINE") != null) "off: MINIPG_OFFLINE is set" else @import("registry.zig").Source.fromEnv(ctx).host});
    try w.flush();
    return 0;
}

pub fn fetch(ctx: Ctx, args: cli.Args) !u8 {
    const m = args.pgdb() orelse return usageError(ctx, "fetch needs a Postgres major, such as 17", .{});
    const major = std.fmt.parseInt(u32, m, 10) catch return usageError(ctx, "fetch needs a Postgres major, such as 17", .{});
    if (ctx.getenv("MINIPG_OFFLINE") != null) return ctx.fail("MINIPG_OFFLINE is set", .{});
    if (native) return ctx.fail("this minipg runs the Postgres {d} it's installed with, and can't download others", .{(try roots.embeddedMeta(ctx.arena)).major});
    const r = @import("registry.zig").pull(ctx, major) catch |err| return ctx.fail("downloading Postgres {d}: {s}", .{ major, @import("registry.zig").describe(err) });
    var buf: [256]u8 = undefined;
    var out = ctx.stdout(&buf);
    try out.interface.print("Postgres {s} ({s})\n", .{ r.meta.version, r.meta.digest });
    try out.interface.flush();
    return 0;
}

pub fn prune(ctx: Ctx, args: cli.Args) !u8 {
    _ = args;
    if (native) return 0;
    const meta = try roots.embeddedMeta(ctx.arena);
    const keep = try roots.dirName(ctx.arena, meta.digest);
    var d = std.Io.Dir.cwd().openDir(ctx.io, ctx.dirs.roots, .{ .iterate = true }) catch return 0;
    defer d.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(ctx.io)) |e| {
        const base = if (std.mem.endsWith(u8, e.name, ".json")) e.name[0 .. e.name.len - 5] else e.name;
        if (std.mem.eql(u8, base, keep)) continue;
        try names.append(ctx.arena, try ctx.arena.dupe(u8, e.name));
    }
    for (names.items) |n| {
        d.deleteTree(ctx.io, n) catch |err| ctx.warn("removing {s}: {t}", .{ n, err });
        if (!std.mem.endsWith(u8, n, ".json")) ctx.warn("removed {s}", .{n});
    }
    return 0;
}
