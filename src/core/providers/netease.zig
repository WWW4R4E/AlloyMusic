// src/core/providers/netease.zig — 网易云直调实现（sidecar/providers/netease.cjs +
// NeteaseCloudMusicApi SDK 加密链路的 Zig 移植，只移植项目用到的端点）。
//
// 加密链路（util/crypto.js 同源）：
//   weapi: text → AES-128-CBC(presetKey,iv) b64 → AES-128-CBC(randomSecret,iv) b64
//          = params；encSecKey = RSA-None(secret 倒序)^65537 mod N（hex）
//   eapi:  params = AES-128-ECB(eapiKey, `${uri}-36cd479b6b5-${text}-36cd479b6b5-${md5}`) hex 大写
// RSA 无填充用 std.math.big.int 手写 square-and-multiply（指数 65537，17 步）。
//
// 端点映射（module/*.js 同路径同参数）：
//   search        eapi  /api/search/get
//   songUrl       eapi  /api/song/enhance/player/url/v1（上游间歇 502 → 退避重试）
//   lyrics        eapi  /api/song/lyric/v1
//   playlist      eapi  /api/v6/playlist/detail
//   playlistTracks eapi v6/detail 取 trackIds → v3/song/detail（c 参数）
//   recommend     weapi /api/playlist/list（每日推荐需登录，探索页用热榜）
//   fm            weapi /api/v1/radio/get
//   library       weapi nuser/account/get + user/playlist + album/sublist
//   liked         eapi  /api/song/like/get → song/detail 补全
//   like          weapi /api/radio/like（加）；eapi /api/playlist/manipulate/tracks（删）
//   登录          eapi  /api/login/qrcode/unikey + client/login
//
// 登录态：根目录 auth.json 的 netease.cookie（完整 cookie 串），与 sidecar 共享。
// 匿名 token（MUSIC_A）：读 /tmp/anonymous_token（SDK 留下的），缺失则现场注册。

const std = @import("std");
const Allocator = std.mem.Allocator;
const mod = @import("mod.zig");
const qr = @import("../qr.zig");
const paths = @import("../paths.zig");

pub const available = true;

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Result = mod.Result;
const ErrorCode = mod.ErrorCode;

pub const Error = error{ Api, OutOfMemory };

const EAPI_KEY = "e82ckenh8dichen8";
const PRESET_KEY = "0CoJUm6Qyw8W8jud";
const IV = "0102030405060708";
const BASE62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const RSA_N_HEX = "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7";
const RSA_E: u32 = 65537;
const DOMAIN = "https://music.163.com";
const API_DOMAIN = "https://interface.music.163.com";
const WEAPI_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0";
const EAPI_UA = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)";
const VIP_FEE = [_]f64{ 1, 4 }; // 1=VIP 4=购买专辑；8=低音质免费，不算 VIP

const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    a: Allocator, // arena
    client: std.http.Client,
    cookie: []const u8 = "", // 用户 cookie 串（MUSIC_U/__csrf 等）
    code: ErrorCode = .invalid_response,
    msg: []const u8 = "",

    fn fail(self: *Ctx, code: ErrorCode, msg: []const u8) Error {
        self.code = code;
        self.msg = msg;
        return error.Api;
    }
};

// ── JSON 小工具 ──

fn getF(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn objF(v: Value, key: []const u8) ?Value {
    const f = getF(v, key) orelse return null;
    return if (f == .object) f else null;
}

fn arrF(v: Value, key: []const u8) ?Value {
    const f = getF(v, key) orelse return null;
    return if (f == .array) f else null;
}

fn strF(v: Value, key: []const u8) ?[]const u8 {
    const f = getF(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn numF(v: Value, key: []const u8) f64 {
    const f = getF(v, key) orelse return 0;
    return switch (f) {
        .integer => |n| @floatFromInt(n),
        .float => |fl| fl,
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch 0,
        .bool => |b| if (b) 1 else 0,
        else => 0,
    };
}

fn numToString(a: Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        else => "",
    };
}

fn param(params: []const mod.Param, name: []const u8) []const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return "";
}

fn nowMs(ctx: *Ctx) i64 {
    return std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();
}

fn randomBytesHex(ctx: *Ctx, out: []u8, comptime upper: bool) void {
    const hex = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var buf: [64]u8 = undefined;
    var filled: usize = 0;
    while (filled < out.len) {
        ctx.io.random(&buf);
        for (buf) |b| {
            if (filled >= out.len) break;
            out[filled] = hex[b & 0xF];
            filled += 1;
        }
    }
}

// ── 加密原语 ──

fn md5Hex(text: []const u8) [32]u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(text);
    return std.fmt.bytesToHex(md5.finalResult(), .lower);
}

/// AES-128 单块
fn aesEncBlock(block: *std.crypto.core.aes.AesEncryptCtx(std.crypto.core.aes.Aes128), src: *const [16]u8, dst: *[16]u8) void {
    block.encrypt(dst, src);
}

/// PKCS7 填充 + AES-128-CBC，输出 base64（CryptoJS cbc 同语义）
fn aesCbcB64(ctx: *Ctx, key: []const u8, text: []const u8) Error![]const u8 {
    const a = ctx.a;
    const n_pad = 16 - (text.len % 16);
    const padded_len = text.len + n_pad;
    const buf = try a.alloc(u8, padded_len);
    @memcpy(buf[0..text.len], text);
    @memset(buf[text.len..], @intCast(n_pad));

    var block = std.crypto.core.aes.Aes128.initEnc(key[0..16].*);
    var out = try a.alloc(u8, padded_len);
    var prev: [16]u8 = IV[0..16].*;
    var i: usize = 0;
    while (i < padded_len) : (i += 16) {
        var xored: [16]u8 = undefined;
        for (0..16) |j| xored[j] = buf[i + j] ^ prev[j];
        var enc: [16]u8 = undefined;
        aesEncBlock(&block, &xored, &enc);
        @memcpy(out[i .. i + 16], &enc);
        prev = enc;
    }
    const enc64 = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc64.calcSize(padded_len));
    _ = enc64.encode(b64, out);
    return b64;
}

/// PKCS7 填充 + AES-128-ECB，输出大写 hex（eapi/linuxapi 同语义）
fn aesEcbHex(ctx: *Ctx, key: []const u8, text: []const u8) Error![]const u8 {
    const a = ctx.a;
    const n_pad = 16 - (text.len % 16);
    const padded_len = text.len + n_pad;
    const buf = try a.alloc(u8, padded_len);
    @memcpy(buf[0..text.len], text);
    @memset(buf[text.len..], @intCast(n_pad));

    var block = std.crypto.core.aes.Aes128.initEnc(key[0..16].*);
    var out = try a.alloc(u8, padded_len);
    var i: usize = 0;
    while (i < padded_len) : (i += 16) {
        var enc: [16]u8 = undefined;
        aesEncBlock(&block, buf[i..][0..16], &enc);
        @memcpy(out[i .. i + 16], &enc);
    }
    const hx = try a.alloc(u8, padded_len * 2);
    const symbols = "0123456789ABCDEF";
    for (out, 0..) |b, j| {
        hx[j * 2] = symbols[b >> 4];
        hx[j * 2 + 1] = symbols[b & 0xF];
    }
    return hx;
}

/// 大端字节串 → 大整数（r = r*256 + b；Managed 不允许目的与操作数别名）
fn setBytesBig(m: *std.math.big.int.Managed, bytes: []const u8) !void {
    var base = try std.math.big.int.Managed.init(m.allocator);
    defer base.deinit();
    try base.set(256);
    var digit = try std.math.big.int.Managed.init(m.allocator);
    defer digit.deinit();
    var tmp = try std.math.big.int.Managed.init(m.allocator);
    defer tmp.deinit();
    for (bytes) |b| {
        try tmp.mul(m, &base);
        try m.copy(tmp.toConst());
        try digit.set(b);
        try tmp.add(m, &digit);
        try m.copy(tmp.toConst());
    }
}

