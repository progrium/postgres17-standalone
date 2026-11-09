//! The control protocol between minipg commands and a running server, over
//! a unix socket in the .pgdb's runtime directory, and run.json, which
//! says where that socket is.
//!
//! A request is one line, `minipg/<protocol> <command> [args]`. The reply
//! starts with a line: `ok`, or `error <message>`; after `ok` comes the
//! command's output until the server closes the connection. Commands:
//!
//!   status          a JSON object (Status)
//!   stop            asks for a clean shutdown; replies at once
//!   logs [follow]   the log window; with follow, then new output until
//!                   the server exits or the client hangs up
//!   clients         the number of client connections
//!
//! A server refuses a request in another protocol version, naming both.

const std = @import("std");
const paths = @import("paths.zig");

pub const protocol: u32 = 1;

/// run.json: written by the server once its control socket listens,
/// removed when it exits. One for a .pgdb whose lock isn't held is stale.
pub const RunInfo = struct {
    pid: i32,
    port: u16,
    listen: []const u8,
    control: []const u8,
    protocol: u32,
    version: []const u8,
    pgdb: []const u8,
};

pub const Status = struct {
    /// starting, ready or stopping.
    state: []const u8,
    pid: i32,
    port: u16,
    listen: []const u8,
    /// Client connections, -1 before the server is ready.
    clients: i64,
    pg_version: []const u8,
    backend: []const u8,
    /// Unix seconds.
    started: i64,
    /// Seconds without clients before the server stops; 0 for never.
    idle_timeout: i64,
    version: []const u8,
    pgdb: []const u8,
};

pub fn runJsonPath(arena: std.mem.Allocator, runtime_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ runtime_dir, "run.json" });
}

pub fn socketPath(arena: std.mem.Allocator, runtime_dir: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ runtime_dir, "control.sock" });
}

pub fn readRunInfo(arena: std.mem.Allocator, io: std.Io, runtime_dir: []const u8) !RunInfo {
    const p = try runJsonPath(arena, runtime_dir);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 << 10));
    return std.json.parseFromSliceLeaky(RunInfo, arena, text, .{ .ignore_unknown_fields = true });
}

pub fn writeRunInfo(arena: std.mem.Allocator, io: std.Io, runtime_dir: []const u8, info: RunInfo) !void {
    const text = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(info, .{ .whitespace = .indent_2 })});
    try paths.writeAtomic(io, arena, try runJsonPath(arena, runtime_dir), text, 0o600);
}

pub const Error = error{
    /// The server answered `error <message>`; see `Reply.message`.
    Refused,
    /// No server is listening on the socket.
    NotRunning,
    Protocol,
};

pub const Reply = struct {
    ok: bool,
    /// The error message, or the output after `ok`.
    body: []const u8,
};

fn dial(io: std.Io, socket: []const u8) !std.Io.net.Stream {
    const ua = std.Io.net.UnixAddress.init(socket) catch return error.NotRunning;
    return ua.connect(io) catch return error.NotRunning;
}

/// Sends `command` and reads the whole reply.
pub fn request(arena: std.mem.Allocator, io: std.Io, socket: []const u8, command: []const u8) !Reply {
    const conn = try dial(io, socket);
    defer conn.close(io);
    var wbuf: [256]u8 = undefined;
    var w = conn.writer(io, &wbuf);
    try w.interface.print("minipg/{d} {s}\n", .{ protocol, command });
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    const all = r.interface.allocRemaining(arena, .limited(64 << 20)) catch |err| switch (err) {
        error.ReadFailed => return error.Protocol,
        else => |e| return e,
    };
    const nl = std.mem.indexOfScalar(u8, all, '\n') orelse return error.Protocol;
    const head = all[0..nl];
    if (std.mem.eql(u8, head, "ok")) return .{ .ok = true, .body = all[nl + 1 ..] };
    if (std.mem.startsWith(u8, head, "error ")) return .{ .ok = false, .body = head[6..] };
    return error.Protocol;
}

/// Sends `command` and copies the reply's output to `out` as it arrives,
/// for `logs follow`. Returns the error message if the server refused.
pub fn stream(arena: std.mem.Allocator, io: std.Io, socket: []const u8, command: []const u8, out: *std.Io.Writer) !?[]const u8 {
    const s = try dial(io, socket);
    defer s.close(io);
    var wbuf: [256]u8 = undefined;
    var w = s.writer(io, &wbuf);
    try w.interface.print("minipg/{d} {s}\n", .{ protocol, command });
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = s.reader(io, &rbuf);
    const head = (r.interface.takeDelimiter('\n') catch return error.Protocol) orelse return error.Protocol;
    if (std.mem.startsWith(u8, head, "error ")) return try arena.dupe(u8, head[6..]);
    if (!std.mem.eql(u8, head, "ok")) return error.Protocol;
    while (true) {
        _ = r.interface.stream(out, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => break,
        };
        out.flush() catch break;
    }
    out.flush() catch {};
    return null;
}

/// Parses a request line: its protocol version and the rest.
pub fn parseRequest(line: []const u8) ?struct { version: u32, command: []const u8 } {
    if (!std.mem.startsWith(u8, line, "minipg/")) return null;
    const rest = line["minipg/".len..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    const v = std.fmt.parseInt(u32, rest[0..sp], 10) catch return null;
    return .{ .version = v, .command = std.mem.trim(u8, rest[sp..], " \r") };
}

test parseRequest {
    const r = parseRequest("minipg/1 logs follow").?;
    try std.testing.expectEqual(@as(u32, 1), r.version);
    try std.testing.expectEqualStrings("logs follow", r.command);
    try std.testing.expectEqualStrings("status", parseRequest("minipg/2 status").?.command);
    try std.testing.expect(parseRequest("GET /") == null);
}
