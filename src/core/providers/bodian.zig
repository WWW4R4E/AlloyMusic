// src/core/providers/bodian.zig — 波点直调实现（sidecar/providers/bodian.cjs 的 Zig 移植）。
//
// 传输与签名直接复用存量 src/core/http.zig（bodian 直连客户端，kuwotest MD5 签名、
// 桌面端头、uid/token 注入——三平台化之前移植的遗产）；本文件只做 op 映射与
// 统一 schema 磨平，语义对齐 node_modules/bodian-music-api/src/*.cjs：
//   - 分页：offset/limit → pn/rn；服务端可能吞掉不可用歌曲，hasMore 按页边界
//     而不是返回条数推进（pageData 语义）
//   - 外源歌单匿名态默认 source 拉不到 → source=5 重试一次
//   - 受版权保护的歌走试听（checkRight status=3 → preview）
//
// 登录态存 根目录 auth.json 的 bodian 段（uid/token/user），与 sidecar 共享。

const std = @import("std");
const Allocator = std.mem.Allocator;
const mod = @import("mod.zig");
const bodianHttp = @import("../http.zig");
const qr = @import("../qr.zig");
const paths = @import("../paths.zig");

pub const available = true;

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Result = mod.Result;
const ErrorCode = mod.ErrorCode;
const Param = bodianHttp.Param;

pub const Error = error{ Api, OutOfMemory, NoSpaceLeft };

const DEFAULT_DEVICE_ID = "0123456789abcdef0123456789abcdef";

const Session = struct {
    uid: []const u8,
    token: []const u8,
    user: ?Value = null, // { id, nickname, avatarUrl }
};

const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    a: Allocator,
    client: bodianHttp.Client,
    session: ?Session = null,
    code: ErrorCode = .invalid_response,
    msg: []const u8 = "",

    fn fail(self: *Ctx, code: ErrorCode, msg: []const u8) Error {
        self.code = code;
        self.msg = msg;
        return error.Api;
    }
};

// ── JSON 小工具（与 qq.zig 同款）──

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

fn param(params: []const Param, name: []const u8) []const u8 {
    for (params) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return "";
}

// ── 登录态持久化（auth.json bodian 段）──

var session_cache: ?Session = null; // 字符串由 page_allocator 持有；null=未加载/未登录

fn loadSession(ctx: *Ctx) ?Session {
    if (session_cache) |s| return s;
    const pa = std.heap.page_allocator;
    const loaded: ?Session = blk: {
        const a = ctx.a;
        const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, paths.authPath(ctx.io, a), a, .limited(1 << 20)) catch break :blk null;
        const v = std.json.parseFromSliceLeaky(Value, a, raw, .{}) catch break :blk null;
        const b = objF(v, "bodian") orelse break :blk null;
        const uid = strF(b, "uid") orelse break :blk null;
        const token = strF(b, "token") orelse break :blk null;
        if (uid.len == 0 or token.len == 0) break :blk null;
        break :blk Session{
            .uid = pa.dupe(u8, uid) catch break :blk null,
            .token = pa.dupe(u8, token) catch break :blk null,
            .user = null,
        };
    };
    session_cache = loaded;
    return session_cache;
}

/// session 写/清 → auth.json（0600，读改写保留其他段）
fn saveSession(ctx: *Ctx, s: ?Session) Error!void {
    const a = ctx.a;
    var m: ObjectMap = .empty;
    if (std.Io.Dir.cwd().readFileAlloc(ctx.io, paths.authPath(ctx.io, a), a, .limited(1 << 20))) |raw| {
        if (std.json.parseFromSliceLeaky(Value, a, raw, .{}) catch null) |root| {
            if (root == .object) m = root.object;
        }
    } else |_| {}

    if (s) |sess| {
        var b: ObjectMap = .empty;
        try b.put(a, "uid", .{ .string = sess.uid });
        try b.put(a, "token", .{ .string = sess.token });
        if (sess.user) |u| try b.put(a, "user", u);
        try m.put(a, "bodian", .{ .object = b });
    } else {
        try m.put(a, "bodian", .{ .null = {} });
    }
    const payload = std.json.Stringify.valueAlloc(a, Value{ .object = m }, .{ .whitespace = .indent_2 }) catch
        return ctx.fail(.invalid_response, "auth 序列化失败");
    const file = std.Io.Dir.cwd().createFile(ctx.io, paths.authPath(ctx.io, a), .{
        .permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600),
    }) catch return ctx.fail(.invalid_response, "auth.json 写入失败");
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, payload) catch return ctx.fail(.invalid_response, "auth.json 写入失败");
    // page_allocator 持有的旧缓存不释放（进程级一次性，可接受泄漏级大小）
    if (s) |sess| {
        const pa = std.heap.page_allocator;
        session_cache = Session{
            .uid = pa.dupe(u8, sess.uid) catch sess.uid,
            .token = pa.dupe(u8, sess.token) catch sess.token,
            .user = null,
        };
    } else {
        session_cache = null;
    }
    ctx.session = session_cache;
}

