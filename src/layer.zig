//! Applying an OCI image layer (a tar stream) to a directory: files,
//! directories, symlinks and hard links, with the layer's whiteouts
//! removing what earlier layers put there. std.tar has no hard links,
//! which image layers use, so this reads the headers itself (ustar, GNU
//! long names, PAX path and size).
//!
//! Windows lets only an administrator, or Developer Mode, make a symlink,
//! so there a layer's symlinks become hard links to their targets (copies
//! for directories), resolved inside the root once the layer is applied.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

const block = 512;

pub const Error = error{ BadTar, UnsafePath, OutOfMemory } || Io.Reader.Error;

const Entry = struct {
    name: []const u8,
    link: []const u8,
    size: u64,
    mode: u32,
    kind: u8,
};

fn octal(field: []const u8) !u64 {
    // GNU base-256 for large sizes.
    if (field.len > 0 and field[0] & 0x80 != 0) {
        var v: u64 = field[0] & 0x7f;
        for (field[1..]) |b| v = (v << 8) | b;
        return v;
    }
    const t = std.mem.trim(u8, field, " \x00");
    if (t.len == 0) return 0;
    return std.fmt.parseInt(u64, t, 8) catch error.BadTar;
}

fn cstr(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

/// Reads tar entries from a stream.
pub const Reader = struct {
    r: *Io.Reader,
    arena: std.mem.Allocator,
    pad: u64 = 0,
    unread: u64 = 0,

    pub fn next(t: *Reader) !?Entry {
        try t.r.discardAll64(t.unread + t.pad);
        t.unread = 0;
        t.pad = 0;
        var long_name: ?[]const u8 = null;
        var long_link: ?[]const u8 = null;
        var pax_size: ?u64 = null;
        while (true) {
            const h = t.r.takeArray(block) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => |e| return e,
            };
            if (std.mem.allEqual(u8, h, 0)) return null;
            const size = try octal(h[124..136]);
            const kind = h[156];
            const padded = std.mem.alignForward(u64, size, block);
            switch (kind) {
                'L', 'K', 'x', 'g' => {
                    const data = try t.arena.alloc(u8, @intCast(size));
                    try t.r.readSliceAll(data);
                    try t.r.discardAll64(padded - size);
                    switch (kind) {
                        'L' => long_name = cstr(data),
                        'K' => long_link = cstr(data),
                        'x' => {
                            // Records: "<len> <key>=<value>\n".
                            var rest: []const u8 = data;
                            while (rest.len > 0) {
                                const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse break;
                                const n = std.fmt.parseInt(usize, rest[0..sp], 10) catch break;
                                if (n > rest.len or n < sp + 2) break;
                                const rec = rest[sp + 1 .. n - 1];
                                rest = rest[n..];
                                const eq = std.mem.indexOfScalar(u8, rec, '=') orelse continue;
                                const k = rec[0..eq];
                                const v = rec[eq + 1 ..];
                                if (std.mem.eql(u8, k, "path")) long_name = v;
                                if (std.mem.eql(u8, k, "linkpath")) long_link = v;
                                if (std.mem.eql(u8, k, "size")) pax_size = std.fmt.parseInt(u64, v, 10) catch null;
                            }
                        },
                        else => {},
                    }
                    continue;
                },
                else => {},
            }
            var name = long_name orelse blk: {
                const n = cstr(h[0..100]);
                const prefix = if (std.mem.eql(u8, h[257..262], "ustar")) cstr(h[345..500]) else "";
                break :blk if (prefix.len > 0) try std.fmt.allocPrint(t.arena, "{s}/{s}", .{ prefix, n }) else try t.arena.dupe(u8, n);
            };
            name = std.mem.trimStart(u8, name, "./");
            name = std.mem.trimEnd(u8, name, "/");
            const real_size = pax_size orelse size;
            t.unread = real_size;
            t.pad = std.mem.alignForward(u64, real_size, block) - real_size;
            return .{
                .name = name,
                .link = long_link orelse try t.arena.dupe(u8, cstr(h[157..257])),
                .size = real_size,
                .mode = @intCast(try octal(h[100..108]) & 0o7777),
                .kind = kind,
            };
        }
    }
};