/// RSA-None：m = 字节串（大端）→ m^65537 mod N → 128 字节大端 hex
fn rsaNoPadHex(ctx: *Ctx, msg: []const u8) Error![]const u8 {
    const a = ctx.a;
    var m = std.math.big.int.Managed.init(a) catch return error.OutOfMemory;
    var n = std.math.big.int.Managed.init(a) catch return error.OutOfMemory;
    var r = std.math.big.int.Managed.init(a) catch return error.OutOfMemory;
    var tmp = std.math.big.int.Managed.init(a) catch return error.OutOfMemory;
    var q = std.math.big.int.Managed.init(a) catch return error.OutOfMemory;

    setBytesBig(&m, msg) catch return error.OutOfMemory;
    // 模数：hex → 字节 → 大端
    // RSA_N_HEX 是 257 个字符（奇数）：高位补 0 凑偶数再两两成字节
    const hex_full = if (RSA_N_HEX.len % 2 == 1) "0" ++ RSA_N_HEX else RSA_N_HEX;
    const n_bytes = try a.alloc(u8, hex_full.len / 2);
    for (n_bytes, 0..) |*b, i| {
        const hi = std.fmt.charToDigit(hex_full[i * 2], 16) catch 0;
        const lo = std.fmt.charToDigit(hex_full[i * 2 + 1], 16) catch 0;
        b.* = @as(u8, @intCast(hi)) << 4 | @as(u8, @intCast(lo));
    }
    setBytesBig(&n, n_bytes) catch return error.OutOfMemory;

    // square-and-multiply（从高位起；目的与操作数不别名）
    const e = RSA_E;
    var started = false;
    for (0..@bitSizeOf(u32)) |bit| {
        const bit_i = @bitSizeOf(u32) - 1 - bit;
        if (started) {
            tmp.mul(&r, &r) catch return error.OutOfMemory;
            q.divFloor(&r, &tmp, &n) catch return error.OutOfMemory;
        }
        if ((e >> @intCast(bit_i)) & 1 == 1) {
            if (!started) {
                r.copy(m.toConst()) catch return error.OutOfMemory;
                started = true;
            } else {
                tmp.mul(&r, &m) catch return error.OutOfMemory;
                q.divFloor(&r, &tmp, &n) catch return error.OutOfMemory;
            }
        }
    }

    // 结果 → 256 hex 字符，左补零（forge bytesToHex 小写）
    const hex_str = r.toString(a, 16, .lower) catch return error.OutOfMemory;
    const hx = try a.alloc(u8, 256);
    const pad = 256 - hex_str.len;
    @memset(hx[0..pad], '0');
    @memcpy(hx[pad..], hex_str);
    return hx;
}

/// weapi 加密（crypto.js weapi）
fn weapi(ctx: *Ctx, data: Value) Error!struct { params: []const u8, enc_sec_key: []const u8 } {
    const a = ctx.a;
    const text = std.json.Stringify.valueAlloc(a, data, .{}) catch return error.OutOfMemory;
    var secret: [16]u8 = undefined;
    for (&secret) |*c| {
        c.* = BASE62[randomUpto(ctx, BASE62.len)];
    }
    const first = try aesCbcB64(ctx, PRESET_KEY, text);
    const params = try aesCbcB64(ctx, &secret, first);
    // RSA 输入是 secret 倒序
    var reversed: [16]u8 = undefined;
    for (0..16) |i| reversed[i] = secret[15 - i];
    const enc_sec_key = try rsaNoPadHex(ctx, &reversed);
    return .{ .params = params, .enc_sec_key = enc_sec_key };
}

/// eapi 加密（crypto.js eapi）
fn eapi(ctx: *Ctx, uri: []const u8, data: Value) Error![]const u8 {
    const a = ctx.a;
    const text = std.json.Stringify.valueAlloc(a, data, .{}) catch return error.OutOfMemory;
    // digest = md5("nobody{url}use{text}md5forencrypt")（crypto.js eapi）
    const digest_src = try std.fmt.allocPrint(a, "nobody{s}use{s}md5forencrypt", .{ uri, text });
    const digest = md5Hex(digest_src);
    const message = try std.fmt.allocPrint(a, "{s}-36cd479b6b5-{s}-36cd479b6b5-{s}", .{ uri, text, digest });
    return aesEcbHex(ctx, EAPI_KEY, message);
}

fn randomUpto(ctx: *Ctx, range: usize) usize {
    var buf: [8]u8 = undefined;
    ctx.io.random(&buf);
    return @intCast(std.mem.readInt(u64, &buf, .little) % range);
}

// ── cookie 处理 ──

/// "k=v; k2=v2" → map
/// cookie 串按 ';' 切（auth.json 存的是 SDK set-cookie join(';')，含属性对，
/// 服务端容忍多余属性；解析时 trim 空白）
/// JS encodeURIComponent
fn encodeURIComponent(a: Allocator, s: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => try out.append(a, c),
            else => {
                try out.append(a, '%');
                try out.append(a, hex[c >> 4]);
                try out.append(a, hex[c & 0xF]);
            },
        }
    }
    return out.items;
}

fn parseCookie(ctx: *Ctx, cookie: []const u8) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, cookie, ';');
    while (it.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " ");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = pair[0..eq];
        // 过滤纯属性对（Max-Age/Expires/Path/Domain/Secure/HttpOnly/SameSite）
        if (std.ascii.eqlIgnoreCase(name, "Max-Age") or std.ascii.eqlIgnoreCase(name, "Expires") or
            std.ascii.eqlIgnoreCase(name, "Path") or std.ascii.eqlIgnoreCase(name, "Domain") or
            std.ascii.eqlIgnoreCase(name, "Secure") or std.ascii.eqlIgnoreCase(name, "HttpOnly") or
            std.ascii.eqlIgnoreCase(name, "SameSite")) continue;
        try map.put(ctx.a, name, pair[eq + 1 ..]);
    }
    return map;
}

/// processCookieObject：匿名/设备 cookie 默认值 + 用户 MUSIC_U 合并（weapi 用）
fn weapiCookieHeader(ctx: *Ctx, with_nmtid: bool) Error![]const u8 {
    const a = ctx.a;
    var m = parseCookie(ctx, ctx.cookie) catch return error.OutOfMemory;
    const anon = anonymousToken(ctx) catch "";
    const parts = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "__remember_me", .v = "true" },
        .{ .k = "ntes_kaola_ad", .v = "1" },
        .{ .k = "osver", .v = "Microsoft-Windows-10-Professional-build-19045-64bit" },
        .{ .k = "os", .v = "pc" },
        .{ .k = "channel", .v = "netease" },
        .{ .k = "appver", .v = "3.1.17.204416" },
    };
    for (parts) |p| {
        if (m.get(p.k) == null) m.put(a, p.k, p.v) catch return error.OutOfMemory;
    }
    if (m.get("_ntes_nuid") == null) {
        var uid: [32]u8 = undefined;
        randomBytesHex(ctx, &uid, false);
        m.put(a, "_ntes_nuid", try a.dupe(u8, &uid)) catch return error.OutOfMemory;
        m.put(a, "_ntes_nnid", try std.fmt.allocPrint(a, "{s},{d}", .{ uid[0..], nowMs(ctx) })) catch return error.OutOfMemory;
    }
    if (m.get("MUSIC_U") == null and anon.len > 0) {
        m.put(a, "MUSIC_A", anon) catch return error.OutOfMemory;
    }
    if (with_nmtid and m.get("NMTID") == null) {
        var nid: [16]u8 = undefined;
        randomBytesHex(ctx, &nid, false);
        m.put(a, "NMTID", try a.dupe(u8, &nid)) catch return error.OutOfMemory;
    }
    var out: std.ArrayList(u8) = .empty;
    var it = m.iterator();
    while (it.next()) |e| {
        if (out.items.len > 0) try out.appendSlice(a, "; ");
        try out.appendSlice(a, e.key_ptr.*);
        try out.append(a, '=');
        try out.appendSlice(a, e.value_ptr.*);
    }
    return out.items;
}

