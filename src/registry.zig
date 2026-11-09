//! Pulling a Postgres root from an image registry at runtime, the same way
//! scripts/root.sh does at build time: anonymous token auth, the index
//! resolved to linux/<host arch>, layers applied in order with whiteouts,
//! the same trim, and the image config's ENV recorded beside the tree.
//!
//! MINIPG_REGISTRY names another registry: `host` (the image is then
//! library/postgres there) or `host/repository`.

const std = @import("std");
const Io = std.Io;
const Ctx = @import("ctx.zig").Ctx;
const roots = @import("roots.zig");
const layer = @import("layer.zig");
const https = @import("https.zig");

pub const default_host = "registry-1.docker.io";
pub const default_repo = "library/postgres";

/// What scripts/root.sh trims: LLVM for JIT, headers and docs.
pub const trim = [_][]const u8{
    "usr/local/lib/postgresql/bitcode",
    "usr/local/include",
    "usr/share/doc",
    "usr/share/man",
};

const accept_index = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json";
const accept_manifest = "application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json";

pub const Source = struct {
    host: []const u8,
    repo: []const u8,

    pub fn fromEnv(ctx: Ctx) Source {
        const v = ctx.getenv("MINIPG_REGISTRY") orelse return .{ .host = default_host, .repo = default_repo };
        const t = std.mem.trimEnd(u8, v, "/");
        if (std.mem.indexOfScalar(u8, t, '/')) |i| return .{ .host = t[0..i], .repo = t[i + 1 ..] };
        return .{ .host = t, .repo = default_repo };
    }
};