// ── 统一 schema 构造（对齐 bodian.cjs 的 songOf/playlistOf/pageMeta）──

/// payInfo 真实响应是对象、mock 是字符串，两者都当"存在即付费"
fn payVip(v: Value) bool {
    return switch (v) {
        .null => false,
        .string => |s| s.len > 0,
        .object => |o| o.count() > 0,
        .bool => |b| b,
        else => false,
    };
}

fn songOf(ctx: *Ctx, raw: Value) Error!?Value {
    const a = ctx.a;
    if (raw != .object) return null;
    const id_raw = getF(raw, "musicId") orelse getF(raw, "id") orelse return null;
    const id = try numToString(a, id_raw);
    if (id.len == 0) return null;
    var artists: std.ArrayList(u8) = .empty;
    if (arrF(raw, "artists")) |arts| {
        for (arts.array.items) |x| {
            const name = strF(x, "name") orelse continue;
            if (name.len == 0) continue;
            if (artists.items.len > 0) try artists.appendSlice(a, " / ");
            try artists.appendSlice(a, name);
        }
    }
    var m: ObjectMap = .empty;
    try m.put(a, "id", .{ .string = id });
    try m.put(a, "backend", .{ .string = "bodian" });
    try m.put(a, "title", .{ .string = strF(raw, "name") orelse strF(raw, "songName") orelse "" });
    const artist = strF(raw, "artist") orelse "";
    try m.put(a, "artist", .{ .string = if (artists.items.len > 0) artists.items else if (artist.len > 0) artist else "未知歌手" });
    const album = strF(raw, "album") orelse strF(raw, "albumName") orelse "";
    try m.put(a, "album", .{ .string = if (album.len > 0) album else "未知专辑" });
    try m.put(a, "durationS", .{ .integer = @intFromFloat(numF(raw, "duration")) });
    try m.put(a, "vip", .{ .bool = payVip(getF(raw, "payInfo") orelse Value{ .null = {} }) });
    try m.put(a, "coverUrl", .{ .string = strF(raw, "albumPic") orelse strF(raw, "albumPic120") orelse "" });
    return .{ .object = m };
}

fn playlistOf(ctx: *Ctx, raw: Value) Error!Value {
    const a = ctx.a;
    var m: ObjectMap = .empty;
    try m.put(a, "id", .{ .string = try numToString(a, getF(raw, "id") orelse Value{ .null = {} }) });
    try m.put(a, "backend", .{ .string = "bodian" });
    try m.put(a, "name", .{ .string = strF(raw, "name") orelse strF(raw, "title") orelse "" });
    try m.put(a, "trackCount", .{ .integer = @intFromFloat(numF(raw, "musicCount")) });
    try m.put(a, "kind", .{ .string = if (numF(raw, "sourceType") == 6) "album" else "playlist" });
    return .{ .object = m };
}

const PageMeta = struct {
    has_more: bool,
    total: ?u64,
};

/// pageData 语义：hasMore 按页边界推进（服务端可能吞掉不可用歌曲）
fn pageMeta(data: Value, list: []const Value, size: u32, page: u32) PageMeta {
    var total: ?u64 = null;
    if (getF(data, "total")) |t| {
        switch (t) {
            .integer => |n| {
                if (n >= 0) total = @intCast(n);
            },
            .number_string, .string => |s| {
                total = std.fmt.parseInt(u64, s, 10) catch null;
            },
            else => {},
        }
    }
    const has_more = list.len > 0 and if (total) |t|
        @as(u64, page + 1) * size < t
    else
        list.len == size;
    return .{ .has_more = has_more, .total = total };
}

/// client.call 结果 → data 字段（err 上抛为 ctx.fail）
fn dataOf(ctx: *Ctx, r: bodianHttp.Result(Value)) Error!Value {
    switch (r) {
        .err => |e| return ctx.fail(e.code, e.message),
        .ok => |v| {
            if (objF(v, "data")) |d| return d;
            return ctx.fail(.invalid_response, "Bodian response is missing data");
        },
    }
}

