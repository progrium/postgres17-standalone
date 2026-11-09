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

/// The root cached under `name` (a directory and its `<name>.json`), if
/// it's there.
pub fn cached(ctx: anytype, name: []const u8) ?Root {
    const arena = ctx.arena;
    const dir = std.fs.path.join(arena, &.{ ctx.dirs.roots, name }) catch return null;
    const json_path = std.fmt.allocPrint(arena, "{s}.json", .{dir}) catch return null;
    std.Io.Dir.cwd().access(ctx.io, dir, .{}) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, json_path, arena, .limited(1 << 20)) catch return null;
    const meta = parseMeta(arena, text) catch return null;
    return .{ .dir = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, dir, arena) catch return null, .meta = meta };
}

/// Every root in the cache for this host's arch.
pub fn list(ctx: anytype) ![]Root {
    const arena = ctx.arena;
    var out: std.ArrayList(Root) = .empty;
    var d = std.Io.Dir.cwd().openDir(ctx.io, ctx.dirs.roots, .{ .iterate = true }) catch return out.items;
    defer d.close(ctx.io);
    var it = d.iterate();
    while (try it.next(ctx.io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".json")) continue;
        const name = try arena.dupe(u8, e.name[0 .. e.name.len - 5]);
        const r = cached(ctx, name) orelse continue;
        if (std.mem.eql(u8, r.meta.arch, host_arch)) try out.append(arena, r);
    }
    std.mem.sort(Root, out.items, {}, struct {
        fn lt(_: void, a: Root, b: Root) bool {
            return versionLess(b.meta.version, a.meta.version);
        }
    }.lt);
    return out.items;
}

/// Compares Postgres versions such as 17.4 and 18.10 numerically.
pub fn versionLess(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null or pb == null) return pa == null and pb != null;
        const na = std.fmt.parseInt(u32, pa.?, 10) catch 0;
        const nb = std.fmt.parseInt(u32, pb.?, 10) catch 0;
        if (na != nb) return na < nb;
    }
}

pub const Want = struct {
    /// Download the major if no root has it (unless MINIPG_OFFLINE).
    fetch: bool = true,
};

/// The newest root for a Postgres major: the embedded one, a cached one,
/// or (unless MINIPG_OFFLINE is set) one downloaded now. Prints why there
/// is none and returns `error.NoRoot`.
pub fn forMajor(ctx: anytype, major: u32, want: Want) !Root {
    const meta = try embeddedMeta(ctx.arena);
    var best: ?Root = null;
    for (try list(ctx)) |r| {
        if (r.meta.major == major and (best == null or versionLess(best.?.meta.version, r.meta.version))) best = r;
    }
    if (meta.major == major and (best == null or !versionLess(meta.version, best.?.meta.version)))
        return embedded(ctx.gpa, ctx.arena, ctx.io, ctx.dirs.roots);
    if (best) |b| return b;
    if (want.fetch and ctx.getenv("MINIPG_OFFLINE") == null) {
        return @import("registry.zig").pull(ctx, major) catch |err| {
            ctx.warn("downloading Postgres {d}: {s}", .{ major, @import("registry.zig").describe(err) });
            return error.NoRoot;
        };
    }
    ctx.warn("no Postgres {d} root is available{s}; minipg fetch {d} downloads it", .{ major, if (ctx.getenv("MINIPG_OFFLINE") != null) " offline (MINIPG_OFFLINE is set)" else "", major });
    return error.NoRoot;
}

/// The root a .pgdb runs on: the newest one for its major.
pub fn forPgdb(ctx: anytype, p: anytype) !Root {
    const major = if (p.config.pg_major != 0) p.config.pg_major else (try embeddedMeta(ctx.arena)).major;
    return forMajor(ctx, major, .{});
}

test versionLess {
    try std.testing.expect(versionLess("17.4", "18.1"));
    try std.testing.expect(versionLess("18.2", "18.10"));
    try std.testing.expect(!versionLess("18.10", "18.2"));
    try std.testing.expect(!versionLess("18.1", "18.1"));
}
