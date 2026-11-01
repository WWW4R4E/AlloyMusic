const std = @import("std");
const Allocator = std.mem.Allocator;
const core_lyrics = @import("../core/lyrics.zig");

// src/ui/lyrics.zig — 歌词展示层。
//
// 混淆解码直接复用 core/lyrics.zig 的 decodeLyrics（import，不改动）：
// content 是歌词接口 data.content base64 解码后的原始文本，先还原成
// 行级 LRC（main_text），再把每行的 [mm:ss.xx] 时间轴翻成行列表。
// 同一时间戳出现第二行按 LRC 惯例视为上一行的翻译，mock 数据靠这个
// 约定生成中英对照。

pub const Line = struct {
    time_ms: u32,
    text: []const u8,
    translation: ?[]const u8 = null,
};

pub const Lyrics = struct {
    lines: []Line,

    /// 当前应高亮的行：时间不大于 pos_ms 的最后一行（线性扫即可，几百行）。
    pub fn currentIndex(self: Lyrics, pos_ms: u32) ?usize {
        var found: ?usize = null;
        for (self.lines, 0..) |line, i| {
            if (line.time_ms > pos_ms) break;
            found = i;
        }
        return found;
    }
};

/// content → 解混淆 → 行级时间轴。全部分配在 arena 上，无需 deinit。
pub fn decodeAndParse(a: Allocator, content: []const u8) !Lyrics {
    const decoded = try core_lyrics.decodeLyrics(a, content);
    return parse(a, decoded.main_text);
}

pub fn parse(a: Allocator, main_text: []const u8) !Lyrics {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(a);

    var it = std.mem.splitScalar(u8, main_text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var rest = line;
        var time: ?u32 = null;
        // 行首可能有多个 [..] 标签；取第一个合法时间戳，其余当元数据剥掉
        while (rest.len > 0 and rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
            if (parseTimestamp(rest[1..close])) |ms| {
                time = ms;
                rest = rest[close + 1 ..];
                break;
            }
            rest = rest[close + 1 ..];
        }
        const ms = time orelse continue;
        const text = std.mem.trim(u8, rest, " ");
        // 与上一行同时间戳且上一行还没有翻译 → 这行是它的翻译
        if (text.len > 0 and lines.items.len > 0) {
            const last = &lines.items[lines.items.len - 1];
            if (last.time_ms == ms and last.translation == null) {
                last.translation = text;
                continue;
            }
        }
        try lines.append(a, .{ .time_ms = ms, .text = text });
    }
    return .{ .lines = try lines.toOwnedSlice(a) };
}

/// "mm:ss.xx" / "mm:ss.xxx" → 毫秒；不合法返回 null（当普通标签跳过）。
fn parseTimestamp(tag: []const u8) ?u32 {
    const colon = std.mem.indexOfScalar(u8, tag, ':') orelse return null;
    const mm = std.fmt.parseInt(u32, tag[0..colon], 10) catch return null;
    if (mm > 90) return null;
    const rest = tag[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    const ss_part = if (dot) |d| rest[0..d] else rest;
    if (ss_part.len < 2) return null;
    const ss = std.fmt.parseInt(u32, ss_part[0..2], 10) catch return null;
    if (ss > 59) return null;
    var ms: u32 = (mm * 60 + ss) * 1000;
    if (dot) |d| {
        // 小数部分是厘秒（.50 = 500ms）；xxx 毫秒格式取前三位
        const frac = rest[d + 1 ..];
        if (frac.len == 1) {
            ms += (std.fmt.parseInt(u32, frac[0..1], 10) catch 0) * 100;
        } else if (frac.len == 2) {
            ms += (std.fmt.parseInt(u32, frac[0..2], 10) catch 0) * 10;
        } else if (frac.len >= 3) {
            ms += std.fmt.parseInt(u32, frac[0..3], 10) catch 0;
        }
    }
    return ms;
}

// ── 离线测试 ──

test "parse: 时间轴 + 重复时间戳配对成翻译" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const lyrics = try parse(arena.allocator(),
        \\[00:01.00]第一句
        \\[00:01.00]Line one
        \\[00:05.50]第二句
        \\[ar:测试]
        \\无时间戳的行
    );
    try std.testing.expectEqual(@as(usize, 2), lyrics.lines.len);
    try std.testing.expectEqualStrings("第一句", lyrics.lines[0].text);
    try std.testing.expectEqualStrings("Line one", lyrics.lines[0].translation.?);
    try std.testing.expectEqual(@as(u32, 5500), lyrics.lines[1].time_ms);
    try std.testing.expect(lyrics.lines[1].translation == null);
}

test "currentIndex: 定位不大于进度的最后一行" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const lyrics = try parse(arena.allocator(), "[00:10.00]甲\n[00:20.00]乙\n[00:30.00]丙");
    try std.testing.expect(lyrics.currentIndex(0) == null);
    try std.testing.expectEqual(@as(usize, 0), lyrics.currentIndex(10_000).?);
    try std.testing.expectEqual(@as(usize, 1), lyrics.currentIndex(25_000).?);
    try std.testing.expectEqual(@as(usize, 2), lyrics.currentIndex(600_000).?);
}

test "decodeAndParse: 走通 core 解混淆链路" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    // [kuwo:21]（八进制 17：起始系数 1、时长系数 7）
    // <100+700, 100-700> → 起始 100ms、时长 100ms
    const lyrics = try decodeAndParse(arena.allocator(), "[kuwo:21][00:00.10]<800,-600>甲乙");
    try std.testing.expectEqual(@as(usize, 1), lyrics.lines.len);
    try std.testing.expectEqualStrings("甲乙", lyrics.lines[0].text);
}