const Client = struct {
    ctx: Ctx,
    https: https.Client,
    src: Source,
    token: ?[]const u8 = null,

    fn init(ctx: Ctx, src: Source) !Client {
        return .{ .ctx = ctx, .https = try .init(ctx.gpa, ctx.arena, ctx.io, ctx.env), .src = src };
    }

    fn deinit(c: *Client) void {
        c.https.deinit();
    }

    fn url(c: *Client, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(c.ctx.arena, "https://{s}/v2/{s}/{s}", .{ c.src.host, c.src.repo, path });
    }

    /// GETs `u`, following redirects. The token goes only to the registry
    /// itself, not to the blob store a redirect points at.
    fn open(c: *Client, u: []const u8, accept: ?[]const u8) !*https.Response {
        const arena = c.ctx.arena;
        var target = u;
        var hops: u32 = 0;
        while (true) : (hops += 1) {
            var hdrs: std.ArrayList(std.http.Header) = .empty;
            if (accept) |a| try hdrs.append(arena, .{ .name = "Accept", .value = a });
            if (hops == 0) if (c.token) |t|
                try hdrs.append(arena, .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{t}) });
            const r = try c.https.get(arena, target, hdrs.items);
            if (r.head.status.class() != .redirect) return r;
            defer r.deinit(c.ctx.io);
            if (hops >= 5) return error.TooManyRedirects;
            const loc = r.head.location orelse return error.RegistryError;
            const base = try std.Uri.parse(target);
            var buf: [8192]u8 = undefined;
            if (loc.len > buf.len) return error.RegistryError;
            @memcpy(buf[0..loc.len], loc);
            var aux: []u8 = &buf;
            const next = try base.resolveInPlace(loc.len, &aux);
            target = try std.fmt.allocPrint(arena, "{f}", .{next.fmt(.all)});
        }
    }

    /// GETs a small document, authenticating on a 401.
    fn getSmall(c: *Client, path: []const u8, accept: []const u8) ![]const u8 {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const r = try c.open(try c.url(path), accept);
            defer r.deinit(c.ctx.io);
            switch (r.head.status) {
                .ok => return try readAll(c.ctx.arena, r),
                .unauthorized => {
                    const auth = r.header("www-authenticate");
                    if (attempt > 0 or auth == null) return error.Unauthorized;
                    try c.authenticate(try c.ctx.arena.dupe(u8, auth.?));
                },
                .not_found => return error.NotFound,
                .too_many_requests => return error.RateLimited,
                else => return error.RegistryError,
            }
        }
    }

    fn readAll(arena: std.mem.Allocator, r: *https.Response) ![]const u8 {
        var out: Io.Writer.Allocating = .init(arena);
        _ = r.body.streamRemaining(&out.writer) catch |err| switch (err) {
            error.ReadFailed => return r.bodyErr(),
            else => |e| return e,
        };
        return out.written();
    }

    /// Bearer realm="...",service="...",scope="..." → an anonymous token.
    fn authenticate(c: *Client, challenge: []const u8) !void {
        if (!std.ascii.startsWithIgnoreCase(challenge, "bearer ")) return error.Unauthorized;
        var realm: []const u8 = "";
        var service: []const u8 = "";
        var it = std.mem.tokenizeScalar(u8, challenge[7..], ',');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const k = std.mem.trim(u8, kv[0..eq], " ");
            const v = std.mem.trim(u8, kv[eq + 1 ..], " \"");
            if (std.mem.eql(u8, k, "realm")) realm = v;
            if (std.mem.eql(u8, k, "service")) service = v;
        }
        if (realm.len == 0) return error.Unauthorized;
        const u = try std.fmt.allocPrint(c.ctx.arena, "{s}?service={s}&scope=repository:{s}:pull", .{ realm, service, c.src.repo });
        const r = try c.https.get(c.ctx.arena, u, &.{});
        defer r.deinit(c.ctx.io);
        if (r.head.status != .ok) return error.Unauthorized;
        const body = try readAll(c.ctx.arena, r);
        const T = struct { token: ?[]const u8 = null, access_token: ?[]const u8 = null };
        const parsed = try std.json.parseFromSliceLeaky(T, c.ctx.arena, body, .{ .ignore_unknown_fields = true });
        c.token = parsed.token orelse parsed.access_token orelse return error.Unauthorized;
    }

    /// Streams a blob through gzip into the layer applier.
    fn applyLayer(c: *Client, digest: []const u8, dest: Io.Dir) !void {
        const r = try c.open(try c.url(try std.fmt.allocPrint(c.ctx.arena, "blobs/{s}", .{digest})), null);
        defer r.deinit(c.ctx.io);
        if (r.head.status != .ok) return error.RegistryError;
        var zbuf: [std.compress.flate.max_window_len]u8 = undefined;
        var gz: std.compress.flate.Decompress = .init(r.body, .gzip, &zbuf);
        layer.apply(c.ctx.gpa, c.ctx.io, dest, &gz.reader) catch |err| switch (err) {
            error.ReadFailed => return if (gz.err) |e| e else r.bodyErr(),
            else => |e| return e,
        };
    }
};

const Descriptor = struct { digest: []const u8, mediaType: []const u8 = "", platform: ?struct { os: []const u8 = "", architecture: []const u8 = "" } = null };
const Manifest = struct {
    manifests: ?[]const Descriptor = null,
    config: ?Descriptor = null,
    layers: ?[]const Descriptor = null,
};
const Config = struct { config: struct { Env: ?[]const []const u8 = null } = .{} };

/// A sentence for a pull's error.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.RateLimited => "the registry's pull rate limit was reached (Docker Hub limits anonymous pulls per IP); try again later, or set MINIPG_REGISTRY to a mirror",
        error.NotFound => "no such image in the registry",
        error.Unauthorized => "the registry refused anonymous access",
        error.NoPlatform => "the image has no build for this arch",
        error.ProxyRefused, error.ProxyError => "the HTTPS proxy refused the connection",
        else => @errorName(err),
    };
}

