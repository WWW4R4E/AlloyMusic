const std = @import("std");
const Allocator = std.mem.Allocator;

const WordPair = struct { a: i64, b: i64, len: usize };
// src/core/lyrics.zig — 波点歌词的逐字时间轴解码，对应 bodian-music-api/src/lyrics.cjs。
//
// 原始格式：`[mm:ss.xx]` 行级时间戳（标准 LRC）+ `<a,b>` 字级时间对。
// `<a,b>` 不是毫秒而是混淆值，钥匙在 `[kuwo:<八进制>]` 标签里：
//   十位（八进制转十进制后）= 起始时间系数，个位 = 时长系数，
//   还原：起始 = |a+b| / (2*起始系数)，时长 = |a-b| / (2*时长系数)，整除截断。
// 无标签时默认系数为十进制 11（1 和 1）。系数为 0（如显式 [kuwo:11]，八进制 11=9）
// 或标签里没有合法八进制数字时解不出时间轴。

/// decodeLyrics 的产出。main_text 是删掉 `<a,b>` 和 `[kuwo:...]` 后的逐行歌词；
/// word_by_word_text 是已还原成毫秒的 AWLRC 文本（`<起始,时长>` 对），没有字级
/// 时间轴或解码失败时为 null。两个字段都由 gpa 分配，用完调用 deinit 释放。
pub const Lyrics = struct {
    main_text: []u8,
    word_by_word_text: ?[]u8,

    pub fn deinit(self: Lyrics, gpa: Allocator) void {
        gpa.free(self.main_text);
        if (self.word_by_word_text) |w| gpa.free(w);
    }
};

pub fn decodeLyrics(gpa: Allocator, content: []const u8) Allocator.Error!Lyrics {
    var main: std.ArrayList(u8) = .empty;
    errdefer main.deinit(gpa);
    var has_word = false;

    var i: usize = 0;
    while (i < content.len) {
        if (skipKuwoTag(content, i)) |next| {
            i = next;
        } else if (content[i] == '<') {
            if (parsePair(content[i..])) |p| {
                has_word = true;
                i += p.len;
            } else {
                try main.append(gpa, content[i]);
                i += 1;
            }
        } else {
            try main.append(gpa, content[i]);
            i += 1;
        }
    }

    const main_text = try main.toOwnedSlice(gpa);
    errdefer gpa.free(main_text);
    const word = if (has_word) try decodeWordTiming(gpa, content) else null;
    return .{ .main_text = main_text, .word_by_word_text = word };
}

