//! Finding a .pgdb's server, or starting one.
//!
//! Commands never host Postgres themselves. If the .pgdb's lock is held, a
//! server is running and run.json says where its control socket is.
//! Otherwise the command starts `minipg serve --background` as a separate
//! process in its own process group, waits for it to report ready, and
//! connects. That server stops after MINIPG_IDLE seconds without clients.

const std = @import("std");
const builtin = @import("builtin");
const Ctx = @import("ctx.zig").Ctx;
const pgdb_mod = @import("pgdb.zig");
const paths = @import("paths.zig");
const control = @import("control.zig");

const Pgdb = pgdb_mod.Pgdb;

/// The default idle timeout, in seconds.
pub const default_idle: i64 = 60;

pub const Running = struct {
    info: control.RunInfo,
    runtime: []const u8,
    /// The server this command started, if it did.
    child: ?std.process.Child = null,
};

pub fn runtimeDir(ctx: Ctx, p: Pgdb) ![]const u8 {
    return ctx.dirs.runtimeFor(ctx.arena, try paths.key(ctx.arena, p.path));
}

/// The running server's run.json, or null if none is running. A server
/// that holds the lock but hasn't written run.json yet is waited for.
pub fn find(ctx: Ctx, p: Pgdb) !?Running {
    const runtime = try runtimeDir(ctx, p);
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (!pgdb_mod.locked(ctx.arena, ctx.io, p)) return null;
        if (control.readRunInfo(ctx.arena, ctx.io, runtime)) |info| {
            // A killed server's guest processes can hold the lock for a few
            // seconds after it's gone; wait them out.
            if (alive(info.pid)) return .{ .info = info, .runtime = runtime };
            if (tries > 400) return error.StaleLock;
        } else |_| {
            if (tries > 100) return error.NoRunInfo;
        }
        try ctx.io.sleep(.fromMilliseconds(50), .awake);
    }
}

/// Whether `pid` is a live process: not gone, and not a zombie waiting
/// for a parent to reap it.
fn alive(pid: i32) bool {
    if (pid <= 0) return true;
    if (std.c.kill(pid, @enumFromInt(0)) != 0 and std.c._errno().* == @intFromEnum(std.c.E.SRCH)) return false;
    if (builtin.os.tag != .linux) return true;
    var path: [32:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return true;
    const fd = std.c.open(z, .{});
    if (fd < 0) return true;
    defer _ = std.c.close(fd);
    var buf: [512]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return true;
    // "pid (comm) S ...": the state follows the last ')'.
    const stat = buf[0..@intCast(n)];
    const i = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true;
    return !(i + 2 < stat.len and stat[i + 2] == 'Z');
}

/// Asks a running server for its status.
pub fn status(ctx: Ctx, r: Running) !control.Status {
    if (r.info.protocol != control.protocol) {
        ctx.warn("the server for {s} is minipg {s}, which speaks control protocol {d}; this minipg speaks {d}", .{ r.info.pgdb, r.info.version, r.info.protocol, control.protocol });
        return error.ProtocolMismatch;
    }
    const reply = try control.request(ctx.arena, ctx.io, r.info.control, "status");
    if (!reply.ok) {
        ctx.warn("server: {s}", .{reply.body});
        return error.Refused;
    }
    return std.json.parseFromSliceLeaky(control.Status, ctx.arena, reply.body, .{ .ignore_unknown_fields = true });
}

pub const EnsureOptions = struct {
    idle_timeout: i64 = default_idle,
};

/// The running server, or a new background one, once it's ready.
pub fn ensure(ctx: Ctx, p: Pgdb, opts: EnsureOptions) !Running {
    if (try find(ctx, p)) |r| {
        try waitReady(ctx, r, null);
        return r;
    }
    var r: Running = .{ .info = undefined, .runtime = try runtimeDir(ctx, p) };
    r.child = try spawn(ctx, p, opts);
    // Wait for run.json, then for ready.
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (try exited(&r.child.?)) |code| return serverFailed(ctx, p, code);
        if (control.readRunInfo(ctx.arena, ctx.io, r.runtime)) |info| {
            if (info.pid == r.child.?.id.?) {
                r.info = info;
                break;
            }
        } else |_| {}
        if (tries > 600) return error.ServerTimeout;
        try ctx.io.sleep(.fromMilliseconds(50), .awake);
    }
    try waitReady(ctx, r, p);
    return r;
}