/// Pulls postgres:<major>-alpine for the host's arch into the root cache,
/// unless that image's digest is already there, and returns it.
pub fn pull(ctx: Ctx, major: u32) !roots.Root {
    const arena = ctx.arena;
    const io = ctx.io;
    const src = Source.fromEnv(ctx);
    const tag = try std.fmt.allocPrint(arena, "{d}-alpine", .{major});
    var c = try Client.init(ctx, src);
    defer c.deinit();

    var doc = try c.getSmall(try std.fmt.allocPrint(arena, "manifests/{s}", .{tag}), accept_index ++ "," ++ accept_manifest);
    var m = try std.json.parseFromSliceLeaky(Manifest, arena, doc, .{ .ignore_unknown_fields = true });
    var digest: []const u8 = "";
    if (m.manifests) |list| {
        for (list) |d| if (d.platform) |p| {
            if (std.mem.eql(u8, p.os, "linux") and std.mem.eql(u8, p.architecture, roots.host_arch)) {
                digest = d.digest;
                break;
            }
        };
        if (digest.len == 0) {
            ctx.warn("{s}/{s}:{s} has no linux/{s} image", .{ src.host, src.repo, tag, roots.host_arch });
            return error.NoPlatform;
        }
        doc = try c.getSmall(try std.fmt.allocPrint(arena, "manifests/{s}", .{digest}), accept_manifest);
        m = try std.json.parseFromSliceLeaky(Manifest, arena, doc, .{ .ignore_unknown_fields = true });
    } else {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(doc, &h, .{});
        digest = try std.fmt.allocPrint(arena, "sha256:{x}", .{&h});
    }
    const name = try roots.dirName(arena, digest);
    try std.Io.Dir.cwd().createDirPath(io, ctx.dirs.roots);
    var cache = try std.Io.Dir.cwd().openDir(io, ctx.dirs.roots, .{});
    defer cache.close(io);
    if (roots.cached(ctx, name)) |r| return r;

    const cfg_desc = m.config orelse return error.RegistryError;
    const cfg_doc = try c.getSmall(try std.fmt.allocPrint(arena, "blobs/{s}", .{cfg_desc.digest}), "*/*");
    const cfg = try std.json.parseFromSliceLeaky(Config, arena, cfg_doc, .{ .ignore_unknown_fields = true });
    const env = cfg.config.Env orelse &.{};
    var version: []const u8 = "";
    for (env) |e| if (std.mem.startsWith(u8, e, "PG_VERSION=")) {
        version = e["PG_VERSION=".len..];
    };
    if (version.len == 0) return error.NoVersion;

    ctx.warn("downloading Postgres {s} ({s}/{s}:{s}, linux/{s})...", .{ version, src.host, src.repo, tag, roots.host_arch });
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(arena, ".tmp-{x}", .{&rnd});
    try cache.createDirPath(io, tmp);
    defer cache.deleteTree(io, tmp) catch {};
    {
        var dest = try cache.openDir(io, tmp, .{});
        defer dest.close(io);
        for (m.layers orelse &.{}) |l| try c.applyLayer(l.digest, dest);
        for (trim) |p| dest.deleteTree(io, p) catch {};
        // LLVM: libLLVM* and llvmjit*.
        try deleteMatching(io, dest, "usr/lib", "libLLVM");
        try deleteMatching(io, dest, "usr/local/lib/postgresql", "llvmjit");
    }
    const meta: roots.Meta = .{
        .arch = roots.host_arch,
        .ref = try std.fmt.allocPrint(arena, "{s}:{s}", .{ src.repo, tag }),
        .digest = digest,
        .version = version,
        .major = major,
        .env = env,
    };
    const json = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(meta, .{ .whitespace = .indent_2 })});
    try roots.writeMeta(arena, io, cache, name, json);
    cache.rename(tmp, cache, name, io) catch |err| {
        if (cache.access(io, name, .{})) |_| {} else |_| return err;
    };
    return roots.cached(ctx, name) orelse error.RegistryError;
}

fn deleteMatching(io: Io, dest: Io.Dir, dir: []const u8, prefix: []const u8) !void {
    var d = dest.openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var names: [64][256]u8 = undefined;
    var lens: [64]usize = undefined;
    var n: usize = 0;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (n < names.len and std.mem.startsWith(u8, e.name, prefix) and e.name.len <= 256) {
            @memcpy(names[n][0..e.name.len], e.name);
            lens[n] = e.name.len;
            n += 1;
        }
    }
    for (0..n) |i| d.deleteTree(io, names[i][0..lens[i]]) catch {};
}