/// eapi header cookie（request.js createHeaderCookie：header 字段全量进 cookie）
fn eapiCookieHeader(ctx: *Ctx) Error![]const u8 {
    const a = ctx.a;
    var m = parseCookie(ctx, ctx.cookie) catch return error.OutOfMemory;
    var header: std.ArrayList(u8) = .empty;
    const music_u = m.get("MUSIC_U");
    const buildver = try std.fmt.allocPrint(a, "{d}", .{ @divTrunc(nowMs(ctx), 1000) });
    var rid_buf: [24]u8 = undefined;
    randomBytesHex(ctx, rid_buf[0..4], false);
    const request_id = try std.fmt.allocPrint(a, "{d}_{s}", .{ nowMs(ctx), rid_buf[0..4] });
    const fields = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "osver", .v = m.get("osver") orelse "Microsoft-Windows-10-Professional-build-19045-64bit" },
        .{ .k = "deviceId", .v = m.get("deviceId") orelse "" },
        .{ .k = "os", .v = m.get("os") orelse "pc" },
        .{ .k = "appver", .v = m.get("appver") orelse "3.1.17.204416" },
        .{ .k = "versioncode", .v = "140" },
        .{ .k = "mobilename", .v = "" },
        .{ .k = "buildver", .v = buildver },
        .{ .k = "resolution", .v = "1920x1080" },
        .{ .k = "__csrf", .v = m.get("__csrf") orelse "" },
        .{ .k = "channel", .v = m.get("channel") orelse "netease" },
        .{ .k = "requestId", .v = request_id },
    };
    for (fields) |f| {
        if (header.items.len > 0) try header.appendSlice(a, "; ");
        try header.appendSlice(a, f.k);
        try header.append(a, '=');
        try header.appendSlice(a, f.v);
    }
    if (music_u) |u| {
        try header.appendSlice(a, "; MUSIC_U=");
        try header.appendSlice(a, u);
    } else {
        const anon = anonymousToken(ctx) catch "";
        if (anon.len > 0) {
            try header.appendSlice(a, "; MUSIC_A=");
            try header.appendSlice(a, anon);
        }
    }
    return header.items;
}

/// 匿名 token（MUSIC_A）：优先 /tmp/anonymous_token（SDK 留下的）；缺失且
/// allow_register 时现场调 register_anonimous 换一个
fn anonymousToken(ctx: *Ctx) ![]const u8 {
    if (anonymous_token_cache) |t| return t;
    if (std.Io.Dir.cwd().readFileAlloc(ctx.io, "/tmp/anonymous_token", ctx.a, .limited(4096))) |raw| {
        const t = std.mem.trim(u8, raw, " \n\r\t");
        if (t.len > 0) {
            anonymous_token_cache = t;
            return t;
        }
    } else |_| {}
    const t = registerAnonymous(ctx) catch "";
    if (t.len > 0) anonymous_token_cache = t;
    return t;
}

var anonymous_token_cache: ?[]const u8 = null; // page_allocator 持有

/// register_anonimous：deviceId 52 位大写 hex → XOR 混淆 + md5b64 → base64 用户名
fn registerAnonymous(ctx: *Ctx) ![]const u8 {
    const a = ctx.a;
    var dev: [52]u8 = undefined;
    randomBytesHex(ctx, &dev, true);
    const key1 = "3go8&$8*3*3h0k(2)2";
    // cloudmusic_dll_encode_id：逐码点 XOR 后按 UTF-8 编码（XOR 可能 >127）
    var xored_utf8: std.ArrayList(u8) = .empty;
    for (dev, 0..) |c, i| {
        const code: u21 = c ^ key1[i % key1.len];
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(code, &buf) catch continue;
        try xored_utf8.appendSlice(a, buf[0..n]);
    }
    const dll_b64 = std.base64.standard.Encoder;
    const md5_digest = md5Hex(xored_utf8.items);
    const dll_id = try a.alloc(u8, dll_b64.calcSize(md5_digest.len));
    _ = dll_b64.encode(dll_id, &md5_digest);
    const username_src = try std.fmt.allocPrint(a, "{s} {s}", .{ dev[0..], dll_id });
    const username = try a.alloc(u8, dll_b64.calcSize(username_src.len));
    _ = dll_b64.encode(username, username_src);

    var data: ObjectMap = .empty;
    try data.put(a, "username", .{ .string = username });
    // 直发（不经过 weapiCall，避免 anonymousToken 递归）
    const enc = try weapi(ctx, .{ .object = data });
    const body = try formEncode(ctx, &.{ .{ "params", enc.params }, .{ "encSecKey", enc.enc_sec_key } });
    const cookie = try weapiCookieHeaderNoAnon(ctx);
    const url = try std.fmt.allocPrint(a, "{s}/weapi/register/anonimous", .{DOMAIN});
    const resp = try post(ctx, url, body, cookie, WEAPI_UA, DOMAIN);
    for (resp.set_cookies) |line| {
        const pair_end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const pair = line[0..pair_end];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], "MUSIC_A")) {
            const token = try std.heap.page_allocator.dupe(u8, pair[eq + 1 ..]);
            // 顺手落 /tmp/anonymous_token（与 SDK 同位置）
            if (std.Io.Dir.cwd().createFile(ctx.io, "/tmp/anonymous_token", .{})) |f| {
                f.writeStreamingAll(ctx.io, token) catch {};
                f.close(ctx.io);
            } else |_| {}
            return token;
        }
    }
    return "";
}

/// weapi cookie 但不带 MUSIC_A（注册匿名时用）
fn weapiCookieHeaderNoAnon(ctx: *Ctx) Error![]const u8 {
    const a = ctx.a;
    var m = parseCookie(ctx, ctx.cookie) catch return error.OutOfMemory;
    const parts = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "__remember_me", .v = "true" },
        .{ .k = "ntes_kaola_ad", .v = "1" },
        .{ .k = "osver", .v = "Microsoft-Windows-10-Professional-build-19045-64bit" },
        .{ .k = "os", .v = "pc" },
        .{ .k = "channel", .v = "netease" },
        .{ .k = "appver", .v = "3.1.17.204416" },
    };
    for (parts) |p| {
        if (m.get(p.k) == null) m.put(a, p.k, p.v) catch return error.OutOfMemory;
    }
    var out: std.ArrayList(u8) = .empty;
    var it = m.iterator();
    while (it.next()) |e| {
        if (out.items.len > 0) try out.appendSlice(a, "; ");
        try out.appendSlice(a, e.key_ptr.*);
        try out.append(a, '=');
        try out.appendSlice(a, try encodeURIComponent(a, e.value_ptr.*));
    }
    return out.items;
}

// ── 请求 ──

const Resp = struct {
    status: u16,
    set_cookies: []const []const u8 = &.{},
    body: []const u8 = "",
};

/// URLSearchParams 序列化（空格→+，其余保留集外 %XX 大写）
fn formEncode(ctx: *Ctx, pairs: []const [2][]const u8) Error![]const u8 {
    const a = ctx.a;
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |pair, i| {
        if (i > 0) try out.append(a, '&');
        for (pair[0]) |c| try formAppend(a, &out, c);
        try out.append(a, '=');
        for (pair[1]) |c| try formAppend(a, &out, c);
    }
    return out.items;
}

