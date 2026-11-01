const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;

const API_ORIGIN = "https://bd-api.kuwo.cn";
const LYRIC_ORIGIN = "https://mlyric.kuwo.cn";
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;

pub const ErrorCode = enum {
    unsupported,
    invalid_response,
    auth_required,
    unavailable,
    network,
    not_playable,
    region_restricted,
};

pub const BodianError = struct {
    code: ErrorCode,
    message: []const u8,
    upstream_code: ?i64 = null,
};

pub const Param = struct { name: []const u8, value: []const u8 };

const Session = struct {
    uid: []const u8,
    token: []const u8,
};

const CallOptions = struct {
    params: []const Param = &.{},
    body: []const u8 = "",
    method: std.http.Method = .GET,
    signed: bool = false,
    anonymous: bool = false,
    lyric: bool = false,
};

const RequestOptions = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    named_headers: http.Client.Request.Headers = .{},
    headers: []const http.Header = &.{},
    body: []const u8 = "",
};

const DesktopHeaders = struct {
    named: http.Client.Request.Headers,
    extra: [9]http.Header,
};

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: BodianError,
    };
}

fn md5Hex(text: []const u8) [32]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(text);
    return std.fmt.bytesToHex(md5.finalResult(), .lower);
}

pub fn encodeQuery(gpa: Allocator, params: []const Param) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (params, 0..) |p, i| {
        if (i > 0) try out.append(gpa, '&');
        try encodeComponent(gpa, &out, p.name);
        try out.append(gpa, '=');
        try encodeComponent(gpa, &out, p.value);
    }
    return out.toOwnedSlice(gpa);
}

pub fn encodeComponent(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '*', '-', '.', '_' => try out.append(gpa, c),
            ' ' => try out.append(gpa, '+'),
            else => {
                try out.append(gpa, '%');
                try out.append(gpa, hex[c >> 4]);
                try out.append(gpa, hex[c & 0xF]);
            },
        }
    }
}

fn signQuery(gpa: Allocator, path: []const u8, query: []const u8, body: []const u8) Allocator.Error![32]u8 {
    var seed: std.ArrayList(u8) = .empty;
    defer seed.deinit(gpa);
    try seed.appendSlice(gpa, "kuwotest");

    for (query) |c|
        if (std.ascii.isAlphanumeric(c)) try seed.append(gpa, c);

    std.mem.sort(u8, seed.items[8..], {}, std.sort.asc(u8));

    if (body.len > 0) {
        var body_md5 = std.crypto.hash.Md5.init(.{});
        body_md5.update(body);
        body_md5.update("kuwotest");
        try seed.appendSlice(gpa, &std.fmt.bytesToHex(body_md5.finalResult(), .lower));
    }
    try seed.appendSlice(gpa, path);

    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(seed.items);
    return std.fmt.bytesToHex(md5.finalResult(), .lower);
}

fn desktopHeaders(device_id: []const u8) DesktopHeaders {
    return .{
        .named = .{
            .user_agent = .{ .override = "Dart/3.3 (dart:io)" },
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "gzip" },
        },
        .extra = .{
            .{ .name = "plat", .value = "win" },
            .{ .name = "channel", .value = "W1" },
            .{ .name = "ver", .value = "1.1.7" },
            .{ .name = "svrver", .value = "13" },
            .{ .name = "api-ver", .value = "application/json" },
            .{ .name = "brand", .value = "Windows" },
            .{ .name = "net", .value = "wifi" },
            .{ .name = "devid", .value = device_id },
            .{ .name = "qimei36", .value = device_id },
        },
    };
}

/// JS 的 Number(response.code)：兼容数字和数字字符串，取不到返回 null
fn codeOf(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        .number_string, .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// 传输层：发送请求并返回原始字节。传输失败用 Zig error 表达，
/// 由 Client.call 装进 Result.err。响应体的 gzip 由 std.http.Client 自动解压。
fn requestJson(client: *std.http.Client, gpa: Allocator, opts: RequestOptions) ![]u8 {
    if (opts.method == .GET and opts.body.len > 0)
        return requestJsonGetWithBody(client, gpa, opts);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = opts.url },
        .method = opts.method,
        .payload = if (opts.body.len > 0) opts.body else null,
        .headers = opts.named_headers,
        .extra_headers = opts.headers,
        .response_writer = &aw.writer,
    });

    const body = aw.written();
    const status = result.status;
    if (status == .unauthorized) return error.AuthRequired;
    switch (status.class()) {
        .success => {},
        else => return error.Network,
    }
    if (body.len > MAX_RESPONSE_BYTES) return error.ResponseTooLarge;
    return gpa.dupe(u8, body);
}

