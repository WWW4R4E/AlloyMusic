const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zz = @import("zigzag");
const theme = @import("theme.zig");
const model = @import("model.zig");
const mock = @import("mock.zig");
const widgets = @import("widgets.zig");
const lyrics_mod = @import("lyrics.zig");
const app_mod = @import("app.zig");

// src/ui/pages.zig — 各页签的行模型与主体渲染。
//
// 关键约定：buildRows 同时服务 update（按键解释游标所在行）和 view
// （渲染可视窗口），两边看到的是同一份行序列，游标语义不会漂移。
// 行模型仿 qq-music-tui 的 rows.go：分节标题/提示行不可选，歌曲与
// 歌单行可选，移动游标时跳过不可选行。

pub const SongRef = struct {
    list: []const model.Song, // Enter 播放时整个列表成为队列
    idx: usize,
    num: usize, // 显示序号
};

pub const Row = union(enum) {
    section: []const u8,
    note: []const u8,
    song: SongRef,
    playlist: model.Playlist,
};

pub fn selectable(row: Row) bool {
    return switch (row) {
        .song, .playlist => true,
        .section, .note => false,
    };
}

fn currentSong(m: *const app_mod.Model) ?model.Song {
    const i = m.q_index orelse return null;
    if (i >= m.queue.items.len) return null;
    return m.queue.items[i];
}

fn playingId(m: *const app_mod.Model) ?[]const u8 {
    const s = currentSong(m) orelse return null;
    return s.id;
}

fn playingFlag(m: *const app_mod.Model, song: model.Song) bool {
    const id = playingId(m) orelse return false;
    return std.mem.eql(u8, id, song.id);
}

fn appendSong(a: Allocator, rows: *std.ArrayList(Row), list: []const model.Song, num_offset: usize) void {
    for (list, 0..) |_, i| {
        rows.append(a, .{ .song = .{ .list = list, .idx = i, .num = num_offset + i + 1 } }) catch return;
    }
}

fn appendPlaylists(a: Allocator, rows: *std.ArrayList(Row), list: []const model.Playlist) void {
    for (list) |pl| rows.append(a, .{ .playlist = pl }) catch return;
}

/// 分节标题自带前空行（首个除外）——留白靠这个
fn addSection(a: Allocator, rows: *std.ArrayList(Row), title: []const u8) void {
    if (rows.items.len > 0) rows.append(a, .{ .note = "" }) catch {};
    rows.append(a, .{ .section = title }) catch {};
}

/// 各页的完整行序列（含分节标题、提示行）。frame allocator 上分配。
pub fn buildRows(a: Allocator, m: *const app_mod.Model, page: widgets.Page) []Row {
    var rows: std.ArrayList(Row) = .empty;
    const d: *const mock.Data = &m.data;
    const real = m.backend != .mock;
    switch (page) {
        .explore => {
            if (m.loading[app_mod.kindIndex(.explore)]) {
                rows.append(a, .{ .note = "加载中…" }) catch {};
            }
            if (d.errors.items.len > 0) {
                for (d.errors.items) |e| rows.append(a, .{ .note = e }) catch {};
            }
            if (d.recommend.len > 0) {
                addSection(a, &rows, "推荐歌单");
                appendPlaylists(a, &rows, d.recommend);
            }
            if (d.fm.len > 0) {
                addSection(a, &rows, "每日推荐");
                appendSong(a, &rows, d.fm, 0);
            }
            if (d.discover.len > 0) {
                addSection(a, &rows, "Discover 歌单");
                appendPlaylists(a, &rows, d.discover);
            }
            if (rows.items.len == 0) rows.append(a, .{ .note = if (real and m.backend == .bodian)
                "（波点探索页需要登录：按 L 扫码登录）"
            else if (real)
                "（探索页暂无数据，可按 s 切换音源）"
            else
                "（探索页无数据：检查 testdata/mock/）" }) catch {};
        },
        .search => {
            if (m.loading[app_mod.kindIndex(.search)]) {
                rows.append(a, .{ .note = std.fmt.allocPrint(a, "搜索“{s}”中…", .{if (m.search_input.value.items.len > 0) m.search_input.value.items else " "}) catch "搜索中…" }) catch {};
            } else if (!m.search_done) {
                rows.append(a, .{ .note = if (real) "输入关键词后回车搜索（音源见顶栏，s 切换）" else "输入关键词后回车查看结果（演示数据）" }) catch {};
            } else {
                const head = std.fmt.allocPrint(a, "“{s}” · 共 {d} 条", .{ if (m.search_input.value.items.len > 0) m.search_input.value.items else " ", d.search.len }) catch "";
                rows.append(a, .{ .note = head }) catch {};
                appendSong(a, &rows, d.search, 0);
            }
        },
        .now => {},
        .liked => {
            appendSong(a, &rows, d.liked, 0);
            if (rows.items.len == 0) rows.append(a, .{ .note = if (real) "（红心歌单需要登录：按 L 登录当前音源）" else "（红心歌单为空）" }) catch {};
        },
        .queue => {
            for (m.queue.items, 0..) |_, i| {
                rows.append(a, .{ .song = .{ .list = m.queue.items, .idx = i, .num = i + 1 } }) catch {};
            }
            if (m.queue.items.len == 0) rows.append(a, .{ .note = "（队列为空：任意列表按 Enter 开始播放）" }) catch {};
        },
    }
    return rows.toOwnedSlice(a) catch &.{};
}

