//! Where minipg keeps things outside the .pgdb: runtime state (run.json,
//! the control socket), logs, and the root cache. The .pgdb itself holds
//! only data and config.
//!
//!   what        Linux                                macOS
//!   runtime     $XDG_RUNTIME_DIR/minipg/<key>/       $TMPDIR/minipg-$UID/<key>/
//!   logs        ~/.local/state/minipg/logs/<key>.log ~/Library/Logs/minipg/<key>.log
//!   roots       ~/.cache/minipg/roots/<digest>/      ~/Library/Caches/minipg/roots/<digest>/
//!
//! <key> is a hash of the .pgdb directory's device and inode, so it
//! follows the directory through renames. Linux falls back to
//! ~/.cache/minipg/run/ without XDG_RUNTIME_DIR, and honors XDG_STATE_HOME
//! and XDG_CACHE_HOME. Runtime directories are mode 0700.

const std = @import("std");
const builtin = @import("builtin");

const Environ = std.process.Environ;

pub const Dirs = struct {
    /// Parent of the per-.pgdb runtime directories.
    runtime: []const u8,
    /// Directory of per-.pgdb log files.
    logs: []const u8,
    /// The root cache.
    roots: []const u8,

    pub fn runtimeFor(d: Dirs, arena: std.mem.Allocator, k: []const u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ d.runtime, k });
    }

    pub fn logFor(d: Dirs, arena: std.mem.Allocator, k: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}.log", .{ d.logs, k });
    }
};

fn get(env: *const Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len > 0) v else null;
}

pub fn dirs(arena: std.mem.Allocator, env: *const Environ.Map) !Dirs {
    const home = get(env, "HOME") orelse return error.NoHomeDir;
    if (builtin.os.tag == .macos) {
        const tmp = get(env, "TMPDIR") orelse "/tmp";
        return .{
            .runtime = try std.fmt.allocPrint(arena, "{s}/minipg-{d}", .{ std.mem.trimEnd(u8, tmp, "/"), std.c.getuid() }),
            .logs = try std.fs.path.join(arena, &.{ home, "Library/Logs/minipg" }),
            .roots = try std.fs.path.join(arena, &.{ home, "Library/Caches/minipg/roots" }),
        };
    }
    const cache = get(env, "XDG_CACHE_HOME") orelse try std.fs.path.join(arena, &.{ home, ".cache" });
    const state = get(env, "XDG_STATE_HOME") orelse try std.fs.path.join(arena, &.{ home, ".local/state" });
    const runtime = if (get(env, "XDG_RUNTIME_DIR")) |r|
        try std.fs.path.join(arena, &.{ r, "minipg" })
    else
        try std.fs.path.join(arena, &.{ cache, "minipg/run" });
    return .{
        .runtime = runtime,
        .logs = try std.fs.path.join(arena, &.{ state, "minipg/logs" }),
        .roots = try std.fs.path.join(arena, &.{ cache, "minipg/roots" }),
    };
}

/// The key for a .pgdb directory: its device and inode, hashed.
pub fn key(arena: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const z = try arena.dupeZ(u8, dir);
    var h: std.hash.Wyhash = .init(0);
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .INO = true }, &st)) != .SUCCESS) return error.FileNotFound;
        h.update(std.mem.asBytes(&st.dev_major));
        h.update(std.mem.asBytes(&st.dev_minor));
        h.update(std.mem.asBytes(&st.ino));
        return std.fmt.allocPrint(arena, "{x:0>16}", .{h.final()});
    }
    var st: std.c.Stat = undefined;
    if (std.c.stat(z, &st) != 0) return error.FileNotFound;
    h.update(std.mem.asBytes(&st.dev));
    h.update(std.mem.asBytes(&st.ino));
    return std.fmt.allocPrint(arena, "{x:0>16}", .{h.final()});
}

/// Creates `path` and its parents, and makes `path` itself mode 0700.
pub fn makePrivateDir(io: std.Io, arena: std.mem.Allocator, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
    const z = try arena.dupeZ(u8, path);
    _ = std.c.chmod(z, 0o700);
}

/// Writes `data` to `path` through a temporary file and a rename, so
/// readers see the old contents or the new, never part.
pub fn writeAtomic(io: std.Io, arena: std.mem.Allocator, path: []const u8, data: []const u8, mode: std.c.mode_t) !void {
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp{d}", .{ path, std.c.getpid() });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data });
    _ = std.c.chmod(try arena.dupeZ(u8, tmp), mode);
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
}

test key {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = try key(arena.allocator(), "/");
    try std.testing.expectEqual(@as(usize, 16), a.len);
    try std.testing.expectEqualStrings(a, try key(arena.allocator(), "/"));
}
