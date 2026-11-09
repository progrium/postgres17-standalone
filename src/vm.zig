//! h9 machines: the server machine that runs Postgres over a .pgdb, and the
//! short-lived tool machines that run psql, pg_dump and the rest against
//! it over loopback. Both use the same root; writes outside the machine's
//! cwd go to an overlay in memory and vanish when it exits.
//!
//! The Linux build (`-Dhost=linux`) runs inside the Postgres image, so the
//! same two runs are ordinary processes there: the server in its own
//! process group with its output in the log, and a tool in the
//! foreground with the caller's terminal.

const std = @import("std");
const h9 = @import("h9");
const native = @import("build_options").native;
const host = @import("host.zig");
const root_mod = @import("roots.zig");

/// The .pgdb directory as the server sees it: the machine's cwd, or in the
/// Linux build the directory itself.
pub fn guestPgdb(arena: std.mem.Allocator, pgdb: []const u8) ![]const u8 {
    return if (native) arena.dupe(u8, pgdb) else "/mnt/term/cwd";
}

/// Postgres's data directory: `pgdata` in the .pgdb.
pub fn guestPgdata(arena: std.mem.Allocator, pgdb: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/pgdata", .{try guestPgdb(arena, pgdb)});
}

/// Guest memory for the server machine (the POC's figure).
pub const server_memory: u64 = 2 << 30;
/// Guest memory for a tool machine.
pub const tool_memory: u64 = 1 << 30;