pub fn detailRows(a: Allocator, m: *const app_mod.Model) []Row {
    var rows: std.ArrayList(Row) = .empty;
    if (m.loading[app_mod.kindIndex(.detail)]) {
        rows.append(a, .{ .note = "加载歌单中…" }) catch {};
    }
    const dt = &m.detail;
    appendSong(a, &rows, dt.songs, 0);
    if (rows.items.len == 0) rows.append(a, .{ .note = "（无曲目）" }) catch {};
    return rows.toOwnedSlice(a) catch &.{};
}

// ── 渲染 ──

fn renderRows(a: Allocator, w: usize, h: usize, rows: []Row, cursor: u16, scroll: u16, m: *const app_mod.Model) []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    const end = @min(rows.len, @as(usize, scroll) + h);
    var i: usize = scroll;
    while (i < end) : (i += 1) {
        const row = rows[i];
        const line: []const u8 = switch (row) {
            .section => |t| widgets.sectionRow(a, w, t),
            .note => |t| widgets.noteRow(a, w, t),
            .song => |ref| widgets.songRow(a, w, .{
                .num = ref.num,
                .song = ref.list[ref.idx],
                .selected = i == cursor,
                .playing = playingFlag(m, ref.list[ref.idx]),
            }),
            .playlist => |pl| widgets.playlistRow(a, w, pl, i == cursor),
        };
        lines.append(a, line) catch {};
    }
    while (lines.items.len < h) lines.append(a, widgets.fit(a, "", w, null)) catch {};
    return zz.joinVertical(a, lines.items) catch "";
}

/// 页头：绿色竖条 + 大标题 + 暗色副标题，第三行留空
fn pageHeader(a: Allocator, title: []const u8, subtitle: []const u8) []const u8 {
    const accent = theme.inlineBold(theme.green).render(a, "▎") catch "";
    const t = theme.inlineBold(theme.text).render(a, title) catch "";
    const line1 = zz.joinHorizontal(a, &.{ accent, t }) catch "";
    const line2 = theme.note().render(a, std.fmt.allocPrint(a, " {s}", .{subtitle}) catch "") catch "";
    return zz.joinVertical(a, &.{ line1, line2, widgets.fit(a, "", 1, null) }) catch "";
}

fn pageSubtitle(a: Allocator, m: *const app_mod.Model, page: widgets.Page) []const u8 {
    return switch (page) {
        .explore => if (m.backend != .mock) "发现好音乐" else "发现好音乐 · 演示数据",
        .search => if (m.backend != .mock)
            std.fmt.allocPrint(a, "音源 {s} · s 切换音源", .{m.backend.label()}) catch ""
        else
            "演示模式：任意关键词返回同一份固定结果",
        .now => "",
        .liked => if (m.backend != .mock)
            std.fmt.allocPrint(a, "音源 {s}", .{m.backend.label()}) catch ""
        else
            std.fmt.allocPrint(a, "共 {d} 首 · 演示数据", .{m.data.liked.len}) catch "",
        .queue => std.fmt.allocPrint(a, "共 {d} 首 · Enter 跳转播放", .{m.queue.items.len}) catch "",
    };
}