fn formAppend(a: Allocator, out: *std.ArrayList(u8), c: u8) !void {
    switch (c) {
        // URLSearchParams：'+' 必须编成 %2B（裸 + 会被服务端当空格，毁掉 base64）
        'A'...'Z', 'a'...'z', '0'...'9', '*', '-', '.', '_' => try out.append(a, c),
        ' ' => try out.append(a, '+'),
        else => {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(a, "%");
            try out.append(a, hex[c >> 4]);
            try out.append(a, hex[c & 0xF]);
        },
    }
}

fn post(ctx: *Ctx, url: []const u8, body: []const u8, cookie: []const u8, ua: []const u8, referer: []const u8) Error!Resp {
    const a = ctx.a;
    const uri = std.Uri.parse(url) catch return ctx.fail(.network, "URL 解析失败");
    var extra: std.ArrayList(std.http.Header) = .empty;
    try extra.append(a, .{ .name = "Cookie", .value = cookie });
    if (referer.len > 0) try extra.append(a, .{ .name = "Referer", .value = referer });

    var req = ctx.client.request(.POST, uri, .{
        .headers = .{
            .user_agent = .{ .override = ua },
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .extra_headers = extra.items,
        .redirect_behavior = @enumFromInt(3),
    }) catch return ctx.fail(.network, "netease 上游连接失败");
    defer req.deinit();
    req.sendBodyComplete(@constCast(body)) catch return ctx.fail(.network, "netease 请求发送失败");
    var response = req.receiveHead(&.{}) catch return ctx.fail(.network, "netease 响应接收失败");

    var cookies: std.ArrayList([]const u8) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
            cookies.append(a, a.dupe(u8, h.value) catch "") catch {};
        }
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => a.alloc(u8, std.compress.flate.max_window_len) catch @constCast(&.{}),
        .zstd => a.alloc(u8, std.compress.zstd.default_window_len) catch @constCast(&.{}),
        .compress => return ctx.fail(.network, "netease 压缩方式不支持"),
    };
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&aw.writer) catch return ctx.fail(.network, "netease 响应读取失败");
    return .{
        .status = @intFromEnum(response.head.status),
        .set_cookies = cookies.items,
        .body = aw.written(),
    };
}

/// eapi 请求：POST {API_DOMAIN}/eapi/<path>，body params=<hex>
fn eapiCall(ctx: *Ctx, uri: []const u8, data: *ObjectMap) Error!Value {
    const r = try eapiCallFull(ctx, uri, data);
    return r.body;
}

const FullResp = struct { body: Value, set_cookies: []const []const u8 };

fn eapiCallFull(ctx: *Ctx, uri: []const u8, data: *ObjectMap) Error!FullResp {
    const a = ctx.a;
    // request.js：data.e_r = false（encryptResponse 关闭，响应明文 JSON）
    try data.put(a, "e_r", .{ .bool = false });
    // request.js eapi 分支：设备 header 嵌进加密体（data.header = header）
    // 另有 data.e_r = false（encryptResponse 关闭，响应明文 JSON）
    try data.put(a, "e_r", .{ .bool = false });
        var m = parseCookie(ctx, ctx.cookie) catch return error.OutOfMemory;
        const buildver = try std.fmt.allocPrint(a, "{d}", .{@divTrunc(nowMs(ctx), 1000)});
        var rid_buf: [4]u8 = undefined;
        randomBytesHex(ctx, &rid_buf, false);
        const request_id = try std.fmt.allocPrint(a, "{d}_{s}", .{ nowMs(ctx), rid_buf[0..] });
        var header = emptyObj();
        const fields = [_]struct { k: []const u8, v: Value }{
            .{ .k = "osver", .v = .{ .string = m.get("osver") orelse "Microsoft-Windows-10-Professional-build-19045-64bit" } },
            .{ .k = "deviceId", .v = .{ .string = m.get("deviceId") orelse "" } },
            .{ .k = "os", .v = .{ .string = m.get("os") orelse "pc" } },
            .{ .k = "appver", .v = .{ .string = m.get("appver") orelse "3.1.17.204416" } },
            .{ .k = "versioncode", .v = .{ .string = "140" } },
            .{ .k = "mobilename", .v = .{ .string = "" } },
            .{ .k = "buildver", .v = .{ .string = buildver } },
            .{ .k = "resolution", .v = .{ .string = "1920x1080" } },
            .{ .k = "__csrf", .v = .{ .string = m.get("__csrf") orelse "" } },
            .{ .k = "channel", .v = .{ .string = m.get("channel") orelse "netease" } },
            .{ .k = "requestId", .v = .{ .string = request_id } },
        };
        for (fields) |f| try header.object.put(a, f.k, f.v);
        if (m.get("MUSIC_U")) |u| {
            try header.object.put(a, "MUSIC_U", .{ .string = u });
        } else {
            const anon = anonymousToken(ctx) catch "";
            if (anon.len > 0) try header.object.put(a, "MUSIC_A", .{ .string = anon });
        }
        try data.put(a, "header", header);
    const enc = try eapi(ctx, uri, .{ .object = data.* });
    const body = try formEncode(ctx, &.{.{ "params", enc }});
    const cookie = try eapiCookieHeader(ctx);
    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ API_DOMAIN, try eapiPath(ctx, uri) });
    const resp = try post(ctx, url, body, cookie, EAPI_UA, "");
    return .{ .body = try parseNeteaseBody(ctx, resp), .set_cookies = resp.set_cookies };
}

/// /api/xxx → /eapi/xxx
fn eapiPath(ctx: *Ctx, uri: []const u8) Error![]const u8 {
    if (!std.mem.startsWith(u8, uri, "/api/")) return ctx.fail(.unsupported, "bad uri");
    return std.fmt.allocPrint(ctx.a, "/eapi/{s}", .{uri[5..]}) catch error.OutOfMemory;
}

/// weapi 请求：POST {DOMAIN}/weapi/<path>，body params&encSecKey
fn weapiCall(ctx: *Ctx, uri: []const u8, data: *ObjectMap) Error!Value {
    const a = ctx.a;
    // data.csrf_token = cookie 里的 __csrf
    {
        const csrf = blk: {
            var m = parseCookie(ctx, ctx.cookie) catch break :blk "";
            break :blk m.get("__csrf") orelse "";
        };
        try data.put(a, "csrf_token", .{ .string = csrf });
    }
    const enc = try weapi(ctx, .{ .object = data.* });
    const body = try formEncode(ctx, &.{ .{ "params", enc.params }, .{ "encSecKey", enc.enc_sec_key } });
    const cookie = try weapiCookieHeader(ctx, std.mem.indexOf(u8, uri, "login") == null);
    const url = try std.fmt.allocPrint(a, "{s}/weapi/{s}", .{ DOMAIN, uri[5..] });
    const resp = try post(ctx, url, body, cookie, WEAPI_UA, DOMAIN);
    return parseNeteaseBody(ctx, resp);
}

/// 响应解析 + code 检查（netease.cjs call() 的映射：301/302→auth_required）
fn parseNeteaseBody(ctx: *Ctx, resp: Resp) Error!Value {
    const a = ctx.a;
    const v = std.json.parseFromSliceLeaky(Value, a, resp.body, .{}) catch
        return ctx.fail(.network, "netease 返回非 JSON");
    const code = numF(v, "code");
    if (code == 0) return v; // 无 code 字段当成功
    if (code == 301 or code == 302)
        return ctx.fail(.auth_required, try std.fmt.allocPrint(a, "需要登录（upstream {d}）", .{code}));
    // SDK 的 SPECIAL_STATUS_CODES：201/302/400/502/800/801/802/803 当 200 放行
    const special = [_]f64{ 201, 302, 400, 502, 800, 801, 802, 803 };
    for (special) |s| {
        if (code == s) return v;
    }
    if (code >= 400 and code != 803) {
        // 4xx/5xx 上游错误码（800/801/802/803 已在上面放行）
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(a, "upstream code {d}", .{code}));
    }
    return v;
}