fn apiGet(ctx: *Ctx, path: []const u8, params: []const Param) Error!Value {
    const r = try ctx.client.call(ctx.a, path, .{ .params = params });
    return dataOf(ctx, r);
}

fn songsEnvelope(ctx: *Ctx, data: Value, field: []const u8, size: u32, page: u32) Error!Value {
    const a = ctx.a;
    var list: []const Value = &.{};
    if (arrF(data, field)) |l| list = l.array.items;
    var arr = std.json.Array.init(a);
    for (list) |item| {
        if (try songOf(ctx, item)) |song| try arr.append(song);
    }
    const meta = pageMeta(data, list, size, page);
    var m: ObjectMap = .empty;
    try m.put(a, "songs", .{ .array = arr });
    try m.put(a, "hasMore", .{ .bool = meta.has_more });
    if (meta.total) |t| try m.put(a, "total", .{ .integer = @intCast(t) });
    return .{ .object = m };
}

// ── op 实现 ──

fn opSearch(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    const kw = std.mem.trim(u8, param(params, "kw"), " ");
    if (kw.len == 0) return ctx.fail(.unsupported, "缺少 kw");
    const page: u32 = std.fmt.parseInt(u32, param(params, "page"), 10) catch 0;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 50;
    const data = try apiGet(ctx, "/api/search/music/list", &.{
        .{ .name = "keyword", .value = kw },
        .{ .name = "correct", .value = "1" },
        .{ .name = "pn", .value = try std.fmt.allocPrint(a, "{d}", .{page}) },
        .{ .name = "rn", .value = try std.fmt.allocPrint(a, "{d}", .{size}) },
    });
    return songsEnvelope(ctx, data, "resultList", size, page);
}

fn opSongUrl(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    const level = param(params, "level");
    const quality: []const u8 = if (std.mem.eql(u8, level, "lossless"))
        "lossless"
    else if (std.mem.eql(u8, level, "standard"))
        "standard"
    else
        "high";
    const format: []const u8 = if (std.mem.eql(u8, quality, "lossless")) "flac" else "mp3";
    const br: []const u8 = if (std.mem.eql(u8, quality, "lossless"))
        "2000kflac"
    else if (std.mem.eql(u8, quality, "standard"))
        "128kmp3"
    else
        "320kmp3";

    // 1. checkRight（GET+JSON body、signed——波点播放类接口的形态）
    const right_body = try std.fmt.allocPrint(a, "{{\"musicId\":{s},\"freeSign\":\"\"}}", .{id});
    const right = try dataOf(ctx, try ctx.client.call(a, "/api/play/music/v2/checkRight", .{
        .params = &.{
            .{ .name = "musicId", .value = id },
            .{ .name = "freeSign", .value = "" },
        },
        .body = right_body,
        .method = .GET,
        .signed = true,
    }));
    const status = numF(right, "status");
    if (status == 3) {
        // 受版权保护 → 试听
        const preview = objF(right, "audition") orelse
            return ctx.fail(.not_playable, "Bodian preview is unavailable");
        const url = strF(preview, "https") orelse strF(preview, "url") orelse
            return ctx.fail(.not_playable, "Bodian preview is unavailable");
        try validateAudioUrl(ctx, url);
        var m: ObjectMap = .empty;
        try m.put(a, "url", .{ .string = url });
        try m.put(a, "quality", .{ .string = "standard" });
        try m.put(a, "format", .{ .null = {} });
        var p: ObjectMap = .empty;
        const start_ms: i64 = @intFromFloat(numF(preview, "start"));
        const end_ms: i64 = @intFromFloat(numF(preview, "end"));
        try p.put(a, "startMs", .{ .integer = start_ms });
        try p.put(a, "endMs", .{ .integer = end_ms });
        try m.put(a, "preview", .{ .object = p });
        return .{ .object = m };
    }
    if (status == 7 or getF(right, "status") == null) {
        return ctx.fail(
            if (ctx.session != null) .not_playable else .auth_required,
            if (ctx.session != null) "Bodian requires additional playback rights" else "Bodian playback rights are unavailable",
        );
    }

    // 2. audioUrl（正式播放链接，需权益）
    const audio_body = try std.fmt.allocPrint(a, "{{\"devId\":\"{s}\",\"musicId\":{s},\"format\":\"{s}\",\"br\":\"{s}\",\"freeSign\":\"\"}}", .{ DEFAULT_DEVICE_ID, id, format, br });
    const audio = try dataOf(ctx, try ctx.client.call(a, "/api/play/music/v2/audioUrl", .{
        .params = &.{
            .{ .name = "devId", .value = DEFAULT_DEVICE_ID },
            .{ .name = "musicId", .value = id },
            .{ .name = "format", .value = format },
            .{ .name = "br", .value = br },
            .{ .name = "freeSign", .value = "" },
        },
        .body = audio_body,
        .method = .GET,
        .signed = true,
    }));
    const url = strF(audio, "audioHttpsUrl") orelse strF(audio, "audioUrl") orelse
        return ctx.fail(.not_playable, "Bodian returned no audio URL");
    try validateAudioUrl(ctx, url);
    var m: ObjectMap = .empty;
    try m.put(a, "url", .{ .string = url });
    try m.put(a, "quality", .{ .string = quality });
    try m.put(a, "format", .{ .null = {} });
    try m.put(a, "preview", .{ .null = {} });
    return .{ .object = m };
}

