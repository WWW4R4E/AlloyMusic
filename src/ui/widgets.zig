const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zz = @import("zigzag");
const theme = @import("theme.zig");
const model = @import("model.zig");

// src/ui/widgets.zig — 复用部件：页签栏、播放栏、进度条、列表行、状态行。
// 所有函数只在渲染期调用，分配用 frame allocator，产出的每一行都恰好
// 等宽于传入的 w（不足补空、超长截断），保证 zigzag 的 diff 渲染不会
// 因行溢出而整屏重画。

pub const Page = enum(u3) {
    explore,
    search,
    now,
    liked,
    queue,

    pub fn title(self: Page) []const u8 {
        return switch (self) {
            .explore => "探索",
            .search => "搜索",
            .now => "正在播放",
            .liked => "我的喜欢",
            .queue => "队列",
        };
    }

    pub fn count() usize {
        return @typeInfo(Page).@"enum".field_names.len;
    }

    /// 导航页签。正在播放是 v 键切换的全屏播放模式，不占页签位；
    /// 音乐库不再占页签——侧栏"我的歌单"就是音乐库。
    pub const tabs = [_]Page{ .explore, .search, .liked, .queue };
};

/// 侧栏条目布局：第 0..3 项是页签，第 4 项是"我的歌单"，第 5 项起是歌单行
/// （页签和"我的歌单"之间不留空行，紧凑排布）。
/// onMouse 的命中判定（sidebarHit）与渲染共用这套常量。
pub const SB_MYPL: usize = Page.tabs.len;
pub const SB_PL_START: usize = Page.tabs.len + 1;

/// 侧栏行号 → 条目序号（0..3 页签，4 = 我的歌单，5.. = 歌单，序号-5 为歌单下标）。
pub fn sidebarHit(row: usize, n_pls: usize) ?usize {
    if (row < Page.tabs.len) return row;
    if (row == SB_MYPL) return Page.tabs.len;
    if (n_pls > 0 and row >= SB_PL_START and row < SB_PL_START + n_pls)
        return Page.tabs.len + 1 + (row - SB_PL_START);
    return null;
}

pub const SidebarInfo = struct {
    page: Page,
    cover: ?model.Song = null,
    playlists: []const model.Playlist = &.{},
    /// "我的歌单"导航模式打开中
    selecting: bool = false,
    /// 已在右侧打开的歌单索引（0 计），▎ 树条标记
    open_idx: ?usize = null,
};

pub fn formatDuration(a: Allocator, secs: u32) []const u8 {
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}", .{ secs / 60, secs % 60 }) catch "--:--";
}

/// 浮层打开时的暗色空底帧（无任何文字，避免 LayerStack 合成时
/// 不透明卡片劈开底帧全角字符造成的行宽错位）
pub fn blankFrame(a: Allocator, w: usize, h: usize) []const u8 {
    const s = (zz.Style{}).bg(zz.Color.color256(234)).width(@intCast(w)).height(@intCast(h));
    return s.render(a, " ") catch "";
}

/// 终端字格高宽比（行高/列宽），封面方格行数按它换算。
/// 默认 2.25，启动时用 ioctl(TIOCGWINSZ) 的终端像素尺寸实测覆盖
/// （xpixel/ypixel 多数位图终端都报），AM_CELL_RATIO 仍可手动覆盖。
pub var cell_ratio: f32 = 2.25;

/// 用 TIOCGWINSZ 的像素尺寸实测字格比；拿不到（不支持/报 0）则保持现值。
pub fn probeCellRatio() void {
    if (builtin.os.tag == .windows) return; // Windows 控制台无像素尺寸，走默认/env
    const posix = std.posix;
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    // TIOCGWINSZ = 0x5413（Linux）
    const rc = posix.system.ioctl(1, 0x5413, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS) return;
    if (ws.col == 0 or ws.row == 0 or ws.xpixel == 0 or ws.ypixel == 0) return;
    const cell_w: f32 = @as(f32, @floatFromInt(ws.xpixel)) / @as(f32, @floatFromInt(ws.col));
    const cell_h: f32 = @as(f32, @floatFromInt(ws.ypixel)) / @as(f32, @floatFromInt(ws.row));
    if (cell_w <= 0 or cell_h <= 0) return;
    const r = cell_h / cell_w;
    if (r >= 1.0 and r <= 4.0) cell_ratio = r;
}