/// 内容块整体左右各缩进 2 列（留白），行宽归一到 w
fn indentBlock(a: Allocator, block: []const u8, w: usize) []const u8 {
    const inner_w = w -| 4;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |l| {
        const line = widgets.fit(a, l, inner_w, null);
        out.append(a, zz.joinHorizontal(a, &.{ "  ", line, "  " }) catch line) catch {};
    }
    return zz.joinVertical(a, out.items) catch "";
}

pub fn renderPage(a: Allocator, m: *const app_mod.Model, page: widgets.Page, w: usize, h: usize) []const u8 {
    if (page == .search) return renderSearch(a, m, w, h);
    if (page == .now) return renderNow(a, m, w, h);
    const content_w = w -| 4;
    const rows_h = h -| 3;
    const rows = buildRows(a, m, page);
    const body = renderRows(a, content_w, rows_h, rows, m.cursors[@intFromEnum(page)], m.scrolls[@intFromEnum(page)], m);
    const header = pageHeader(a, page.title(), pageSubtitle(a, m, page));
    const all = zz.joinVertical(a, &.{ header, body }) catch "";
    return fitVertical(a, all, w, h);
}

/// 搜索页：页头 + 圆角搜索框（聚焦变绿）+ 结果区
fn renderSearch(a: Allocator, m: *const app_mod.Model, w: usize, h: usize) []const u8 {
    const content_w = w -| 4;
    const focused = m.focus == .input;
    const input_line = m.search_input.view(a) catch "";
    const box = theme.inputBox(focused)
        .width(@intCast(content_w -| 2))
        .paddingAll(0)
        .render(a, input_line) catch "";

    const header = pageHeader(a, "搜索", pageSubtitle(a, m, .search));
    // 头部 7 行：页头 3 + 搜索框（含边框）3 + 空行 1
    const rows_h = h -| 3 -| 7;
    const rows = buildRows(a, m, .search);
    const body = renderRows(a, content_w, rows_h, rows, m.cursors[@intFromEnum(widgets.Page.search)], m.scrolls[@intFromEnum(widgets.Page.search)], m);
    const all = zz.joinVertical(a, &.{
        header,
        zz.joinHorizontal(a, &.{ "  ", box }) catch box,
        widgets.fit(a, "", 1, null),
        indentBlock(a, body, w),
    }) catch "";
    return fitVertical(a, all, w, h);
}

pub fn renderDetail(a: Allocator, m: *const app_mod.Model, w: usize, h: usize) []const u8 {
    const rows = detailRows(a, m);
    return renderRows(a, w, h, rows, m.detail.cursor, m.detail.scroll, m);
}

/// 侧栏选中的歌单在主区展开的歌曲列表（页头 + 歌曲行，复用 detail 状态）
pub fn renderPlaylistView(a: Allocator, m: *const app_mod.Model, w: usize, h: usize) []const u8 {
    const content_w = w -| 4;
    const rows = detailRows(a, m);
    const body = renderRows(a, content_w, h -| 3, rows, m.detail.cursor, m.detail.scroll, m);
    const subtitle = std.fmt.allocPrint(a, "{s} · 共 {d} 首 · Esc 返回", .{
        m.detail.playlist.typeName(), m.detail.songs.len,
    }) catch "";
    const header = pageHeader(a, m.detail.playlist.name, subtitle);
    return fitVertical(a, zz.joinVertical(a, &.{ header, body }) catch "", w, h);
}