// ── 统一 schema（对齐 netease.cjs 的 song/playlistOf）──

fn isVipFee(fee: f64) bool {
    for (VIP_FEE) |v| {
        if (fee == v) return true;
    }
    return false;
}

fn httpsOf(a: Allocator, url: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, url, "http:")) {
        return std.fmt.allocPrint(a, "https:{s}", .{url[5..]});
    }
    return url;
}

fn songOf(ctx: *Ctx, raw: Value) Error!?Value {
    const a = ctx.a;
    if (raw != .object) return null;
    const id_raw = getF(raw, "id") orelse return null;
    const id = try numToString(a, id_raw);
    if (id.len == 0) return null;
    const artists = arrF(raw, "artists") orelse arrF(raw, "ar");
    const album = objF(raw, "album") orelse objF(raw, "al") orelse emptyObj();
    var artist_str: std.ArrayList(u8) = .empty;
    if (artists) |arts| {
        for (arts.array.items) |x| {
            const name = strF(x, "name") orelse continue;
            if (name.len == 0) continue;
            if (artist_str.items.len > 0) try artist_str.appendSlice(a, " / ");
            try artist_str.appendSlice(a, name);
        }
    }
    var m: ObjectMap = .empty;
    try m.put(a, "id", .{ .string = id });
    try m.put(a, "backend", .{ .string = "netease" });
    try m.put(a, "title", .{ .string = strF(raw, "name") orelse "" });
    try m.put(a, "artist", .{ .string = if (artist_str.items.len > 0) artist_str.items else "未知歌手" });
    try m.put(a, "album", .{ .string = strF(album, "name") orelse "未知专辑" });
    try m.put(a, "durationS", .{ .integer = @intFromFloat(@round(numF(raw, "duration") / 1000)) });
    try m.put(a, "vip", .{ .bool = isVipFee(numF(raw, "fee")) });
    const pic = strF(album, "picUrl") orelse strF(raw, "picUrl") orelse "";
    try m.put(a, "coverUrl", .{ .string = try httpsOf(a, pic) });
    return .{ .object = m };
}

fn emptyObj() Value {
    return .{ .object = .empty };
}

fn playlistOf(ctx: *Ctx, raw: Value) Error!Value {
    const a = ctx.a;
    var m: ObjectMap = .empty;
    try m.put(a, "id", .{ .string = try numToString(a, getF(raw, "id") orelse Value{ .null = {} }) });
    try m.put(a, "backend", .{ .string = "netease" });
    try m.put(a, "name", .{ .string = strF(raw, "name") orelse "" });
    try m.put(a, "trackCount", .{ .integer = @intFromFloat(numF(raw, "trackCount") + numF(raw, "trackCountSize")) });
    try m.put(a, "kind", .{ .string = "playlist" });
    return .{ .object = m };
}

/// 搜索接口的 song.album 无 picUrl → 按 id 批量补（song_detail，失败静默）
fn fillCovers(ctx: *Ctx, songs: []Value) Error!void {
    const a = ctx.a;
    var missing: std.ArrayList([]const u8) = .empty;
    for (songs) |s| {
        const cu = strF(s, "coverUrl") orelse "";
        if (cu.len == 0) {
            missing.append(a, strF(s, "id") orelse continue) catch {};
        }
    }
    if (missing.items.len == 0) return;
    var c: std.ArrayList(u8) = .empty;
    try c.append(a, '[');
    for (missing.items, 0..) |id, i| {
        if (i > 0) try c.append(a, ',');
        try c.appendSlice(a, try std.fmt.allocPrint(a, "{{\"id\":{s}}}", .{id}));
    }
    try c.append(a, ']');
    const ids_arr = try std.fmt.allocPrint(a, "[{s}]", .{try std.mem.join(a, ",", missing.items)});
    var data: ObjectMap = .empty;
    try data.put(a, "c", .{ .string = c.items });
    try data.put(a, "ids", .{ .string = ids_arr });
    const r = weapiCall(ctx, "/api/v3/song/detail", &data) catch return;
    const body = objF(r, "body") orelse return;
    const detail = objF(body, "songs") orelse return;
    if (detail != .array) return;
    for (detail.array.items) |full| {
        const fid = try numToString(a, getF(full, "id") orelse continue);
        const al = objF(full, "al") orelse objF(full, "album") orelse continue;
        const pic = strF(al, "picUrl") orelse continue;
        for (songs) |*s| {
            if (std.mem.eql(u8, strF(s.*, "id") orelse "", fid)) {
                try s.object.put(a, "coverUrl", .{ .string = try httpsOf(a, pic) });
                break;
            }
        }
    }
}

fn songsEnvelope(ctx: *Ctx, songs: []Value, has_more: bool, total: ?u64) Error!Value {
    const a = ctx.a;
    var arr = std.json.Array.init(a);
    try arr.appendSlice(songs);
    var m: ObjectMap = .empty;
    try m.put(a, "songs", .{ .array = arr });
    try m.put(a, "hasMore", .{ .bool = has_more });
    if (total) |t| try m.put(a, "total", .{ .integer = @intCast(t) });
    return .{ .object = m };
}

// ── op 实现 ──

fn opSearch(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const kw = std.mem.trim(u8, param(params, "kw"), " ");
    if (kw.len == 0) return ctx.fail(.unsupported, "缺少 kw");
    const page: u32 = std.fmt.parseInt(u32, param(params, "page"), 10) catch 0;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 50;
    var data: ObjectMap = .empty;
    try data.put(a, "s", .{ .string = kw });
    try data.put(a, "type", .{ .integer = 1 });
    try data.put(a, "limit", .{ .integer = size });
    try data.put(a, "offset", .{ .integer = @intCast(page * size) });
    const r = try eapiCall(ctx, "/api/search/get", &data);
    const result = objF(r, "result") orelse emptyObj();
    var songs: std.ArrayList(Value) = .empty;
    if (arrF(result, "songs")) |l| {
        for (l.array.items) |item| {
            if (try songOf(ctx, item)) |song| try songs.append(a, song);
        }
    }
    try fillCovers(ctx, songs.items);
    const total: ?u64 = if (getF(result, "songCount") != null) @intFromFloat(numF(result, "songCount")) else null;
    return songsEnvelope(ctx, songs.items, songs.items.len == size, total);
}

