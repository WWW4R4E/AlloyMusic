const std = @import("std");
const Allocator = std.mem.Allocator;
const bodianHttp = @import("http.zig");
const lyrics_mod = @import("lyrics.zig");

const Param = bodianHttp.Param;
const BodianError = bodianHttp.BodianError;
const Result = bodianHttp.Result;

// src/core/catalog.zig — 目录类只读操作，对应 bodian-music-api/src/catalog.cjs。
//
// 分页说明：TUI 直接用页号（Page.number），不再做 JS 版 offset/limit → pn/rn 的
// 翻译层。搜索接口 pn 从 0 起，歌单/专辑/收藏类从 1 起，由各操作传入基址。
// hasMore 的规则来自 docs/protocol.md：服务端可能吞掉不可用歌曲、total 不可靠，
// 因此游标永远用页号推进，返回条数只参与 hasMore 判断。

/// UI 构造、core 校验的纯值类型。size 默认 50，UI 可按界面覆盖。
pub const Page = struct {
    number: u32 = 0,
    size: u32 = 50,

    /// 页号基址由操作传入：搜索类 0，歌单/专辑/收藏类 1。
    pub fn pn(self: Page, base: u32) u32 {
        return self.number + base;
    }

    pub fn validate(self: Page) error{InvalidPagination}!void {
        if (self.size < 1 or self.size > 100) return error.InvalidPagination;
    }

    /// 还有没有下一页。raw_list_len 必须是响应里**原始**列表的长度（过滤/展示
    /// 转换之前）：收藏列表按 sourceType 分流后某页可能为空，但原始页是满的、
    /// 后面还有内容，用过滤后的条数会提前断翻页。
    /// total 分支按页边界判断（还有没读的整页才算有）；
    /// 无 total 时拿满一整页才假设还有下一页（短页视为到头）。
    pub fn hasMore(self: Page, raw_list_len: usize, total: ?u64) bool {
        if (raw_list_len == 0) return false;
        if (total) |t| {
            const pages = (t + self.size - 1) / self.size; // ceil
            return self.number + 1 < pages;
        }
        return raw_list_len == self.size;
    }
};

/// 从 JSON 里取非负整数（total 可能是数字或数字字符串）。
fn jsonToU64(v: ?std.json.Value) ?u64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| blk: {
            if (f < 0 or f != @trunc(f) or f > 1.8e19) break :blk null;
            break :blk @intFromFloat(f);
        },
        .number_string, .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

/// 纯数字、1..20 位、不全为零；通过则原样返回（用于路径和 query）。
pub fn mediaId(id: []const u8) ![]const u8 {
    if (id.len < 1 or id.len > 20) return error.InvalidMediaId;
    for (id) |c| if (!std.ascii.isDigit(c)) return error.InvalidMediaId;
    if (std.mem.allEqual(u8, id, '0')) return error.InvalidMediaId;
    return id;
}

/// 歌单来源：缺省 4，合法范围 1..6。
fn playlistSource(source: ?u32) !u32 {
    const s = source orelse 4;
    return if (s >= 1 and s <= 6) s else error.InvalidSource;
}

fn numParam(arena: Allocator, name: []const u8, value: anytype) !Param {
    return .{ .name = name, .value = try std.fmt.allocPrint(arena, "{d}", .{value}) };
}

pub const PageResult = struct {
    data: std.json.Value, // 响应的 data 字段，原样保留
    has_more: bool, // 按原始列表长度算好，UI 直接用
};