/// 封面占位面板：总尺寸 cover_cols×cover_rows（含圆角边框各 2）。
/// 位图封面（kitty/iterm2/sixel，Cmd.image_data）浮在面板上方；终端
/// 不支持位图协议时只有这个占位。bg 非空时内部行补齐到底色宽度。
fn coverPanel(a: Allocator, song: model.Song, cover_cols: usize, cover_rows: usize, bg: ?zz.Color, bordered: bool) []const u8 {
    const inner_w = cover_cols -| (if (bordered) @as(usize, 2) else 0);
    const g1_st = if (bg) |c| theme.boldOn(theme.green, c) else theme.inlineBold(theme.green);
    const g2_st = if (bg) |c| theme.inlineOn(theme.dim, c) else theme.note();
    const g3_st = if (bg) |c| theme.inlineOn(theme.text, c) else theme.inlineStyle(theme.text);
    const album_trunc = zz.measure.truncate(a, song.album, inner_w) catch song.album;
    const cover_body = zz.joinVertical(a, &.{
        widgets.fit(a, g1_st.render(a, "♪ ♪ ♪") catch "", inner_w, bg),
        widgets.fit(a, g2_st.render(a, "专辑") catch "", inner_w, bg),
        widgets.fit(a, g3_st.render(a, album_trunc) catch "", inner_w, bg),
    }) catch "";
    // bordered=false：播放页无框，位图直接铺满面板矩形
    if (!bordered) {
        const st0 = if (bg) |c| (zz.Style{}).bg(c) else zz.Style{};
        return st0
            .width(@intCast(inner_w))
            .height(@intCast(cover_rows))
            .valign(.middle)
            .render(a, cover_body) catch "";
    }
    var st = theme.panel();
    if (bg) |c| st = st.bg(c).borderBackground(c);
    return st
        .width(@intCast(inner_w))
        .height(@intCast(cover_rows -| 2))
        .valign(.middle)
        .render(a, cover_body) catch "";
}

/// 正在播放页（全屏播放模式，不显示侧栏）：左列大封面 + 封面下歌名行
/// （歌名白色、歌手绿色，同参考播放界面），右列歌词自动跟随居中，
/// 当前行 ▶ 绿色高亮、翻译粉色；底部右对齐一行按键提示。
/// 极窄（内容区 <72 列）改为封面在上、歌词在下的垂直堆叠。
pub const LyricGeom = struct {
    y0: usize, // 歌词区第一行（body 行坐标）
    x0: usize, // 歌词区左缘（屏幕列）
    x1: usize, // 右缘（不含）
    lyr_h: usize, // 歌词区高度（= lyricView 的 h）
};

/// 歌词区的屏幕几何——渲染（renderNow）与点击/滚轮命中必须共用，
/// 否则“看到的行”和“点到的行”对不上。公式与 renderNow 的骨架逐行同源。
pub fn lyricGeom(m: *const app_mod.Model, w: usize, h: usize) ?LyricGeom {
    if (currentSong(m) == null) return null;
    // Windows：无封面布局（renderNow 同源）——顶部标题+专辑+空行，歌词占余
    if (comptime builtin.os.tag == .windows) {
        const mx: usize = if (w >= 140) 4 else if (w >= 90) 3 else if (w >= 64) 2 else 1;
        const my: usize = if (h >= 34) 2 else if (h >= 24) 1 else 0;
        return .{ .y0 = my + 3, .x0 = mx, .x1 = w -| mx, .lyr_h = (h -| (my * 2)) -| 3 };
    }
    const mx: usize = if (w >= 140) 4 else if (w >= 90) 3 else if (w >= 64) 2 else 1;
    const my: usize = if (h >= 34) 2 else if (h >= 24) 1 else 0;
    const cw = w -| (mx * 2);
    const ch = h -| (my * 2);
    if (cw < 72 and ch >= 14) {
        // 极窄堆叠：歌词在封面+标题+专辑之下，占满内容宽
        const rows_fit: usize = @max(@min(ch / 3, 14), 5);
        const cover_cols_v: usize = @max(@min(rows_fit * 9 / 4, cw -| 4), 10);
        const cover_rows_v: usize = widgets.coverRows(cover_cols_v);
        return .{ .y0 = my + cover_rows_v + 3, .x0 = mx, .x1 = w -| mx, .lyr_h = ch -| (cover_rows_v + 3) };
    }
    // 横排：歌词在右列
    const cover_cols: usize = @max(@min(@min((ch -| 8) * 9 / 4, 75), cw * 2 / 5), 12);
    const gap: usize = std.math.clamp(cw / 32, 2, 6);
    return .{ .y0 = my, .x0 = mx + cover_cols + gap, .x1 = w -| mx, .lyr_h = ch };
}