pub fn setCellRatio(v: ?[]const u8) void {
    const raw = v orelse return;
    const r = std.fmt.parseFloat(f32, raw) catch return;
    if (r >= 1.0 and r <= 4.0) cell_ratio = r;
}

/// cover_cols 列的正方形封面需要多少行
pub fn coverRows(cover_cols: usize) usize {
    const rows: usize = @intFromFloat(@as(f64, @floatFromInt(cover_cols)) / cell_ratio);
    return @max(rows, 4);
}

/// n 列宽的带底色空格段（行内样式、无换行，可安全拼接进一行）
pub fn bgSpan(a: Allocator, n: usize, c: zz.Color) []const u8 {
    if (n == 0) return "";
    return (zz.Style{}).bg(c).inline_style(true).render(a, blankSpaces(a, n)) catch "";
}

pub fn blankSpaces(a: Allocator, n: usize) []const u8 {
    const s = a.alloc(u8, n) catch return "";
    @memset(s, ' ');
    return s;
}

/// 行宽归一：把内容补齐/截断到恰好 w 列。
/// 带底色时不能靠 Style.bg 自动补位——行内片段结尾的 reset 会把外层
/// bg 清掉、补位空格变透明，所以截断后手工拼带底色的空格段。
pub fn fit(a: Allocator, content: []const u8, w: usize, bg: ?zz.Color) []const u8 {
    if (bg) |c| {
        const t = zz.measure.truncate(a, content, w) catch content;
        const tw = @min(zz.width(t), w);
        if (tw >= w) return t;
        return zz.joinHorizontal(a, &.{ t, bgSpan(a, w - tw, c) }) catch t;
    }
    const s = (zz.Style{}).width(@intCast(w)).overflow(.ellipsis);
    return s.render(a, content) catch "";
}

/// fit 的无省略号版：纯切断 + 补空格到恰好 w 列。用于 toast 盖顶栏这类
/// "内容只是被遮住、不是被裁掉"的场景——zigzag 的 truncate/ellipsis
/// 只要发生裁切就追加 "..."，看起来像凭空多了省略号。
pub fn fitPlain(a: Allocator, content: []const u8, w: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var tw: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == 0x1b) {
            // ANSI 转义：原样保留、不计宽（与 zigzag 同款解析）
            const start = i;
            i += 1;
            if (i < content.len and content[i] == '[') {
                i += 1;
                while (i < content.len and !((content[i] >= 'A' and content[i] <= 'Z') or (content[i] >= 'a' and content[i] <= 'z'))) i += 1;
                if (i < content.len) i += 1;
            }
            out.appendSlice(a, content[start..i]) catch break;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(content[i]) catch 1;
        const end = @min(i + seq_len, content.len);
        const cw = zz.width(content[i..end]);
        if (tw + cw > w) break;
        out.appendSlice(a, content[i..end]) catch break;
        tw += cw;
        i = end;
    }
    out.appendSlice(a, blankSpaces(a, w -| tw)) catch {};
    return out.items;
}

