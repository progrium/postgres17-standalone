//! The .pgdb: a directory holding one Postgres cluster, its config and its
//! credentials.
//!
//!   app.pgdb/
//!     minipg.toml   settings and the generated password (config.zig)
//!     pgdata/       Postgres's data directory, as plain files
//!     .lock         held by the server for its whole life
//!
//! A directory is a .pgdb when it has minipg.toml and pgdata/PG_VERSION.
//! One with minipg.toml alone was created but never started; the next
//! server start initializes its cluster.

const std = @import("std");
const config = @import("config.zig");
const paths = @import("paths.zig");

pub const Config = config.Config;

pub const toml_name = "minipg.toml";

pub const OpenError = error{
    /// Nothing at the path.
    NotFound,
    /// Something is there, but it's not a .pgdb.
    NotPgdb,
    /// minipg.toml is unreadable or malformed.
    BadConfig,
    /// The .pgdb's format is newer than this minipg's.
    NewerFormat,
};

pub const Pgdb = struct {
    /// Absolute, symlinks resolved.
    path: []const u8,
    config: Config,

    pub fn sub(p: Pgdb, arena: std.mem.Allocator, file: []const u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ p.path, file });
    }

    /// Whether the cluster has been initialized: pgdata/PG_VERSION exists.
    pub fn initialized(p: Pgdb, arena: std.mem.Allocator, io: std.Io) bool {
        const v = p.sub(arena, "pgdata/PG_VERSION") catch return false;
        std.Io.Dir.cwd().access(io, v, .{}) catch return false;
        return true;
    }

    /// The major in pgdata/PG_VERSION.
    pub fn dataMajor(p: Pgdb, arena: std.mem.Allocator, io: std.Io) !u32 {
        const v = try p.sub(arena, "pgdata/PG_VERSION");
        const text = try std.Io.Dir.cwd().readFileAlloc(io, v, arena, .limited(64));
        return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \r\n"), 10);
    }

    pub fn save(p: Pgdb, arena: std.mem.Allocator, io: std.Io) !void {
        var buf: std.Io.Writer.Allocating = .init(arena);
        try p.config.write(&buf.writer);
        try paths.writeAtomic(io, arena, try p.sub(arena, toml_name), buf.written(), 0o600);
    }

    /// The name people know it by: the path as given, or its base name.
    pub fn name(p: Pgdb) []const u8 {
        return std.fs.path.basename(p.path);
    }
};

/// Resolves `path` to an absolute path, following symlinks when it exists.
pub fn absolute(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch {
        const cwd = try std.process.currentPathAlloc(io, arena);
        return std.fs.path.resolve(arena, &.{ cwd, path });
    };
}

pub fn open(arena: std.mem.Allocator, io: std.Io, path: []const u8) (OpenError || error{OutOfMemory})!Pgdb {
    const cwd = std.Io.Dir.cwd();
    const abs = cwd.realPathFileAlloc(io, path, arena) catch return error.NotFound;
    var dir = cwd.openDir(io, abs, .{}) catch return error.NotPgdb;
    dir.close(io);
    const text = cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ abs, toml_name }), arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.NotPgdb,
        else => return error.BadConfig,
    };
    const c = Config.parse(arena, text) catch return error.BadConfig;
    if (c.format > config.format_version) return error.NewerFormat;
    if (c.format == 0) return error.BadConfig;
    return .{ .path = abs, .config = c };
}

/// Creates the .pgdb directory and its minipg.toml. Refuses if anything
/// exists at `path`.
pub fn create(arena: std.mem.Allocator, io: std.Io, path: []const u8, c: Config) !Pgdb {
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, path, .{})) |_| return error.PathAlreadyExists else |_| {}
    try cwd.createDir(io, path, .default_dir);
    errdefer cwd.deleteTree(io, path) catch {};
    _ = std.c.chmod(try arena.dupeZ(u8, path), 0o700);
    const p: Pgdb = .{ .path = try cwd.realPathFileAlloc(io, path, arena), .config = c };
    try p.save(arena, io);
    return p;
}

/// The default database name for a .pgdb path: its file name without the
/// extension (app.pgdb is "app").
pub fn defaultDatabase(path: []const u8) []const u8 {
    const base = std.fs.path.basename(std.mem.trimEnd(u8, path, "/"));
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| (if (dot > 0) base[0..dot] else base) else base;
    return if (stem.len == 0) "app" else stem;
}

/// A password for the superuser: 24 random letters and digits.
pub fn generatePassword(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var raw: [24]u8 = undefined;
    io.random(&raw);
    const out = try arena.alloc(u8, raw.len);
    for (out, raw) |*o, r| o.* = alphabet[r % alphabet.len];
    return out;
}

/// The .pgdb's lock: held by its server for its whole life. The OS drops
/// it when the process dies, even on kill -9.
pub fn tryLock(arena: std.mem.Allocator, io: std.Io, p: Pgdb) !?std.Io.File {
    const f = try std.Io.Dir.cwd().createFile(io, try p.sub(arena, ".lock"), .{ .truncate = false });
    if (f.tryLock(io, .exclusive) catch false) return f;
    f.close(io);
    return null;
}

/// Whether a server holds the lock right now.
pub fn locked(arena: std.mem.Allocator, io: std.Io, p: Pgdb) bool {
    const f = (tryLock(arena, io, p) catch return false) orelse return true;
    f.close(io);
    return false;
}

test defaultDatabase {
    try std.testing.expectEqualStrings("app", defaultDatabase("app.pgdb"));
    try std.testing.expectEqualStrings("my.data", defaultDatabase("/x/my.data.pgdb"));
    try std.testing.expectEqualStrings("app", defaultDatabase("dir/app.pgdb/"));
    try std.testing.expectEqualStrings("plain", defaultDatabase("plain"));
}