fn renderNow(a: Allocator, m: *const app_mod.Model, w: usize, h: usize) []const u8 {
    const song = currentSong(m) orelse {
        return fitVertical(a, zz.joinVertical(a, &.{
            pageHeader(a, "正在播放", "未在播放"),
            widgets.noteRow(a, w -| 4, "（队列为空：去探索或搜索页按 Enter 播放）"),
        }) catch "", w, h);
    };

    // ── 响应式骨架：外边距随尺寸伸缩，内容对齐两边 ──
    // 大屏留白多（宽 ≥140 留 4 列、高 ≥34 留 2 行），小屏收到 1 列 0 行贴边；
    // @min/@max 结果一律显式 usize（收窄类型算术会溢出）。
    // Windows：封面组件整体移除——顶部歌名/歌手/专辑居中，歌词整块居中占余。
    if (comptime builtin.os.tag == .windows) {
        const mx: usize = if (w >= 140) 4 else if (w >= 90) 3 else if (w >= 64) 2 else 1;
        const my: usize = if (h >= 34) 2 else if (h >= 24) 1 else 0;
        const cw = w -| (mx * 2);
        const ch = h -| (my * 2);
        const title_line = zz.joinHorizontal(a, &.{
            theme.inlineBold(theme.text).render(a, song.title) catch "",
            theme.inlineStyle(theme.dim).render(a, " - ") catch "",
            theme.inlineBold(theme.green).render(a, song.artist) catch "",
        }) catch "";
        const title_fit = zz.measure.truncate(a, title_line, cw) catch title_line;
        const album_fit = zz.measure.truncate(a, song.album, cw) catch song.album;
        const title_c = zz.place.place(a, cw, 1, .center, .top, title_fit) catch title_fit;
        const album_c = zz.place.place(a, cw, 1, .center, .top, theme.note().render(a, album_fit) catch album_fit) catch album_fit;
        // 歌词区高度与 lyricGeom 的 Windows 分支同源（标题+专辑+空行 = 3 行）
        const lyric_h = ch -| 3;
        const lyrics = renderLyrics(a, m, cw, lyric_h);
        const inner = zz.joinVertical(a, &.{
            title_c,
            album_c,
            widgets.fit(a, "", 1, null),
            lyrics,
        }) catch "";
        return zz.place.place(a, w, h, .center, .middle, fitVertical(a, inner, cw, ch)) catch inner;
    }
    const mx: usize = if (w >= 140) 4 else if (w >= 90) 3 else if (w >= 64) 2 else 1;
    const my: usize = if (h >= 34) 2 else if (h >= 24) 1 else 0;
    const cw = w -| (mx * 2);
    const ch = h -| (my * 2);

    // ── 极窄：封面在上、歌词在下（并排会把歌词挤成一列省略号）──
    if (cw < 72 and ch >= 14) {
        // 正方形封面：行:列=4:9（终端行高≈2.1~2.4 倍列宽）
        const rows_fit: usize = @max(@min(ch / 3, 14), 5);
        const cover_cols_v: usize = @max(@min(rows_fit * 9 / 4, cw -| 4), 10);
        const cover_rows_v: usize = widgets.coverRows(cover_cols_v);
        const cover_v = coverPanel(a, song, cover_cols_v, cover_rows_v, null, false);
        const cover_line = zz.place.place(a, cw, cover_rows_v, .center, .top, cover_v) catch cover_v;

        const title_line = zz.joinHorizontal(a, &.{
            theme.inlineBold(theme.text).render(a, song.title) catch "",
            theme.inlineStyle(theme.dim).render(a, " - ") catch "",
            theme.inlineBold(theme.green).render(a, song.artist) catch "",
        }) catch "";
        const title_fit = zz.measure.truncate(a, title_line, cw) catch title_line;
        const album_fit = zz.measure.truncate(a, song.album, cw) catch song.album;
        const title_c = zz.place.place(a, cw, 1, .center, .top, title_fit) catch title_fit;
        const album_c = zz.place.place(a, cw, 1, .center, .top, theme.note().render(a, album_fit) catch album_fit) catch album_fit;

        // 纵向占用：封面 + 空行 + 标题 + 专辑（按键提示统一在最底状态行）
        const lyric_h = ch -| (cover_rows_v + 3);
        const lyrics_v = renderLyrics(a, m, cw, lyric_h);
        const inner = zz.joinVertical(a, &.{
            cover_line,
            widgets.fit(a, "", 1, null),
            title_c,
            album_c,
            lyrics_v,
        }) catch "";
        return zz.place.place(a, w, h, .center, .middle, fitVertical(a, inner, cw, ch)) catch inner;
    }

    // 横排：正方形封面（行:列=4:9），高度主导、宽度不超过内容区 40%
    const cover_cols: usize = @max(@min(@min((ch -| 8) * 9 / 4, 75), cw * 2 / 5), 12);
    const cover_rows: usize = widgets.coverRows(cover_cols);
    const left_w: usize = cover_cols;
    const cover = coverPanel(a, song, cover_cols, cover_rows, null, false);
    const cover_line = zz.place.place(a, left_w, cover_rows, .center, .top, cover) catch "";

    // 封面下：歌名 - 歌手（歌名白粗、歌手绿粗），再一行专辑（暗）
    const title_line = zz.joinHorizontal(a, &.{
        theme.inlineBold(theme.text).render(a, song.title) catch "",
        theme.inlineStyle(theme.dim).render(a, " - ") catch "",
        theme.inlineBold(theme.green).render(a, song.artist) catch "",
    }) catch "";
    const title_fit = zz.measure.truncate(a, title_line, left_w) catch title_line;
    const album_fit = zz.measure.truncate(a, song.album, left_w) catch song.album;

    var left_lines: std.ArrayList([]const u8) = .empty;
    left_lines.append(a, cover_line) catch {};
    left_lines.append(a, widgets.fit(a, "", 1, null)) catch {};
    left_lines.append(a, title_fit) catch {};
    left_lines.append(a, theme.note().render(a, album_fit) catch album_fit) catch {};
    const left_block = zz.joinVertical(a, left_lines.items) catch "";

    // ── 右列：歌词占剩余宽度（对齐右缘）──
    const gap: usize = std.math.clamp(cw / 32, 2, 6);
    const lyric_w = cw -| (left_w + gap);
    const lyrics = renderLyrics(a, m, lyric_w, ch);
    var gap_buf: [8]u8 = @splat(' ');
    const gap_str: []const u8 = gap_buf[0..@min(gap, gap_buf.len)];
    const row = zz.joinHorizontal(a, &.{
        zz.place.place(a, left_w, ch, .center, .top, left_block) catch left_block,
        gap_str,
        lyrics,
    }) catch "";

    const inner = fitVertical(a, row, cw, ch);

    // 整块在外框内居中 → 天然形成四周外边距
    return zz.place.place(a, w, h, .center, .middle, inner) catch inner;
}

