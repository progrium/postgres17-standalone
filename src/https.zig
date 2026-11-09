//! A small HTTPS GET client, one request per connection. std.http.Client
//! (Zig 0.16) doesn't start TLS inside a CONNECT tunnel, so it can't reach
//! an HTTPS server through a proxy; this opens the tunnel itself. Honors
//! HTTPS_PROXY and NO_PROXY.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const tls = std.crypto.tls;

const Env = std.process.Environ.Map;

pub const Proxy = struct {
    host: []const u8,
    port: u16,
    /// "Basic ..." from the URL's userinfo.
    auth: ?[]const u8 = null,

    /// Parses http://[user:pass@]host[:port][/].
    pub fn parse(arena: std.mem.Allocator, url: []const u8) !Proxy {
        var s = url;
        if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
        s = std.mem.trimEnd(u8, s, "/");
        var auth: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, s, '@')) |at| {
            const user = s[0..at];
            const enc = std.base64.standard.Encoder;
            const buf = try arena.alloc(u8, enc.calcSize(user.len));
            auth = try std.fmt.allocPrint(arena, "Basic {s}", .{enc.encode(buf, user)});
            s = s[at + 1 ..];
        }
        var port: u16 = 80;
        if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| {
            port = std.fmt.parseInt(u16, s[c + 1 ..], 10) catch return error.BadProxy;
            s = s[0..c];
        }
        if (s.len == 0) return error.BadProxy;
        return .{ .host = s, .port = port, .auth = auth };
    }
};

/// Whether NO_PROXY's list (comma-separated hosts, suffixes, or `*`)
/// covers `host`.
pub fn bypass(no_proxy: []const u8, host: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, no_proxy, ", ");
    while (it.next()) |raw| {
        if (std.mem.eql(u8, raw, "*")) return true;
        const pat = std.mem.trimStart(u8, std.mem.trimStart(u8, raw, "*"), ".");
        if (pat.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(host, pat)) return true;
        if (host.len > pat.len and host[host.len - pat.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - pat.len ..], pat)) return true;
    }
    return false;
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: Io,
    bundle: std.crypto.Certificate.Bundle = .empty,
    lock: Io.RwLock = .init,
    now: Io.Timestamp,
    proxy: ?Proxy = null,
    no_proxy: []const u8 = "",

    /// The system's CA roots plus SSL_CERT_FILE's, and the proxy from the
    /// environment.
    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, env: *const Env) !Client {
        const now = Io.Clock.real.now(io);
        var c: Client = .{ .gpa = gpa, .io = io, .now = now };
        c.bundle.rescan(gpa, io, now) catch {};
        if (env.get("SSL_CERT_FILE")) |f| c.bundle.addCertsFromFilePathAbsolute(gpa, io, now, f) catch {};
        const p = env.get("HTTPS_PROXY") orelse env.get("https_proxy") orelse
            env.get("ALL_PROXY") orelse env.get("all_proxy");
        if (p) |v| if (v.len > 0) {
            c.proxy = try Proxy.parse(arena, v);
        };
        c.no_proxy = env.get("NO_PROXY") orelse env.get("no_proxy") orelse "";
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.bundle.deinit(c.gpa);
    }

    /// Sends a GET and reads the response head. The caller reads the body
    /// from `Response.body` and calls `deinit`.
    pub fn get(c: *Client, arena: std.mem.Allocator, url: []const u8, headers: []const http.Header) !*Response {
        const uri = try std.Uri.parse(url);
        if (!std.mem.eql(u8, uri.scheme, "https")) return error.UnsupportedUriScheme;
        const host = (try uri.getHostAlloc(arena)).bytes;
        const port = uri.port orelse 443;
        const r = try arena.create(Response);
        r.* = .{ .stream = undefined, .sr = undefined, .sw = undefined, .tls = undefined, .hr = undefined, .head = undefined, .body = undefined };
        const via = if (c.proxy) |p| (if (bypass(c.no_proxy, host)) null else p) else null;
        const target = if (via) |p| p.host else host;
        const tport = if (via) |p| p.port else port;
        const hn = try Io.net.HostName.init(target);
        r.stream = try hn.connect(c.io, tport, .{ .mode = .stream });
        errdefer r.stream.close(c.io);
        r.sr = r.stream.reader(c.io, &r.sock_in);
        r.sw = r.stream.writer(c.io, &r.sock_out);

        if (via) |p| {
            const w = &r.sw.interface;
            try w.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ host, port, host, port });
            if (p.auth) |a| try w.print("Proxy-Authorization: {s}\r\n", .{a});
            try w.writeAll("\r\n");
            try w.flush();
            var pr: http.Reader = .{ .in = &r.sr.interface, .interface = undefined, .state = .ready, .max_head_len = 8192 };
            const ph = http.Client.Response.Head.parse(try pr.receiveHead()) catch return error.ProxyError;
            if (ph.status != .ok) return error.ProxyRefused;
        }

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        c.io.random(&entropy);
        r.tls = try tls.Client.init(&r.sr.interface, &r.sw.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{ .gpa = c.gpa, .io = c.io, .lock = &c.lock, .bundle = &c.bundle } },
            .read_buffer = &r.tls_in,
            .write_buffer = &r.tls_out,
            .entropy = &entropy,
            .realtime_now = c.now,
            // Content-Length and chunking detect a truncated body.
            .allow_truncation_attacks = true,
        });

        const w = &r.tls.writer;
        const path = try std.fmt.allocPrint(arena, "{f}", .{uri.fmt(.{ .path = true, .query = true })});
        try w.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: minipg\r\nConnection: close\r\n", .{ if (path.len == 0) "/" else path, host });
        for (headers) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        try w.writeAll("\r\n");
        try w.flush();
        try r.sw.interface.flush();

        r.hr = .{ .in = &r.tls.reader, .interface = undefined, .state = .ready, .max_head_len = r.tls_in.len };
        const bytes = try arena.dupe(u8, try r.hr.receiveHead());
        r.head = try http.Client.Response.Head.parse(bytes);
        r.body = r.hr.bodyReader(&r.transfer, r.head.transfer_encoding, r.head.content_length);
        return r;
    }
};