fn opSongUrl(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    // song_url_v1（eapi）上游间歇性 502：带 timerstamp 防缓存 + 退避重试
    var last_err_code: ErrorCode = .network;
    var last_err_msg: []const u8 = "netease request failed";
    for (0..3) |attempt| {
        if (attempt > 0) {
            var req_ts: std.os.linux.timespec = .{ .sec = 0, .nsec = @intCast(400 * attempt * std.time.ns_per_ms) };
            _ = std.os.linux.nanosleep(&req_ts, null);
        }
        var data: ObjectMap = .empty;
        try data.put(a, "ids", .{ .string = try std.fmt.allocPrint(a, "[{s}]", .{id}) });
        // level 缺省 standard（sidecar server 时代默认；空串上游会按无权限处理）
    try data.put(a, "level", .{ .string = blk: {
        const lv = param(params, "level");
        break :blk if (lv.len > 0) lv else "standard";
    } });
        try data.put(a, "encodeType", .{ .string = "flac" });
        try data.put(a, "timerstamp", .{ .integer = nowMs(ctx) });
        const r = eapiCall(ctx, "/api/song/enhance/player/url/v1", &data) catch |e| switch (e) {
            error.Api => {
                if (ctx.code != .network) return error.Api; // not_playable/auth 重试无意义
                last_err_code = ctx.code;
                last_err_msg = ctx.msg;
                continue;
            },
            else => return e,
        };
        const darr = arrF(r, "data") orelse emptyObj();
        if (darr == .array and darr.array.items.len > 0) {
            const d = darr.array.items[0];
            const url = strF(d, "url") orelse "";
            if (url.len == 0) return ctx.fail(.not_playable, "无可用播放链接（VIP 或版权限制）");
            var m: ObjectMap = .empty;
            try m.put(a, "url", .{ .string = url });
            try m.put(a, "quality", .{ .string = strF(d, "level") orelse param(params, "level") });
            try m.put(a, "format", .{ .string = strF(d, "type") orelse "" });
            if (objF(d, "freeTrialInfo")) |trial| {
                var p: ObjectMap = .empty;
                try p.put(a, "startMs", .{ .integer = @intFromFloat(numF(trial, "start")) });
                try p.put(a, "endMs", .{ .integer = @intFromFloat(numF(trial, "end")) });
                try m.put(a, "preview", .{ .object = p });
            } else {
                try m.put(a, "preview", .{ .null = {} });
            }
            return .{ .object = m };
        }
        return ctx.fail(.not_playable, "无可用播放链接（VIP 或版权限制）");
    }
    return ctx.fail(last_err_code, last_err_msg);
}

fn opLyrics(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    var data: ObjectMap = .empty;
    try data.put(a, "id", .{ .string = id });
    try data.put(a, "cp", .{ .bool = false });
    try data.put(a, "tv", .{ .integer = 0 });
    try data.put(a, "lv", .{ .integer = 0 });
    try data.put(a, "rv", .{ .integer = 0 });
    try data.put(a, "kv", .{ .integer = 0 });
    try data.put(a, "yv", .{ .integer = 0 });
    try data.put(a, "ytv", .{ .integer = 0 });
    try data.put(a, "yrv", .{ .integer = 0 });
    const r = try eapiCall(ctx, "/api/song/lyric/v1", &data);
    const lrc_obj = objF(r, "lrc") orelse emptyObj();
    const tlyric_obj = objF(r, "tlyric") orelse emptyObj();
    const lrc = strF(lrc_obj, "lyric") orelse "";
    if (lrc.len == 0) return ctx.fail(.invalid_response, "歌词为空");
    var m: ObjectMap = .empty;
    try m.put(a, "lrc", .{ .string = lrc });
    try m.put(a, "tlyric", .{ .string = strF(tlyric_obj, "lyric") orelse "" });
    return .{ .object = m };
}

fn opPlaylist(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    var data: ObjectMap = .empty;
    try data.put(a, "id", .{ .string = id });
    try data.put(a, "n", .{ .integer = 100000 });
    try data.put(a, "s", .{ .integer = 8 });
    const r = try eapiCall(ctx, "/api/v6/playlist/detail", &data);
    const p = objF(r, "playlist") orelse return ctx.fail(.invalid_response, "playlist 缺失");
    var m: ObjectMap = .empty;
    try m.put(a, "playlist", try playlistOf(ctx, p));
    return .{ .object = m };
}

fn opPlaylistTracks(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    const page: u32 = std.fmt.parseInt(u32, param(params, "page"), 10) catch 0;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 50;
    // v6/detail 拿 trackIds（不翻页，全量 id 便宜）→ v3/song/detail 取当前页
    var data: ObjectMap = .empty;
    try data.put(a, "id", .{ .string = id });
    try data.put(a, "n", .{ .integer = 100000 });
    try data.put(a, "s", .{ .integer = 8 });
    const r = try eapiCall(ctx, "/api/v6/playlist/detail", &data);
    const pl = objF(r, "playlist") orelse return ctx.fail(.invalid_response, "playlist 缺失");
    var track_ids: std.ArrayList([]const u8) = .empty;
    if (arrF(pl, "trackIds")) |l| {
        for (l.array.items) |item| {
            try track_ids.append(a, try numToString(a, getF(item, "id") orelse continue));
        }
    }
    const total: u64 = track_ids.items.len;
    const start = @min(@as(usize, page) * size, track_ids.items.len);
    const end = @min(start + size, track_ids.items.len);
    if (start >= end) {
        return songsEnvelope(ctx, &.{}, false, total);
    }
    var c: std.ArrayList(u8) = .empty;
    try c.append(a, '[');
    for (track_ids.items[start..end], 0..) |tid, i| {
        if (i > 0) try c.append(a, ',');
        try c.appendSlice(a, try std.fmt.allocPrint(a, "{{\"id\":{s}}}", .{tid}));
    }
    try c.append(a, ']');
    var ddata: ObjectMap = .empty;
    try ddata.put(a, "c", .{ .string = c.items });
    const dr = try weapiCall(ctx, "/api/v3/song/detail", &ddata);
    var songs: std.ArrayList(Value) = .empty;
    if (arrF(dr, "songs")) |l| {
        for (l.array.items) |item| {
            if (try songOf(ctx, item)) |song| try songs.append(a, song);
        }
    }
    try fillCovers(ctx, songs.items);
    return songsEnvelope(ctx, songs.items, end < total, total);
}

/// login_status → profile.userId（library/radio/unlike 共用）
fn currentUid(ctx: *Ctx) Error!?[]const u8 {
    var no_data: ObjectMap = .empty;
    const r = weapiCall(ctx, "/api/w/nuser/account/get", &no_data) catch |e| switch (e) {
        error.Api => return null,
        else => return e,
    };
    const data = objF(r, "data") orelse r;
    const profile = objF(data, "profile") orelse objF(r, "profile") orelse return null;
    const uid = try numToString(ctx.a, getF(profile, "userId") orelse return null);
    if (uid.len == 0) return null;
    return uid;
}

fn opLibrary(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    _ = params;
    const uid = (try currentUid(ctx)) orelse return ctx.fail(.auth_required, "需要登录");
    var pl_data: ObjectMap = .empty;
    try pl_data.put(a, "uid", .{ .string = uid });
    try pl_data.put(a, "limit", .{ .integer = 100 });
    const pl = try weapiCall(ctx, "/api/user/playlist", &pl_data);
    var al_data: ObjectMap = .empty;
    try al_data.put(a, "limit", .{ .integer = 100 });
    const al = try weapiCall(ctx, "/api/album/sublist", &al_data);

    var owned = std.json.Array.init(a);
    var collected = std.json.Array.init(a);
    if (arrF(pl, "playlist")) |l| {
        if (l == .array) {
            for (l.array.items) |item| {
                if (getF(item, "subscribed")) |sub| {
                    if (sub == .bool and sub.bool) {
                        try collected.append(try playlistOf(ctx, item));
                    } else {
                        try owned.append(try playlistOf(ctx, item));
                    }
                }
            }
        }
    }
    var albums = std.json.Array.init(a);
    if (arrF(al, "data")) |l| {
        for (l.array.items) |raw| {
            var m: ObjectMap = .empty;
            try m.put(a, "id", .{ .string = try numToString(a, getF(raw, "id") orelse continue) });
            try m.put(a, "backend", .{ .string = "netease" });
            try m.put(a, "name", .{ .string = strF(raw, "name") orelse "" });
            try m.put(a, "trackCount", .{ .integer = @intFromFloat(numF(raw, "size")) });
            try m.put(a, "kind", .{ .string = "album" });
            try albums.append(.{ .object = m });
        }
    }
    var m: ObjectMap = .empty;
    try m.put(a, "owned", .{ .array = owned });
    try m.put(a, "collectedPlaylists", .{ .array = collected });
    try m.put(a, "collectedAlbums", .{ .array = albums });
    return .{ .object = m };
}

