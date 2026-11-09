//! What every command gets: allocators, io, the environment and minipg's
//! directories.

const std = @import("std");
const paths = @import("paths.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    dirs: paths.Dirs,
    version: []const u8,

    /// Prints a message to stderr, prefixed with `minipg: `.
    pub fn warn(_: Ctx, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("minipg: " ++ fmt ++ "\n", args);
    }

    /// Prints a message to stderr and returns exit code 1.
    pub fn fail(c: Ctx, comptime fmt: []const u8, args: anytype) u8 {
        c.warn(fmt, args);
        return 1;
    }

    pub fn getenv(c: Ctx, name: []const u8) ?[]const u8 {
        const v = c.env.get(name) orelse return null;
        return if (v.len > 0) v else null;
    }

    pub fn stdout(c: Ctx, buf: []u8) std.Io.File.Writer {
        return std.Io.File.stdout().writerStreaming(c.io, buf);
    }
};
