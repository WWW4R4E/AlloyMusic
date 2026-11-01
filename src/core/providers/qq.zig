// src/core/providers/qq.zig — QQ 音乐直调实现（sidecar/providers/qq.cjs 的 Zig 移植）。
//
// 协议：musicu.fcg 直连（无第三方 SDK），参考 HM2899/qq-music-tui 的
// qqmusic_api.py（GPL-3.0，按接口协议重写）。只读请求匿名即可（关键：访客
// cookie uin=o0000000000，否则 req.code=2001）；登录态经 ptlogin2 扫码获得。
//
// 与 Node 版的差异：
//   - 请求无显式 15s 超时（std.http.Client 不便设；风控退避节奏同源）。
//   - 登录态存根目录 auth.json 的 qq 段（读改写，保留
//     netease/bodian 段）；路径相对 cwd。
//   - QR 会话只在内存，进程重启需重扫（同 Node 版）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const mod = @import("mod.zig");

pub const available = true;

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Result = mod.Result;
const ErrorCode = mod.ErrorCode;

const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const LYRIC_URL = "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg";
const HOSTS = [_][]const u8{ "u.y.qq.com", "u6.y.qq.com" };
const APPID = "716027609";
const DAID = "383";
const PT_3RD_AID = "100497308";

pub const Error = error{ Api, OutOfMemory };

// ── 调用上下文：协议错误 ctx.fail → error.Api，call() 统一装 envelope ──

const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    a: Allocator, // arena：本请求所有产物
    client: std.http.Client,
    code: ErrorCode = .invalid_response,
    msg: []const u8 = "",

    fn fail(self: *Ctx, code: ErrorCode, msg: []const u8) Error {
        self.code = code;
        self.msg = msg;
        return error.Api;
    }
};

fn errEnvelope(a: Allocator, code: ErrorCode, msg: []const u8) Allocator.Error!Value {
    var m: ObjectMap = .empty;
    try m.put(a, "ok", .{ .bool = false });
    try m.put(a, "code", .{ .string = @tagName(code) });
    try m.put(a, "message", .{ .string = msg });
    return .{ .object = m };
}

// ── JSON Value 小工具 ──

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

/// JS Number(v)：数字/数字串/bool 都收，取不到 0
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

/// requireOk：node.code ?? 0 非 0 → invalid_response
fn requireOk(ctx: *Ctx, v: Value, name: []const u8) Error!Value {
    if (v != .object)
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(ctx.a, "{s} upstream code 缺失", .{name}));
    const code = numF(v, "code");
    if (code != 0)
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(ctx.a, "{s} upstream code {d}", .{ name, code }));
    return v;
}

fn param(params: []const mod.Param, name: []const u8) []const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return "";
}

fn emptyObj() Value {
    return .{ .object = .empty };
}

fn randomU64(ctx: *Ctx, range: u64) u64 {
    var buf: [8]u8 = undefined;
    ctx.io.random(&buf);
    return std.mem.readInt(u64, &buf, .little) % range;
}

fn nowMs(ctx: *Ctx) i64 {
    return std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();
}

// ── 持久登录态：根目录 auth.json 的 qq 段（读改写，与 sidecar 共存）──

var cookie_cache: ?[]const u8 = null; // page_allocator 持有；"" = 匿名

fn userCookie(ctx: *Ctx) []const u8 {
    if (cookie_cache) |c| return c;
    const loaded = loadCookie(ctx) catch "";
    cookie_cache = std.heap.page_allocator.dupe(u8, loaded) catch "";
    return cookie_cache.?;
}

fn loadCookie(ctx: *Ctx) ![]const u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "auth.json", ctx.a, .limited(1 << 20));
    const v = std.json.parseFromSliceLeaky(Value, ctx.a, raw, .{}) catch return "";
    const qq = objF(v, "qq") orelse return "";
    return strF(qq, "cookie") orelse "";
}

/// 凭证 → auth.json qq 段（0600；读改写保留 netease/bodian）
fn saveAuth(ctx: *Ctx, cookie: []const u8, uin: []const u8, nickname: []const u8) Error!void {
    const a = ctx.a;
    var m: ObjectMap = .empty;
    if (std.Io.Dir.cwd().readFileAlloc(ctx.io, "auth.json", a, .limited(1 << 20))) |raw| {
        if (std.json.parseFromSliceLeaky(Value, a, raw, .{}) catch null) |root| {
            if (root == .object) m = root.object;
        }
    } else |_| {}

    var qm: ObjectMap = .empty;
    try qm.put(a, "cookie", .{ .string = cookie });
    try qm.put(a, "uin", .{ .string = uin });
    try qm.put(a, "nickname", .{ .string = nickname });
    try qm.put(a, "createdAt", .{ .integer = nowMs(ctx) });
    try m.put(a, "qq", .{ .object = qm });

    const payload = std.json.Stringify.valueAlloc(a, Value{ .object = m }, .{ .whitespace = .indent_2 }) catch
        return ctx.fail(.invalid_response, "auth 序列化失败");
    const file = std.Io.Dir.cwd().createFile(ctx.io, "auth.json", .{
        .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600),
    }) catch return ctx.fail(.invalid_response, "auth.json 写入失败");
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, payload) catch return ctx.fail(.invalid_response, "auth.json 写入失败");
}

// ── cookie 处理 ──

/// 访客 cookie：qm_keyst 恒空、qimei36 每请求随机（固定值会被间歇性限流 2001）
fn guestCookie(ctx: *Ctx) Error![]const u8 {
    const a = ctx.a;
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(a, "00");
    for (0..30) |_| {
        const d = randomU64(ctx, 16);
        try s.append(a, "0123456789abcdef"[d]);
    }
    return std.fmt.allocPrint(a, "uin=o0000000000; qm_keyst=; qimei36={s}", .{s.items});
}

/// cookie 里的 uin=o12345 → "12345"；访客/缺失 → "0"
fn uinOf(cookie: []const u8) []const u8 {
    const key = "uin=o";
    var it = std.mem.splitSequence(u8, cookie, "; ");
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (std.mem.startsWith(u8, trimmed, key)) {
            const rest = trimmed[key.len..];
            if (rest.len > 0 and std.ascii.isDigit(rest[0])) return rest;
        }
    }
    return "0";
}

fn cookieValue(cookie: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, cookie, "; ");
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (std.mem.startsWith(u8, trimmed, name) and trimmed.len > name.len and trimmed[name.len] == '=') {
            return trimmed[name.len + 1 ..];
        }
    }
    return null;
}

// ── 传输 ──

const Resp = struct {
    status: u16,
    location: []const u8 = "",
    set_cookies: []const []const u8 = &.{},
    body: []const u8 = "",
};

const ReqOpts = struct {
    method: std.http.Method = .GET,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    cookie: []const u8 = "",
    referer: []const u8 = "",
    /// true = 不跟随重定向（30x 交给调用方看 Set-Cookie/Location）
    manual: bool = false,
};