fn opRecommend(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 30;
    var data: ObjectMap = .empty;
    try data.put(a, "cat", .{ .string = "全部" });
    try data.put(a, "order", .{ .string = "hot" });
    try data.put(a, "limit", .{ .integer = size });
    try data.put(a, "offset", .{ .integer = 0 });
    try data.put(a, "total", .{ .bool = true });
    const r = try weapiCall(ctx, "/api/playlist/list", &data);
    var arr = std.json.Array.init(a);
    if (arrF(r, "playlists")) |l| {
        for (l.array.items) |item| {
            try arr.append(try playlistOf(ctx, item));
        }
    }
    var m: ObjectMap = .empty;
    try m.put(a, "playlists", .{ .array = arr });
    return .{ .object = m };
}

fn opLiked(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 100;
    var data: ObjectMap = .empty;
    try data.put(a, "uid", .{ .string = "" });
    try data.put(a, "timerstamp", .{ .integer = nowMs(ctx) });
    const r = try eapiCall(ctx, "/api/song/like/get", &data);
    var ids: std.ArrayList(u8) = .empty;
    try ids.append(a, '[');
    var count: usize = 0;
    if (arrF(r, "ids")) |l| {
        for (l.array.items) |item| {
            if (count >= @min(@as(u32, size), 200)) break;
            if (count > 0) try ids.append(a, ',');
            try ids.appendSlice(a, try numToString(a, item));
            count += 1;
        }
    }
    try ids.append(a, ']');
    if (count == 0) return songsEnvelope(ctx, &.{}, false, 0);
    // song_detail 的 c 是 id 对象数组
    var ids2: std.ArrayList(u8) = .empty;
    try ids2.append(a, '[');
    var it = std.mem.splitScalar(u8, ids.items[1 .. ids.items.len - 1], ',');
    var first = true;
    while (it.next()) |tid| {
        if (!first) try ids2.append(a, ',');
        try ids2.appendSlice(a, try std.fmt.allocPrint(a, "{{\"id\":{s}}}", .{tid}));
        first = false;
    }
    try ids2.append(a, ']');
    var sdata: ObjectMap = .empty;
    try sdata.put(a, "c", .{ .string = ids2.items });
    try sdata.put(a, "timerstamp", .{ .integer = nowMs(ctx) });
    const dr = try weapiCall(ctx, "/api/v3/song/detail", &sdata);
    var songs: std.ArrayList(Value) = .empty;
    if (arrF(dr, "songs")) |l| {
        for (l.array.items) |item| {
            if (try songOf(ctx, item)) |song| try songs.append(a, song);
        }
    }
    try fillCovers(ctx, songs.items);
    return songsEnvelope(ctx, songs.items, false, null);
}

fn opLike(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    const on = std.mem.eql(u8, param(params, "like"), "true");
    if (id.len == 0) return ctx.fail(.invalid_response, "缺少歌曲 id");
    if (on) {
        var data: ObjectMap = .empty;
        try data.put(a, "alg", .{ .string = "itembased" });
        try data.put(a, "trackId", .{ .integer = std.fmt.parseInt(i64, id, 10) catch 0 });
        try data.put(a, "like", .{ .bool = true });
        try data.put(a, "time", .{ .string = "3" });
        const r = try weapiCall(ctx, "/api/radio/like", &data);
        const code = numF(r, "code");
        // 502 = 已在红心列表，幂等视为成功
        if (code != 0 and code != 200 and code != 502)
            return ctx.fail(.invalid_response, try std.fmt.allocPrint(a, "like 返回 {d}", .{code}));
        var m: ObjectMap = .empty;
        try m.put(a, "liked", .{ .bool = true });
        return .{ .object = m };
    }
    // 取消喜欢：/api/like like=false 是假成功，必须对我喜欢的歌单删曲
    const pid = (try likedPid(ctx)) orelse return ctx.fail(.auth_required, "未登录，无法取消喜欢");
    var data: ObjectMap = .empty;
    try data.put(a, "op", .{ .string = "del" });
    try data.put(a, "pid", .{ .string = pid });
    try data.put(a, "trackIds", .{ .string = try std.fmt.allocPrint(a, "[{s}]", .{id}) });
    try data.put(a, "imme", .{ .string = "true" });
    const r = try eapiCall(ctx, "/api/playlist/manipulate/tracks", &data);
    var code = numF(r, "code");
    if (objF(r, "body")) |b| {
        if (numF(b, "code") != 0) code = numF(b, "code");
    }
    if (code != 0 and code != 200)
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(a, "unlike 返回 {d}", .{code}));
    var m: ObjectMap = .empty;
    try m.put(a, "liked", .{ .bool = false });
    return .{ .object = m };
}

fn opFm(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    _ = params;
    var no_data: ObjectMap = .empty;
    const r = try weapiCall(ctx, "/api/v1/radio/get", &no_data);
    var songs: std.ArrayList(Value) = .empty;
    if (arrF(r, "data")) |l| {
        for (l.array.items) |item| {
            const main = objF(item, "mainSong") orelse item;
            if (try songOf(ctx, main)) |song| try songs.append(a, song);
        }
    }
    return songsEnvelope(ctx, songs.items, false, null);
}

var heart_pid_cache: ?[]u8 = null; // page_allocator

/// 我喜欢的歌单 pid：login_status → user_playlist 第一条自建歌单
fn likedPid(ctx: *Ctx) Error!?[]const u8 {
    if (heart_pid_cache) |p| return p;
    const uid = (try currentUid(ctx)) orelse return null;
    var data: ObjectMap = .empty;
    try data.put(ctx.a, "uid", .{ .string = uid });
    try data.put(ctx.a, "limit", .{ .integer = 1 });
    const r = try weapiCall(ctx, "/api/user/playlist", &data);
    const body = objF(r, "body") orelse return null;
    const list = arrF(body, "playlist") orelse return null;
    if (list.array.items.len == 0) return null;
    const pid = try numToString(ctx.a, getF(list.array.items[0], "id") orelse return null);
    heart_pid_cache = std.heap.page_allocator.dupe(u8, pid) catch null;
    return heart_pid_cache;
}

/// 电台（心动模式）：种子 + 我喜欢的歌单 pid；无种子/未登录回落私人 FM
fn opRadio(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    const count: u32 = std.fmt.parseInt(u32, param(params, "count"), 10) catch 12;
    if (id.len > 0) {
        if (likedPid(ctx) catch null) |pid| {
            var data: ObjectMap = .empty;
            try data.put(a, "id", .{ .string = id });
            try data.put(a, "pid", .{ .string = pid });
            try data.put(a, "sid", .{ .string = id });
            try data.put(a, "count", .{ .integer = count });
            if (eapiCall(ctx, "/api/playmode/intelligence/list", &data)) |r| {
                const body = objF(r, "body") orelse emptyObj();
                var songs: std.ArrayList(Value) = .empty;
                if (arrF(body, "data")) |l| {
                    for (l.array.items) |item| {
                        const info = objF(item, "songInfo") orelse item;
                        if (try songOf(ctx, info)) |song| {
                            try songs.append(a, song);
                            if (songs.items.len >= count) break;
                        }
                    }
                }
                if (songs.items.len > 0) return songsEnvelope(ctx, songs.items, false, null);
            } else |_| {}
        }
    }
    return opFm(ctx, &.{});
}

// ── 登录（QR）──

