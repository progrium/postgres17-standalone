//! Postgres roots: Alpine trees with Postgres in them, which h9 serves as
//! the Linux root. The binary embeds one (scripts/root.sh makes it) for its
//! own architecture; it is unpacked once into the root cache, in a
//! directory named after the image's digest.

const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");

/// The default major's root, an xz-compressed tarball.
const embedded_tar = @embedFile("root_tar");
/// What scripts/root.sh recorded about it.
const embedded_meta = @embedFile("root_meta");

/// The host's architecture, in Docker's names.
pub const host_arch: []const u8 = switch (builtin.cpu.arch) {
    .x86_64 => "amd64",
    .aarch64 => "arm64",
    else => @compileError("minipg runs on x86_64 and aarch64 hosts only"),
};

pub const Meta = struct {
    arch: []const u8,
    ref: []const u8 = "",
    digest: []const u8,
    version: []const u8,
    major: u32,
    /// The image config's ENV, as NAME=value.
    env: []const []const u8 = &.{},

    /// The value of the image's ENV entry `name`.
    pub fn getEnv(m: Meta, name: []const u8) ?[]const u8 {
        for (m.env) |e| {
            if (e.len > name.len and std.mem.startsWith(u8, e, name) and e[name.len] == '=') return e[name.len + 1 ..];
        }
        return null;
    }
};

/// A root ready to run: its unpacked directory and what it is.
pub const Root = struct {
    dir: []const u8,
    meta: Meta,
};

pub fn embeddedMeta(arena: std.mem.Allocator) !Meta {
    return parseMeta(arena, embedded_meta);
}

pub fn parseMeta(arena: std.mem.Allocator, text: []const u8) !Meta {
    return std.json.parseFromSliceLeaky(Meta, arena, text, .{ .ignore_unknown_fields = true });
}

/// The cache directory name for a digest: `sha256:abc...` becomes
/// `sha256-abc...`. A `local` digest (a root made from a local tree) is
/// named after a hash of the embedded archive instead.
pub fn dirName(arena: std.mem.Allocator, digest: []const u8) ![]const u8 {
    if (std.mem.eql(u8, digest, "local"))
        return std.fmt.allocPrint(arena, "local-{x:0>16}", .{std.hash.Wyhash.hash(0, embedded_tar)});
    const out = try arena.dupe(u8, digest);
    for (out) |*ch| if (ch.* == ':') {
        ch.* = '-';
    };
    return out;
}

/// The embedded root, unpacked into `roots_dir` if it isn't already.
pub fn embedded(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, roots_dir: []const u8) !Root {
    const meta = try embeddedMeta(arena);
    const name = try dirName(arena, meta.digest);
    try std.Io.Dir.cwd().createDirPath(io, roots_dir);
    var cache = try std.Io.Dir.cwd().openDir(io, roots_dir, .{});
    defer cache.close(io);
    const path = try std.fs.path.join(arena, &.{ roots_dir, name });
    if (cache.access(io, name, .{})) |_| {
        return .{ .dir = try std.Io.Dir.cwd().realPathFileAlloc(io, path, arena), .meta = meta };
    } else |_| {}

    std.debug.print("Unpacking Postgres {s} into {s}...\n", .{ meta.version, path });
    var src: std.Io.Reader = .fixed(embedded_tar);
    try unpackXz(gpa, arena, io, cache, name, &src);
    try writeMeta(arena, io, cache, name, embedded_meta);
    return .{ .dir = try std.Io.Dir.cwd().realPathFileAlloc(io, path, arena), .meta = meta };
}

/// Unpacks an xz-compressed tar from `src` into `cache/name`, through a
/// temporary directory and a rename, so a failed run never leaves a partial
/// root under the final name.
pub fn unpackXz(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, name: []const u8, src: *std.Io.Reader) !void {
    // The decompressor owns the buffer and frees it in deinit.
    const buf = try gpa.alloc(u8, 1 << 16);
    var xz = try std.compress.xz.Decompress.init(src, gpa, buf);
    defer xz.deinit();
    try unpackTar(arena, io, cache, name, &xz.reader);
}

/// Unpacks a tar stream into `cache/name` the same way.
pub fn unpackTar(arena: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, name: []const u8, tar: *std.Io.Reader) !void {
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(arena, ".tmp-{x}", .{&rnd});
    try cache.createDirPath(io, tmp);
    defer cache.deleteTree(io, tmp) catch {};
    {
        var dest = try cache.openDir(io, tmp, .{});
        defer dest.close(io);
        try std.tar.extract(io, dest, tar, .{ .mode_mode = .executable_bit_only });
    }
    cache.rename(tmp, cache, name, io) catch |err| {
        // Another process unpacked the same root first.
        if (cache.access(io, name, .{})) |_| return else |_| {}
        return err;
    };
}

/// Records a root's metadata beside it, as `<name>.json`.
pub fn writeMeta(arena: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, name: []const u8, json: []const u8) !void {
    const file = try std.fmt.allocPrint(arena, "{s}.json", .{name});
    try cache.writeFile(io, .{ .sub_path = file, .data = json });
}

/// The root a .pgdb runs on: one whose major matches the .pgdb's. Prints
/// why there is none and returns `error.NoRoot`.
pub fn forPgdb(ctx: anytype, p: anytype) !Root {
    const r = try embedded(ctx.gpa, ctx.arena, ctx.io, ctx.dirs.roots);
    if (p.config.pg_major == 0 or p.config.pg_major == r.meta.major) return r;
    ctx.warn("{s} uses Postgres {d}, and this minipg has only Postgres {d}", .{ p.path, p.config.pg_major, r.meta.major });
    return error.NoRoot;
}