fn validateAudioUrl(ctx: *Ctx, url: []const u8) Error!void {
    const ok = (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) and url.len > 0;
    // URL 里不允许 userinfo（user:pass@）
    var clean = ok;
    if (clean) {
        const scheme_end = std.mem.indexOf(u8, url, "://").?;
        const authority = url[scheme_end + 3 ..];
        const path_start = std.mem.indexOfScalar(u8, authority, '/') orelse authority.len;
        if (std.mem.indexOfScalar(u8, authority[0..path_start], '@') != null) clean = false;
    }
    if (!clean) return ctx.fail(.invalid_response, "Bodian returned an invalid audio URL");
}

/// bodian 歌词：剥 [kuwo:…] 标签与逐字计时对 <a,b>（mainText 无逐字信息）
fn decodeLyrics(a: Allocator, content: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '<') {
            // <num,num> 剥掉（数字/负号开头才当计时对，防误吞普通尖括号）
            const close = std.mem.indexOfScalarPos(u8, content, i, '>');
            if (close) |c| {
                const inner = content[i + 1 .. c];
                if (inner.len > 0 and (std.ascii.isDigit(inner[0]) or inner[0] == '-')) {
                    i = c + 1;
                    continue;
                }
            }
        } else if (i + 6 <= content.len and std.mem.startsWith(u8, content[i..], "[kuwo:")) {
            if (std.mem.indexOfScalarPos(u8, content, i, ']')) |c| {
                i = c + 1;
                continue;
            }
        }
        try out.append(a, content[i]);
        i += 1;
    }
    return out.items;
}

fn opLyrics(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    const query = try std.fmt.allocPrint(a, "type=lyric&req=2&lrcx=1&rid={s}&songname=&artist=&corp=kuwo&fromchannel=bodian", .{id});
    const enc = std.base64.standard.Encoder;
    const q_buf = try a.alloc(u8, enc.calcSize(query.len));
    _ = enc.encode(q_buf, query);
    const r = try ctx.client.call(a, "/mobi.s", .{
        .params = &.{
            .{ .name = "f", .value = "bodian" },
            .{ .name = "q", .value = q_buf },
        },
        .lyric = true,
    });
    switch (r) {
        .err => |e| return ctx.fail(e.code, e.message),
        .ok => |v| {
            const content = blk: {
                const d = getF(v, "data") orelse break :blk null;
                break :blk strF(d, "content");
            } orelse return ctx.fail(.invalid_response, "Bodian lyric content is missing");
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(content) catch
                return ctx.fail(.invalid_response, "Bodian lyric content is missing");
            const raw = a.alloc(u8, n) catch return error.OutOfMemory;
            dec.decode(raw, content) catch
                return ctx.fail(.invalid_response, "Bodian lyric content is missing");
            const lrc = decodeLyrics(a, raw) catch return error.OutOfMemory;
            if (lrc.len == 0) return ctx.fail(.invalid_response, "歌词为空");
            var m: ObjectMap = .empty;
            try m.put(a, "lrc", .{ .string = lrc });
            try m.put(a, "tlyric", .{ .string = "" }); // 波点翻译混在正文，无独立轨
            return .{ .object = m };
        },
    }
}