pub const Catalog = struct {
    client: *bodianHttp.Client,

    // ─────────────────────────────────────────────────────────────
    // 私有助手调用层次（UI 只调 14 个 pub 方法）：
    //
    //   search ────────────────────→ paged ─────┐
    //   playlistTracks 等 4 个 ─────→ pagedId ──┤
    //                                           ├─→ finishPaged → client.call（http.zig）
    //   albumDetail 等 3 个 ────────→ getId ────┘（不经 finishPaged）
    //   recommendations 等 5 个 ────→ get ──────┘
    //
    // 四个入口助手对应 2×2 组合：路径带不带 ID × 带不带分页。
    // 对应 JS 原版：get/getId ≈ `const call = ...`，paged/pagedId ≈ `const page = ...`，
    // finishPaged ≈ pageData。
    // ─────────────────────────────────────────────────────────────

    /// 最底层助手：发一个固定路径、不带 ID、不带分页的 GET。
    /// /api/ 前缀在编译期拼上（运行时零拼接）。
    /// 使用者：recommendations、personalFm、songDetail、homeModule、aiPlaylistDetail。
    fn get(self: *Catalog, arena: Allocator, comptime path: []const u8, params: []const Param) !Result(std.json.Value) {
        return self.client.call(arena, "/api/" ++ path, .{ .params = params });
    }

    /// get 的变体：把 mediaId 校验后的 ID 拼进路径模板。
    /// comptime assert 保证模板里恰好一个 {s}——路径拼错是编译错误而非运行时 404。
    /// 使用者：albumDetail、artistDetail、playlistDetail。
    fn getId(self: *Catalog, arena: Allocator, comptime template: []const u8, id: []const u8, params: []const Param) !Result(std.json.Value) {
        comptime std.debug.assert(std.mem.count(u8, template, "{s}") == 1);
        return self.client.call(arena, try std.fmt.allocPrint(arena, "/api/" ++ template, .{try mediaId(id)}), .{ .params = params });
    }

    /// get + 分页：在业务参数外拼上 pn（page.pn(base) 换算基址）和 rn 两个
    /// 分页参数，交给 finishPaged 统一发请求、处理响应。
    /// 使用者：search。
    fn paged(self: *Catalog, arena: Allocator, comptime path: []const u8, extra: []const Param, field: []const u8, base: u32, page: Page) !Result(PageResult) {
        try page.validate();
        var params: std.ArrayList(Param) = .empty;
        try params.appendSlice(arena, extra);
        try params.append(arena, .{ .name = "pn", .value = try std.fmt.allocPrint(arena, "{d}", .{page.pn(base)}) });
        try params.append(arena, .{ .name = "rn", .value = try std.fmt.allocPrint(arena, "{d}", .{page.size}) });
        return finishPaged(self, arena, "/api/" ++ path, params.items, field, page);
    }

    /// getId + 分页：路径嵌 ID 又要翻页的列表。
    /// 使用者：playlistTracks、albumTracks、artistSongs、artistAlbums。
    fn pagedId(self: *Catalog, arena: Allocator, comptime template: []const u8, id: []const u8, extra: []const Param, field: []const u8, base: u32, page: Page) !Result(PageResult) {
        try page.validate();
        comptime std.debug.assert(std.mem.count(u8, template, "{s}") == 1);
        var params: std.ArrayList(Param) = .empty;
        try params.appendSlice(arena, extra);
        try params.append(arena, .{ .name = "pn", .value = try std.fmt.allocPrint(arena, "{d}", .{page.pn(base)}) });
        try params.append(arena, .{ .name = "rn", .value = try std.fmt.allocPrint(arena, "{d}", .{page.size}) });
        const path = try std.fmt.allocPrint(arena, "/api/" ++ template, .{try mediaId(id)});
        return finishPaged(self, arena, path, params.items, field, page);
    }

    /// paged / pagedId 共用的响应加工尾段：
    ///   发请求 → 确认响应是 JSON object → 取 data 字段
    ///   → 按 field 量出原始列表长度（搜索是 "resultList"，歌单是 "list"）
    ///   → 顺带读 total → page.hasMore 判断是否还有下一页 → 打包 PageResult。
    fn finishPaged(self: *Catalog, arena: Allocator, path: []const u8, params: []const Param, field: []const u8, page: Page) !Result(PageResult) {
        switch (try self.client.call(arena, path, .{ .params = params })) {
            .err => |e| return .{ .err = e },
            .ok => |v| {
                if (v != .object) return .{ .err = .{ .code = .invalid_response, .message = "Bodian returned an unreadable response" } };
                const data = v.object.get("data") orelse return .{ .err = .{ .code = .invalid_response, .message = "Bodian response is missing data" } };
                var raw_len: usize = 0;
                var total: ?u64 = null;
                if (data == .object) {
                    if (data.object.get(field)) |f| {
                        if (f == .array) raw_len = f.array.items.len;
                    }
                    total = jsonToU64(data.object.get("total"));
                }
                return .{ .ok = .{ .data = data, .has_more = page.hasMore(raw_len, total) } };
            },
        }
    }

    // ── 无参数直取 ──
    pub fn recommendations(self: *Catalog, arena: Allocator) !Result(std.json.Value) {
        return self.get(arena, "service/finds/playlist", &.{});
    }

    pub fn personalFm(self: *Catalog, arena: Allocator) !Result(std.json.Value) {
        return self.get(arena, "service/music/recommendList", &.{});
    }

    // ── ID 进路径的详情 ──
    pub fn songDetail(self: *Catalog, arena: Allocator, id: []const u8) !Result(std.json.Value) {
        return self.get(arena, "service/music/info", &.{.{ .name = "musicId", .value = try mediaId(id) }});
    }

    pub fn albumDetail(self: *Catalog, arena: Allocator, id: []const u8) !Result(std.json.Value) {
        return self.getId(arena, "service/album/{s}", id, &.{});
    }

    pub fn artistDetail(self: *Catalog, arena: Allocator, id: []const u8) !Result(std.json.Value) {
        return self.getId(arena, "service/artist/{s}", id, &.{});
    }

    pub fn playlistDetail(self: *Catalog, arena: Allocator, id: []const u8, source: ?u32) !Result(std.json.Value) {
        return self.getId(arena, "service/playlist/info/{s}", id, &.{try numParam(arena, "source", try playlistSource(source))});
    }

    // ── 带分页的列表（playlistTracks 基址是 1，其余是 0）──
    pub fn search(self: *Catalog, arena: Allocator, query: []const u8, page: Page) !Result(PageResult) {
        const q = std.mem.trim(u8, query, " \t\r\n");
        if (q.len == 0 or q.len > 500) return .{ .err = .{ .code = .invalid_response, .message = "Invalid Bodian search query" } };
        return self.paged(arena, "search/music/list", &.{
            .{ .name = "keyword", .value = q },
            .{ .name = "correct", .value = "1" },
        }, "resultList", 0, page);
    }

    pub fn playlistTracks(self: *Catalog, arena: Allocator, id: []const u8, source: ?u32, page: Page) !Result(PageResult) {
        return self.pagedId(arena, "service/playlist/{s}/musicList", id, &.{try numParam(arena, "source", try playlistSource(source))}, "list", 1, page);
    }

    pub fn albumTracks(self: *Catalog, arena: Allocator, id: []const u8, page: Page) !Result(PageResult) {
        return self.pagedId(arena, "service/album/music/{s}", id, &.{}, "resultList", 0, page);
    }

    pub fn artistSongs(self: *Catalog, arena: Allocator, id: []const u8, page: Page) !Result(PageResult) {
        return self.pagedId(arena, "service/artist/music/{s}", id, &.{}, "resultList", 0, page);
    }

    pub fn artistAlbums(self: *Catalog, arena: Allocator, id: []const u8, page: Page) !Result(PageResult) {
        return self.pagedId(arena, "service/artist/album/{s}", id, &.{}, "resultList", 0, page);
    }

    // ── 校验一个 0..100 的数 ──
    pub fn homeModule(self: *Catalog, arena: Allocator, module_id: u32) !Result(std.json.Value) {
        if (module_id > 100) return .{ .err = .{ .code = .invalid_response, .message = "Invalid Bodian home module id" } };
        return self.get(arena, "service/home/module", &.{try numParam(arena, "moduleId", module_id)});
    }

    pub fn aiPlaylistDetail(self: *Catalog, arena: Allocator, index: u32) !Result(std.json.Value) {
        if (index > 100) return .{ .err = .{ .code = .invalid_response, .message = "Invalid Bodian Discover index" } };
        return self.get(arena, "service/home/aiPlaylistDetail", &.{try numParam(arena, "index", index)});
    }

    // ── 歌词：歌词站 + Base64，解码接 lyrics.zig。Lyrics 分配在 arena 上，
    // 调用方连 arena 一起释放，不必调 deinit。──
    pub fn lyrics(self: *Catalog, arena: Allocator, id: []const u8) !Result(lyrics_mod.Lyrics) {
        const query = try std.fmt.allocPrint(arena, "type=lyric&req=2&lrcx=1&rid={s}&songname=&artist=&corp=kuwo&fromchannel=bodian", .{try mediaId(id)});
        const enc = std.base64.standard.Encoder;
        const q = try arena.alloc(u8, enc.calcSize(query.len));
        _ = enc.encode(q, query);

        switch (try self.client.call(arena, "/mobi.s", .{
            .lyric = true, // 走 mlyric.kuwo.cn
            .params = &.{ .{ .name = "f", .value = "bodian" }, .{ .name = "q", .value = q } },
        })) {
            .err => |e| return .{ .err = e },
            .ok => |v| {
                const missing: BodianError = .{ .code = .invalid_response, .message = "Bodian lyric content is missing" };
                if (v != .object) return .{ .err = missing };
                const data = v.object.get("data") orelse return .{ .err = missing };
                if (data != .object) return .{ .err = missing };
                const content = data.object.get("content") orelse return .{ .err = missing };
                if (content != .string) return .{ .err = missing };
                const dec = std.base64.standard.Decoder;
                const raw = try arena.alloc(u8, dec.calcSizeForSlice(content.string) catch return .{ .err = missing });
                dec.decode(raw, content.string) catch return .{ .err = missing };
                return .{ .ok = try lyrics_mod.decodeLyrics(arena, raw) };
            },
        }
    }
};