/// 单行在 w 列内水平居中（超宽则截断）。歌词列宽随终端拉伸，
/// 行居中让留白分到两侧，宽屏下右侧不会空一大块。
fn centerLine(a: Allocator, line: []const u8, w: usize) []const u8 {
    if (zz.width(line) >= w) return widgets.fit(a, line, w, null);
    return zz.place.place(a, w, 1, .center, .top, line) catch line;
}

/// 歌词显示行（原文 + 翻译各占一行），渲染与点击命中共用。
pub const LyricRow = struct {
    line_idx: usize, // lyr.lines 下标（取时间用）
    translation: bool,
};

pub const LyricView = struct {
    rows: []LyricRow, // 展开后的显示行
    start: i64, // 本窗口第一行在 rows 里的下标（负数 = 顶部留白行数）
    cur_disp: usize, // 当前播放行在 rows 里的下标
    browse: bool, // 是否处于手动浏览（未跟随播放）
};

/// 计算歌词窗口：跟随模式当前行垂直居中；浏览模式（m.lyr_browse）按
/// 用户滚到的位置显示。
pub fn lyricView(a: Allocator, m: *const app_mod.Model, h: usize) LyricView {
    var rows: std.ArrayList(LyricRow) = .empty;
    const lyr = m.lyrics orelse return .{ .rows = &.{}, .start = 0, .cur_disp = 0, .browse = m.lyr_browse != null };
    for (lyr.lines, 0..) |line, li| {
        if (line.text.len > 0) rows.append(a, .{ .line_idx = li, .translation = false }) catch {};
        if (line.translation) |t| {
            if (t.len > 0) rows.append(a, .{ .line_idx = li, .translation = true }) catch {};
        }
    }
    var cur_disp: usize = 0;
    if (lyr.currentIndex(m.pos_ms)) |ci| {
        cur_disp = rows.items.len -| 1;
        for (rows.items, 0..) |d, di| {
            if (d.line_idx == ci and !d.translation) {
                cur_disp = di;
                break;
            }
        }
    }
    var start: i64 = 0;
    if (m.lyr_browse) |st| {
        start = @intCast(@min(st, rows.items.len -| @min(rows.items.len, h)));
    } else {
        // 当前行垂直居中；开头/结尾两侧留白也保持居中（start 可为负）
        start = @as(i64, @intCast(cur_disp)) - @as(i64, @intCast(h / 2));
    }
    return .{ .rows = rows.items, .start = start, .cur_disp = cur_disp, .browse = m.lyr_browse != null };
}