/// Whether a path from a layer stays inside the root.
fn safe(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "/")) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

/// Applies one layer to `dest`.
pub fn apply(gpa: std.mem.Allocator, io: Io, dest: Io.Dir, tar: *Io.Reader) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var t: Reader = .{ .r = tar, .arena = arena_state.allocator() };
    var buf: [64 << 10]u8 = undefined;
    var links: std.ArrayList(Link) = .empty;
    while (try t.next()) |e| {
        if (e.name.len == 0) continue;
        if (!safe(e.name)) return error.UnsafePath;
        const dir = std.fs.path.dirname(e.name);
        const base = std.fs.path.basename(e.name);
        // Whiteouts: an opaque directory drops what earlier layers put in
        // it; .wh.<name> drops <name>.
        if (std.mem.eql(u8, base, ".wh..wh..opq")) {
            if (dir) |d| {
                dest.deleteTree(io, d) catch {};
                try dest.createDirPath(io, d);
            }
            continue;
        }
        if (std.mem.startsWith(u8, base, ".wh.")) {
            const target = if (dir) |d| try std.fs.path.join(t.arena, &.{ d, base[4..] }) else base[4..];
            dest.deleteTree(io, target) catch {};
            continue;
        }
        if (dir) |d| try dest.createDirPath(io, d);
        switch (e.kind) {
            '5' => {
                dest.createDirPath(io, e.name) catch |err| switch (err) {
                    error.NotDir => {
                        dest.deleteFile(io, e.name) catch {};
                        try dest.createDirPath(io, e.name);
                    },
                    else => return err,
                };
                setMode(t.arena, dest, e.name, e.mode);
            },
            '2' => {
                dest.deleteTree(io, e.name) catch {};
                if (is_windows) {
                    try links.append(t.arena, .{ .name = e.name, .target = e.link });
                } else try dest.symLink(io, e.link, e.name, .{});
            },
            '1' => {
                if (!safe(e.link)) return error.UnsafePath;
                const src = std.mem.trimStart(u8, e.link, "./");
                dest.deleteTree(io, e.name) catch {};
                // A copy rather than a link, so the tree packs and moves
                // simply; the duplicates are small.
                dest.copyFile(src, dest, e.name, io, .{}) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            },
            '0', 0, '7' => {
                dest.deleteTree(io, e.name) catch {};
                var f = try dest.createFile(io, e.name, .{});
                defer f.close(io);
                var w = f.writer(io, &buf);
                try tar.streamExact64(&w.interface, e.size);
                t.unread = 0;
                try w.interface.flush();
                setMode(t.arena, dest, e.name, e.mode);
            },
            else => {}, // devices, fifos: not needed in a root
        }
    }
    if (links.items.len > 0) try materialize(t.arena, io, dest, links.items);
}

/// A symlink not made yet: `name` links to `target`.
const Link = struct { name: []const u8, target: []const u8 };

/// Makes each link a hard link to the file it resolves to inside `dest`,
/// or a copy of the directory. A link to a link waits for that one; a
/// link to nothing is left out.
fn materialize(arena: std.mem.Allocator, io: Io, dest: Io.Dir, links: []Link) !void {
    var pending = links;
    var pass: u32 = 0;
    while (pending.len > 0 and pass < 16) : (pass += 1) {
        var left: usize = 0;
        for (pending) |l| {
            const target = try resolveLink(arena, l.name, l.target);
            const st = dest.statFile(io, target, .{}) catch {
                pending[left] = l;
                left += 1;
                continue;
            };
            dest.deleteTree(io, l.name) catch {};
            if (st.kind == .directory) {
                try copyTree(arena, io, dest, target, l.name);
            } else {
                dest.hardLink(target, dest, l.name, io, .{}) catch
                    try dest.copyFile(target, dest, l.name, io, .{});
            }
        }
        if (left == pending.len) break;
        pending = pending[0..left];
    }
}

