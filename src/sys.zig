//! What differs between POSIX and Windows hosts outside the console and
//! signals (host.zig): process ids, telling whether a process is alive,
//! and the host paths h9 takes.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

/// The Win32 calls minipg makes that std doesn't wrap.
pub const win = struct {
    const w = std.os.windows;
    pub const HANDLE = w.HANDLE;
    pub const DWORD = w.DWORD;
    pub const BOOL = w.BOOL;

    pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
    pub const STILL_ACTIVE: DWORD = 259;
    pub const WAIT_OBJECT_0: DWORD = 0;
    pub const FILE_SHARE_ALL: DWORD = 0x7;
    pub const OPEN_EXISTING: DWORD = 3;
    pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;

    pub const BY_HANDLE_FILE_INFORMATION = extern struct {
        dwFileAttributes: DWORD,
        ftCreationTime: [2]DWORD,
        ftLastAccessTime: [2]DWORD,
        ftLastWriteTime: [2]DWORD,
        dwVolumeSerialNumber: DWORD,
        nFileSizeHigh: DWORD,
        nFileSizeLow: DWORD,
        nNumberOfLinks: DWORD,
        nFileIndexHigh: DWORD,
        nFileIndexLow: DWORD,
    };

    pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    pub extern "kernel32" fn GetProcessId(process: HANDLE) callconv(.winapi) DWORD;
    pub extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
    pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
    pub extern "kernel32" fn GetFileInformationByHandle(h: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GetHandleInformation(h: HANDLE, flags: *DWORD) callconv(.winapi) BOOL;
    pub extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
    pub const HANDLE_FLAG_INHERIT: DWORD = 1;
};

/// The standard handles, made non-inheritable while a child is spawned.
/// CreateProcess passes every inheritable handle to the child, so a
/// background server would hold the caller's stdout pipe open, and
/// `$x = minipg shell ...` would wait for the server to idle out. A no-op
/// on POSIX, where std closes them in the child.
pub const StdNoInherit = struct {
    handles: [3]?win.HANDLE = .{ null, null, null },

    pub fn begin() StdNoInherit {
        var s: StdNoInherit = .{};
        if (!is_windows) return s;
        // STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE.
        const which = [3]win.DWORD{ @bitCast(@as(i32, -10)), @bitCast(@as(i32, -11)), @bitCast(@as(i32, -12)) };
        for (which, 0..) |w, i| {
            const h = win.GetStdHandle(w) orelse continue;
            if (h == std.os.windows.INVALID_HANDLE_VALUE) continue;
            var flags: win.DWORD = 0;
            if (!win.GetHandleInformation(h, &flags).toBool() or flags & win.HANDLE_FLAG_INHERIT == 0) continue;
            if (win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, 0).toBool()) s.handles[i] = h;
        }
        return s;
    }

    pub fn restore(s: StdNoInherit) void {
        if (!is_windows) return;
        for (s.handles) |h| if (h) |x| {
            _ = win.SetHandleInformation(x, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT);
        };
    }
};

/// This process's id.
pub fn pid() i32 {
    if (is_windows) return @bitCast(win.GetCurrentProcessId());
    return std.c.getpid();
}

/// Whether process `id` is alive: not gone, and on Linux not a zombie
/// waiting for its parent to reap it.
pub fn alive(id: i32) bool {
    if (id <= 0) return true;
    if (is_windows) {
        const h = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, @bitCast(id)) orelse
            // No such process, or one we may not look at: only the first
            // means it's gone, and a server is always the user's own.
            return false;
        defer _ = win.CloseHandle(h);
        var code: win.DWORD = 0;
        if (!win.GetExitCodeProcess(h, &code).toBool()) return true;
        return code == win.STILL_ACTIVE;
    }
    if (std.c.kill(id, @enumFromInt(0)) != 0 and std.c._errno().* == @intFromEnum(std.c.E.SRCH)) return false;
    if (builtin.os.tag != .linux) return true;
    var path: [32:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{id}) catch return true;
    const fd = std.c.open(z, .{});
    if (fd < 0) return true;
    defer _ = std.c.close(fd);
    var buf: [512]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return true;
    // "pid (comm) S ...": the state follows the last ')'.
    const stat = buf[0..@intCast(n)];
    const i = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true;
    return !(i + 2 < stat.len and stat[i + 2] == 'Z');
}

/// A spawned child's process id, as run.json records it.
pub fn childPid(child: std.process.Child) ?i32 {
    const id = child.id orelse return null;
    if (is_windows) return @bitCast(win.GetProcessId(id));
    return id;
}

/// The exit code of a child that has exited, without waiting; null while
/// it runs.
pub fn childExited(child: *std.process.Child) ?u8 {
    const id = child.id orelse return 0;
    if (is_windows) {
        if (win.WaitForSingleObject(id, 0) != win.WAIT_OBJECT_0) return null;
        var code: win.DWORD = 1;
        _ = win.GetExitCodeProcess(id, &code);
        child.id = null;
        return std.math.cast(u8, code) orelse 1;
    }
    var st: c_int = 0;
    const rc = std.c.waitpid(id, &st, std.c.W.NOHANG);
    if (rc == 0) return null;
    child.id = null;
    if (rc < 0) return 1;
    const u: u32 = @bitCast(st);
    return if (std.c.W.IFEXITED(u)) std.c.W.EXITSTATUS(u) else 1;
}

/// A host path as h9 takes it: unchanged on POSIX, and on Windows in its
/// `#U` form, `C:\Users\me` as `/C:/Users/me` (hyper9's docs/embedding.md,
/// "Rules for embedders").
pub fn kernPath(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (!is_windows) return p;
    return kernPathWindows(arena, p);
}

fn kernPathWindows(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    var s = p;
    // realpath can hand back a \\?\ path.
    if (std.mem.startsWith(u8, s, "\\\\?\\")) s = s[4..];
    const out = try arena.alloc(u8, s.len + 1);
    out[0] = '/';
    for (s, out[1..]) |c, *o| o.* = if (c == '\\') '/' else c;
    if (out.len >= 3 and out[2] == ':') out[1] = std.ascii.toUpper(out[1]);
    // "C:/" is "/C:".
    return if (out.len == 4 and out[3] == '/') out[0..3] else std.mem.trimEnd(u8, out, "/");
}

/// On Windows, a file or directory's identity: its volume serial number
/// and file index, which follow it through renames as an inode does.
pub fn fileId(arena: std.mem.Allocator, path: []const u8) ![2]u64 {
    if (!is_windows) @compileError("fileId is for Windows");
    const w16 = try std.unicode.wtf8ToWtf16LeAllocZ(arena, path);
    const h = win.CreateFileW(w16.ptr, 0, win.FILE_SHARE_ALL, null, win.OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return error.FileNotFound;
    defer _ = win.CloseHandle(h);
    var info: win.BY_HANDLE_FILE_INFORMATION = undefined;
    if (!win.GetFileInformationByHandle(h, &info).toBool()) return error.FileNotFound;
    return .{ info.dwVolumeSerialNumber, (@as(u64, info.nFileIndexHigh) << 32) | info.nFileIndexLow };
}

test kernPathWindows {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/C:/Users/me/app.pgdb", try kernPathWindows(a, "c:\\Users\\me\\app.pgdb"));
    try std.testing.expectEqualStrings("/C:", try kernPathWindows(a, "C:\\"));
    try std.testing.expectEqualStrings("/D:/x", try kernPathWindows(a, "\\\\?\\D:\\x\\"));
}