/// 某一显示行对应的歌词时间（seek 用）
pub fn lyricRowMs(m: *const app_mod.Model, view: LyricView, row: usize) ?u32 {
    if (m.lyrics == null) return null;
    const r: i64 = @intCast(row);
    if (r < view.start or r >= view.start + @as(i64, @intCast(view.rows.len))) return null;
    const d = view.rows[@intCast(r - view.start)];
    return m.lyrics.?.lines[d.line_idx].time_ms;
}

pub fn renderLyricsForDebug(a: Allocator, m: *const app_mod.Model, w: usize, h: usize) []const u8 {
    return renderLyrics(a, m, w, h);
}

fn renderLyrics(a: Allocator, m: *const app_mod.Model, w: usize, h: usize) []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    const lyr = m.lyrics orelse {
        lines.append(a, centerLine(a, widgets.noteRow(a, w, "（暂无歌词）"), w)) catch {};
        while (lines.items.len < h) lines.append(a, widgets.fit(a, "", w, null)) catch {};
        return zz.joinVertical(a, lines.items) catch "";
    };
    _ = lyr;
    const cur = if (m.lyrics) |ly| ly.currentIndex(m.pos_ms) else null;
    const view = lyricView(a, m, h);
    const display = view.rows;
    if (display.len == 0) {
        lines.append(a, centerLine(a, widgets.noteRow(a, w, "（纯音乐，请欣赏）"), w)) catch {};
        while (lines.items.len < h) lines.append(a, widgets.fit(a, "", w, null)) catch {};
        return zz.joinVertical(a, lines.items) catch "";
    }

    // 负起点 = 顶部留白（开头几句保持垂直居中）
    if (view.start < 0) {
        const blank: usize = @intCast(-view.start);
        for (0..@min(blank, h)) |_| lines.append(a, widgets.fit(a, "", w, null)) catch {};
    }
    const from: usize = @intCast(@max(view.start, 0));
    const end = @min(display.len, from + h -| @as(usize, @intCast(@max(-view.start, 0))));
    for (display[from..end], from..) |d, di| {
        const is_cur = (cur != null and d.line_idx == cur.? and di == view.cur_disp);
        const is_sel = m.lyr_sel != null and (m.lyr_sel.? == di);
        const txt0 = m.lyrics.?.lines[d.line_idx];
        const txt = zz.measure.truncate(a, if (d.translation) txt0.translation.? else txt0.text, w -| 2) catch txt0.text;
        const line_str = if (is_sel)
            theme.inlineBold(theme.text).render(a, std.fmt.allocPrint(a, "◇ {s}", .{txt}) catch "") catch ""
        else if (is_cur and !d.translation)
            theme.inlineBold(theme.green).render(a, std.fmt.allocPrint(a, "▶ {s}", .{txt}) catch "") catch ""
        else if (d.translation)
            theme.inlineStyle(theme.pink).render(a, txt) catch ""
        else
            theme.inlineStyle(theme.dim).render(a, txt) catch "";
        lines.append(a, centerLine(a, line_str, w)) catch {};
    }
    while (lines.items.len < h) lines.append(a, widgets.fit(a, "", w, null)) catch {};
    return zz.joinVertical(a, lines.items) catch "";
}