fn opLoginQrKey(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    _ = params;
    var data: ObjectMap = .empty;
    try data.put(a, "type", .{ .integer = 3 });
    try data.put(a, "timerstamp", .{ .integer = nowMs(ctx) });
    const r = try eapiCall(ctx, "/api/login/qrcode/unikey", &data);
    const key = blk: {
        // SDK 包装：body.data = 原始响应；unikey 在原始响应顶层
        const d = objF(r, "data") orelse r;
        break :blk strF(d, "unikey") orelse "";
    };
    if (key.len == 0) return ctx.fail(.invalid_response, "netease unikey 缺失");
    const url = try std.fmt.allocPrint(a, "https://music.163.com/login?codekey={s}", .{key});
    const matrix = qr.encode(a, url, .medium) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TextTooLong => return ctx.fail(.invalid_response, "QR text too long"),
    };
    var rows = std.json.Array.init(a);
    for (0..matrix.size) |y| {
        const row = try a.alloc(u8, matrix.size);
        for (0..matrix.size) |x| {
            row[x] = if (matrix.modules[y * matrix.size + x]) '1' else '0';
        }
        try rows.append(.{ .string = row });
    }
    var m: ObjectMap = .empty;
    try m.put(a, "ok", .{ .bool = true });
    try m.put(a, "key", .{ .string = key });
    try m.put(a, "url", .{ .string = url });
    try m.put(a, "size", .{ .integer = matrix.size });
    try m.put(a, "rows", .{ .array = rows });
    return .{ .object = m };
}

fn opLoginQrCheck(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const key = param(params, "key");
    if (key.len == 0) return ctx.fail(.unsupported, "缺少 key");
    var data: ObjectMap = .empty;
    try data.put(a, "key", .{ .string = key });
    try data.put(a, "type", .{ .integer = 3 });
    try data.put(a, "timerstamp", .{ .integer = nowMs(ctx) });
    const full = try eapiCallFull(ctx, "/api/login/qrcode/client/login", &data);
    const r = full.body;
    const code = numF(r, "code");
    const state: ?[]const u8 = if (code == 800)
        "expired"
    else if (code == 801)
        "waiting"
    else if (code == 802)
        "scanned"
    else if (code == 803)
        "confirmed"
    else
        null;
    const state_str = state orelse
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(a, "netease QR code {d}", .{code}));
    if (!std.mem.eql(u8, state_str, "confirmed")) return stateEnvelope(a, state_str, "");

    // 803：Set-Cookie 里的 MUSIC_U/__csrf 合并落 auth.json（noCookie 语义由这里统一保存）
    var merged = parseCookie(ctx, ctx.cookie) catch return error.OutOfMemory;
    for (full.set_cookies) |line| {
        const pair_end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const pair = line[0..pair_end];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (eq == 0) continue;
        merged.put(a, pair[0..eq], pair[eq + 1 ..]) catch {};
    }
    var out: std.ArrayList(u8) = .empty;
    var it = merged.iterator();
    while (it.next()) |e| {
        if (out.items.len > 0) try out.appendSlice(a, "; ");
        try out.appendSlice(a, e.key_ptr.*);
        try out.append(a, '=');
        try out.appendSlice(a, e.value_ptr.*);
    }
    try saveCookie(ctx, out.items);
    ctx.cookie = out.items;

    const profile = objF(r, "profile") orelse emptyObj();
    return stateEnvelope(a, "confirmed", strF(profile, "nickname") orelse "");
}

fn stateEnvelope(a: Allocator, state: []const u8, nickname: []const u8) Allocator.Error!Value {
    var m: ObjectMap = .empty;
    try m.put(a, "ok", .{ .bool = true });
    try m.put(a, "state", .{ .string = state });
    var user: ObjectMap = .empty;
    try user.put(a, "nickname", .{ .string = nickname });
    try m.put(a, "user", .{ .object = user });
    return .{ .object = m };
}

fn opLogout(ctx: *Ctx, params: []const mod.Param) Error!Value {
    _ = params;
    try saveCookie(ctx, "");
    var m: ObjectMap = .empty;
    try m.put(ctx.a, "ok", .{ .bool = true });
    try m.put(ctx.a, "state", .{ .string = "logged_out" });
    return .{ .object = m };
}

fn saveCookie(ctx: *Ctx, cookie: []const u8) Error!void {
    const a = ctx.a;
    var m: ObjectMap = .empty;
    if (std.Io.Dir.cwd().readFileAlloc(ctx.io, paths.authPath(ctx.io, a), a, .limited(1 << 20))) |raw| {
        if (std.json.parseFromSliceLeaky(Value, a, raw, .{}) catch null) |root| {
            if (root == .object) m = root.object;
        }
    } else |_| {}
    var n: ObjectMap = .empty;
    try n.put(a, "cookie", .{ .string = cookie });
    try m.put(a, "netease", .{ .object = n });
    const payload = std.json.Stringify.valueAlloc(a, Value{ .object = m }, .{ .whitespace = .indent_2 }) catch
        return ctx.fail(.invalid_response, "auth 序列化失败");
    const file = std.Io.Dir.cwd().createFile(ctx.io, paths.authPath(ctx.io, a), .{
        .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600),
    }) catch return ctx.fail(.invalid_response, "auth.json 写入失败");
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, payload) catch return ctx.fail(.invalid_response, "auth.json 写入失败");
    cookie_cache = std.heap.page_allocator.dupe(u8, cookie) catch "";
}

var cookie_cache: ?[]const u8 = null;

// ── 分发 ──

const OpName = enum {
    search,
    songUrl,
    lyrics,
    playlist,
    playlistTracks,
    recommend,
    fm,
    radio,
    library,
    liked,
    like,
    loginQrKey,
    loginQrCheck,
    logout,
};

pub fn call(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    op: []const u8,
    params: []const mod.Param,
) Allocator.Error!?Result(Value) {
    var ctx = Ctx{
        .gpa = gpa,
        .io = io,
        .a = arena,
        .client = .{ .allocator = gpa, .io = io },
    };
    defer ctx.client.deinit();
    // 登录态懒加载（auth.json netease.cookie）
    if (cookie_cache == null) {
        if (std.Io.Dir.cwd().readFileAlloc(io, paths.authPath(io, arena), arena, .limited(1 << 20))) |raw| {
            if (std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch null) |root| {
                if (objF(root, "netease")) |n| {
                    const c = strF(n, "cookie") orelse "";
                    if (c.len > 0) cookie_cache = std.heap.page_allocator.dupe(u8, c) catch "";
                }
            }
        } else |_| {}
        if (cookie_cache == null) cookie_cache = "";
    }
    ctx.cookie = cookie_cache.?;

    const kind = std.meta.stringToEnum(OpName, op) orelse
        return Result(Value){ .err = .{ .code = .unsupported, .message = "未知操作" } };
    const v = run(&ctx, kind, params) catch |e| switch (e) {
        error.Api => return Result(Value){ .err = .{ .code = ctx.code, .message = ctx.msg } },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return Result(Value){ .ok = v };
}

fn run(ctx: *Ctx, op: OpName, params: []const mod.Param) Error!Value {
    return switch (op) {
        .search => opSearch(ctx, params),
        .songUrl => opSongUrl(ctx, params),
        .lyrics => opLyrics(ctx, params),
        .playlist => opPlaylist(ctx, params),
        .playlistTracks => opPlaylistTracks(ctx, params),
        .recommend => opRecommend(ctx, params),
        .fm => opFm(ctx, params),
        .radio => opRadio(ctx, params),
        .library => opLibrary(ctx, params),
        .liked => opLiked(ctx, params),
        .like => opLike(ctx, params),
        .loginQrKey => opLoginQrKey(ctx, params),
        .loginQrCheck => opLoginQrCheck(ctx, params),
        .logout => opLogout(ctx, params),
    };
}