/// The image's environment as h9 env vars, with `extra` overriding it.
pub fn environment(arena: std.mem.Allocator, meta: root_mod.Meta, extra: []const h9.EnvVar) ![]const h9.EnvVar {
    var vars: std.ArrayList(h9.EnvVar) = .empty;
    outer: for (meta.env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        const name = e[0..eq];
        for (extra) |x| if (std.mem.eql(u8, x.name, name)) continue :outer;
        try vars.append(arena, .{ .name = name, .value = e[eq + 1 ..] });
    }
    // An image without ENV (a local tree) still needs a PATH.
    var has_path = false;
    for (vars.items) |v| has_path = has_path or std.mem.eql(u8, v.name, "PATH");
    for (extra) |x| has_path = has_path or std.mem.eql(u8, x.name, "PATH");
    if (!has_path) try vars.append(arena, .{ .name = "PATH", .value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" });
    try vars.appendSlice(arena, extra);
    return vars.items;
}

/// A Linux exit status from a machine's run, as a process exit code.
pub fn exitCode(status: h9.Status) u8 {
    return switch (status) {
        .exited => |msg| if (msg.len == 0) 0 else std.fmt.parseInt(u8, msg, 10) catch 1,
        .killed => 1,
    };
}

/// The backend machines run on. h9's `auto` never picks its native
/// backend, which isn't a security boundary against a hostile guest. minipg
/// runs only the image's own Postgres binaries, so where there's no
/// hypervisor it asks for native, as Linux CI runners and containers need.
pub fn backend() h9.vmm.BackendKind {
    if (h9.vmm.whyUnavailable(.auto) == null) return .auto;
    if (h9.vmm.whyUnavailable(.native) == null) return .native;
    return .auto;
}

fn unavailable(err: anyerror) []const u8 {
    return h9.vmm.whyUnavailable(.auto) orelse @errorName(err);
}

pub const ServerRun = struct {
    root: root_mod.Root,
    /// The .pgdb directory, absolute and resolved.
    pgdb: []const u8,
    env: []const h9.EnvVar,
    /// The program: the image's entrypoint unless said otherwise.
    prog: []const u8 = "/usr/local/bin/docker-entrypoint.sh",
    argv: []const []const u8,
    /// Receives Postgres's stdout and stderr.
    log: *std.Io.Writer,
    signals: *h9.Machine.Signals,
    /// The machine's console input, if any.
    in: ?*std.Io.Reader = null,
    in_cancel: ?h9.consin.Cancel = null,
};

pub const RunResult = struct {
    status: ?h9.Status,
    /// Why the run couldn't start or failed, when `status` is null.
    err_msg: []const u8 = "",
    stuck: bool = false,
};

/// Runs Postgres in a server machine until it exits.
pub fn runServer(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, r: ServerRun) RunResult {
    return if (native) runServerProcess(io, arena, r) else runServerMachine(gpa, io, arena, r);
}

fn runServerMachine(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, r: ServerRun) RunResult {
    const opts: h9.Machine.Options = .{
        .backend = backend(),
        .linux_root = r.root.dir,
        .cwd = r.pgdb,
        .env = r.env,
        .guest_tools = false,
        .builtin = .off,
        .console_tty = false,
        .policy = .{
            // Postgres listens on the host's own ports.
            .net = .enable,
            .cwd_writable = true,
            .memory = server_memory,
        },
        .signals = r.signals,
        .stdio = .{ .out = r.log, .err = r.log, .in = r.in, .in_cancel = r.in_cancel },
    };
    var machine = h9.Machine.init(gpa, io, opts) catch |err|
        return .{ .status = null, .err_msg = std.fmt.allocPrint(arena, "cannot create a machine: {s} ({t})", .{ unavailable(err), err }) catch "cannot create a machine" };
    defer machine.deinit();
    const prog: h9.Program = .{ .guest = r.prog };
    const status = machine.run(prog, r.argv) catch |err| {
        const msg = if (machine.err_msg.len > 0) machine.err_msg else @errorName(err);
        return .{ .status = null, .stuck = machine.stuck, .err_msg = std.fmt.allocPrint(arena, "{s}: {s}", .{ prog.guest, msg }) catch "run failed" };
    };
    return .{ .status = status, .stuck = machine.stuck };
}

pub const ToolRun = struct {
    root: root_mod.Root,
    /// The host directory the tool sees as its cwd: the caller's.
    cwd: []const u8,
    env: []const h9.EnvVar,
    argv: []const []const u8,
    /// Stdin instead of the caller's (restore's dump file); never a terminal.
    in: ?*host.Stdin = null,
};

/// Runs a tool such as psql in a fresh machine with the caller's stdio,
/// and returns its exit code.
pub fn runTool(gpa: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, r: ToolRun) !u8 {
    return if (native) runToolProcess(io, env_map, r) else runToolMachine(gpa, io, env_map, r);
}

fn runToolMachine(gpa: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map, r: ToolRun) !u8 {
    var terminal: host.Terminal = .{};
    defer terminal.restore();
    const tty = r.in == null and (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);

    var sig: host.Signals = undefined;
    try sig.init(io, .tool, null);
    defer sig.deinit();

    var in_buf: [4096]u8 = undefined;
    var stdin: host.Stdin = undefined;
    stdin.init(&in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    var err_w = std.Io.File.stderr().writerStreaming(io, &.{});

    var env: std.ArrayList(h9.EnvVar) = .empty;
    defer env.deinit(gpa);
    try env.appendSlice(gpa, r.env);
    if (tty) try env.append(gpa, .{ .name = "TERM", .value = env_map.get("TERM") orelse "xterm" });

    const opts: h9.Machine.Options = .{
        .backend = backend(),
        .linux_root = r.root.dir,
        .cwd = r.cwd,
        .env = env.items,
        .guest_tools = false,
        .builtin = .off,
        .console_tty = tty,
        .policy = .{
            .net = .enable,
            .cwd_writable = true,
            .memory = tool_memory,
        },
        .signals = &sig.machine,
        .stdio = .{
            .in = if (r.in) |i| &i.interface else &stdin.interface,
            .in_cancel = if (r.in) |i| i.cancelHook() else stdin.cancelHook(),
            .out = &out.interface,
            .err = &err_w.interface,
            .raw = if (tty) terminal.hook() else null,
        },
    };
    var machine = h9.Machine.init(gpa, io, opts) catch |err| {
        std.debug.print("minipg: cannot create a machine: {s} ({t})\n", .{ unavailable(err), err });
        return 1;
    };
    defer machine.deinit();
    const status = machine.run(.{ .guest = r.argv[0] }, r.argv) catch |err| {
        if (machine.stuck) {
            terminal.restore();
            std.process.exit(1);
        }
        switch (err) {
            error.NotFound => {
                std.debug.print("minipg: {s}: not found in the Postgres root\n", .{r.argv[0]});
                return 127;
            },
            else => {
                std.debug.print("minipg: {s}: {s}\n", .{ r.argv[0], if (machine.err_msg.len > 0) machine.err_msg else @errorName(err) });
                return 1;
            },
        }
    };
    const code = exitCode(status);
    if (machine.stuck) {
        terminal.restore();
        std.process.exit(code);
    }
    return code;
}

// The Linux build's runs, as processes.

/// An exit status as h9 reports one, for `exitCode`.
fn statusOf(arena: std.mem.Allocator, term: std.process.Child.Term) h9.Status {
    return switch (term) {
        .exited => |code| .{ .exited = if (code == 0) "" else std.fmt.allocPrint(arena, "{d}", .{code}) catch "1" },
        .signal => |sig| .{ .killed = std.fmt.allocPrint(arena, "signal {d}", .{@intFromEnum(sig)}) catch "signal" },
        else => .{ .killed = "stopped" },
    };
}

fn pipeCloexec() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.SystemResources;
    for (fds) |fd| _ = std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC));
    return fds;
}

fn fileOf(fd: std.posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Copies what `fd` reads into `w` until end of file, then closes `fd`.
fn pumpOut(fd: std.posix.fd_t, w: *std.Io.Writer) void {
    defer _ = std.c.close(fd);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return;
        }
        if (n == 0) return;
        w.writeAll(buf[0..@intCast(n)]) catch return;
        w.flush() catch return;
    }
}

