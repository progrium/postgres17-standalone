//! A minimal Postgres client: the v3 wire protocol's startup, SCRAM-SHA-256
//! (or trust) authentication and simple queries over TCP or a unix socket. minipg uses it on
//! the host for what doesn't need a tool machine: checking that a server is
//! ready, counting clients, and small admin queries.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    /// The server sent an ErrorResponse; `Conn.err_msg` has its message.
    ServerError,
    /// The server sent something this client doesn't speak.
    Protocol,
    /// The server asked for an authentication method other than SCRAM or trust.
    UnsupportedAuth,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    EndOfStream,
    ConnectFailed,
};

pub const Options = struct {
    /// An address, or as in libpq, a directory holding the server's unix
    /// socket (`.s.PGSQL.<port>`) when it starts with `/`.
    host: []const u8 = "127.0.0.1",
    port: u16,
    user: []const u8,
    password: []const u8 = "",
    database: []const u8,
    application_name: []const u8 = "minipg",
};

/// A result row: one optional value per column, as text.
pub const Row = []const ?[]const u8;

pub const Conn = struct {
    io: Io,
    gpa: std.mem.Allocator,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    rbuf: [8192]u8 = undefined,
    wbuf: [4096]u8 = undefined,
    /// The message of the last ErrorResponse, or of a failed connect.
    err_msg: []const u8 = "",
    /// The SQLSTATE code of the last ErrorResponse.
    err_code: [5]u8 = "00000".*,
    msg: std.ArrayList(u8) = .empty,

    /// Connects and authenticates. The returned value must not move, since
    /// its reader and writer point into it, so it's heap-allocated.
    pub fn connect(gpa: std.mem.Allocator, io: Io, opts: Options) Error!*Conn {
        const stream = if (opts.host.len > 0 and opts.host[0] == '/') blk: {
            var buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/.s.PGSQL.{d}", .{ opts.host, opts.port }) catch return error.ConnectFailed;
            const ua = Io.net.UnixAddress.init(path) catch return error.ConnectFailed;
            break :blk ua.connect(io) catch return error.ConnectFailed;
        } else blk: {
            const addr = Io.net.IpAddress.parse(opts.host, opts.port) catch return error.ConnectFailed;
            break :blk addr.connect(io, .{ .mode = .stream }) catch return error.ConnectFailed;
        };
        const c = gpa.create(Conn) catch {
            stream.close(io);
            return error.OutOfMemory;
        };
        c.* = .{ .io = io, .gpa = gpa, .stream = stream, .reader = undefined, .writer = undefined };
        c.reader = stream.reader(io, &c.rbuf);
        c.writer = stream.writer(io, &c.wbuf);
        c.startup(opts) catch |err| {
            const msg = c.err_msg;
            const code = c.err_code;
            c.close();
            // The caller can't read a closed Conn, so report through a
            // thread-local copy.
            last_err_len = @min(msg.len, last_err_buf.len);
            @memcpy(last_err_buf[0..last_err_len], msg[0..last_err_len]);
            last_err_code = code;
            return err;
        };
        return c;
    }

    pub fn close(c: *Conn) void {
        // Terminate, best effort.
        const w = &c.writer.interface;
        w.writeAll(&.{ 'X', 0, 0, 0, 4 }) catch {};
        w.flush() catch {};
        c.stream.close(c.io);
        c.msg.deinit(c.gpa);
        if (c.err_msg.len > 0) c.gpa.free(c.err_msg);
        c.gpa.destroy(c);
    }

    fn startup(c: *Conn, opts: Options) Error!void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(c.gpa);
        try appendInt(c.gpa, &body, u32, 196608);
        for ([_][2][]const u8{
            .{ "user", opts.user },
            .{ "database", opts.database },
            .{ "application_name", opts.application_name },
            .{ "client_encoding", "UTF8" },
        }) |kv| {
            try body.appendSlice(c.gpa, kv[0]);
            try body.append(c.gpa, 0);
            try body.appendSlice(c.gpa, kv[1]);
            try body.append(c.gpa, 0);
        }
        try body.append(c.gpa, 0);
        try c.send(null, body.items);

        var scram: ?Scram = null;
        while (true) {
            const t = try c.recv();
            switch (t) {
                'R' => {
                    var r: Io.Reader = .fixed(c.msg.items);
                    const code = r.takeInt(u32, .big) catch return error.Protocol;
                    switch (code) {
                        0 => {},
                        10 => {
                            // SASL: SCRAM-SHA-256 must be among the mechanisms.
                            if (std.mem.indexOf(u8, c.msg.items[4..], "SCRAM-SHA-256") == null) return error.UnsupportedAuth;
                            scram = Scram.init(c.io);
                            const first = scram.?.clientFirst();
                            var m: std.ArrayList(u8) = .empty;
                            defer m.deinit(c.gpa);
                            try m.appendSlice(c.gpa, "SCRAM-SHA-256");
                            try m.append(c.gpa, 0);
                            try appendInt(c.gpa, &m, u32, @intCast(first.len));
                            try m.appendSlice(c.gpa, first);
                            try c.send('p', m.items);
                        },
                        11 => {
                            const s = &(scram orelse return error.Protocol);
                            const final = s.clientFinal(c.msg.items[4..], opts.password) catch return error.Protocol;
                            try c.send('p', final);
                        },
                        12 => {
                            const s = &(scram orelse return error.Protocol);
                            if (!s.verifyServer(c.msg.items[4..])) {
                                try c.setErr("server signature mismatch");
                                return error.Protocol;
                            }
                        },
                        3 => {
                            // Cleartext: only ever on loopback here.
                            var m: std.ArrayList(u8) = .empty;
                            defer m.deinit(c.gpa);
                            try m.appendSlice(c.gpa, opts.password);
                            try m.append(c.gpa, 0);
                            try c.send('p', m.items);
                        },
                        else => return error.UnsupportedAuth,
                    }
                },
                'E' => return c.serverError(),
                'Z' => return,
                else => {},
            }
        }
    }

    /// Runs one statement with the simple query protocol and returns its
    /// rows, allocated in `arena`.
    pub fn query(c: *Conn, arena: std.mem.Allocator, sql: []const u8) Error![]Row {
        var m: std.ArrayList(u8) = .empty;
        defer m.deinit(c.gpa);
        try m.appendSlice(c.gpa, sql);
        try m.append(c.gpa, 0);
        try c.send('Q', m.items);
        var rows: std.ArrayList(Row) = .empty;
        var failed = false;
        while (true) {
            const t = try c.recv();
            switch (t) {
                'D' => {
                    var r: Io.Reader = .fixed(c.msg.items);
                    const n = r.takeInt(u16, .big) catch return error.Protocol;
                    const row = try arena.alloc(?[]const u8, n);
                    for (row) |*v| {
                        const len = r.takeInt(i32, .big) catch return error.Protocol;
                        v.* = if (len < 0) null else try arena.dupe(u8, r.take(@intCast(len)) catch return error.Protocol);
                    }
                    try rows.append(arena, row);
                },
                'E' => {
                    c.serverError() catch {};
                    failed = true;
                },
                'Z' => break,
                else => {},
            }
        }
        if (failed) return error.ServerError;
        return rows.items;
    }

    /// Runs a query expected to return one value.
    pub fn scalar(c: *Conn, arena: std.mem.Allocator, sql: []const u8) Error!?[]const u8 {
        const rows = try c.query(arena, sql);
        if (rows.len == 0 or rows[0].len == 0) return null;
        return rows[0][0];
    }

    fn send(c: *Conn, t: ?u8, body: []const u8) Error!void {
        const w = &c.writer.interface;
        if (t) |b| w.writeByte(b) catch return error.WriteFailed;
        w.writeInt(u32, @intCast(body.len + 4), .big) catch return error.WriteFailed;
        w.writeAll(body) catch return error.WriteFailed;
        w.flush() catch return error.WriteFailed;
    }

    /// Reads one message into `msg` and returns its type.
    fn recv(c: *Conn) Error!u8 {
        const r = &c.reader.interface;
        const t = r.takeByte() catch |err| return mapRead(err);
        const len = r.takeInt(u32, .big) catch |err| return mapRead(err);
        if (len < 4 or len > 64 << 20) return error.Protocol;
        c.msg.clearRetainingCapacity();
        try c.msg.resize(c.gpa, len - 4);
        r.readSliceAll(c.msg.items) catch |err| return mapRead(err);
        return t;
    }

    fn mapRead(err: anytype) Error {
        return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => error.ReadFailed,
        };
    }

    fn serverError(c: *Conn) Error {
        // Fields: a type byte and a C string each, ending with a 0.
        var msg: []const u8 = "";
        var detail: []const u8 = "";
        var it = std.mem.splitScalar(u8, c.msg.items, 0);
        while (it.next()) |f| {
            if (f.len == 0) continue;
            switch (f[0]) {
                'M' => msg = f[1..],
                'D' => detail = f[1..],
                'C' => if (f.len == 6) @memcpy(&c.err_code, f[1..6]),
                else => {},
            }
        }
        if (detail.len > 0) {
            const both = std.fmt.allocPrint(c.gpa, "{s} ({s})", .{ msg, detail }) catch return error.OutOfMemory;
            defer c.gpa.free(both);
            c.setErr(both) catch return error.OutOfMemory;
        } else c.setErr(msg) catch return error.OutOfMemory;
        return error.ServerError;
    }

    fn setErr(c: *Conn, msg: []const u8) error{OutOfMemory}!void {
        if (c.err_msg.len > 0) c.gpa.free(c.err_msg);
        c.err_msg = try c.gpa.dupe(u8, msg);
    }
};