/// 把一块内容裁/补到恰好 h 行、每行 w 列
fn fitVertical(a: Allocator, content: []const u8, w: usize, h: usize) []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| {
        if (lines.items.len >= h) break;
        lines.append(a, widgets.fit(a, l, w, null)) catch {};
    }
    while (lines.items.len < h) lines.append(a, widgets.fit(a, "", w, null)) catch {};
    return zz.joinVertical(a, lines.items) catch "";
}

/// 帮助卡片内容（? 浮层）。content_w 是卡片内容区显示宽度——
/// 两列键位表按 zz.width 补位对齐（不能按字节：键位里的 ↑↓→ 和
/// 中文描述都是多字节），右侧描述吃剩余宽度，窄终端截断不折行。
pub fn helpLines(a: Allocator, content_w: usize) []const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    const L = struct { key: []const u8, desc: []const u8 };
    const left = [_]L{
        .{ .key = "1-4", .desc = "切换页签" },
        .{ .key = "Tab", .desc = "进入/离开侧栏歌单" },
        .{ .key = "↑↓ jk PgUp/PgDn", .desc = "列表移动" },
        .{ .key = "Enter", .desc = "播放 / 打开歌单专辑" },
        .{ .key = "a", .desc = "追加到队列" },
        .{ .key = "Esc", .desc = "关闭浮层 / 返回列表" },
        .{ .key = "s", .desc = "切换音源（网易/QQ/波点）" },
        .{ .key = "o", .desc = "电台模式（自动续推荐）" },
        .{ .key = "L", .desc = "登录（选音源扫码）" },
    };
    const right = [_]L{
        .{ .key = "空格", .desc = "播放 / 暂停" },
        .{ .key = "n / p", .desc = "下一首 / 上一首" },
        .{ .key = "← →", .desc = "快退 / 快进 5 秒" },
        .{ .key = "v", .desc = "播放界面" },
        .{ .key = "/", .desc = "搜索" },
        .{ .key = "?", .desc = "帮助" },
        .{ .key = "- = m", .desc = "音量 / 静音" },
        .{ .key = "r", .desc = "播放模式（循环/单曲/随机）" },
        .{ .key = "q / Ctrl+C", .desc = "退出" },
    };
    // 各列显示宽度取本列最宽项；左描述封顶防挤掉右列
    var k1w: usize = 0;
    var d1w: usize = 0;
    var k2w: usize = 0;
    for (left) |l| k1w = @max(k1w, zz.width(l.key));
    for (left) |l| d1w = @max(d1w, zz.width(l.desc));
    for (right) |l| k2w = @max(k2w, zz.width(l.key));
    d1w = @min(d1w, 26);
    const fixed = k1w + 1 + d1w + 3 + k2w + 1;
    const d2w = content_w -| fixed;
    for (left, right) |l, r| {
        const line = std.fmt.allocPrint(a, "{s} {s} │ {s} {s}", .{
            padVis(a, l.key, k1w),
            padVis(a, l.desc, d1w),
            padVis(a, r.key, k2w),
            padVis(a, truncVis(a, r.desc, d2w), d2w),
        }) catch "";
        lines.append(a, line) catch {};
    }
    lines.append(a, "") catch {};
    lines.append(a, "演示模式：数据来自 testdata/mock/*.json，播放为假进度") catch {};
    lines.append(a, "支持鼠标：点击/双击/滚轮；列表里右键弹操作菜单（喜欢/下一首/队列）") catch {};
    lines.append(a, "歌词页（v）：↑↓ 选句 · Enter 跳到该句 · 滚轮浏览（3 秒回归）") catch {};
    return lines.items;
}

/// 按显示宽度补右侧空格（超宽原样返回，调用方保证列宽 >= 实宽）
fn padVis(a: Allocator, s: []const u8, n: usize) []const u8 {
    const w = zz.width(s);
    if (w >= n) return s;
    return zz.joinHorizontal(a, &.{ s, widgets.blankSpaces(a, n - w) }) catch s;
}

/// 按显示宽度截断（超出部分以 … 结尾）
fn truncVis(a: Allocator, s: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    if (zz.width(s) <= n) return s;
    return zz.measure.truncate(a, s, n) catch s;
}