fn spawn(ctx: Ctx, p: Pgdb, opts: EnsureOptions) !std.process.Child {
    const self = try std.process.executablePathAlloc(ctx.io, ctx.arena);
    const idle = try std.fmt.allocPrint(ctx.arena, "--idle={d}", .{opts.idle_timeout});
    return std.process.spawn(ctx.io, .{
        .argv = &.{ self, "serve", "--background", idle, p.path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        // Its own process group, so a Ctrl-C meant for psql doesn't stop it.
        .pgid = 0,
    });
}

/// The exit code of a child that has exited, without waiting.
fn exited(child: *std.process.Child) !?u8 {
    const pid = child.id orelse return 0;
    var st: c_int = 0;
    const rc = std.c.waitpid(pid, &st, std.c.W.NOHANG);
    if (rc == 0) return null;
    child.id = null;
    if (rc < 0) return 1;
    const u: u32 = @bitCast(st);
    return if (std.c.W.IFEXITED(u)) std.c.W.EXITSTATUS(u) else 1;
}

fn serverFailed(ctx: Ctx, p: Pgdb, code: u8) error{ServerFailed} {
    ctx.warn("the server for {s} failed to start (exit {d}); its log ends:", .{ p.path, code });
    printLogTail(ctx, p, 20);
    return error.ServerFailed;
}

/// Prints the last `n` lines of the .pgdb's default log file.
pub fn printLogTail(ctx: Ctx, p: Pgdb, n: usize) void {
    const key = paths.key(ctx.arena, p.path) catch return;
    const path = ctx.dirs.logFor(ctx.arena, key) catch return;
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 << 20)) catch return;
    var start = text.len;
    var lines: usize = 0;
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    start = trimmed.len;
    while (start > 0 and lines < n) {
        start -= 1;
        if (trimmed[start] == '\n') lines += 1;
    }
    if (start > 0) start += 1;
    std.debug.print("{s}\n", .{trimmed[start..]});
}

/// Polls the server's status until it's ready. `starting` is the .pgdb when
/// this command started the server, to tell the user about a first start.
fn waitReady(ctx: Ctx, r: Running, starting: ?Pgdb) !void {
    var tries: u32 = 0;
    var said = false;
    // A first start unpacks the root and runs initdb: allow minutes.
    while (tries < 3000) : (tries += 1) {
        if (r.child) |ch| {
            var copy = ch;
            if (try exited(&copy)) |code| return serverFailed(ctx, starting.?, code);
        }
        if (status(ctx, r)) |st| {
            if (std.mem.eql(u8, st.state, "ready")) return;
            if (std.mem.eql(u8, st.state, "stopping")) return error.ServerStopping;
        } else |err| switch (err) {
            error.ProtocolMismatch => return err,
            else => {},
        }
        if (tries == 50 and !said) {
            said = true;
            ctx.warn("waiting for the server for {s} to start...", .{r.info.pgdb});
        }
        try ctx.io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.ServerTimeout;
}

/// Asks the server to stop and waits until its lock is free.
pub fn stop(ctx: Ctx, p: Pgdb, r: Running) !void {
    const reply = try control.request(ctx.arena, ctx.io, r.info.control, "stop");
    if (!reply.ok) {
        ctx.warn("server: {s}", .{reply.body});
        return error.Refused;
    }
    // Postgres's fast shutdown, or the 30s limit after which the server
    // stops the machine.
    var tries: u32 = 0;
    while (pgdb_mod.locked(ctx.arena, ctx.io, p)) : (tries += 1) {
        if (tries > 400) return error.StopTimeout;
        try ctx.io.sleep(.fromMilliseconds(100), .awake);
    }
}