/// GET 带 JSON body 的手动发送路径（波点播放类接口的形态：POST 会被服务端
/// 500 拒绝，GET+body 才有效）。std.http.Client 的 sendBodiless / sendBody
/// 按"方法是否有 body"互斥断言，不支持 GET+body，所以走底层 Request：
/// head 里塞 content-length（extra_headers 原样输出），随后原样追加 body 字节。
fn requestJsonGetWithBody(client: *std.http.Client, gpa: Allocator, opts: RequestOptions) ![]u8 {
    const uri = try std.Uri.parse(opts.url);
    const len_str = try std.fmt.allocPrint(gpa, "{d}", .{opts.body.len});
    defer gpa.free(len_str);
    var extra: std.ArrayList(http.Header) = .empty;
    defer extra.deinit(gpa);
    try extra.appendSlice(gpa, opts.headers);
    try extra.append(gpa, .{ .name = "content-length", .value = len_str });

    var req = try client.request(.GET, uri, .{
        .headers = opts.named_headers,
        .extra_headers = extra.items,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();
    try req.sendBodiless();
    try req.connection.?.writer().writeAll(opts.body);
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    const status = response.head.status;
    if (status == .unauthorized) return error.AuthRequired;
    switch (status.class()) {
        .success => {},
        else => return error.Network,
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // 对齐 fetch 的响应读取姿势：gzip/deflate 需要显式解压 reader 与窗口缓冲
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .compress => return error.Network,
    };
    defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = try reader.streamRemaining(&aw.writer);

    const body = aw.written();
    if (body.len > MAX_RESPONSE_BYTES) return error.ResponseTooLarge;
    return gpa.dupe(u8, body);
}

pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    device_id: []const u8,
    session: ?Session = null,
    http_client: std.http.Client,

    pub fn init(gpa: Allocator, io: std.Io, device_id: []const u8) (Allocator.Error || error{InvalidDeviceId})!Client {
        if (device_id.len != 32) return error.InvalidDeviceId;
        for (device_id) |c| {
            if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidDeviceId;
        }
        return .{
            .gpa = gpa,
            .io = io,
            .device_id = device_id,
            .http_client = .{ .allocator = gpa, .io = io },
        };
    }

    pub fn deinit(self: *Client) void {
        self.http_client.deinit();
    }

    pub fn call(self: *Client, arena: Allocator, path: []const u8, opts: CallOptions) (Allocator.Error || error{NoSpaceLeft})!Result(std.json.Value) {
        if (!std.mem.startsWith(u8, path, "/") or std.mem.indexOf(u8, path, "..") != null) {
            return .{ .err = .{ .code = .unsupported, .message = "Invalid Bodian path" } };
        }

        const session: ?Session = if (opts.anonymous) null else self.session;

        // 拼 query：业务参数 + uid/token（匿名占位 -1/""），signed 时再加 timestamp
        var params: std.ArrayList(Param) = .empty;
        try params.appendSlice(arena, opts.params);
        var ts_buf: [24]u8 = undefined;
        if (session) |s| {
            try params.append(arena, .{ .name = "uid", .value = s.uid });
            try params.append(arena, .{ .name = "token", .value = s.token });
        } else {
            try params.append(arena, .{ .name = "uid", .value = "-1" });
            try params.append(arena, .{ .name = "token", .value = "" });
        }
        if (opts.signed) {
            const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            try params.append(arena, .{ .name = "timestamp", .value = try std.fmt.bufPrint(&ts_buf, "{d}", .{now_ms}) });
        }

        const query_for_sign = try encodeQuery(arena, params.items);
        const sign = try signQuery(arena, path, query_for_sign, opts.body);
        try params.append(arena, .{ .name = "sign", .value = &sign });

        const query = try encodeQuery(arena, params.items);
        const url = try std.fmt.allocPrint(arena, "{s}{s}?{s}", .{
            if (opts.lyric) LYRIC_ORIGIN else API_ORIGIN, path, query,
        });

        const desktop = desktopHeaders(self.device_id);
        var headers: std.ArrayList(http.Header) = .empty;
        try headers.appendSlice(arena, &desktop.extra);
        if (session) |s| {
            try headers.append(arena, .{ .name = "uid", .value = s.uid });
            try headers.append(arena, .{ .name = "token", .value = s.token });
        }

        const bytes = requestJson(&self.http_client, arena, .{
            .url = url,
            .method = opts.method,
            .named_headers = desktop.named,
            .headers = headers.items,
            .body = opts.body,
        }) catch |e| switch (e) {
            error.AuthRequired => return .{ .err = .{
                .code = .auth_required,
                .message = "Bodian HTTP 401",
            } },
            error.ResponseTooLarge => return .{ .err = .{
                .code = .invalid_response,
                .message = "Bodian response exceeded the size limit",
            } },
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .err = .{
                .code = .network,
                .message = "Bodian request failed",
            } },
        };

        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch
            return .{ .err = .{
                .code = .invalid_response,
                .message = "Bodian returned an unreadable response",
            } };

        const code = codeOf(if (value == .object) value.object.get("code") else null) orelse
            return .{ .err = .{
                .code = .invalid_response,
                .message = "Bodian rejected the request (code missing)",
            } };
        if (code == 200) return .{ .ok = value };

        if (code == 407) {
            var msg: []const u8 = "由于版权保护，该资源仅限中国大陆地区使用";
            if (value == .object) {
                const upstream = value.object.get("msg") orelse value.object.get("message");
                if (upstream) |m| {
                    if (m == .string and m.string.len > 0) msg = m.string;
                }
            }
            return .{ .err = .{
                .code = .region_restricted,
                .message = msg,
                .upstream_code = code,
            } };
        }

        return .{ .err = .{
            .code = if (code == 11012) .auth_required else if (code == 20018) .not_playable else .invalid_response,
            .message = try std.fmt.allocPrint(arena, "Bodian rejected the request (code {d})", .{code}),
            .upstream_code = code,
        } };
    }
};