pub const Response = struct {
    stream: Io.net.Stream,
    sr: Io.net.Stream.Reader,
    sw: Io.net.Stream.Writer,
    tls: tls.Client,
    hr: http.Reader,
    head: http.Client.Response.Head,
    body: *Io.Reader,
    sock_in: [tls.Client.min_buffer_len]u8 = undefined,
    sock_out: [tls.Client.min_buffer_len]u8 = undefined,
    tls_in: [tls.Client.min_buffer_len + 16 << 10]u8 = undefined,
    tls_out: [tls.Client.min_buffer_len]u8 = undefined,
    transfer: [64 << 10]u8 = undefined,

    /// A header's value from the response head.
    pub fn header(r: *const Response, name: []const u8) ?[]const u8 {
        var it = r.head.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    /// The real error behind a body ReadFailed.
    pub fn bodyErr(r: *const Response) anyerror {
        if (r.hr.body_err) |e| return e;
        if (r.tls.read_err) |e| return e;
        return r.sr.err orelse error.ReadFailed;
    }

    pub fn deinit(r: *Response, io: Io) void {
        r.stream.close(io);
    }
};

test Proxy {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try Proxy.parse(arena.allocator(), "http://u:p@127.0.0.1:3128/");
    try std.testing.expectEqualStrings("127.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 3128), p.port);
    try std.testing.expectEqualStrings("Basic dTpw", p.auth.?);
    try std.testing.expect(bypass("localhost,.example.com", "a.example.com"));
    try std.testing.expect(bypass("localhost,*.svc.local", "x.svc.local"));
    try std.testing.expect(!bypass("localhost,example.com", "registry-1.docker.io"));
}