fn request(ctx: *Ctx, url: []const u8, opts: ReqOpts) Error!Resp {
    const a = ctx.a;
    const uri = std.Uri.parse(url) catch return ctx.fail(.network, "URL 解析失败");

    var extra: std.ArrayList(std.http.Header) = .empty;
    if (opts.cookie.len > 0) try extra.append(a, .{ .name = "Cookie", .value = opts.cookie });
    // Node 版所有请求都带 Referer（c.y.qq.com 的歌词接口缺了会返回空 lyric）
    try extra.append(a, .{ .name = "Referer", .value = if (opts.referer.len > 0) opts.referer else "https://y.qq.com/" });

    var req = ctx.client.request(opts.method, uri, .{
        .headers = .{
            .user_agent = .{ .override = UA },
            .content_type = if (opts.body != null) .{ .override = opts.content_type } else .default,
        },
        .extra_headers = extra.items,
        .redirect_behavior = if (opts.manual) .unhandled else @enumFromInt(3),
    }) catch return ctx.fail(.network, "QQ 上游连接失败");
    defer req.deinit();

    if (opts.body) |b| {
        req.sendBodyComplete(@constCast(b)) catch return ctx.fail(.network, "QQ 请求发送失败");
    } else {
        req.sendBodiless() catch return ctx.fail(.network, "QQ 请求发送失败");
    }
    var response = req.receiveHead(&.{}) catch return ctx.fail(.network, "QQ 响应接收失败");

    // 收集跳转头（Location / Set-Cookie），再读 body
    var location: []const u8 = "";
    var cookies: std.ArrayList([]const u8) = .empty;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "location")) {
            location = a.dupe(u8, h.value) catch "";
        } else if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
            const dup = a.dupe(u8, h.value) catch continue;
            cookies.append(a, dup) catch {};
        }
    }

    var aw: std.Io.Writer.Allocating = .init(a);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .deflate, .gzip => a.alloc(u8, std.compress.flate.max_window_len) catch @constCast(&.{}),
        .zstd => a.alloc(u8, std.compress.zstd.default_window_len) catch @constCast(&.{}),
        .compress => return ctx.fail(.network, "QQ 上游压缩方式不支持"),
    };
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&aw.writer) catch return ctx.fail(.network, "QQ 响应读取失败");

    return .{
        .status = @intFromEnum(response.head.status),
        .location = location,
        .set_cookies = cookies.items,
        .body = aw.written(),
    };
}

// ── 迷你 cookie jar（键 name@domain；空值=过期标记，忽略）──
// 坑：check_sig 的 Set-Cookie 会先发真值 p_skey=<40位>、再发一条空的
// p_skey=（针对别的 Path 的过期标记）——空值不能当删除指令，否则把刚
// 收到的真值抹掉。

const Jar = struct {
    a: Allocator,
    map: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn get(self: *Jar, name: []const u8) ?[]const u8 {
        var it = self.map.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.startsWith(u8, key, name) and key.len > name.len and key[name.len] == '@') {
                return e.value_ptr.*;
            }
        }
        return null;
    }

    fn header(self: *Jar, host: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = self.map.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const at = std.mem.lastIndexOfScalar(u8, key, '@') orelse continue;
            const domain = key[at + 1 ..];
            const match = std.mem.eql(u8, host, domain) or
                (host.len > domain.len and std.mem.endsWith(u8, host, domain) and host[host.len - domain.len - 1] == '.');
            if (!match) continue;
            if (out.items.len > 0) try out.appendSlice(self.a, "; ");
            try out.appendSlice(self.a, key[0..at]);
            try out.append(self.a, '=');
            try out.appendSlice(self.a, e.value_ptr.*);
        }
        return out.items;
    }

    fn absorb(self: *Jar, set_cookies: []const []const u8, host: []const u8) !void {
        for (set_cookies) |line| {
            const pair_end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const pair = line[0..pair_end];
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (eq == 0) continue;
            const name = std.mem.trim(u8, pair[0..eq], " ");
            const value = std.mem.trim(u8, pair[eq + 1 ..], " ");
            if (value.len == 0) continue; // 空值=过期标记，忽略
            var domain = host;
            // Domain=.qq.com → qq.com（其余属性一律忽略，与迷你 jar 语义一致）
            const attrs = if (pair_end < line.len) line[pair_end + 1 ..] else "";
            var attr_it = std.mem.splitScalar(u8, attrs, ';');
            while (attr_it.next()) |attr| {
                const da = std.mem.indexOfScalar(u8, attr, '=') orelse continue;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, attr[0..da], " "), "domain")) {
                    domain = std.mem.trimStart(u8, std.mem.trim(u8, attr[da + 1 ..], " "), ".");
                }
            }
            const key = try std.fmt.allocPrint(self.a, "{s}@{s}", .{ name, domain });
            try self.map.put(self.a, key, value);
        }
    }
};

// ── QR 登录会话（内存；进程重启后二维码需重扫）──

const QrSession = struct {
    arena: *std.heap.ArenaAllocator,
    jar: Jar,
    qrsig: []const u8,
    created_ms: i64,
};

var qr_session: ?*QrSession = null;

fn dropQrSession() void {
    if (qr_session) |s| {
        const arena = s.arena;
        qr_session = null;
        arena.deinit();
        std.heap.page_allocator.destroy(arena);
    }
}

// ── musicu：风控退避 + 网关轮换 ──

/// 顶层各 req 键里任一 code=2001 → 退避重试并轮换 u.y/u6.y
fn riskControlled(json: Value) bool {
    if (json != .object) return false;
    var it = json.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .object and numF(e.value_ptr.*, "code") == 2001) return true;
    }
    return false;
}

/// 2001 = 服务端风控/限流。窗口式触发：同参数这秒挂、下秒过，
/// 退避重试可穿越（窗口一般 <5s）。最坏 ~18s 放弃。
const BACKOFFS_MS = [_]u64{ 0, 600, 1500, 3000, 5000, 8000 };

fn musicu(ctx: *Ctx, payload: Value) Error!Value {
    const a = ctx.a;
    // 登录态 musicu 必须带 tmeLoginType+authst，否则即使 cookie 有效
    // 也被判未登录（GetLoginUserInfo/recommend 返回 1000/1101）
    const cookie = userCookie(ctx);
    if (cookieValue(cookie, "qm_keyst")) |key| {
        if (key.len > 0) {
            if (payload.object.getEntry("comm")) |entry| {
                if (entry.value_ptr.* == .object) {
                    try entry.value_ptr.object.put(a, "tmeLoginType", .{ .integer = 2 });
                    try entry.value_ptr.object.put(a, "authst", .{ .string = key });
                }
            }
        }
    }
    var last: Value = .{ .null = {} };
    for (BACKOFFS_MS, 0..) |ms, attempt| {
        if (ms > 0) {
            const jitter = randomU64(ctx, 300);
            var req_ts: std.os.linux.timespec = .{ .sec = @intCast((ms + jitter) / 1000), .nsec = @intCast(((ms + jitter) % 1000) * std.time.ns_per_ms) };
            _ = std.os.linux.nanosleep(&req_ts, null);
        }
        last = try musicuOnce(ctx, HOSTS[attempt % HOSTS.len], payload);
        if (!riskControlled(last)) return last;
    }
    return last;
}

fn musicuOnce(ctx: *Ctx, host: []const u8, payload: Value) Error!Value {
    const a = ctx.a;
    const body = std.json.Stringify.valueAlloc(a, payload, .{}) catch return error.OutOfMemory;
    const url = try std.fmt.allocPrint(a, "https://{s}/cgi-bin/musicu.fcg", .{host});
    const cookie = if (userCookie(ctx).len > 0) userCookie(ctx) else try guestCookie(ctx);
    const resp = try request(ctx, url, .{
        .method = .POST,
        .body = body,
        .cookie = cookie,
        .referer = "https://y.qq.com/",
    });
    return std.json.parseFromSliceLeaky(Value, a, resp.body, .{}) catch
        ctx.fail(.invalid_response, "musicu.fcg 返回非 JSON");
}

// ── 统一 schema 条目构造（对齐 qq.cjs 的 trackOf/playlistOf 输出）──