fn opPlaylist(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    const source = param(params, "source");
    var pl = try playlistDetail(ctx, id, if (source.len > 0) source else null);
    // 匿名/默认 source 下外源歌单会返回"默认列表"占位 → source=5 重试
    const name = strF(pl, "name") orelse "";
    if ((name.len == 0 or std.mem.eql(u8, name, "默认列表")) and source.len == 0) {
        if (playlistDetail(ctx, id, "5")) |pl2| {
            const name2 = strF(pl2, "name") orelse "";
            if (name2.len > 0 and !std.mem.eql(u8, name2, "默认列表")) pl = pl2;
        } else |_| {}
    }
    var m: ObjectMap = .empty;
    try m.put(a, "playlist", pl);
    return .{ .object = m };
}

fn playlistDetail(ctx: *Ctx, id: []const u8, source: ?[]const u8) Error!Value {
    const a = ctx.a;
    var plist: std.ArrayList(Param) = .empty;
    try plist.append(a, .{ .name = "source", .value = source orelse "4" });
    const r = try ctx.client.call(a, try std.fmt.allocPrint(a, "/api/service/playlist/info/{s}", .{id}), .{
        .params = plist.items,
    });
    return playlistOf(ctx, try dataOf(ctx, r));
}

fn opPlaylistTracks(ctx: *Ctx, params: []const Param) Error!Value {
    const id = param(params, "id");
    if (id.len == 0) return ctx.fail(.unsupported, "缺少 id");
    const page: u32 = std.fmt.parseInt(u32, param(params, "page"), 10) catch 0;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 50;
    const source = param(params, "source");

    var first = try playlistTracksPage(ctx, id, page, size, if (source.len > 0) source else null);
    // 默认 source 拉不到（外源歌单匿名态）→ source=5 重试一次
    var empty = true;
    if (arrF(first, "songs")) |arr| empty = arr.array.items.len == 0;
    if (empty and source.len == 0) {
        if (playlistTracksPage(ctx, id, page, size, "5")) |second| {
            var nonempty = false;
            if (arrF(second, "songs")) |arr| nonempty = arr.array.items.len > 0;
            if (nonempty) first = second;
        } else |_| {}
    }
    return first;
}

/// 歌单曲目页：pn = page + 1（歌单/专辑/收藏类分页从 1 起）
fn playlistTracksPage(ctx: *Ctx, id: []const u8, page: u32, size: u32, source: ?[]const u8) Error!Value {
    const a = ctx.a;
    const data = try apiGet(ctx, try std.fmt.allocPrint(a, "/api/service/playlist/{s}/musicList", .{id}), &.{
        .{ .name = "pn", .value = try std.fmt.allocPrint(a, "{d}", .{page + 1}) },
        .{ .name = "rn", .value = try std.fmt.allocPrint(a, "{d}", .{size}) },
        .{ .name = "source", .value = source orelse "4" },
    });
    return songsEnvelope(ctx, data, "list", size, page);
}

fn opLiked(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    const size: u32 = std.fmt.parseInt(u32, param(params, "size"), 10) catch 100;
    const sess = ctx.session orelse return ctx.fail(.auth_required, "Bodian sign-in is required");
    // liked_songs：fond（我喜欢）歌单 id → musicList
    const fond = try apiGet(ctx, "/api/service/playlist/fond", &.{
        .{ .name = "userId", .value = sess.uid },
        .{ .name = "fromUid", .value = sess.uid },
    });
    const fond_id = (strF(fond, "id") orelse numToString(a, getF(fond, "id") orelse Value{ .null = {} }) catch "") ;
    if (fond_id.len == 0) {
        var m: ObjectMap = .empty;
        try m.put(a, "songs", .{ .array = std.json.Array.init(a) });
        return .{ .object = m };
    }
    const data = try apiGet(ctx, try std.fmt.allocPrint(a, "/api/service/playlist/{s}/musicList", .{fond_id}), &.{
        .{ .name = "source", .value = "5" },
        .{ .name = "pn", .value = "1" },
        .{ .name = "rn", .value = try std.fmt.allocPrint(a, "{d}", .{@min(size, 200)}) },
    });
    return songsEnvelope(ctx, data, "list", size, 0);
}