/// ── 左侧导航栏：编号导航 + 我的歌单 + 底部当前歌曲封面小面板 ──
/// 透明底（不用色块），右缘一条竖分割线与主区分隔；歌单行点击/回车
/// 在右侧打开歌曲列表。封面面板按 行:列=4:9 取正方形（终端行高≈2.4 倍列宽）。
pub fn sidebar(a: Allocator, w: usize, h: usize, info: SidebarInfo) []const u8 {
    const nav_w = w -| 1; // 右缘 1 列留给分割线
    var lines: std.ArrayList([]const u8) = .empty;
    inline for (Page.tabs, 0..) |p, i| {
        // "我的歌单"激活时不标页签（▎/高亮只属于当前位置）
        const cur = p == info.page and !info.selecting;
        const label = std.fmt.allocPrint(a, "{s} {d} {s}", .{
            if (cur) "▎" else " ",
            i + 1,
            p.title(),
        }) catch "";
        const st = if (cur)
            theme.inlineBold(theme.green)
        else
            theme.inlineStyle(theme.dim);
        lines.append(a, fit(a, st.render(a, label) catch "", nav_w, null)) catch {};
    }

    // 我的歌单：页签后一行（显示编号 5），歌单行直接列在下面（选取模式下带高亮游标）
    const n_show = @min(info.playlists.len, h -| SB_PL_START);
    if (h > SB_MYPL) {
        const label = std.fmt.allocPrint(a, "{s} 5 我的歌单", .{if (info.selecting) "▎" else " " }) catch "";
        const st = if (info.selecting)
            theme.inlineBold(theme.green)
        else
            theme.inlineStyle(theme.text);
        lines.append(a, fit(a, st.render(a, label) catch "", nav_w, null)) catch {};
    }
    if (n_show > 0) {
        for (info.playlists[0..n_show], 0..) |pl, i| {
            const opened = info.open_idx != null and info.open_idx.? == i;
            // 树条随歌单行缩进一格（与外层页签的 ▎ 错开一列）
            const label = std.fmt.allocPrint(a, "  {s} ♪ {s}", .{ if (opened) "▎" else " ", pl.name }) catch "";
            const st = if (opened)
                theme.inlineBold(theme.green)
            else if (pl.kind == .album)
                theme.inlineStyle(theme.dim)
            else
                theme.inlineStyle(theme.text);
            lines.append(a, fit(a, st.render(a, label) catch "", nav_w, null)) catch {};
        }
    }

    // 底部封面占位：正方形（含圆角边框），行:列=4:9（格高比在 2.1~2.4 之间）。
    // Windows：封面组件整体移除（位图不支持，占位框只占地方）
    if (comptime builtin.os.tag != .windows) {
        const cover_cols: usize = @min(nav_w -| 2, 16);
        const cover_rows: usize = coverRows(cover_cols);
        if (h > lines.items.len + cover_rows + 1) {
            while (lines.items.len + cover_rows + 1 < h) lines.append(a, "") catch {};
            const glyph = if (info.cover != null)
                theme.inlineBold(theme.green).render(a, "♪") catch ""
            else
                theme.note().render(a, "·") catch "";
            const panel = theme.panel()
                .width(@intCast(cover_cols -| 2))
                .height(@intCast(cover_rows -| 2))
                .alignH(.center)
                .valign(.middle)
                .render(a, glyph) catch "";
            lines.append(a, zz.place.place(a, nav_w, cover_rows, .center, .top, panel) catch "") catch {};
        }
    }

    // 每行恰好 nav_w 宽（fit 补齐过），拼上分割线列。
    // 分割线逐行样式化再 joinVertical——多行文本经 inline 样式 render
    // 会把换行吞掉，变成一横排
    const content = zz.joinVertical(a, lines.items) catch "";
    const dv = theme.inlineStyle(theme.rule).render(a, "│") catch "│";
    var div_parts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < h) : (i += 1) div_parts.append(a, dv) catch {};
    const divider = zz.joinVertical(a, div_parts.items) catch dv;
    return zz.joinHorizontal(a, &.{ content, divider }) catch content;
}

/// ── 全局顶栏（1 行）：应用名徽标居左，登录态居右 ──
/// 顶栏右侧标签：音源 + 登录态（调用方拼好，如 "音源 网易云 · 未登录 (L)"）
pub fn topBar(a: Allocator, w: usize, right_label: []const u8) []const u8 {
    const badge = theme.headerBadge().render(a, " ♫ AlloyMusic") catch "";
    const login = theme.warnInline().render(a, right_label) catch "";
    const room = w -| zz.width(badge);
    const right = zz.place.placeHorizontal(a, room, .right, login) catch "";
    return fit(a, zz.joinHorizontal(a, &.{ badge, right }) catch "", w, null);
}