// ── 测试：纯函数部分离线验证；网络路径由 http.zig 层的联调覆盖 ──

test "Page: pn 基址与 validate 边界" {
    try std.testing.expectEqual(@as(u32, 0), (Page{}).pn(0));
    try std.testing.expectEqual(@as(u32, 4), (Page{ .number = 3 }).pn(1));
    try std.testing.expectEqual(@as(u32, 1), (Page{ .number = 0 }).pn(1));

    try (Page{ .size = 1 }).validate();
    try (Page{ .size = 100 }).validate();
    try std.testing.expectError(error.InvalidPagination, (Page{ .size = 0 }).validate());
    try std.testing.expectError(error.InvalidPagination, (Page{ .size = 101 }).validate());
}

test "Page.hasMore: total 分支按页边界，无 total 分支按满页" {
    // total=101, size=50 → 3 页；number=1 时还有第 2 页没读
    try std.testing.expect((Page{ .number = 1, .size = 50 }).hasMore(50, 101));
    try std.testing.expect(!(Page{ .number = 2, .size = 50 }).hasMore(50, 101));
    // 空页兜底：total 撒谎也停
    try std.testing.expect(!(Page{ .number = 0, .size = 50 }).hasMore(0, 999));
    // 无 total：满页继续，短页停止
    try std.testing.expect((Page{ .number = 0, .size = 50 }).hasMore(50, null));
    try std.testing.expect(!(Page{ .number = 0, .size = 50 }).hasMore(49, null));
}