/// 把 `<a,b>` 对还原成毫秒并去掉 `[kuwo:...]` 标签，其余内容原样保留。
/// 时间轴解不出来（系数无效）时返回 null，调用方退回逐行歌词。
fn decodeWordTiming(gpa: Allocator, content: []const u8) Allocator.Error!?[]u8 {
    // JS 的默认值是十进制 11，不是八进制 "11"——已与原实现对拍确认。
    var factors: u64 = 11;
    if (kuwoFactorDigits(content)) |digits| {
        factors = std.fmt.parseInt(u64, digits, 8) catch return null;
    }
    const start_factor = factors / 10;
    const duration_factor = factors % 10;
    if (start_factor == 0 or duration_factor == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const start_factor_wide: i128 = @intCast(start_factor);
    const duration_factor_wide: i128 = @intCast(duration_factor);
    var buf: [64]u8 = undefined;

    var i: usize = 0;
    while (i < content.len) {
        if (skipKuwoTag(content, i)) |next| {
            i = next;
        } else if (content[i] == '<') {
            if (parsePair(content[i..])) |p| {
                const sum: i128 = @as(i128, p.a) + p.b;
                const diff: i128 = @as(i128, p.a) - p.b;
                const start_ms = @divTrunc(@as(i128, @intCast(@abs(sum))), 2 * start_factor_wide);
                const duration_ms = @divTrunc(@as(i128, @intCast(@abs(diff))), 2 * duration_factor_wide);
                const printed = std.fmt.bufPrint(&buf, "<{d},{d}>", .{ start_ms, duration_ms }) catch unreachable;
                try out.appendSlice(gpa, printed);
                i += p.len;
            } else {
                try out.append(gpa, content[i]);
                i += 1;
            }
        } else {
            try out.append(gpa, content[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(gpa);
}

/// 找第一个合法的 `[kuwo:<八进制>]` 标签，返回其中八进制数字段；找不到返回 null。
/// JS 正则要求 `]` 紧跟在数字后，所以 `[kuwo:8a]` 这类无效标签会被跳过、
/// 继续找后面的。
fn kuwoFactorDigits(content: []const u8) ?[]const u8 {
    const tag = "[kuwo:";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, content, from, tag)) |at| {
        var j = at + tag.len;
        const digits_start = j;
        while (j < content.len and content[j] >= '0' and content[j] <= '7') j += 1;
        if (j > digits_start and j < content.len and content[j] == ']') return content[digits_start..j];
        from = at + tag.len;
    }
    return null;
}

/// 如果 content[i..] 以 `[kuwo:` 开头且在本串里有 `]`，返回跳过整个标签后的下标。
/// 对应删除用的正则 `\[kuwo:[^\]]*\]`；没有闭合 `]` 时标签按普通文本保留。
fn skipKuwoTag(content: []const u8, i: usize) ?usize {
    const tag = "[kuwo:";
    if (!std.mem.startsWith(u8, content[i..], tag)) return null;
    const close = std.mem.indexOfScalarPos(u8, content, i + tag.len, ']') orelse return null;
    return close + 1;
}

/// 解析 `<-?\d+,-?\d+>`；格式不符（如 `<1,2,3>`）或数字溢出 i64 时返回 null，
/// 调用方按普通文本处理，与 JS 正则不匹配时的行为一致。
fn parsePair(s: []const u8) ?WordPair {
    if (s.len == 0 or s[0] != '<') return null;
    var i: usize = 1;
    const a = parseI64(s, &i) orelse return null;
    if (i >= s.len or s[i] != ',') return null;
    i += 1;
    const b = parseI64(s, &i) orelse return null;
    if (i >= s.len or s[i] != '>') return null;
    return .{ .a = a, .b = b, .len = i + 1 };
}

fn parseI64(s: []const u8, i: *usize) ?i64 {
    var j = i.*;
    if (j < s.len and s[j] == '-') j += 1;
    const digits_start = j;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    if (j == digits_start) return null;
    const value = std.fmt.parseInt(i64, s[i.*..j], 10) catch return null;
    i.* = j;
    return value;
}

test "decodeLyrics: 完整解码（对拍 bodian-music-api/src/lyrics.cjs）" {
    const gpa = std.testing.allocator;
    const lyrics = try decodeLyrics(gpa, "[kuwo:21][00:01.00]<100,200>你好<300,-50>天空");
    defer lyrics.deinit(gpa);
    try std.testing.expectEqualStrings("[00:01.00]你好天空", lyrics.main_text);
    try std.testing.expectEqualStrings("[00:01.00]<150,7>你好<125,25>天空", lyrics.word_by_word_text.?);
}

test "decodeLyrics: 无标签时用默认系数 11（十进制）" {
    const gpa = std.testing.allocator;
    const lyrics = try decodeLyrics(gpa, "<100,200>你好");
    defer lyrics.deinit(gpa);
    try std.testing.expectEqualStrings("你好", lyrics.main_text);
    try std.testing.expectEqualStrings("<150,50>你好", lyrics.word_by_word_text.?);
}

test "decodeLyrics: 没有字级时间轴时 word_by_word_text 为 null" {
    const gpa = std.testing.allocator;
    const lyrics = try decodeLyrics(gpa, "[kuwo:21][00:01.00]你好");
    defer lyrics.deinit(gpa);
    try std.testing.expectEqualStrings("[00:01.00]你好", lyrics.main_text);
    try std.testing.expect(lyrics.word_by_word_text == null);
}

test "decodeLyrics: 畸形对按原文保留，非法八进制标签跳过" {
    const gpa = std.testing.allocator;
    const lyrics = try decodeLyrics(gpa, "<1,2,3>[kuwo:8]<-5,10>x");
    defer lyrics.deinit(gpa);
    try std.testing.expectEqualStrings("<1,2,3>x", lyrics.main_text);
    try std.testing.expectEqualStrings("<1,2,3><2,7>x", lyrics.word_by_word_text.?);
}

test "decodeWordTiming: 大系数与零起点（对拍 [kuwo:77] 用例）" {
    const gpa = std.testing.allocator;
    const word = (try decodeWordTiming(gpa, "[kuwo:77][02:00.00]<0,0>a<999999,-999999>b")).?;
    defer gpa.free(word);
    try std.testing.expectEqualStrings("[02:00.00]<0,0>a<0,333333>b", word);
}