/// ── 进度条：mm:ss ━━━━●──── mm:ss ──
pub fn progressBar(a: Allocator, w: usize, pos_ms: u32, dur_ms: u32) []const u8 {
    const bar_w = w -| 14;
    if (bar_w < 4) return "";
    var filled: usize = 0;
    if (dur_ms > 0) {
        const pct = @as(u64, pos_ms) * 100 / @as(u64, dur_ms);
        filled = @intCast(@as(u64, bar_w) * @min(pct, 100) / 100);
    }
    var buf: std.Io.Writer.Allocating = .init(a);
    const writer = &buf.writer;
    writer.print("{s} ", .{formatDuration(a, pos_ms / 1000)}) catch {};
    // 已播放段 + 播放头
    const head: usize = if (filled > 0) 1 else 0;
    var i: usize = 0;
    while (i < filled - head) : (i += 1) writer.writeAll("━") catch {};
    if (filled > 0) writer.writeAll("●") catch {};
    i = 0;
    while (i < bar_w - filled) : (i += 1) writer.writeAll("─") catch {};
    writer.print(" {s}", .{formatDuration(a, dur_ms / 1000)}) catch {};
    const line = buf.written();
    // 分段着色：时间暗色、条绿色。StyleRange 按字节偏移切分——
    // ━ ● ─ 都是 3 字节 UTF-8，列数要乘 3 才是字节边界。
    const time_w = 5;
    const bar_off = time_w + 1;
    const fill_end = bar_off + filled * 3;
    const bar_end = bar_off + bar_w * 3;
    var ranges: [4]zz.StyleRange = undefined;
    var n: usize = 0;
    ranges[n] = .{ .start = 0, .end = time_w, .s = theme.inlineStyle(theme.dim) };
    n += 1;
    ranges[n] = .{ .start = bar_off, .end = fill_end, .s = theme.inlineBold(theme.green) };
    n += 1;
    ranges[n] = .{ .start = fill_end, .end = bar_end, .s = theme.inlineStyle(theme.dim) };
    n += 1;
    ranges[n] = .{ .start = bar_end + 1, .end = line.len, .s = theme.inlineStyle(theme.dim) };
    const styled = zz.renderWithRanges(a, line, ranges[0..n]) catch line;
    return fit(a, styled, w, null);
}

/// ── 播放栏第 1 行：状态符号 + 歌名 — 歌手（右：音质 · 音量）──
pub const PlayerInfo = struct {
    has_song: bool,
    playing: bool,
    title: []const u8 = "",
    artist: []const u8 = "",
    vip: bool = false,
    volume: u8 = 80,
    mute: bool = false,
    radio: bool = false, // 电台模式开着就常驻显示，不随状态条消息消失
    /// 当前播放模式（列表循环/单曲循环/随机），空串则不显示
    mode_label: []const u8 = "",
};

pub fn playerInfoLine(a: Allocator, w: usize, info: PlayerInfo) []const u8 {
    var right_buf: std.Io.Writer.Allocating = .init(a);
    const rw = &right_buf.writer;
    if (info.radio) rw.writeAll("电台 ") catch {};
    if (info.mode_label.len > 0) rw.print("{s} ", .{info.mode_label}) catch {};
    if (info.has_song and info.vip) rw.writeAll("VIP ") catch {};
    if (info.mute) {
        rw.writeAll("♪ 静音") catch {};
    } else {
        rw.print("♪ {d}%", .{info.volume}) catch {};
    }
    const right = theme.inlineStyle(theme.dim).render(a, right_buf.written()) catch "";

    var left_buf: std.Io.Writer.Allocating = .init(a);
    const lw = &left_buf.writer;
    if (info.has_song) {
        // 图标表示“按下的动作”：暂停中 ▶（点击播放），播放中 ⏸（点击暂停）
        const sym: []const u8 = if (info.playing) "⏸" else "▶";
        lw.print("{s} {s} — {s}", .{ sym, info.title, info.artist }) catch {};
    } else {
        lw.writeAll("· 未在播放") catch {};
    }
    const left_plain = left_buf.written();
    // StyleRange 按字节偏移切分，边界必须落在完整字符上。
    // "▶"/"⏸" 都是 3 字节 UTF-8，第 4 字节是空格，正文从第 5 字节起。
    const styled = if (info.has_song)
        zz.renderWithRanges(a, left_plain, &.{
            .{ .start = 0, .end = 3, .s = theme.inlineBold(theme.green) },
            .{ .start = 4, .end = left_plain.len, .s = theme.inlineStyle(theme.text) },
        }) catch left_plain
    else
        theme.inlineStyle(theme.dim).render(a, left_plain) catch left_plain;

    const room = w -| (zz.width(right) + 1);
    const left_fit = fit(a, styled, room, null);
    const row = zz.joinHorizontal(a, &.{ left_fit, right }) catch "";
    return fit(a, row, w, null);
}

/// ── 列表行 ──

pub const SongRowInfo = struct {
    num: ?usize, // 序号（探索页分节内编号、搜索/队列等全页编号）
    song: model.Song,
    selected: bool,
    playing: bool,
};