fn opLibrary(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    _ = params;
    const sess = ctx.session orelse return ctx.fail(.auth_required, "Bodian sign-in is required");
    const user = [_]Param{
        .{ .name = "userId", .value = sess.uid },
        .{ .name = "fromUid", .value = sess.uid },
    };
    // 自建 + 收藏（收藏列表按 sourceType 分流歌单/专辑；上游 total 含两类，不外传）
    const owned = try apiGet(ctx, "/api/service/playlist/userCreate", &user);
    const collected = try apiGet(ctx, "/api/service/collect/4/list", &user);

    var owned_arr = std.json.Array.init(a);
    if (arrF(owned, "playLists")) |l| {
        for (l.array.items) |item| {
            if (item == .object) try owned_arr.append(try playlistOf(ctx, item));
        }
    }
    var pl_arr = std.json.Array.init(a);
    var album_arr = std.json.Array.init(a);
    if (arrF(collected, "playLists")) |l| {
        for (l.array.items) |item| {
            if (item != .object) continue;
            if (numF(item, "sourceType") == 6) {
                try album_arr.append(try playlistOf(ctx, item));
            } else {
                try pl_arr.append(try playlistOf(ctx, item));
            }
        }
    }
    var m: ObjectMap = .empty;
    try m.put(a, "owned", .{ .array = owned_arr });
    try m.put(a, "collectedPlaylists", .{ .array = pl_arr });
    try m.put(a, "collectedAlbums", .{ .array = album_arr });
    return .{ .object = m };
}

fn opRecommend(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    _ = params;
    var pl_arr = std.json.Array.init(a);
    // 登录态走推荐接口；未登录回落匿名首页模块（宝藏歌单库 moduleId=2，
    // songList 是真歌单；moduleId=1 的 id 是分组序号不能用）
    if (ctx.session != null) {
        if (apiGet(ctx, "/api/service/finds/playlist", &.{})) |data| {
            if (arrF(data, "playLists")) |l| {
                for (l.array.items) |item| {
                    if (item == .object) try pl_arr.append(try playlistOf(ctx, item));
                }
            }
        } else |_| {}
    }
    if (pl_arr.items.len == 0) {
        if (apiGet(ctx, "/api/service/home/module", &.{.{ .name = "moduleId", .value = "2" }})) |data| {
            if (arrF(data, "songList")) |l| {
                for (l.array.items) |g| {
                    const gid = numF(g, "id");
                    if (gid <= 0) continue;
                    var m: ObjectMap = .empty;
                    try m.put(a, "id", .{ .string = try numToString(a, getF(g, "id") orelse Value{ .null = {} }) });
                    try m.put(a, "backend", .{ .string = "bodian" });
                    try m.put(a, "name", .{ .string = strF(g, "name") orelse strF(g, "title") orelse "" });
                    try m.put(a, "trackCount", .{ .integer = 0 });
                    try m.put(a, "kind", .{ .string = "playlist" });
                    try pl_arr.append(.{ .object = m });
                }
            }
        } else |_| {}
    }
    var m: ObjectMap = .empty;
    try m.put(a, "playlists", .{ .array = pl_arr });
    return .{ .object = m };
}

/// personal_fm 真实响应是 data.musicList（不是 resultList）
fn fmSongs(ctx: *Ctx) Error!std.ArrayList(Value) {
    const a = ctx.a;
    const data = try apiGet(ctx, "/api/service/music/recommendList", &.{});
    var list: []const Value = &.{};
    if (arrF(data, "musicList")) |l| {
        list = l.array.items;
    } else if (arrF(data, "resultList")) |l| {
        list = l.array.items;
    }
    var out: std.ArrayList(Value) = .empty;
    for (list) |item| {
        if (try songOf(ctx, item)) |song| try out.append(a, song);
    }
    return out;
}

fn opFm(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    _ = params;
    var songs: std.ArrayList(Value) = fmSongs(ctx) catch .empty;
    // 未登录回落匿名 AI 歌单（前 3 组里找非空）
    var idx: u32 = 0;
    while (songs.items.len == 0 and idx < 3) : (idx += 1) {
        if (apiGet(ctx, "/api/service/home/aiPlaylistDetail", &.{
            .{ .name = "index", .value = try std.fmt.allocPrint(a, "{d}", .{idx}) },
        })) |data| {
            if (arrF(data, "musicList")) |l| {
                for (l.array.items) |item| {
                    if (try songOf(ctx, item)) |song| try songs.append(a, song);
                }
            }
        } else |_| {}
    }
    var m: ObjectMap = .empty;
    var arr = std.json.Array.init(a);
    try arr.appendSlice(songs.items);
    try m.put(a, "songs", .{ .array = arr });
    return .{ .object = m };
}

/// 电台 = 私人推荐（无种子概念）；拿不到真推荐如实报错，不拿 AI 歌单冒充
fn opRadio(ctx: *Ctx, params: []const Param) Error!Value {
    _ = params;
    const songs = try fmSongs(ctx);
    if (songs.items.len == 0) return ctx.fail(.invalid_response, "私人推荐为空（可能需登录）");
    var m: ObjectMap = .empty;
    var arr = std.json.Array.init(ctx.a);
    try arr.appendSlice(songs.items);
    try m.put(ctx.a, "songs", .{ .array = arr });
    return .{ .object = m };
}

