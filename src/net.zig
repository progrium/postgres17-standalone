//! Host ports: whether one is free, and finding one that is.

const std = @import("std");
const c = std.c;
const sys = @import("sys.zig");

/// The address to reach a server listening on `listen` (Postgres's
/// listen_addresses) from this host: loopback for a wildcard or loopback
/// listen, the first address otherwise.
pub fn dialHost(listen: []const u8) []const u8 {
    const first = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, listen, ',')) |i| listen[0..i] else listen, " ");
    if (first.len == 0 or std.mem.eql(u8, first, "*") or std.mem.eql(u8, first, "0.0.0.0") or
        std.mem.eql(u8, first, "localhost") or std.mem.eql(u8, first, "::")) return "127.0.0.1";
    if (std.mem.eql(u8, first, "::1")) return "::1";
    return first;
}

/// The host for a client of a server described by `listen` and `socket`:
/// its unix socket's directory when it has no TCP listener, else
/// `dialHost(listen)`.
pub fn clientHost(listen: []const u8, socket: []const u8) []const u8 {
    if (socketOnly(listen) and socket.len > 0) return socket;
    return dialHost(listen);
}

/// Whether a listen setting is `none`: Postgres on its unix socket alone,
/// with no TCP listener (the Linux build only, where minipg and its
/// clients share Postgres's file system).
pub fn socketOnly(listen: []const u8) bool {
    const t = std.mem.trim(u8, listen, " ");
    return t.len == 0 or std.mem.eql(u8, t, "none");
}

/// Whether this host has TCP at all. h9's web host doesn't: a page has no
/// sockets, so the Linux build defaults to `--listen none` there.
pub fn tcpAvailable() bool {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return false;
    _ = c.close(fd);
    return portFree("127.0.0.1", 0);
}

/// Whether a listen address is loopback only.
pub fn isLoopback(listen: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, listen, ", ");
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "localhost") or std.mem.eql(u8, a, "::1")) continue;
        if (std.mem.startsWith(u8, a, "127.")) continue;
        return false;
    }
    return true;
}

fn bindable(addr: std.Io.net.IpAddress) bool {
    if (sys.is_windows) return bindableWindows(addr);
    var sa: c.sockaddr.in6 = undefined;
    var sa4: c.sockaddr.in = undefined;
    const fam: c_uint = switch (addr) {
        .ip4 => c.AF.INET,
        .ip6 => c.AF.INET6,
    };
    const fd = c.socket(fam, c.SOCK.STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    const rc = switch (addr) {
        .ip4 => |a| blk: {
            sa4 = std.mem.zeroes(c.sockaddr.in);
            sa4.family = c.AF.INET;
            sa4.port = std.mem.nativeToBig(u16, a.port);
            sa4.addr = @bitCast(a.bytes);
            break :blk c.bind(fd, @ptrCast(&sa4), @sizeOf(c.sockaddr.in));
        },
        .ip6 => |a| blk: {
            sa = std.mem.zeroes(c.sockaddr.in6);
            sa.family = c.AF.INET6;
            sa.port = std.mem.nativeToBig(u16, a.port);
            sa.addr = a.bytes;
            break :blk c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in6));
        },
    };
    return rc == 0;
}

/// The same with Winsock. Without SO_REUSEADDR, which on Windows would let
/// the bind take a port another socket holds.
fn bindableWindows(addr: std.Io.net.IpAddress) bool {
    const ws = struct {
        const SOCKET = usize;
        const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);
        const WSADATA = extern struct { data: [408]u8 };
        extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) i32;
        extern "ws2_32" fn socket(af: i32, kind: i32, proto: i32) callconv(.winapi) SOCKET;
        extern "ws2_32" fn bind(s: SOCKET, name: *const anyopaque, len: i32) callconv(.winapi) i32;
        extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    };
    const AF_INET = 2;
    const AF_INET6 = 23;
    const SOCK_STREAM = 1;
    var data: ws.WSADATA = undefined;
    // Counted: Winsock stays up for std's sockets after this.
    if (ws.WSAStartup(0x0202, &data) != 0) return false;
    const fd = ws.socket(if (addr == .ip4) AF_INET else AF_INET6, SOCK_STREAM, 0);
    if (fd == ws.INVALID_SOCKET) return false;
    defer _ = ws.closesocket(fd);
    // sockaddr_in and sockaddr_in6 have the same layout as on POSIX.
    var sa4 = std.mem.zeroes(extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 });
    var sa6 = std.mem.zeroes(extern struct { family: u16, port: u16, flowinfo: u32, addr: [16]u8, scope_id: u32 });
    const rc = switch (addr) {
        .ip4 => |a| blk: {
            sa4.family = AF_INET;
            sa4.port = std.mem.nativeToBig(u16, a.port);
            sa4.addr = a.bytes;
            break :blk ws.bind(fd, &sa4, @sizeOf(@TypeOf(sa4)));
        },
        .ip6 => |a| blk: {
            sa6.family = AF_INET6;
            sa6.port = std.mem.nativeToBig(u16, a.port);
            sa6.addr = a.bytes;
            break :blk ws.bind(fd, &sa6, @sizeOf(@TypeOf(sa6)));
        },
    };
    return rc == 0;
}

/// Whether Postgres could bind `port` on `listen`'s first address.
pub fn portFree(listen: []const u8, port: u16) bool {
    const first = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, listen, ',')) |i| listen[0..i] else listen, " ");
    const host = if (first.len == 0 or std.mem.eql(u8, first, "*")) "0.0.0.0" else if (std.mem.eql(u8, first, "localhost")) "127.0.0.1" else first;
    const addr = std.Io.net.IpAddress.parse(host, port) catch return false;
    return bindable(addr);
}

/// A free port on loopback and on all interfaces, chosen at random from
/// 54320-54999 so URLs look like Postgres's.
pub fn freePort() !u16 {
    var seed: u64 = @intCast(@as(u64, @bitCast(@as(i64, sys.pid()))) *% 2654435761);
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const p: u16 = 54320 + @as(u16, @intCast((seed >> 33) % 680));
        if (portFree("127.0.0.1", p) and portFree("0.0.0.0", p)) return p;
    }
    return error.NoFreePort;
}

test dialHost {
    try std.testing.expectEqualStrings("127.0.0.1", dialHost("*"));
    try std.testing.expectEqualStrings("127.0.0.1", dialHost("127.0.0.1"));
    try std.testing.expectEqualStrings("10.0.0.2", dialHost("10.0.0.2,127.0.0.1"));
    try std.testing.expect(isLoopback("127.0.0.1"));
    try std.testing.expect(isLoopback("localhost, ::1"));
    try std.testing.expect(!isLoopback("0.0.0.0"));
    try std.testing.expect(!isLoopback("*"));
    try std.testing.expect(socketOnly("none"));
    try std.testing.expect(socketOnly(""));
    try std.testing.expect(!socketOnly("127.0.0.1"));
}