fn cleanText(a: Allocator, v: []const u8) ![]const u8 {
    // 去 <tag> + trim
    var out: std.ArrayList(u8) = .empty;
    var depth: usize = 0;
    for (v) |c| {
        if (c == '<') {
            depth += 1;
        } else if (c == '>') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0) {
            try out.append(a, c);
        }
    }
    return std.mem.trim(u8, out.items, " \t\r\n");
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

/// 搜索条目是平铺形态（name/mid/singer[]），歌单曲目是 track_info 包装，两者都处理
fn trackOf(ctx: *Ctx, item: Value) Error!?Value {
    const a = ctx.a;
    const t = objF(item, "track_info") orelse item;
    if (t != .object) return null;
    var mid = strF(t, "songmid") orelse strF(t, "mid") orelse "";
    const id_raw = getF(t, "songid") orelse getF(t, "id") orelse Value{ .null = {} };
    var id = try numToString(a, id_raw);
    if (mid.len == 0 and id.len == 0) return null;
    if (id.len == 0) id = mid;
    if (mid.len == 0) mid = id;

    var artists: std.ArrayList(u8) = .empty;
    if (arrF(t, "singer")) |singers| {
        for (singers.array.items) |sv| {
            const name = strF(sv, "name") orelse continue;
            const cleaned = try cleanText(a, name);
            if (cleaned.len == 0) continue;
            if (artists.items.len > 0) try artists.appendSlice(a, " / ");
            try artists.appendSlice(a, cleaned);
        }
    }
    const file = objF(t, "file") orelse emptyObj();
    const pay = objF(t, "pay") orelse emptyObj();
    const media_mid = strF(file, "media_mid") orelse mid;
    const album = objF(t, "album");
    const album_mid = if (album) |al| (strF(al, "mid") orelse "") else "";
    const album_name = if (album) |al| (strF(al, "name") orelse "") else "";
    const title_raw = strF(t, "songname") orelse strF(t, "name") orelse strF(t, "title") orelse "";

    var m: ObjectMap = .empty;
    try m.put(a, "id", .{ .string = id });
    try m.put(a, "backend", .{ .string = "qq" });
    try m.put(a, "songMid", .{ .string = mid });
    try m.put(a, "mediaMid", .{ .string = media_mid });
    try m.put(a, "title", .{ .string = try cleanText(a, title_raw) });
    try m.put(a, "artist", .{ .string = if (artists.items.len > 0) artists.items else "未知歌手" });
    const album_clean = try cleanText(a, album_name);
    try m.put(a, "album", .{ .string = if (album_clean.len > 0) album_clean else "未知专辑" });
    try m.put(a, "durationS", .{ .integer = @intFromFloat(numF(t, "interval")) });
    try m.put(a, "vip", .{ .bool = numF(pay, "pay_play") + numF(pay, "payplay") > 0 });
    const file_album_mid = strF(file, "album_mid") orelse "";
    if (album_mid.len > 0 or file_album_mid.len > 0) {
        const am = if (album_mid.len > 0) album_mid else file_album_mid;
        try m.put(a, "coverUrl", .{ .string = try std.fmt.allocPrint(a, "https://y.gtimg.cn/music/photo_new/T002R300x300M000{s}.jpg", .{am}) });
    } else {
        try m.put(a, "coverUrl", .{ .string = "" });
    }
    return .{ .object = m };
}

fn playlistOf(ctx: *Ctx, raw: Value, fallback_id: []const u8) Error!Value {
    const a = ctx.a;
    const basic = objF(raw, "basic") orelse raw;
    const name_raw = strF(basic, "title") orelse strF(basic, "dissname") orelse strF(basic, "name") orelse "";
    var count = numF(basic, "songCount");
    if (count == 0) count = numF(raw, "total_song_num");
    const tid_raw = getF(basic, "tid") orelse getF(basic, "id") orelse getF(basic, "dissid") orelse Value{ .null = {} };
    var id = try numToString(a, tid_raw);
    if (id.len == 0) id = fallback_id;
    var m: ObjectMap = .empty;
    try m.put(a, "id", .{ .string = id });
    try m.put(a, "backend", .{ .string = "qq" });
    try m.put(a, "name", .{ .string = try cleanText(a, name_raw) });
    try m.put(a, "trackCount", .{ .integer = @intFromFloat(count) });
    try m.put(a, "kind", .{ .string = "playlist" });
    return .{ .object = m };
}

fn songArray(ctx: *Ctx, items: []const Value) Error!Value {
    const a = ctx.a;
    var arr = std.json.Array.init(a);
    for (items) |item| {
        if (try trackOf(ctx, item)) |song| try arr.append(song);
    }
    var m: ObjectMap = .empty;
    try m.put(a, "songs", .{ .array = arr });
    return .{ .object = m };
}

// ── 歌词 ──

/// 仅当整体像 base64 才解码（纯文本 LRC 会被静默解成乱码的坑同源）；
/// 否则按 nobase64=1 的 HTML 转义文本反转义
fn decodeLyric(ctx: *Ctx, raw: []const u8) Error![]const u8 {
    const a = ctx.a;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len >= 16 and isBase64Shape(trimmed)) {
        const dec = std.base64.standard.Decoder;
        if (dec.calcSizeForSlice(trimmed)) |n| {
            const buf = a.alloc(u8, n) catch return error.OutOfMemory;
            if (dec.decode(buf, trimmed)) {
                if (std.mem.indexOfScalar(u8, buf, 0) == null) return buf;
            } else |_| {}
        } else |_| {}
    }
    const pairs = [_][2][]const u8{
        .{ "&amp;", "&" },
        .{ "&lt;", "<" },
        .{ "&gt;", ">" },
        .{ "&quot;", "\"" },
        .{ "&#39;", "'" },
    };
    var out: []const u8 = raw;
    for (pairs) |pair| {
        out = try std.mem.replaceOwned(u8, a, out, pair[0], pair[1]);
    }
    return out;
}

fn isBase64Shape(s: []const u8) bool {
    var i: usize = s.len;
    var padding: usize = 0;
    while (i > 0 and s[i - 1] == '=') {
        padding += 1;
        i -= 1;
    }
    if (padding > 2) return false;
    for (s[0..i]) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '+', '/' => {},
            else => return false,
        }
    }
    return true;
}

// ── op 实现 ──

fn opSearch(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const kw = std.mem.trim(u8, param(params, "kw"), " ");
    if (kw.len == 0) return ctx.fail(.unsupported, "缺少 kw");
    const page: u32 = std.fmt.parseInt(u32, param(params, "page"), 10) catch 0;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 50;

    var payload: ObjectMap = .empty;
    var comm: ObjectMap = .empty;
    try comm.put(a, "ct", .{ .integer = 19 });
    try comm.put(a, "cv", .{ .integer = 1859 });
    try comm.put(a, "format", .{ .string = "json" });
    try comm.put(a, "uin", .{ .integer = std.fmt.parseInt(i64, uinOf(userCookie(ctx)), 10) catch 0 });
    var preq: ObjectMap = .empty;
    try preq.put(a, "query", .{ .string = kw });
    try preq.put(a, "page_num", .{ .integer = page + 1 });
    try preq.put(a, "num_per_page", .{ .integer = size });
    try preq.put(a, "search_type", .{ .integer = 0 });
    var req: ObjectMap = .empty;
    try req.put(a, "module", .{ .string = "music.search.SearchCgiService" });
    try req.put(a, "method", .{ .string = "DoSearchForQQMusicDesktop" });
    try req.put(a, "param", .{ .object = preq });
    try payload.put(a, "comm", .{ .object = comm });
    try payload.put(a, "req", .{ .object = req });

    const r = try musicu(ctx, .{ .object = payload });
    const reqv = try requireOk(ctx, getF(r, "req") orelse Value{ .null = {} }, "search");
    const data = objF(reqv, "data") orelse emptyObj();
    var list: []const Value = &.{};
    if (objF(data, "body")) |b| {
        if (objF(b, "song")) |so| {
            if (arrF(so, "list")) |l| list = l.array.items;
        }
    }
    var arr = std.json.Array.init(a);
    for (list) |item| {
        if (try trackOf(ctx, item)) |song| try arr.append(song);
    }
    var total = numF(data, "sum");
    if (objF(data, "meta")) |meta| total = numF(meta, "sum");
    if (total == 0) total = @floatFromInt(arr.items.len);
    var m: ObjectMap = .empty;
    try m.put(a, "songs", .{ .array = arr });
    try m.put(a, "hasMore", .{ .bool = arr.items.len > 0 and @as(f64, @floatFromInt((page + 1) * size)) < total });
    try m.put(a, "total", .{ .integer = @intFromFloat(total) });
    return .{ .object = m };
}