test "jsonToU64: 兼容数字与数字字符串，拒绝负数/小数/畸形" {
    const p = std.json.Value;
    try std.testing.expectEqual(@as(?u64, 200), jsonToU64(p{ .integer = 200 }));
    try std.testing.expectEqual(@as(?u64, 33), jsonToU64(p{ .string = "33" }));
    try std.testing.expectEqual(@as(?u64, 7), jsonToU64(p{ .float = 7.0 }));
    try std.testing.expectEqual(@as(?u64, null), jsonToU64(p{ .float = 7.5 }));
    try std.testing.expectEqual(@as(?u64, null), jsonToU64(p{ .integer = -1 }));
    try std.testing.expectEqual(@as(?u64, null), jsonToU64(null));
}

test "mediaId: 纯数字 1..20 位且不全为零" {
    try std.testing.expectEqualStrings("12345", try mediaId("12345"));
    try std.testing.expectError(error.InvalidMediaId, mediaId(""));
    try std.testing.expectError(error.InvalidMediaId, mediaId("12a"));
    try std.testing.expectError(error.InvalidMediaId, mediaId("000"));
    try std.testing.expectError(error.InvalidMediaId, mediaId("123456789012345678901"));
}

test "playlistSource: 缺省 4，范围 1..6" {
    try std.testing.expectEqual(@as(u32, 4), try playlistSource(null));
    try std.testing.expectEqual(@as(u32, 6), try playlistSource(6));
    try std.testing.expectError(error.InvalidSource, playlistSource(0));
    try std.testing.expectError(error.InvalidSource, playlistSource(7));
}