pub fn songRow(a: Allocator, w: usize, info: SongRowInfo) []const u8 {
    // 选中行：每个片段自带底色（行内 reset 会清掉外层 bg），行尾 fit 补齐
    const bgc: ?zz.Color = if (info.selected) theme.row_on_bg else null;
    // 列宽：序号 4 + 时长 5，三处 2 空格间隔；歌名吃剩余
    const artist_w = std.math.clamp(w * 17 / 100, 8, 24);
    const album_w = std.math.clamp(w * 21 / 100, 8, 26);
    const title_w = w -| (4 + artist_w + album_w + 5 + 6);

    var num_buf: [8]u8 = undefined;
    const num = if (info.num) |n|
        std.fmt.bufPrint(&num_buf, "{d:>3} ", .{n}) catch "    "
    else
        "    ";

    var title_buf: std.Io.Writer.Allocating = .init(a);
    if (info.playing) title_buf.writer.writeAll("▶ ") catch {};
    title_buf.writer.print("{s}", .{info.song.title}) catch {};
    if (info.song.vip) title_buf.writer.writeAll(" ·VIP") catch {};
    const title_fit = zz.measure.truncate(a, title_buf.written(), title_w) catch title_buf.written();
    const title_st = if (info.playing)
        theme.boldOn(theme.green, bgc)
    else
        theme.inlineOn(theme.text, bgc);

    const artist_fit = zz.measure.truncate(a, info.song.artist, artist_w) catch info.song.artist;
    const album_fit = zz.measure.truncate(a, info.song.album, album_w) catch info.song.album;
    const gap = theme.inlineOn(theme.dim, bgc).render(a, "  ") catch "  ";

    const row = zz.joinHorizontal(a, &.{
        theme.inlineOn(theme.dim, bgc).render(a, num) catch "",
        title_st.render(a, title_fit) catch "",
        gap,
        theme.inlineOn(theme.dim, bgc).render(a, artist_fit) catch "",
        gap,
        theme.inlineOn(theme.dim, bgc).render(a, album_fit) catch "",
        gap,
        theme.inlineOn(theme.dim, bgc).render(a, formatDuration(a, info.song.duration_s)) catch "",
    }) catch "";
    return fit(a, row, w, bgc);
}

pub fn playlistRow(a: Allocator, w: usize, pl: model.Playlist, selected: bool) []const u8 {
    const bgc: ?zz.Color = if (selected) theme.row_on_bg else null;
    const right = theme.inlineOn(theme.dim, bgc).render(a, std.fmt.allocPrint(a, "{s} · {d} 首", .{ pl.typeName(), pl.track_count }) catch "") catch "";
    // 计数列贴右缘：左段截断后按实际宽度补中间空隙
    const left_room = w -| (zz.width(right) + 2);
    var left_buf: std.Io.Writer.Allocating = .init(a);
    left_buf.writer.print("♪ {s}", .{pl.name}) catch {};
    const left_fit = zz.measure.truncate(a, left_buf.written(), left_room) catch left_buf.written();
    const left_st = if (selected) theme.boldOn(theme.text, bgc) else theme.inlineOn(theme.text, bgc);
    const styled_left = left_st.render(a, left_fit) catch left_fit;
    const mid_n = w -| zz.width(styled_left) -| zz.width(right);
    const mid = if (bgc) |c| bgSpan(a, mid_n, c) else blankSpaces(a, mid_n);
    const row = zz.joinHorizontal(a, &.{ styled_left, mid, right }) catch "";
    return fit(a, row, w, bgc);
}

pub fn sectionRow(a: Allocator, w: usize, title: []const u8) []const u8 {
    // ── 推荐 ─────── ：标题粉色，尾随横线用更暗的灰
    const head = std.fmt.allocPrint(a, "── {s} ", .{title}) catch "";
    const rest_w = w -| zz.width(head);
    var buf: std.Io.Writer.Allocating = .init(a);
    const writer = &buf.writer;
    writer.print("{s}", .{head}) catch {};
    var i: usize = 0;
    while (i < rest_w) : (i += 1) writer.writeAll("─") catch {};
    const line = buf.written();
    const styled = zz.renderWithRanges(a, line, &.{
        .{ .start = 0, .end = head.len, .s = theme.inlineBold(theme.pink) },
        .{ .start = head.len, .end = line.len, .s = theme.inlineStyle(zz.Color.color256(238)) },
    }) catch line;
    return fit(a, styled, w, null);
}