fn opSongUrl(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const song_mid = param(params, "mid");
    if (song_mid.len == 0) return ctx.fail(.unsupported, "缺少 mid（QQ 取链接用 songMid）");
    const uin = uinOf(userCookie(ctx));

    var payload: ObjectMap = .empty;
    var comm: ObjectMap = .empty;
    try comm.put(a, "uin", .{ .integer = std.fmt.parseInt(i64, uin, 10) catch 0 });
    try comm.put(a, "format", .{ .string = "json" });
    try comm.put(a, "ct", .{ .integer = 24 });
    try comm.put(a, "cv", .{ .integer = 0 });
    var pv: ObjectMap = .empty;
    const guid = randomU64(ctx, 9_000_000_000) + 1_000_000_000;
    try pv.put(a, "guid", .{ .string = try std.fmt.allocPrint(a, "{d}", .{guid}) });
    var mids = std.json.Array.init(a);
    try mids.append(.{ .string = song_mid });
    try pv.put(a, "songmid", .{ .array = mids });
    var types = std.json.Array.init(a);
    try types.append(.{ .integer = 0 });
    try pv.put(a, "songtype", .{ .array = types });
    try pv.put(a, "uin", .{ .string = uin });
    try pv.put(a, "loginflag", .{ .integer = 1 });
    try pv.put(a, "platform", .{ .string = "20" });
    var req0: ObjectMap = .empty;
    try req0.put(a, "module", .{ .string = "vkey.GetVkeyServer" });
    try req0.put(a, "method", .{ .string = "CgiGetVkey" });
    try req0.put(a, "param", .{ .object = pv });
    try payload.put(a, "req_0", .{ .object = req0 });
    try payload.put(a, "comm", .{ .object = comm });

    const r = try musicu(ctx, .{ .object = payload });
    const reqv = try requireOk(ctx, getF(r, "req_0") orelse Value{ .null = {} }, "songUrl");
    const data = objF(reqv, "data") orelse emptyObj();
    var purl: []const u8 = "";
    var sip: []const u8 = "";
    if (arrF(data, "midurlinfo")) |info| {
        if (info.array.items.len > 0) purl = strF(info.array.items[0], "purl") orelse "";
    }
    if (arrF(data, "sip")) |sips| {
        if (sips.array.items.len > 0) {
            sip = switch (sips.array.items[0]) {
                .string => |s| s,
                else => "",
            };
        }
    }
    if (purl.len == 0 or sip.len == 0)
        return ctx.fail(.not_playable, "该歌曲需要 QQ 音乐会员或登录后播放");
    var m: ObjectMap = .empty;
    try m.put(a, "url", .{ .string = try urlJoin(a, sip, purl) });
    try m.put(a, "quality", .{ .string = "default" });
    try m.put(a, "format", .{ .null = {} });
    try m.put(a, "preview", .{ .null = {} });
    return .{ .object = m };
}

/// JS new URL(purl, sip)：purl 是绝对路径 → sip 的 origin + purl
fn urlJoin(a: Allocator, sip: []const u8, purl: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, purl, "http")) return purl;
    const scheme_end = std.mem.indexOf(u8, sip, "://") orelse return purl;
    const path_start = std.mem.indexOfScalarPos(u8, sip, scheme_end + 3, '/') orelse sip.len;
    // purl 相对路径可能不带前导斜杠：保证恰好一个分隔
    if (purl.len > 0 and purl[0] == '/')
        return std.fmt.allocPrint(a, "{s}{s}", .{ sip[0..path_start], purl });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ sip[0..path_start], purl });
}

fn opLyrics(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const song_mid = param(params, "mid");
    if (song_mid.len == 0) return ctx.fail(.unsupported, "缺少 mid");
    const url = try std.fmt.allocPrint(a, "{s}?songmid={s}&format=json&nobase64=1&g_tk=5381", .{ LYRIC_URL, song_mid });
    const resp = try request(ctx, url, .{ .cookie = if (userCookie(ctx).len > 0) userCookie(ctx) else try guestCookie(ctx) });
    const json = std.json.parseFromSliceLeaky(Value, a, resp.body, .{}) catch
        return ctx.fail(.invalid_response, "lyric 返回非 JSON");
    const lrc = try decodeLyric(ctx, strF(json, "lyric") orelse "");
    if (lrc.len == 0) return ctx.fail(.invalid_response, "歌词为空");
    var m: ObjectMap = .empty;
    try m.put(a, "lrc", .{ .string = lrc });
    try m.put(a, "tlyric", .{ .string = try decodeLyric(ctx, strF(json, "trans") orelse "") });
    return .{ .object = m };
}

/// 我的喜欢当 dirid=201 歌单（QQ 语义，参考实现同款）
fn playlistHeader(ctx: *Ctx, fav_total: u64) Error!Value {
    const a = ctx.a;
    var pl: ObjectMap = .empty;
    try pl.put(a, "id", .{ .string = "201" });
    try pl.put(a, "backend", .{ .string = "qq" });
    try pl.put(a, "name", .{ .string = "我的喜欢" });
    try pl.put(a, "trackCount", .{ .integer = @intCast(fav_total) });
    try pl.put(a, "kind", .{ .string = "playlist" });
    var m: ObjectMap = .empty;
    try m.put(a, "playlist", .{ .object = pl });
    return .{ .object = m };
}

fn opPlaylist(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (std.mem.eql(u8, id, "201")) {
        const fav = try myFavMids(ctx);
        return playlistHeader(ctx, fav.total);
    }
    const p = std.fmt.parseInt(u64, id, 10) catch return ctx.fail(.unsupported, "缺少歌单 id（disstid，纯数字）");
    const data = try cgiGetDiss(ctx, p, 0, 1);
    var pl = try playlistOf(ctx, objF(data, "dirinfo") orelse emptyObj(), id);
    // total_song_num 在 data 层，dirinfo 里没有
    const tsn = numF(data, "total_song_num");
    if (tsn > 0) try pl.object.put(a, "trackCount", .{ .integer = @intFromFloat(tsn) });
    var m: ObjectMap = .empty;
    try m.put(a, "playlist", pl);
    return .{ .object = m };
}