/// Where a link resolves in the root: an absolute target from the top, a
/// relative one from the link's directory, with `..` stopping at the top.
fn resolveLink(arena: std.mem.Allocator, name: []const u8, target: []const u8) ![]const u8 {
    const dir = std.fs.path.dirnamePosix(name) orelse "";
    const abs = if (std.mem.startsWith(u8, target, "/"))
        try std.fs.path.resolvePosix(arena, &.{ "/", target })
    else
        try std.fs.path.resolvePosix(arena, &.{ "/", dir, target });
    return std.mem.trimStart(u8, abs, "/");
}

/// Copies the tree at `from` to `to`, both in `dest`.
fn copyTree(arena: std.mem.Allocator, io: Io, dest: Io.Dir, from: []const u8, to: []const u8) !void {
    try dest.createDirPath(io, to);
    var src = try dest.openDir(io, from, .{ .iterate = true });
    defer src.close(io);
    var out = try dest.openDir(io, to, .{});
    defer out.close(io);
    var w = try src.walk(arena);
    defer w.deinit();
    while (try w.next(io)) |e| switch (e.kind) {
        .directory => try out.createDirPath(io, e.path),
        .file => try src.copyFile(e.path, out, e.path, io, .{}),
        else => {},
    };
}

fn setMode(arena: std.mem.Allocator, dest: Io.Dir, name: []const u8, mode: u32) void {
    if (is_windows) return;
    const z = arena.dupeZ(u8, name) catch return;
    _ = std.c.fchmodat(dest.handle, z, @intCast(mode), 0);
}

test "reader parses ustar and pax" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var data: [block * 6]u8 = @splat(0);
    // A PAX header giving a long path, then a regular file with 5 bytes.
    const pax = "30 path=some/long/name/file.t\n";
    makeHeader(data[0..block], "PaxHeader", 'x', pax.len, "");
    @memcpy(data[block..][0..pax.len], pax);
    makeHeader(data[block * 2 ..][0..block], "short", '0', 5, "");
    @memcpy(data[block * 3 ..][0..5], "hello");
    makeHeader(data[block * 4 ..][0..block], "./hard", '1', 0, "some/long/name/file.t");
    var r: Io.Reader = .fixed(&data);
    var t: Reader = .{ .r = &r, .arena = arena.allocator() };
    const a = (try t.next()).?;
    try std.testing.expectEqualStrings("some/long/name/file.t", a.name);
    try std.testing.expectEqual(@as(u64, 5), a.size);
    const b = (try t.next()).?;
    try std.testing.expectEqualStrings("hard", b.name);
    try std.testing.expectEqual(@as(u8, '1'), b.kind);
    try std.testing.expectEqualStrings("some/long/name/file.t", b.link);
    try std.testing.expect((try t.next()) == null);
    try std.testing.expect(!safe("../x"));
    try std.testing.expect(!safe("a/../../x"));
    try std.testing.expect(safe("a/b"));
}

test resolveLink {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("bin/busybox", try resolveLink(a, "usr/sbin/chroot", "/bin/busybox"));
    try std.testing.expectEqualStrings("usr/lib/libz.so.1.3.2", try resolveLink(a, "usr/lib/libz.so.1", "libz.so.1.3.2"));
    try std.testing.expectEqualStrings("run", try resolveLink(a, "var/run", "../run"));
    try std.testing.expectEqualStrings("etc/crontabs", try resolveLink(a, "var/spool/cron/crontabs", "../../../etc/crontabs"));
    try std.testing.expectEqualStrings("x", try resolveLink(a, "a", "../../x"));
}

fn makeHeader(h: *[block]u8, name: []const u8, kind: u8, size: usize, link: []const u8) void {
    @memset(h, 0);
    @memcpy(h[0..name.len], name);
    _ = std.fmt.bufPrint(h[100..108], "{o:0>7}", .{@as(u32, 0o644)}) catch unreachable;
    _ = std.fmt.bufPrint(h[124..136], "{o:0>11}", .{size}) catch unreachable;
    h[156] = kind;
    @memcpy(h[157..][0..link.len], link);
    @memcpy(h[257..263], "ustar\x00");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    _ = std.fmt.bufPrint(h[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
}