/// Copies `r` to `fd` until `r` ends or fails (a cancel), then closes `fd`.
fn pumpIn(r: *std.Io.Reader, fd: std.posix.fd_t) void {
    defer _ = std.c.close(fd);
    // A write after the process has exited fails with EPIPE; SIGPIPE,
    // which is this thread's, stays blocked rather than ending minipg.
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, .PIPE);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);
    while (true) {
        const data = r.peekGreedy(1) catch return;
        var off: usize = 0;
        while (off < data.len) {
            const n = std.c.write(fd, data[off..].ptr, data.len - off);
            if (n < 0) {
                if (std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
                return;
            }
            off += @intCast(n);
        }
        r.toss(data.len);
    }
}

fn envMap(arena: std.mem.Allocator, base: ?*const std.process.Environ.Map, vars: []const h9.EnvVar) !std.process.Environ.Map {
    var m: std.process.Environ.Map = if (base) |b| try b.clone(arena) else .init(arena);
    for (vars) |v| try m.put(v.name, v.value);
    return m;
}

fn runServerProcess(io: std.Io, arena: std.mem.Allocator, r: ServerRun) RunResult {
    return runServerProcessImpl(io, arena, r) catch |err| .{ .status = null, .err_msg = std.fmt.allocPrint(arena, "{s}: {t}", .{ r.prog, err }) catch "run failed" };
}

fn runServerProcessImpl(io: std.Io, arena: std.mem.Allocator, r: ServerRun) !RunResult {
    var env = try envMap(arena, null, r.env);
    const argv = try arena.dupe([]const u8, r.argv);
    argv[0] = r.prog;

    const out = try pipeCloexec();
    const in: ?[2]std.posix.fd_t = if (r.in != null) try pipeCloexec() else null;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = r.pgdb },
        .environ_map = &env,
        .stdin = if (in) |p| .{ .file = fileOf(p[0]) } else .ignore,
        .stdout = .{ .file = fileOf(out[1]) },
        .stderr = .{ .file = fileOf(out[1]) },
        // Its own process group, so stopping it reaches everything it
        // started, as a machine's exit does.
        .pgid = 0,
    }) catch |err| {
        _ = std.c.close(out[0]);
        _ = std.c.close(out[1]);
        if (in) |p| for (p) |fd| {
            _ = std.c.close(fd);
        };
        return err;
    };
    _ = std.c.close(out[1]);
    if (in) |p| _ = std.c.close(p[0]);
    const pid = child.id.?;
    r.signals.pid.store(pid, .release);

    const out_thread = try std.Thread.spawn(.{}, pumpOut, .{ out[0], r.log });
    var in_thread: ?std.Thread = null;
    if (in) |p| in_thread = try std.Thread.spawn(.{}, pumpIn, .{ r.in.?, p[1] });

    const term = child.wait(io) catch std.process.Child.Term{ .unknown = 0 };
    r.signals.pid.store(0, .release);
    // Whatever it left running (the supervisor's stop reader), as a
    // machine's exit would.
    _ = std.c.kill(-pid, .KILL);
    out_thread.join();
    if (in_thread) |t| {
        if (r.in_cancel) |c| c.func(c.ctx, t);
        t.join();
    }
    return .{ .status = statusOf(arena, term) };
}

fn runToolProcess(io: std.Io, env_map: *const std.process.Environ.Map, r: ToolRun) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The caller's environment (HOME, TERM, PAGER and the rest), with the
    // image's and the connection's on top.
    var env = try envMap(arena, env_map, r.env);

    // A tool's own stdin: through a pipe, since the reader may hold what
    // was peeked from it already.
    const in: ?[2]std.posix.fd_t = if (r.in != null) try pipeCloexec() else null;
    var child = std.process.spawn(io, .{
        .argv = r.argv,
        .cwd = .{ .path = r.cwd },
        .environ_map = &env,
        .stdin = if (in) |p| .{ .file = fileOf(p[0]) } else .inherit,
    }) catch |err| {
        if (in) |p| for (p) |fd| {
            _ = std.c.close(fd);
        };
        if (err == error.FileNotFound) {
            std.debug.print("minipg: {s}: not found\n", .{r.argv[0]});
            return 127;
        }
        std.debug.print("minipg: {s}: {t}\n", .{ r.argv[0], err });
        return 1;
    };
    var in_thread: ?std.Thread = null;
    if (in) |p| {
        _ = std.c.close(p[0]);
        in_thread = try std.Thread.spawn(.{}, pumpIn, .{ &r.in.?.interface, p[1] });
    }
    // The terminal's Ctrl-C reaches the tool, in the foreground; minipg
    // only waits, as a shell does.
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var old: [2]std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &ignore, &old[0]);
    std.posix.sigaction(.QUIT, &ignore, &old[1]);
    defer {
        std.posix.sigaction(.INT, &old[0], null);
        std.posix.sigaction(.QUIT, &old[1], null);
    }
    const term = try child.wait(io);
    if (in_thread) |t| {
        r.in.?.cancelHook().func(r.in.?, t);
        t.join();
    }
    return exitCode(statusOf(arena, term));
}