fn cgiGetDiss(ctx: *Ctx, disstid: u64, song_begin: u32, song_num: u32) Error!Value {
    const a = ctx.a;
    var payload: ObjectMap = .empty;
    var comm: ObjectMap = .empty;
    try comm.put(a, "ct", .{ .integer = 24 });
    try comm.put(a, "cv", .{ .integer = 4747474 });
    try comm.put(a, "format", .{ .string = "json" });
    try comm.put(a, "uin", .{ .integer = std.fmt.parseInt(i64, uinOf(userCookie(ctx)), 10) catch 0 });
    var pv: ObjectMap = .empty;
    try pv.put(a, "disstid", .{ .integer = @intCast(disstid) });
    try pv.put(a, "dirid", .{ .integer = 0 });
    try pv.put(a, "tag", .{ .integer = 1 });
    try pv.put(a, "song_begin", .{ .integer = song_begin });
    try pv.put(a, "song_num", .{ .integer = song_num });
    try pv.put(a, "userinfo", .{ .integer = 1 });
    try pv.put(a, "orderlist", .{ .integer = 1 });
    try pv.put(a, "onlysonglist", .{ .integer = 0 });
    var req0: ObjectMap = .empty;
    try req0.put(a, "module", .{ .string = "music.srfDissInfo.DissInfo" });
    try req0.put(a, "method", .{ .string = "CgiGetDiss" });
    try req0.put(a, "param", .{ .object = pv });
    try payload.put(a, "comm", .{ .object = comm });
    try payload.put(a, "req_0", .{ .object = req0 });
    const r = try musicu(ctx, .{ .object = payload });
    const reqv = try requireOk(ctx, getF(r, "req_0") orelse Value{ .null = {} }, "playlist");
    return objF(reqv, "data") orelse emptyObj();
}

fn opPlaylistTracks(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    const page: u32 = std.fmt.parseInt(u32, param(params, "page"), 10) catch 0;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 50;
    if (std.mem.eql(u8, id, "201")) {
        // 我的喜欢：全量 mids → 当前页切片 → 批量详情
        const fav = try myFavMids(ctx);
        const start = @min(@as(usize, page) * size, fav.mids.len);
        const end = @min(start + size, fav.mids.len);
        const songs = try songsByMids(ctx, fav.mids[start..end]);
        var m: ObjectMap = .empty;
        try m.put(a, "songs", songs.object.get("songs").?);
        try m.put(a, "hasMore", .{ .bool = @as(u64, page + 1) * size < fav.total });
        try m.put(a, "total", .{ .integer = @intCast(fav.total) });
        return .{ .object = m };
    }
    const p = std.fmt.parseInt(u64, id, 10) catch return ctx.fail(.unsupported, "缺少歌单 id（disstid，纯数字）");
    const data = try cgiGetDiss(ctx, p, page * size, size);
    var list: []const Value = &.{};
    if (arrF(data, "songlist")) |l| list = l.array.items;
    var arr = std.json.Array.init(a);
    for (list) |item| {
        if (try trackOf(ctx, item)) |song| try arr.append(song);
    }
    const total = @max(arr.items.len, @as(usize, @intFromFloat(numF(data, "total_song_num"))));
    var m: ObjectMap = .empty;
    try m.put(a, "songs", .{ .array = arr });
    try m.put(a, "hasMore", .{ .bool = arr.items.len > 0 and @as(usize, (page + 1)) * size < total });
    try m.put(a, "total", .{ .integer = @intCast(total) });
    return .{ .object = m };
}

fn opLiked(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 100;
    const fav = try myFavMids(ctx);
    const end = @min(fav.mids.len, @min(@as(usize, size), 200));
    return songsByMids(ctx, fav.mids[0..end]);
}

fn opRecommend(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 30;
    var payload: ObjectMap = .empty;
    var comm: ObjectMap = .empty;
    try comm.put(a, "ct", .{ .integer = 24 });
    try comm.put(a, "cv", .{ .integer = 4747474 });
    try comm.put(a, "format", .{ .string = "json" });
    try comm.put(a, "uin", .{ .integer = std.fmt.parseInt(i64, uinOf(userCookie(ctx)), 10) catch 0 });
    var pv: ObjectMap = .empty;
    try pv.put(a, "From", .{ .integer = 0 });
    try pv.put(a, "Size", .{ .integer = size });
    var req0: ObjectMap = .empty;
    try req0.put(a, "module", .{ .string = "music.playlist.PlaylistSquare" });
    try req0.put(a, "method", .{ .string = "GetRecommendFeed" });
    try req0.put(a, "param", .{ .object = pv });
    try payload.put(a, "comm", .{ .object = comm });
    try payload.put(a, "playlists", .{ .object = req0 });

    const r = try musicu(ctx, .{ .object = payload });
    const reqv = try requireOk(ctx, getF(r, "playlists") orelse Value{ .null = {} }, "recommend");
    const data = objF(reqv, "data") orelse emptyObj();
    var arr = std.json.Array.init(a);
    if (arrF(data, "List")) |l| {
        for (l.array.items) |item| {
            const pl_basic = if (objF(item, "Playlist")) |p| (objF(p, "basic") orelse emptyObj()) else emptyObj();
            const tid = strF(pl_basic, "tid") orelse @as([]const u8, "");
            const pl = try playlistOf(ctx, pl_basic, tid);
            const pid = strF(pl, "id") orelse @as([]const u8, "");
            if (pid.len > 0) try arr.append(pl);
        }
    }
    var m: ObjectMap = .empty;
    try m.put(a, "playlists", .{ .array = arr });
    return .{ .object = m };
}

/// 电台（刷歌模式）：radioProxy.MbTrackRadioSvr.get_radio_track。
/// param.song_ids 理论上是种子位，实测传任何 id/mid 都报上游 10006
/// （参考实现也永远传空数组）——带种子的调用一律回落无种子请求。
fn opRadio(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const seed_mid = param(params, "mid");
    if (seed_mid.len > 0) {
        if (radioOnce(ctx, seed_mid)) |songs| {
            if (arrF(songs, "songs")) |arr| {
                if (arr.array.items.len > 0) return songs;
            }
        } else |_| {}
    }
    const songs = try radioOnce(ctx, "");
    if (arrF(songs, "songs")) |arr| {
        if (arr.array.items.len == 0) return ctx.fail(.invalid_response, "电台返回空（可能需登录）");
    }
    return songs;
}

fn radioOnce(ctx: *Ctx, seed_mid: []const u8) Error!Value {
    const a = ctx.a;
    var payload: ObjectMap = .empty;
    var comm: ObjectMap = .empty;
    try comm.put(a, "ct", .{ .integer = 24 });
    try comm.put(a, "cv", .{ .integer = 4747474 });
    try comm.put(a, "format", .{ .string = "json" });
    try comm.put(a, "uin", .{ .integer = std.fmt.parseInt(i64, uinOf(userCookie(ctx)), 10) catch 0 });
    var pv: ObjectMap = .empty;
    try pv.put(a, "id", .{ .integer = 99 });
    try pv.put(a, "num", .{ .integer = 12 });
    try pv.put(a, "from", .{ .integer = 0 });
    try pv.put(a, "scene", .{ .integer = 0 });
    var song_ids = std.json.Array.init(a);
    if (seed_mid.len > 0) try song_ids.append(.{ .string = seed_mid });
    try pv.put(a, "song_ids", .{ .array = song_ids });
    var req0: ObjectMap = .empty;
    try req0.put(a, "module", .{ .string = "music.radioProxy.MbTrackRadioSvr" });
    try req0.put(a, "method", .{ .string = "get_radio_track" });
    try req0.put(a, "param", .{ .object = pv });
    try payload.put(a, "comm", .{ .object = comm });
    try payload.put(a, "radio", .{ .object = req0 });

    const r = try musicu(ctx, .{ .object = payload });
    const reqv = try requireOk(ctx, getF(r, "radio") orelse Value{ .null = {} }, "radio");
    const data = objF(reqv, "data") orelse emptyObj();
    var list: []const Value = &.{};
    if (arrF(data, "tracks")) |l| list = l.array.items;
    return songArray(ctx, list);
}