pub fn noteRow(a: Allocator, w: usize, text: []const u8) []const u8 {
    return fit(a, theme.note().render(a, text) catch text, w, null);
}

/// ── 按键提示段：[键] 说明（键绿色加粗，说明正文色）──
pub fn keyHint(a: Allocator, key: []const u8, desc: []const u8) []const u8 {
    const k = theme.inlineBold(theme.green).render(a, std.fmt.allocPrint(a, "[{s}]", .{key}) catch "") catch "";
    const d = theme.inlineStyle(theme.text).render(a, std.fmt.allocPrint(a, " {s}", .{desc}) catch "") catch "";
    return zz.joinHorizontal(a, &.{ k, d }) catch "";
}

pub fn joinHints(a: Allocator, pairs: []const [2][]const u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (pairs) |p| {
        if (p[0].len == 0) continue;
        parts.append(a, keyHint(a, p[0], p[1])) catch {};
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (parts.items, 0..) |hint, i| {
        if (i > 0) out.append(a, "   ") catch {};
        out.append(a, hint) catch {};
    }
    return zz.joinHorizontal(a, out.items) catch "";
}

/// ── 状态行（1 行）：错误/反馈消息优先，否则按页显示 [键] 说明 提示 ──
/// 放不下时从末尾逐个丢弃提示（顺序按重要性排，q 退出 比 ? 帮助 先留）。
pub fn statusLine(a: Allocator, w: usize, message: ?[]const u8, page: Page) []const u8 {
    if (message) |msg| return fit(a, theme.warnInline().render(a, msg) catch msg, w, null);
    // 播放页专属键并进底部状态行（原来在播放页内部还有一份，已删）
    const now_pairs = [_][2][]const u8{
        .{ "空格", "播放/暂停" }, .{ "←→", "±5秒" },     .{ "n/p", "切歌" }, .{ "r", "播放模式" },
        .{ "o", "电台" },         .{ "v", "返回列表" },   .{ "-/+", "音量" }, .{ "m", "静音" },
        .{ "q", "退出" },         .{ "?", "帮助" },
    };
    const search_pairs = [_][2][]const u8{
        .{ "/", "聚焦输入框" }, .{ "Enter", "搜索" }, .{ "↑↓", "移动" }, .{ "Esc", "退出输入框" },
        .{ "v", "播放界面" },   .{ "Tab", "侧栏" },   .{ "q", "退出" },    .{ "?", "帮助" },
    };
    const list_pairs = [_][2][]const u8{
        .{ "↑↓", "移动" }, .{ "Enter", "播放/打开" }, .{ "a", "加入队列" }, .{ "v", "播放界面" },
        .{ "o", "电台" },  .{ "r", "播放模式" },      .{ "Tab", "侧栏" },   .{ "/", "搜索" },
        .{ "1-4", "页签" }, .{ "q", "退出" },          .{ "?", "帮助" },
    };
    const pairs: []const [2][]const u8 = switch (page) {
        .now => &now_pairs,
        .search => &search_pairs,
        else => &list_pairs,
    };
    var n = pairs.len;
    while (true) {
        const s = joinHints(a, pairs[0..n]);
        if (zz.width(s) <= w or n == 1) return fit(a, s, w, null);
        n -= 1;
    }
}

/// ── 浮层卡片：圆角框内放标题 + 正文，尺寸由调用方算好 ──
pub fn card(a: Allocator, box_w: usize, title: []const u8, body_lines: []const []const u8) []const u8 {
    const content_w = box_w -| 4;
    var lines: std.ArrayList([]const u8) = .empty;
    const title_line = theme.inlineBold(theme.green).render(a, title) catch title;
    lines.append(a, zz.measure.truncate(a, title_line, content_w) catch title_line) catch {};
    for (body_lines) |l| {
        lines.append(a, zz.measure.truncate(a, l, content_w) catch l) catch {};
    }
    const body = zz.joinVertical(a, lines.items) catch "";
    // theme.card() 自带边框 2 列 + paddingAll 1 圈（4 列），width 给内容区
    // ——总宽恰为 box_w。此前给 box_w-2 会多出 2 列，导致调用方按 box_w
    // 截断时把右边框截成省略号
    return theme.card().width(@intCast(box_w -| 4)).paddingAll(1).render(a, body) catch "";
}