threadlocal var last_err_buf: [512]u8 = undefined;
threadlocal var last_err_len: usize = 0;
threadlocal var last_err_code: [5]u8 = "00000".*;

/// The message of the server error that made the last `connect` on this
/// thread fail.
pub fn lastConnectError() []const u8 {
    return last_err_buf[0..last_err_len];
}

/// Its SQLSTATE: 57P03 means the server is starting up.
pub fn lastConnectCode() []const u8 {
    return &last_err_code;
}

fn appendInt(gpa: std.mem.Allocator, l: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .big);
    try l.appendSlice(gpa, &b);
}

/// SCRAM-SHA-256 without channel binding (RFC 5802, RFC 7677).
const Scram = struct {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const b64 = std.base64.standard;

    nonce: [24]u8,
    first_buf: [64]u8 = undefined,
    first_len: usize = 0,
    final_buf: [256]u8 = undefined,
    auth_buf: [512]u8 = undefined,
    auth_len: usize = 0,
    salted: [32]u8 = undefined,

    fn init(io: Io) Scram {
        var raw: [18]u8 = undefined;
        io.random(&raw);
        var s: Scram = .{ .nonce = undefined };
        _ = b64.Encoder.encode(&s.nonce, &raw);
        return s;
    }

    /// client-first-message: "n,," + client-first-message-bare.
    fn clientFirst(s: *Scram) []const u8 {
        const m = std.fmt.bufPrint(&s.first_buf, "n,,n=,r={s}", .{s.nonce}) catch unreachable;
        s.first_len = m.len;
        return m;
    }

    fn clientFinal(s: *Scram, server_first: []const u8, password: []const u8) ![]const u8 {
        var nonce: []const u8 = "";
        var salt_b64: []const u8 = "";
        var iters: u32 = 0;
        var it = std.mem.splitScalar(u8, server_first, ',');
        while (it.next()) |attr| {
            if (attr.len < 2 or attr[1] != '=') continue;
            switch (attr[0]) {
                'r' => nonce = attr[2..],
                's' => salt_b64 = attr[2..],
                'i' => iters = try std.fmt.parseInt(u32, attr[2..], 10),
                else => {},
            }
        }
        if (!std.mem.startsWith(u8, nonce, &s.nonce) or iters == 0) return error.Protocol;
        var salt: [128]u8 = undefined;
        const salt_len = try b64.Decoder.calcSizeForSlice(salt_b64);
        if (salt_len > salt.len) return error.Protocol;
        try b64.Decoder.decode(salt[0..salt_len], salt_b64);

        try std.crypto.pwhash.pbkdf2(&s.salted, password, salt[0..salt_len], iters, Hmac);
        var client_key: [32]u8 = undefined;
        Hmac.create(&client_key, "Client Key", &s.salted);
        var stored_key: [32]u8 = undefined;
        Sha256.hash(&client_key, &stored_key, .{});

        const without_proof = try std.fmt.bufPrint(&s.final_buf, "c=biws,r={s}", .{nonce});
        const auth = try std.fmt.bufPrint(&s.auth_buf, "{s},{s},{s}", .{ s.first_buf[3..s.first_len], server_first, without_proof });
        s.auth_len = auth.len;
        var sig: [32]u8 = undefined;
        Hmac.create(&sig, auth, &stored_key);
        var proof: [32]u8 = undefined;
        for (&proof, client_key, sig) |*p, k, g| p.* = k ^ g;
        var proof_b64: [44]u8 = undefined;
        _ = b64.Encoder.encode(&proof_b64, &proof);
        const n = without_proof.len;
        const rest = try std.fmt.bufPrint(s.final_buf[n..], ",p={s}", .{proof_b64});
        return s.final_buf[0 .. n + rest.len];
    }

    fn verifyServer(s: *Scram, server_final: []const u8) bool {
        if (!std.mem.startsWith(u8, server_final, "v=")) return false;
        var server_key: [32]u8 = undefined;
        Hmac.create(&server_key, "Server Key", &s.salted);
        var sig: [32]u8 = undefined;
        Hmac.create(&sig, s.auth_buf[0..s.auth_len], &server_key);
        var want: [44]u8 = undefined;
        _ = b64.Encoder.encode(&want, &sig);
        const got = std.mem.trimEnd(u8, server_final[2..], "\x00");
        return std.mem.eql(u8, got, &want);
    }
};

test "scram proof matches RFC 7677's example" {
    // RFC 7677 section 3, with the example's nonce and password.
    var s: Scram = .{ .nonce = undefined };
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    // The RFC's client nonce is 20 characters, not our 24, so compute the
    // proof the way clientFinal does.
    const Hmac = Scram.Hmac;
    var salt: [16]u8 = undefined;
    try std.base64.standard.Decoder.decode(&salt, "W22ZaJ0SNY7soEsUEjb6gQ==");
    try std.crypto.pwhash.pbkdf2(&s.salted, "pencil", &salt, 4096, Hmac);
    var ck: [32]u8 = undefined;
    Hmac.create(&ck, "Client Key", &s.salted);
    var sk: [32]u8 = undefined;
    Scram.Sha256.hash(&ck, &sk, .{});
    const auth = "n=user,r=rOprNGfwEbeRWgbNEkqO," ++ server_first ++ ",c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
    var sig: [32]u8 = undefined;
    Hmac.create(&sig, auth, &sk);
    var proof: [32]u8 = undefined;
    for (&proof, ck, sig) |*p, k, g| p.* = k ^ g;
    var out: [44]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &proof);
    try std.testing.expectEqualStrings("dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", &out);
}