/// 我的歌单 = 我的喜欢（QQ 把"我的喜欢"当 dirid=201 歌单；参考实现同款）
fn opLibrary(ctx: *Ctx, params: []const mod.Param) Error!Value {
    _ = params;
    const a = ctx.a;
    const fav = try myFavMids(ctx);
    var owned = std.json.Array.init(a);
    try owned.append(try playlistHeader(ctx, fav.total));
    var m: ObjectMap = .empty;
    try m.put(a, "owned", .{ .array = owned });
    try m.put(a, "collected", .{ .array = std.json.Array.init(a) });
    try m.put(a, "albums", .{ .array = std.json.Array.init(a) });
    return .{ .object = m };
}

const Fav = struct {
    mids: []const []const u8,
    total: u64,
};

/// getmyfav.fcg：g_tk 用 p_l_skey（gtk 算法）+ 登录 cookie
fn myFavMids(ctx: *Ctx) Error!Fav {
    const a = ctx.a;
    const cookie = userCookie(ctx);
    if (cookie.len == 0) return ctx.fail(.auth_required, "QQ 未登录");
    const uin = uinOf(cookie);
    const skey = cookieValue(cookie, "p_l_skey") orelse "";
    const url = try std.fmt.allocPrint(a, "https://c.y.qq.com/splcloud/fcgi-bin/fcg_musiclist_getmyfav.fcg?dirid=201&dirinfo=1&g_tk={d}&format=json&loginUin={s}", .{ gtk(skey), uin });
    const resp = try request(ctx, url, .{ .cookie = cookie });
    const json = std.json.parseFromSliceLeaky(Value, a, resp.body, .{}) catch
        return ctx.fail(.invalid_response, "getmyfav 返回非 JSON");
    if (numF(json, "code") == 1000) return ctx.fail(.auth_required, "QQ 登录已失效，请重新扫码");
    const map = objF(json, "mapmid") orelse blk: {
        if (objF(json, "data")) |d| break :blk objF(d, "mapmid") orelse emptyObj();
        break :blk emptyObj();
    };
    var mids: std.ArrayList([]const u8) = .empty;
    if (map == .object) {
        var it = map.object.iterator();
        while (it.next()) |e| try mids.append(a, e.key_ptr.*);
    }
    var total: u64 = mids.items.len;
    if (numF(json, "totalNum") > 0) total = @intFromFloat(numF(json, "totalNum"));
    return .{ .mids = mids.items, .total = total };
}

/// mid 列表 → 歌曲详情（分批 song_detail，每批 25；musicu 对单请求多 key
/// 有上限，实测 40 个 song_N 就整体拒绝）
fn songsByMids(ctx: *Ctx, mids: []const []const u8) Error!Value {
    const a = ctx.a;
    var all: std.ArrayList(Value) = .empty;
    const BATCH = 25;
    var i: usize = 0;
    while (i < mids.len) : (i += BATCH) {
        const batch = mids[i..@min(i + BATCH, mids.len)];
        var payload: ObjectMap = .empty;
        var comm: ObjectMap = .empty;
        try comm.put(a, "ct", .{ .integer = 24 });
        try comm.put(a, "cv", .{ .integer = 0 });
        try comm.put(a, "format", .{ .string = "json" });
        try comm.put(a, "uin", .{ .integer = std.fmt.parseInt(i64, uinOf(userCookie(ctx)), 10) catch 0 });
        try payload.put(a, "comm", .{ .object = comm });
        for (batch, 0..) |mid, k| {
            var pv: ObjectMap = .empty;
            try pv.put(a, "song_mid", .{ .string = mid });
            var reqk: ObjectMap = .empty;
            try reqk.put(a, "module", .{ .string = "music.pf_song_detail_svr" });
            try reqk.put(a, "method", .{ .string = "get_song_detail_yqq" });
            try reqk.put(a, "param", .{ .object = pv });
            try payload.put(a, try std.fmt.allocPrint(a, "song_{d}", .{k}), .{ .object = reqk });
        }
        const r = try musicu(ctx, .{ .object = payload });
        for (0..batch.len) |k| {
            const key = try std.fmt.allocPrint(a, "song_{d}", .{k});
            const reqv = getF(r, key) orelse continue;
            const track = blk: {
                const d = objF(reqv, "data") orelse break :blk null;
                break :blk objF(d, "track_info");
            };
            if (track) |t| {
                if (try trackOf(ctx, t)) |song| try all.append(a, song);
            }
        }
    }
    var arr = std.json.Array.init(a);
    try arr.appendSlice(all.items);
    var m: ObjectMap = .empty;
    try m.put(a, "songs", .{ .array = arr });
    return .{ .object = m };
}

// ── QQ 扫码登录（ptlogin2 → graph OAuth → musicu 凭证）──
// 流程跨 4 个域，HTTP 客户端不自动带 cookie —— 用迷你 jar 手工管理。

fn hash33(s: []const u8) u64 {
    var r: u64 = 0;
    for (s) |ch| r = (r +% (r << 5) +% ch) & 0x7fffffff;
    return r;
}

fn gtk(skey: []const u8) u64 {
    var r: u64 = 5381;
    for (skey) |ch| r = (r +% (r << 5) +% ch) & 0x7fffffff;
    return r;
}

/// JS encodeURIComponent：空格→%20（有别于 query 的 +）
fn encodeUriComponent(a: Allocator, s: []const u8) ![]const u8 {
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

/// ptqrlogin 响应里的单引号字符串（含 \' 转义）
fn quotedValues(ctx: *Ctx, text: []const u8) Error![]const []const u8 {
    const a = ctx.a;
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\'') {
            i += 1;
            continue;
        }
        i += 1;
        var buf: std.ArrayList(u8) = .empty;
        var closed = false;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                try buf.append(a, text[i + 1]);
                i += 1;
            } else if (text[i] == '\'') {
                closed = true;
                i += 1;
                break;
            } else {
                try buf.append(a, text[i]);
            }
        }
        if (!closed) break;
        try out.append(a, buf.items);
    }
    return out.items;
}

fn opLoginQrKey(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    _ = params;
    dropQrSession();
    // 登录会话用独立 arena：请求 arena 随响应释放，jar/qrsig 必须活过本次调用
    const sess_arena = std.heap.page_allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    sess_arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer {
        sess_arena.deinit();
        std.heap.page_allocator.destroy(sess_arena);
    }
    const sa = sess_arena.allocator();

    var t_buf: [18]u8 = undefined;
    t_buf[0] = '0';
    t_buf[1] = '.';
    for (2..18) |i| t_buf[i] = '0' + @as(u8, @intCast(randomU64(ctx, 10)));
    const url = try std.fmt.allocPrint(a, "https://ssl.ptlogin2.qq.com/ptqrshow?appid={s}&e=2&l=M&s=3&d=72&v=4&t={s}&daid={s}&pt_3rd_aid={s}", .{ APPID, t_buf[0..], DAID, PT_3RD_AID });
    const resp = try request(ctx, url, .{ .referer = "https://xui.ptlogin2.qq.com/" });

    var jar = Jar{ .a = sa };
    try jar.absorb(resp.set_cookies, "ssl.ptlogin2.qq.com");
    const qrsig = jar.get("qrsig") orelse return ctx.fail(.invalid_response, "ptqrshow 未下发 qrsig");

    const pngqr = @import("../pngqr.zig");
    const matrix = pngqr.pngToQrMatrix(a, resp.body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail(.invalid_response, @errorName(e)),
    };
    var rows = std.json.Array.init(a);
    for (matrix.rows) |row| try rows.append(.{ .string = row });

    const sess = std.heap.page_allocator.create(QrSession) catch return error.OutOfMemory;
    sess.* = .{ .arena = sess_arena, .jar = jar, .qrsig = try sa.dupe(u8, qrsig), .created_ms = nowMs(ctx) };
    qr_session = sess;

    var m: ObjectMap = .empty;
    try m.put(a, "ok", .{ .bool = true });
    try m.put(a, "key", .{ .string = qrsig[0..@min(16, qrsig.len)] });
    try m.put(a, "url", .{ .string = "" });
    try m.put(a, "size", .{ .integer = matrix.size });
    try m.put(a, "rows", .{ .array = rows });
    return .{ .object = m };
}