/// like_song：fond（我喜欢）歌单增删曲
fn opLike(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    const id = param(params, "id");
    const like_str = param(params, "like");
    const on = std.mem.eql(u8, like_str, "true");
    if (id.len == 0) return ctx.fail(.invalid_response, "缺少歌曲 id");
    const sess = ctx.session orelse return ctx.fail(.auth_required, "Bodian sign-in is required");
    const fond = try apiGet(ctx, "/api/service/playlist/fond", &.{
        .{ .name = "userId", .value = sess.uid },
    });
    const fond_id = strF(fond, "id") orelse return ctx.fail(.invalid_response, "Bodian fond playlist is missing");
    const path = if (on)
        "/api/service/playlist/music"
    else
        "/api/service/playlist/music/delete";
    const body = try std.fmt.allocPrint(a, "{{\"playListId\":{s},\"musicIdList\":[{s}]}}", .{ fond_id, id });
    _ = try dataOf(ctx, try ctx.client.call(a, path, .{
        .method = .POST,
        .signed = true,
        .body = body,
    }));
    var m: ObjectMap = .empty;
    try m.put(a, "liked", .{ .bool = on });
    return .{ .object = m };
}

// ── 登录（QR；URL 由 key 还原，矩阵本地生成）──

var pending_qr_key: ?[]u8 = null; // page_allocator
var pending_qr_expires: i64 = 0;

fn loginUrlFor(a: Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "https://bodian-oia.kuwo.cn/bodian/download.html?pageName=login_pc&pt=3&id={s}", .{key});
}

fn nowMs(ctx: *Ctx) i64 {
    return std.Io.Timestamp.now(ctx.io, .real).toMilliseconds();
}

fn opLoginQrKey(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    _ = params;
    const data = try apiGet(ctx, "/api/ucenter/login/qrCode", &.{});
    const key = strF(data, "qrCode") orelse
        return ctx.fail(.invalid_response, "Bodian QR key is missing");
    if (key.len == 0) return ctx.fail(.invalid_response, "Bodian QR key is missing");

    const url = try loginUrlFor(a, key);
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

    pending_qr_key = std.heap.page_allocator.dupe(u8, key) catch key[0..0];
    pending_qr_expires = nowMs(ctx) + 5 * 60 * 1000;

    var m: ObjectMap = .empty;
    try m.put(a, "ok", .{ .bool = true });
    try m.put(a, "key", .{ .string = key });
    try m.put(a, "url", .{ .string = url });
    try m.put(a, "size", .{ .integer = matrix.size });
    try m.put(a, "rows", .{ .array = rows });
    return .{ .object = m };
}

fn pendingValid(key: []const u8, now: i64) bool {
    const p = pending_qr_key orelse return false;
    return pending_qr_expires > now and std.mem.eql(u8, p, key);
}

