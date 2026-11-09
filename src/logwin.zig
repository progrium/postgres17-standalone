//! The server's log: Postgres's stdout and stderr, kept in a capped window
//! in memory (what `minipg logs` shows), written in full to a log file, and
//! echoed to the terminal when `serve` runs in the foreground.

const std = @import("std");

/// The default window size.
pub const default_size = 4 << 20;

pub const Log = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    ring: []u8,
    /// Bytes written since the start; the window holds the last
    /// min(total, ring.len) of them.
    total: u64 = 0,
    file: ?std.Io.File = null,
    echo: ?std.Io.File = null,
    interface: std.Io.Writer,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, size: usize) !*Log {
        const l = try gpa.create(Log);
        l.* = .{
            .io = io,
            .ring = try gpa.alloc(u8, size),
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
        return l;
    }

    /// Adds bytes to the window, the file and the echo.
    pub fn put(l: *Log, bytes: []const u8) void {
        if (bytes.len == 0) return;
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        var b = bytes;
        if (b.len > l.ring.len) b = b[b.len - l.ring.len ..];
        const start: usize = @intCast((l.total + (bytes.len - b.len)) % l.ring.len);
        const first = @min(b.len, l.ring.len - start);
        @memcpy(l.ring[start..][0..first], b[0..first]);
        @memcpy(l.ring[0 .. b.len - first], b[first..]);
        l.total += bytes.len;
        if (l.file) |f| f.writeStreamingAll(l.io, bytes) catch {};
        if (l.echo) |f| f.writeStreamingAll(l.io, bytes) catch {};
    }

    /// Appends the bytes written since position `pos` that are still in the
    /// window to `out`, and returns the position to read from next.
    pub fn readSince(l: *Log, gpa: std.mem.Allocator, pos: u64, out: *std.ArrayList(u8)) !u64 {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        const oldest = l.total -| l.ring.len;
        const from = @max(pos, oldest);
        if (from >= l.total) return l.total;
        const len: usize = @intCast(l.total - from);
        const start: usize = @intCast(from % l.ring.len);
        const first = @min(len, l.ring.len - start);
        try out.appendSlice(gpa, l.ring[start..][0..first]);
        try out.appendSlice(gpa, l.ring[0 .. len - first]);
        return l.total;
    }

    pub fn position(l: *Log) u64 {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        return l.total;
    }

    /// Writes a line of minipg's own to the log.
    pub fn note(l: *Log, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "minipg: " ++ fmt ++ "\n", args) catch return;
        l.put(s);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const l: *Log = @alignCast(@fieldParentPtr("interface", w));
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            l.put(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| l.put(last);
        return n + last.len * splat;
    }
};

test Log {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const l = try Log.init(gpa, io, 8);
    defer {
        gpa.free(l.ring);
        gpa.destroy(l);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try l.interface.writeAll("hello");
    var pos = try l.readSince(gpa, 0, &out);
    try std.testing.expectEqualStrings("hello", out.items);
    try l.interface.print("{s}", .{" world!"});
    out.clearRetainingCapacity();
    pos = try l.readSince(gpa, pos, &out);
    try std.testing.expectEqualStrings(" world!", out.items);
    try std.testing.expectEqual(@as(u64, 12), pos);
    out.clearRetainingCapacity();
    // The window keeps the last 8 bytes, so the first 4 are gone.
    _ = try l.readSince(gpa, 0, &out);
    try std.testing.expectEqualStrings("o world!", out.items);
}