fn opLoginQrCheck(ctx: *Ctx, params: []const mod.Param) Error!Value {
    const a = ctx.a;
    _ = params;
    const sess = qr_session orelse return ctx.fail(.unsupported, "二维码未申请（先按 L → 3）");
    if (nowMs(ctx) - sess.created_ms > 180_000) {
        dropQrSession();
        return stateEnvelope(a, "expired", "");
    }
    const login_jump = try encodeUriComponent(a, "https://graph.qq.com/oauth2.0/login_jump");
    const url = try std.fmt.allocPrint(a, "https://ssl.ptlogin2.qq.com/ptqrlogin?u1={s}&ptqrtoken={d}&ptredirect=0&h=1&t=1&g=1&from_ui=1&ptlang=2052&action=0-0-{d}&js_ver=22080914&js_type=1&login_sig=&pt_uistyle=40&aid={s}&daid={s}&pt_3rd_aid={s}", .{ login_jump, hash33(sess.qrsig), nowMs(ctx), APPID, DAID, PT_3RD_AID });
    const resp = try request(ctx, url, .{ .cookie = try sess.jar.header("ssl.ptlogin2.qq.com"), .referer = "https://xui.ptlogin2.qq.com/" });
    try sess.jar.absorb(resp.set_cookies, "ssl.ptlogin2.qq.com");
    const values = try quotedValues(ctx, resp.body);
    const code = if (values.len > 0) values[0] else "";
    if (std.mem.eql(u8, code, "66")) return stateEnvelope(a, "waiting", "");
    if (std.mem.eql(u8, code, "67")) return stateEnvelope(a, "scanned", "");
    if (std.mem.eql(u8, code, "65") or std.mem.eql(u8, code, "68")) {
        dropQrSession();
        return stateEnvelope(a, "expired", "");
    }
    if (!std.mem.eql(u8, code, "0"))
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(a, "ptqrlogin code {s}", .{code}));
    // 确认登录：values[2] 跳转 URL、values[5] 昵称
    const redirect_url = if (values.len > 2) values[2] else "";
    const nickname = if (values.len > 5) values[5] else "";
    const cred = try exchangeCredentials(ctx, sess, redirect_url);
    dropQrSession();
    try saveAuth(ctx, cred.cookie, cred.musicid, nickname);
    cookie_cache = std.heap.page_allocator.dupe(u8, cred.cookie) catch cred.cookie;

    var user: ObjectMap = .empty;
    try user.put(a, "nickname", .{ .string = nickname });
    try user.put(a, "id", .{ .string = cred.musicid });
    var m: ObjectMap = .empty;
    try m.put(a, "ok", .{ .bool = true });
    try m.put(a, "state", .{ .string = "confirmed" });
    try m.put(a, "user", .{ .object = user });
    return .{ .object = m };
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

const Credential = struct {
    musicid: []const u8,
    musickey: []const u8,
    encryptUin: []const u8,
    openid: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    unionid: []const u8,
    refresh_key: []const u8,
    cookie: []const u8,
};

/// check_sig → p_skey，authorize → code，musicu QQLogin → 凭证
fn exchangeCredentials(ctx: *Ctx, sess: *QrSession, redirect_url: []const u8) Error!Credential {
    const a = ctx.a;
    const jar = &sess.jar;
    const uin = queryParamOf(redirect_url, "uin") orelse "";
    const ptsigx = queryParamOf(redirect_url, "ptsigx") orelse "";
    // 3.3 check_sig：禁止跟随重定向，30x 的 Set-Cookie 里收 p_skey
    const s_url = try encodeUriComponent(a, "https://graph.qq.com/oauth2.0/login_jump");
    const check_url = try std.fmt.allocPrint(a, "https://ssl.ptlogin2.graph.qq.com/check_sig?uin={s}&pttype=1&service=ptqrlogin&nodirect=0&ptsigx={s}&s_url={s}&ptlang=2052&ptredirect=100&aid={s}&daid={s}&j_later=0&low_login_hour=0&regmaster=0&pt_login_type=3&pt_aid=0&pt_aaid=16&pt_light=0&pt_3rd_aid={s}", .{ uin, ptsigx, s_url, APPID, DAID, PT_3RD_AID });
    const check = try request(ctx, check_url, .{
        .cookie = try jar.header("ssl.ptlogin2.graph.qq.com"),
        .referer = "https://xui.ptlogin2.qq.com/",
        .manual = true,
    });
    try jar.absorb(check.set_cookies, "ssl.ptlogin2.graph.qq.com");
    if (check.status < 300 or check.status >= 400)
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(a, "check_sig HTTP {d}", .{check.status}));
    var p_skey = jar.get("p_skey");
    if (p_skey == null or p_skey.?.len == 0) {
        // p_skey 可能挂在 30x 跳转链的下一跳（graph.qq.com 域）：manual 再跟一跳
        if (check.location.len > 0) {
            const next = try request(ctx, check.location, .{
                .cookie = try jar.header("graph.qq.com"),
                .referer = "https://graph.qq.com/",
                .manual = true,
            });
            try jar.absorb(next.set_cookies, "graph.qq.com");
            p_skey = jar.get("p_skey");
        }
    }
    if (p_skey == null or p_skey.?.len == 0)
        return ctx.fail(.invalid_response, "check_sig 未下发 p_skey");

    // 3.4 OAuth authorize：302 Location 里解析 code
    const redirect_uri = try encodeUriComponent(a, "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https%3A%2F%2Fy.qq.com%2F");
    var ui: std.ArrayList(u8) = .empty;
    for (0..32) |_| {
        try ui.append(a, "0123456789abcdef"[randomU64(ctx, 16)]);
    }
    const body = try std.fmt.allocPrint(a, "response_type=code&client_id={s}&redirect_uri={s}&scope=get_user_info,get_app_friends&state=state&switch=&from_ptlogin=1&src=1&update_auth=1&openapi=1010_1030&g_tk={d}&auth_time={d}&ui={s}", .{ PT_3RD_AID, redirect_uri, gtk(p_skey.?), nowMs(ctx), ui.items });
    const auth = try request(ctx, "https://graph.qq.com/oauth2.0/authorize", .{
        .method = .POST,
        .body = body,
        .content_type = "application/x-www-form-urlencoded",
        .cookie = try jar.header("graph.qq.com"),
        .referer = "https://graph.qq.com/oauth2.0/login_jump",
        .manual = true,
    });
    try jar.absorb(auth.set_cookies, "graph.qq.com");
    const code = queryParamOf(auth.location, "code");
    if (code == null or code.?.len == 0)
        return ctx.fail(.invalid_response, try std.fmt.allocPrint(a, "authorize 未给 code（HTTP {d}）", .{auth.status}));

    // 3.5 code → 音乐凭证
    var payload: ObjectMap = .empty;
    var comm: ObjectMap = .empty;
    try comm.put(a, "uin", .{ .integer = 0 });
    try comm.put(a, "format", .{ .string = "json" });
    try comm.put(a, "ct", .{ .integer = 24 });
    try comm.put(a, "cv", .{ .integer = 0 });
    try comm.put(a, "tmeLoginType", .{ .integer = 2 });
    var pv: ObjectMap = .empty;
    try pv.put(a, "code", .{ .string = code.? });
    var req0: ObjectMap = .empty;
    try req0.put(a, "module", .{ .string = "QQConnectLogin.LoginServer" });
    try req0.put(a, "method", .{ .string = "QQLogin" });
    try req0.put(a, "param", .{ .object = pv });
    try payload.put(a, "comm", .{ .object = comm });
    try payload.put(a, "req_0", .{ .object = req0 });
    const r = try musicu(ctx, .{ .object = payload });
    const reqv = try requireOk(ctx, getF(r, "req_0") orelse Value{ .null = {} }, "QQLogin");
    var data = objF(reqv, "data") orelse return ctx.fail(.invalid_response, "QQLogin 凭证缺失");
    if (objF(data, "data")) |inner| data = inner; // 参考实现的双层解包
    const musicid = blk: {
        if (getF(data, "musicid")) |v| break :blk try numToString(a, v);
        if (getF(data, "str_musicid")) |v| break :blk try numToString(a, v);
        break :blk "";
    };
    const musickey = strF(data, "musickey") orelse "";
    if (musicid.len == 0 or musickey.len == 0)
        return ctx.fail(.invalid_response, "QQLogin 凭证缺失");

    const encrypt_uin = strF(data, "encryptUin") orelse "";
    const openid = strF(data, "openid") orelse "";
    const access_token = strF(data, "access_token") orelse "";
    const refresh_token = strF(data, "refresh_token") orelse "";
    const unionid = strF(data, "unionid") orelse "";
    const refresh_key = strF(data, "refresh_key") orelse "";

    // 凭证 → cookie（本地拼装，非服务端下发）
    const cookie = try std.fmt.allocPrint(a, "uin=o{s}; qqmusic_uin={s}; qm_keyst={s}; qqmusic_key={s}; p_l_skey={s}; euin={s}; psrf_qqopenid={s}; psrf_qqaccess_token={s}; psrf_qqrefresh_token={s}; psrf_qqunionid={s}; refresh_key={s}", .{ musicid, musicid, musickey, musickey, musickey, encrypt_uin, openid, access_token, refresh_token, unionid, refresh_key });
    return .{
        .musicid = musicid,
        .musickey = musickey,
        .encryptUin = encrypt_uin,
        .openid = openid,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .unionid = unionid,
        .refresh_key = refresh_key,
        .cookie = cookie,
    };
}