fn opLoginQrCheck(ctx: *Ctx, params: []const Param) Error!Value {
    const a = ctx.a;
    const key = param(params, "key");
    if (key.len == 0) return ctx.fail(.unsupported, "缺少 key");
    const now = nowMs(ctx);
    if (!pendingValid(key, now)) return stateEnvelope(a, "expired", "");
    const data = try apiGet(ctx, "/api/ucenter/login/qrCodeStatus", &.{
        .{ .name = "qrCode", .value = key },
    });
    const status = numF(data, "status");
    if (status == 1) return stateEnvelope(a, "waiting", "");
    if (status == 2) {
        pending_qr_key = null;
        return stateEnvelope(a, "expired", "");
    }
    if (status != 3) return ctx.fail(.invalid_response, "Unrecognized Bodian QR status");

    // 确认登录：POST users/login（上游 11027 = 已扫未确认）
    const body = try std.fmt.allocPrint(a, "{{\"authType\":10,\"qrCode\":\"{s}\"}}", .{key});
    const login = ctx.client.call(a, "/api/ucenter/users/login", .{
        .method = .POST,
        .body = body,
        .signed = true,
        .anonymous = true,
    });
    const lr = try login; // 传输错误（OOM 等）上抛
    const login_value = switch (lr) {
        .err => |e| {
            if (e.upstream_code != null and e.upstream_code.? == 11027)
                return stateEnvelope(a, "scanned", "");
            return ctx.fail(e.code, e.message);
        },
        .ok => |v| v,
    };
    if (!pendingValid(key, now)) return stateEnvelope(a, "expired", "");
    const login_data = switch (login_value) {
        .object => |o| Value{ .object = o },
        else => return ctx.fail(.invalid_response, "Unrecognized Bodian QR status"),
    };
    const d = objF(login_data, "data") orelse login_data;

    // loginIdentity：id/uid 必须一致且为 1..20 位非零数字
    const user_obj = objF(d, "userInfo") orelse objF(d, "user");
    var uid: []const u8 = "";
    if (strF(d, "id")) |v| {
        uid = v;
    } else if (strF(d, "uid")) |v| {
        uid = v;
    } else if (user_obj) |u| {
        uid = strF(u, "id") orelse strF(u, "uid") orelse "";
    }
    if (uid.len == 0 or uid.len > 20 or uid[0] == '0' or !allDigits(uid))
        return ctx.fail(.invalid_response, "Bodian returned inconsistent account identity");
    const token_raw = strF(d, "token") orelse "";
    if (std.mem.trim(u8, token_raw, " ").len == 0)
        return ctx.fail(.invalid_response, "Unrecognized Bodian QR status");

    var user: ObjectMap = .empty;
    try user.put(a, "id", .{ .string = uid });
    try user.put(a, "nickname", .{ .string = if (user_obj) |u| (strF(u, "nickname") orelse "") else "" });
    try user.put(a, "avatarUrl", .{ .string = if (user_obj) |u| (strF(u, "headImg") orelse strF(u, "avatarUrl") orelse "") else "" });
    try saveSession(ctx, .{ .uid = uid, .token = token_raw, .user = .{ .object = user } });
    pending_qr_key = null;
    return stateEnvelope(a, "confirmed", if (user_obj) |u| (strF(u, "nickname") orelse "") else "");
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
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

fn opLogout(ctx: *Ctx, params: []const Param) Error!Value {
    _ = params;
    pending_qr_key = null;
    try saveSession(ctx, null);
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
    params: []const Param,
) Allocator.Error!?Result(Value) {
    var ctx = Ctx{
        .gpa = gpa,
        .io = io,
        .a = arena,
        .client = bodianHttp.Client.init(gpa, io, DEFAULT_DEVICE_ID) catch
            return Result(Value){ .err = .{ .code = .invalid_response, .message = "Invalid device id" } },
    };
    defer ctx.client.deinit();
    ctx.session = loadSession(&ctx);
    if (ctx.session) |s| {
        ctx.client.session = .{ .uid = s.uid, .token = s.token };
    }

    const kind = std.meta.stringToEnum(OpName, op) orelse
        return Result(Value){ .err = .{ .code = .unsupported, .message = "未知操作" } };
    const v = run(&ctx, kind, params) catch |e| switch (e) {
        error.Api => {
            // auth-required → 清本地登录态（SDK 语义）
            if (ctx.code == .auth_required and ctx.session != null) {
                saveSession(&ctx, null) catch {};
            }
            return Result(Value){ .err = .{ .code = ctx.code, .message = ctx.msg } };
        },
        error.OutOfMemory, error.NoSpaceLeft => return error.OutOfMemory,
    };
    return Result(Value){ .ok = v };
}

fn run(ctx: *Ctx, op: OpName, params: []const Param) Error!Value {
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

// ── 离线测试 ──

test "payVip/pageMeta 对齐 JS 语义" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(payVip(.{ .string = "x" }));
    try std.testing.expect(!payVip(.{ .string = "" }));
    try std.testing.expect(!payVip(.{ .null = {} }));
    var empty_map: ObjectMap = .empty;
    try std.testing.expect(!payVip(.{ .object = empty_map }));
    try empty_map.put(a, "fee", .{ .integer = 1 });
    try std.testing.expect(payVip(.{ .object = empty_map }));

    // hasMore：total 已知按页边界；未知拿满一页才算有
    var meta = pageMeta(.{ .object = .empty }, &.{ .null, .null }, 2, 0);
    try std.testing.expect(meta.has_more);
    meta = pageMeta(.{ .object = .empty }, &.{.null}, 2, 0);
    try std.testing.expect(!meta.has_more);
}

test "decodeLyrics 剥 kuwo 标签与逐字对" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("[00:01.00]你好", try decodeLyrics(a, "[kuwo:43][00:01.00]<100,200>你好"));
    try std.testing.expectEqualStrings("a<b>普通尖括号保留", try decodeLyrics(a, "a<b>普通尖括号保留"));
}