/// URL query 取参（redirect_url / Location 里的 uin、ptsigx、code）
fn queryParamOf(url: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return null;
    var it = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

fn opLogout(ctx: *Ctx, params: []const mod.Param) Error!Value {
    _ = params;
    dropQrSession();
    try saveAuth(ctx, "", "", "");
    cookie_cache = "";
    var m: ObjectMap = .empty;
    try m.put(ctx.a, "ok", .{ .bool = true });
    try m.put(ctx.a, "state", .{ .string = "logged_out" });
    return .{ .object = m };
}

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

    if (std.meta.stringToEnum(OpName, op)) |kind| {
        const v = run(&ctx, kind, params) catch |e| switch (e) {
            error.Api => return Result(Value){ .err = .{ .code = ctx.code, .message = ctx.msg } },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return Result(Value){ .ok = v };
    }
    return Result(Value){ .err = .{ .code = .unsupported, .message = "未知操作" } };
}

fn run(ctx: *Ctx, op: OpName, params: []const mod.Param) Error!Value {
    return switch (op) {
        .search => opSearch(ctx, params),
        .songUrl => opSongUrl(ctx, params),
        .lyrics => opLyrics(ctx, params),
        .playlist => opPlaylist(ctx, params),
        .playlistTracks => opPlaylistTracks(ctx, params),
        .recommend => opRecommend(ctx, params),
        // QQ 无私人 FM 概念；写接口上游未对接（500003/bad request），如实报不支持
        .fm => ctx.fail(.unsupported, "QQ 无私人 FM"),
        .radio => opRadio(ctx, params),
        .library => opLibrary(ctx, params),
        .liked => opLiked(ctx, params),
        .like => ctx.fail(.unsupported, "QQ 暂不支持修改红心"),
        .loginQrKey => opLoginQrKey(ctx, params),
        .loginQrCheck => opLoginQrCheck(ctx, params),
        .logout => opLogout(ctx, params),
    };
}

// ── 离线测试 ──

test "uinOf/cookieValue/gtk 对齐 JS 语义" {
    try std.testing.expectEqualStrings("12345", uinOf("uin=o12345; qm_keyst=abc"));
    try std.testing.expectEqualStrings("0", uinOf(""));
    try std.testing.expectEqualStrings("0000000000", uinOf("uin=o0000000000; qm_keyst="));
    try std.testing.expectEqualStrings("abc", cookieValue("a=1; qm_keyst=abc", "qm_keyst").?);
    try std.testing.expect(cookieValue("a=1", "qm_keyst") == null);
    try std.testing.expectEqual(@as(u64, 5381), gtk(""));
    var expected: u64 = 5381;
    for ("abc") |ch| expected = (expected +% (expected << 5) +% ch) & 0x7fffffff;
    try std.testing.expectEqual(expected, gtk("abc"));
}

test "jar：空值忽略、domain 匹配、header 拼装" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var jar = Jar{ .a = a };
    try jar.absorb(&.{
        "p_skey=REAL; Path=/; Domain=.qq.com; HttpOnly",
        "p_skey=; Path=/ptlogin2; Domain=ssl.ptlogin2.qq.com",
        "qrsig=QS; Path=/; Domain=ptlogin2.qq.com",
    }, "ssl.ptlogin2.qq.com");
    try std.testing.expectEqualStrings("REAL", jar.get("p_skey").?); // 空值没抹掉真值
    const h1 = try jar.header("ssl.ptlogin2.qq.com");
    try std.testing.expect(std.mem.indexOf(u8, h1, "p_skey=REAL") != null);
    const h2 = try jar.header("xui.ptlogin2.qq.com"); // 子域匹配
    try std.testing.expect(std.mem.indexOf(u8, h2, "qrsig=QS") != null);
}

test "isBase64Shape / urlJoin / queryParamOf" {
    try std.testing.expect(isBase64Shape("YWJjZGVmZ2hpamtsbW4="));
    try std.testing.expect(!isBase64Shape("[ti:海阔天空]"));
    try std.testing.expect(isBase64Shape("abc=")); // 正则同款：形状对就算（16 字节门槛在 decodeLyric）
    try std.testing.expect(!isBase64Shape("a c="));
    const url = try urlJoin(std.testing.allocator, "http://aqqmusic.tc.qq.com/", "/C400xxx.m4a?v=1");
    defer std.testing.allocator.free(@constCast(url));
    try std.testing.expectEqualStrings("http://aqqmusic.tc.qq.com/C400xxx.m4a?v=1", url);
    try std.testing.expectEqualStrings("x", queryParamOf("https://h/p?uin=1&code=x", "code").?);
}
