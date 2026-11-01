const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zz = @import("zigzag");
const theme = @import("theme.zig");
const model = @import("model.zig");
const mock = @import("mock.zig");
const provider = @import("provider.zig");
const player_mod = @import("../core/player.zig");
const api_server = @import("../core/api_server.zig");
const widgets = @import("widgets.zig");
const playmode = @import("playmode.zig");
const pages = @import("pages.zig");
const lyrics_mod = @import("lyrics.zig");

// src/ui/app.zig — Model-Update-View 的 Model：页签/焦点/浮层/播放态/音源/登录。
//
// 数据：backend==.mock 走 testdata（离线演示与测试，本文件原有链路不动）；
// 真实音源（bodian/netease/qq）走 sidecar 异步取数——update() 里 provider.kick
// 派后台线程，每帧开头 drain 信箱收结果，view 永远读上一份完整快照。
// 播放：core/player.zig 派发——mpv IPC（全平台）→ Media Foundation（仅
// windows 的系统 COM 兜底）→ 都不可用降级假进度。
// 登录：L → 浮层选音源（1 波点 / 2 网易云 / 3 QQ）→ 扫码（半块二维码）→ 轮询。
// 布局（参考 qq-music-tui）：
//   页签栏 1 行 / 主内容区 / 播放栏 2 行 / 迷你歌词 0·1·3 行 / 提示行 1 行

const page_count = widgets.Page.count();
pub const Kind = provider.Kind;
pub const Backend = model.Backend;
const kind_count = @typeInfo(provider.Kind).@"enum".field_names.len;

pub fn kindIndex(k: provider.Kind) usize {
    inline for (@typeInfo(provider.Kind).@"enum".field_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, @tagName(k))) return i;
    }
    unreachable;
}

/// health 数组下标（与 provider.Health 约定一致：[波点,网易,QQ]）
fn healthIndex(b: model.Backend) usize {
    return switch (b) {
        .bodian => 0,
        .netease => 1,
        .qq => 2,
        .mock => unreachable,
    };
}

pub const LoginFlow = struct {
    backend: model.Backend,
    phase: enum { choose, qr },
    key: []const u8 = "",
    qr: ?provider.LoginQr = null,
    poll_ms: u32 = 0,
    message: ?[]const u8 = null,
};

pub const DetailState = struct {
    playlist: model.Playlist = .{},
    songs: []const model.Song = &.{},
    cursor: u16 = 0,
    scroll: u16 = 0,
};

pub const Focus = enum { list, input };

pub const Model = struct {
    // 声明哪些事件就收哪些（zigzag 用 @hasField 探测）
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
        window_size: zz.msg.WindowSize,
        tick: zz.msg.Tick,
    };

    // ── 由 main 通过 initWithModel 预置 ──
    mock_dir: []const u8 = "testdata/mock",
    backend: model.Backend = .mock,
    /// 外部歌词/状态接口端口（AM_API_PORT）。0 = 不启动（测试默认关，
    /// main.zig 传真实默认 8790）
    api_port: u16 = 0,

    // ── init 期间建立 ──
    arena_state: std.heap.ArenaAllocator = undefined,
    gpa: Allocator = undefined,
    io: std.Io = undefined,
    data: mock.Data = .{},
    search_input: zz.components.TextInput = undefined,
    queue: std.ArrayList(model.Song) = .empty,
    mb: provider.Mailbox = undefined,
    fq: provider.FetchQueue = undefined,
    player: player_mod.Player = undefined,
    /// 数据纪元：音源切换/新搜索 +1，旧 epoch 的结果到达即丢
    epoch: u64 = 1,
    /// 各 Kind 的 Outcome arena（进程内不主动释放——队列/列表引用其字符串，
    /// 释放会产生悬垂；退出时统一回收。单次会话量级 ≈ 百 KB，可接受）
    slots: [kind_count]?*std.heap.ArenaAllocator = @splat(null),
    loading: [kind_count]bool = @splat(false),
    health: provider.Health = .{},

    // ── 交互状态 ──
    page: widgets.Page = .explore,
    prev_page: widgets.Page = .explore, // v 离开播放界面时回到哪一页
    focus: Focus = .list,
    sb_sel: usize = 0, // 侧栏条目游标（0..3 页签，4 = 我的歌单）
    pl_open: bool = false, // 主区在展示歌单详情（renderPlaylistView 开关）
    open_pl: ?usize = null, // 侧栏"我的歌单"▶ 标记下标（探索页推荐歌单不在其中，不标）
    pl_picker: bool = false, // "我的歌单"选取模式（侧栏歌单行选中）
    picker_cursor: u16 = 0, // 选取游标（allPlaylists 下标）
    last_click: struct { kind: u8 = 0, row: usize = 0, ms: u64 = 0 } = .{}, // 双击检测（ctx.elapsed 毫秒）
    /// 滚轮节流：下次滚轮事件最早允许的时刻（ctx.elapsed 毫秒）。
    /// 高分辨率滚轮一格连发多个事件，100ms 内只认第一发。
    wheel_gate_ms: u64 = 0,
    cursors: [page_count]u16 = @splat(0),
    scrolls: [page_count]u16 = @splat(0),
    search_done: bool = false,
    detail: DetailState = .{},
    help_visible: bool = false,
    overlay_active: bool = false, // detail 或 help 打开时拦截列表按键
    status: ?[]const u8 = null,
    /// 当前提示已显示的毫秒数（onTick 累加，5s 后自动消失）
    status_ms: u64 = 0,
    win_w: u16 = 80,
    win_h: u16 = 24,
    login: ?LoginFlow = null,
    home_dir: []const u8 = "",

    // ── 播放态 ──
    q_index: ?u32 = null,
    playing: bool = false,
    pos_ms: u32 = 0,
    volume: u8 = 80,
    mute: bool = false,
    lyrics: ?lyrics_mod.Lyrics = null,
    /// play_url 请求对应的目标队列下标，结果到达时对得上才交给播放后端
    url_pending_q: ?u32 = null,
    /// 预取下一首（append 进 mpv 播放列表）的目标队列下标
    append_pending_q: ?u32 = null,
    /// mpv 播放列表镜像：第 i 个 entry 对应的队列下标（append-only，
    /// loadfile replace 时清空重置为 [当前歌]）
    pl_order: std.ArrayList(u32) = .empty,
    /// mpv 尚未连上时先缓存的播放链接（connect 成功的 tick 补 loadFile）
    pending_url: ?[]const u8 = null,
    pending_title: []const u8 = "",
    /// lyrics 请求对应的目标歌（backend:id|mid），切歌后晚到的旧歌词丢弃
    lyric_pending_key: []const u8 = "",
    /// 当前播放歌的封面像素（half-block 渲染；outcome arena 由 slots 持有）
    cover: ?provider.Cover = null,
    /// cover 请求对应的歌（backend:id|mid），晚到的旧封面丢弃
    cover_key: []const u8 = "",
    /// 终端是否支持 kitty/iterm2/sixel 位图封面。null = 尚未探测：
    /// init 时 ctx._terminal 还没挂上（zigzag 在 terminal 探测完能力之后
    /// 才设置它），必须等第一次 update 惰性探测
    bitmap_cover: ?bool = null,
    /// 播放后端当前实际加载的歌（songKey）。空 = 还没加载过（重启后/失败）——
    /// 这时按播放键必须走真实加载，不能只翻 playing 标志（否则假进度无声）
    loaded_key: []const u8 = "",
    cover_shown: bool = false, // 屏幕上还挂着位图封面
    cover_rect: CoverRect = .{ .row = 0, .col = 0, .cols = 0, .rows = 0, .bordered = true },
    cover_seq: u64 = 0, // 像素版本（新封面到达 +1）
    drawn_seq: u64 = 0, // 当前屏幕上画的版本

    // ── 电台模式（append-only 推荐流）──
    /// 开启后队列变推荐流：剩 3 首以内自动以当前歌为种子取下一批。
    /// 与三态播放模式正交（电台流里也能单曲循环）。
    radio_mode: bool = false,
    /// 已发出 radio 请求、结果未到（防重复 kick）
    radio_pending: bool = false,
    /// 播放模式状态机（列表循环/单曲循环/随机洗牌袋）
    pc: playmode.PlayControl = .{},
    /// 右键菜单：目标（歌曲或歌单）+ 弹出位置 + 选中项
    ctx_menu: ?CtxMenu = null,
    /// 歌词手动浏览：滚轮离开跟随位置后的绝对显示行起点；3 秒无操作回归
    lyr_browse: ?usize = null,
    lyr_idle_ms: u64 = 0,
    /// 歌词键盘选句（显示行绝对下标）：↑↓ 移动、Enter 跳进度
    lyr_sel: ?usize = null,

    /// 外部 API（loopback HTTP，core/api_server.zig）：第三方取当前播放 +
    /// 歌词。UI 线程每 tick publish 快照，HTTP 线程只读快照、永不碰 Model。
    api: api_server.ApiServer = .{},

    pub const CtxMenu = struct {
        /// 歌曲目标：字符串全部 dupe 进模型 arena——菜单可能活得比
        /// 来源列表的 outcome arena 久，不能持有裸引用
        song: ?model.Song = null,
        pl: ?model.Playlist = null,
        x: usize = 0,
        y: usize = 0,
        sel: usize = 0,
        /// 目标是否已在红心（决定第一项文案）
        liked: bool = false,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.arena_state = std.heap.ArenaAllocator.init(ctx.persistent_allocator);
        self.gpa = ctx.persistent_allocator;

        self.io = ctx.io;
        self.home_dir = ctx.home_dir;
        self.mb = provider.Mailbox.init(ctx.persistent_allocator);
        self.fq = provider.FetchQueue.init(ctx.persistent_allocator, ctx.io, &self.mb);
        self.player = player_mod.Player.init(ctx.persistent_allocator, ctx.io);
        // 注意：这里不探测位图能力——init 时 ctx._terminal 仍为 null，
        // supportsImages() 恒 false；改由 update() 惰性探测
        const a = self.arena_state.allocator();
        _ = self.gpa;

        // 外部歌词/状态接口（AM_API_PORT，0=关；起不来只提示，不影响本体）
        if (self.api_port != 0) {
            if (self.api.start(self.gpa, self.api_port)) {
                self.setStatus(std.fmt.allocPrint(a, "外部接口 127.0.0.1:{d} 已开启（/now /lyrics）", .{self.api_port}) catch null);
            } else {
                self.setStatus("外部接口启动失败（端口被占？），播放不受影响");
            }
        }

        if (self.loadBackend()) |b| self.backend = b;

        self.search_input = zz.components.TextInput.init(a);
        self.search_input.setPlaceholder("搜索歌曲 / 歌手 / 专辑…");
        self.search_input.setPrompt("⌕ ");
        self.search_input.blur();

        if (self.backend != .mock) {
            // 真实音源：数据异步拉，播放后端起不来就降级假进度
            // 播放后端懒启动：首次播放时才初始化（mpv spawn / MF COM 建会话）
            self.kickExplore();
            self.kickHealth();
            self.kickLibrary();
            return zz.Cmd(Msg).everyMs(500);
        }

        self.data = mock.load(a, ctx.io, self.mock_dir);
        // 首屏就有内容可看：每日推荐进队列，停在第一首（暂停态）
        if (self.data.fm.len > 0) {
            self.queueAddSlice(self.data.fm);
            self.q_index = 0;
            self.refreshLyrics();
        }
        if (self.data.errors.items.len > 0) {
            self.setStatus("mock 数据加载不完整，详见探索页");
        }
        return zz.Cmd(Msg).everyMs(500);
    }

    pub fn deinit(self: *Model) void {
        self.api.deinit();
        self.fq.deinit();
        self.player.deinit();
        self.pc.deinit(self.gpa);
        for (&self.slots) |maybe| {
            if (maybe) |ar| {
                ar.deinit();
                self.gpa.destroy(ar);
            }
        }
        while (self.mb.take()) |o| self.mb.free(o);
        self.arena_state.deinit();
    }

    pub fn arena(self: *Model) Allocator {
        return self.arena_state.allocator();
    }

    // ── 取数派发（真实音源） ──

    fn kickJob(self: *Model, job_in: provider.Job) void {
        var job = job_in;
        job.epoch = self.epoch;
        self.fq.kick(job);
        self.loading[kindIndex(job.kind)] = true;
    }

    fn kickExplore(self: *Model) void {
        self.kickJob(.{ .kind = .explore, .backend = self.backend });
    }

    fn kickHealth(self: *Model) void {
        self.kickJob(.{ .kind = .health, .backend = self.backend });
    }

    fn kickLibrary(self: *Model) void {
        self.kickJob(.{ .kind = .library, .backend = self.backend });
        self.kickJob(.{ .kind = .liked, .backend = self.backend });
    }

    /// 电台取一批推荐（种子 = 当前歌；无当前歌也发，各源自有无种子回落）。
    /// 结果不经 epoch 门控（电台流追加进队列，跨 epoch 依然有效）。
    fn kickRadio(self: *Model) void {
        if (self.radio_pending or self.backend == .mock) return;
        self.radio_pending = true;
        const seed: ?model.Song = if (self.q_index) |qi|
            (if (qi < self.queue.items.len) self.queue.items[qi] else null)
        else
            null;
        self.kickJob(.{
            .kind = .radio,
            .backend = self.backend,
            .id = if (seed) |s| s.id else "",
            .mid = if (seed) |s| s.song_mid else "",
        });
    }

    /// o 键：开/关电台模式。开启即取一批；关闭只停续批，队列保留。
    fn toggleRadio(self: *Model) void {
        if (self.backend == .mock) {
            self.setStatus("演示模式不支持电台（真实音源下按 o 开启）");
            return;
        }
        self.radio_mode = !self.radio_mode;
        if (self.radio_mode) {
            self.setStatus("电台模式开启：队列将自动续推荐歌曲");
            self.kickRadio();
        } else {
            self.setStatus("电台模式关闭");
        }
    }

    fn kickSearch(self: *Model, kw: []const u8) void {
        self.epoch += 1; // 新搜索作废旧搜索结果
        self.kickJob(.{ .kind = .search, .backend = self.backend, .kw = self.arena().dupe(u8, kw) catch kw });
    }

    fn kickDetail(self: *Model, pl: model.Playlist) void {
        self.epoch += 1;
        self.kickJob(.{ .kind = .detail, .backend = pl.backend, .id = self.arena().dupe(u8, pl.id) catch pl.id });
    }

    fn songKey(self: *Model, song: model.Song) []const u8 {
        const id = if (song.backend == .qq) song.song_mid else song.id;
        return std.fmt.allocPrint(self.arena(), "{s}:{s}", .{ @tagName(song.backend), id }) catch "";
    }

    fn requestLyrics(self: *Model, song: model.Song) void {
        if (self.backend == .mock) return; // mock 歌词走 refreshLyrics
        self.lyric_pending_key = self.songKey(song);
        self.kickJob(.{
            .kind = .lyrics,
            .backend = song.backend,
            .id = self.arena().dupe(u8, song.id) catch song.id,
            .mid = self.arena().dupe(u8, song.song_mid) catch song.song_mid,
        });
    }

    /// 当前歌封面（位图协议）。尺寸 = 面板矩形的实际设备像素（TIOCGWINSZ
    /// 拿系统像素 ÷ 行列数；拿不到就退 240×480 兜底），原图不放大、不多要。
    /// 同一首歌只取一次；无 cover_url 直接清空。
    fn requestCover(self: *Model, song: model.Song) void {
        if (self.bitmap_cover != true) return; // 不支持位图协议：不取不画
        if (self.backend == .mock or song.cover_url.len == 0) {
            self.cover = null;
            self.cover_key = "";
            return;
        }
        const key = self.songKey(song);
        if (std.mem.eql(u8, key, self.cover_key) and self.cover != null) return;

        // 要画的矩形：优先按播放页大封面算（在别的页切歌也够清晰），
        // 拿不到（终端太小/不在队列）再退当前页矩形。位图只画面板内框（±1 边框）。
        var t = self.coverTarget(self.arena(), true) orelse
            self.coverTarget(self.arena(), false);
        var want_w: u32 = 240; // 终端不报像素尺寸时的兜底（cell≈10x20）
        var want_h: u32 = 480;
        if (terminalCellPx()) |cp| {
            if (t == null) t = CoverRect{ .row = 0, .col = 0, .cols = 24, .rows = 11, .bordered = false };
            const r = t.?;
            want_w = @intCast((r.cols -| 2) * cp.x);
            want_h = @intCast((r.rows -| 2) * cp.y);
        }
        // sidecar 上限 640x1280；封面是方形图、cell 是 1:2，比例天然吻合
        want_w = @max(@min(want_w, 640), 32);
        want_h = @max(@min(want_h, 1280), 32);

        self.cover_key = self.arena().dupe(u8, key) catch key;
        self.cover = null;
        self.kickJob(.{
            .kind = .cover,
            .backend = song.backend,
            .url = self.arena().dupe(u8, song.cover_url) catch song.cover_url,
            .cover_w = want_w,
            .cover_h = want_h,
        });
    }

    /// 终端单元格的设备像素（x/y）。TIOCGWINSZ 的 ws_xpixel/ypixel 为 0
    /// （部分终端不上报）或 ioctl 失败时返回 null，调用方用兜底尺寸。
    fn terminalCellPx() ?struct { x: u32, y: u32 } {
        if (builtin.os.tag == .windows) return null; // Windows 控制台无像素尺寸
        var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = std.os.linux.ioctl(1, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(rc) != .SUCCESS) return null;
        if (ws.xpixel == 0 or ws.ypixel == 0 or ws.col == 0 or ws.row == 0) return null;
        return .{
            .x = @max(ws.xpixel / ws.col, 4),
            .y = @max(ws.ypixel / ws.row, 4),
        };
    }

    /// 预取下一首的播放链接并 append 进 mpv 播放列表。
    /// 洗牌袋/线性顺序由 PlayControl 决定，mpv 列表顺序 = 播放顺序，
    /// 系统媒体键（MPRIS next/prev）驱动的就是这份列表。
    /// （仅 mpv 后端：MF 无播放列表概念，曲间前进由 eof 路径驱动）
    fn syncNext(self: *Model) void {
        if (self.player.kind != .mpv or !self.player.available()) return;
        if (self.append_pending_q != null or self.url_pending_q != null) return;
        const i = self.q_index orelse return;
        const len = self.queue.items.len;
        if (len == 0) return;
        // 已 append 到队尾的就不重复（单曲队列绕回场景）
        const next = self.pc.nextIndex(self.gpa, i, len, .user) orelse return;
        if (self.pl_order.items.len > 0 and self.pl_order.items[self.pl_order.items.len - 1] == next and next != i) return;
        const song = self.queue.items[next];
        self.append_pending_q = @intCast(next);
        self.kickJob(.{
            .kind = .play_url,
            .backend = song.backend,
            .id = self.arena().dupe(u8, song.id) catch song.id,
            .mid = self.arena().dupe(u8, song.song_mid) catch song.song_mid,
            .append = true,
        });
    }

    /// 消费 playlist-pos 属性事件：mpv 自己动了（媒体键/自动前进/idle）
    fn onMpvPosChange(self: *Model, pos: i64) void {
        if (pos < 0) {
            // 列表尾转 idle： eof 兜底（绕回/电台续批）
            self.nextSong(.eof);
            return;
        }
        if (pos >= @as(i64, @intCast(self.pl_order.items.len))) return;
        const idx = self.pl_order.items[@intCast(pos)];
        if (self.q_index == idx) return; // 自己 loadFile 触发的回声
        if (idx >= self.queue.items.len) return;
        self.q_index = idx;
        self.pos_ms = 0;
        self.playing = true;
        self.lyrFollow();
        const song = self.queue.items[idx];
        self.loaded_key = self.songKey(song);
        self.requestLyrics(song);
        self.requestCover(song);
        self.setStatus("已切歌（外部控制）");
        self.syncNext();
    }

    fn requestPlayback(self: *Model, song: model.Song) void {
        self.url_pending_q = self.q_index;
        self.pos_ms = 0;
        self.pending_url = null;
        if (!self.player.started()) {
            if (!self.player.startAsync()) {
                if (comptime builtin.os.tag == .windows) {
                    self.setStatus("播放后端初始化失败（COM 不可用？），播放为假进度");
                } else {
                    self.setStatus("未找到播放后端，播放为假进度（安装 mpv 后重启）");
                }
                return;
            }
        }
        // 链接照常去取：后端未就绪时结果会先缓存到 pending_url，
        // connect 成功的 tick 再补 loadFile（否则首播永远发不出请求）
        if (self.player.available()) self.player.setPause(true); // 取新链接期间先暂停旧曲目
        self.kickJob(.{
            .kind = .play_url,
            .backend = song.backend,
            .id = self.arena().dupe(u8, song.id) catch song.id,
            .mid = self.arena().dupe(u8, song.song_mid) catch song.song_mid,
        });
    }

    // ── 信箱消费 ──

    /// 槽位收编：回收旧槽 arena，保留新 arena，Outcome 壳还给 gpa
    fn adoptSlot(self: *Model, idx: usize, o: *provider.Outcome) void {
        if (self.slots[idx]) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.slots[idx] = o.arena;
        self.gpa.destroy(o);
    }

    fn drainFetches(self: *Model) void {
        while (self.mb.take()) |o| self.consume(o);
    }

    fn consume(self: *Model, o: *provider.Outcome) void {
        const kind: provider.Kind = switch (o.result) {
            .ok => |ok| std.meta.activeTag(ok),
            .err => |e| e.kind,
        };
        self.loading[kindIndex(kind)] = false;

        // 过期结果（音源已切走/新搜索已发出）直接丢弃
        const epoch_gated = switch (kind) {
            .search, .explore, .detail, .health, .library, .liked => true,
            else => false,
        };
        if (epoch_gated and o.epoch != self.epoch) {
            self.mb.free(o);
            return;
        }

        const a = self.arena();
        switch (o.result) {
            .ok => |ok| switch (ok) {
                .search => |p| {
                    self.adoptSlot(kindIndex(.search), o);
                    self.data.search = p.songs;
                    self.setStatus(std.fmt.allocPrint(a, "搜索完成 · 音源 {s} · {d} 条", .{ self.backend.label(), p.songs.len }) catch null);
                },
                .explore => |ex| {
                    self.adoptSlot(kindIndex(.explore), o);
                    self.data.fm = ex.fm;
                    self.data.recommend = ex.recommend;
                    self.data.errors.clearRetainingCapacity();
                    // 首次数据到达且队列还是空的：每日推荐进队列（暂停态）
                    if (self.q_index == null and ex.fm.len > 0) {
                        self.queueAddSlice(ex.fm);
                        self.q_index = 0;
                        self.requestLyrics(self.queue.items[0]);
                        self.requestCover(self.queue.items[0]);
                    }
                },
                .detail => |dt| {
                    self.adoptSlot(kindIndex(.detail), o);
                    self.data.detail_playlist = dt.playlist;
                    self.data.detail_songs = dt.songs;
                    self.detail = .{
                        .playlist = dt.playlist,
                        .songs = dt.songs,
                        .cursor = 0,
                        .scroll = 0,
                    };
                },
                .lyrics => |ly| {
                    // 只认当前歌的歌词（切歌后晚到的旧歌词丢弃）
                    const i = self.q_index orelse {
                        self.mb.free(o);
                        return;
                    };
                    if (i >= self.queue.items.len) {
                        self.mb.free(o);
                        return;
                    }
                    if (!std.mem.eql(u8, self.lyric_pending_key, self.songKey(self.queue.items[i]))) {
                        self.mb.free(o);
                        return;
                    }
                    self.adoptSlot(kindIndex(.lyrics), o);
                    self.lyrics = ly;
                },
                .cover => |cv| {
                    // 只认当前歌的封面（切歌后晚到的旧封面丢弃）
                    const i = self.q_index orelse {
                        self.mb.free(o);
                        return;
                    };
                    if (i >= self.queue.items.len or
                        !std.mem.eql(u8, self.cover_key, self.songKey(self.queue.items[i])))
                    {
                        self.mb.free(o);
                        return;
                    }
                    self.adoptSlot(kindIndex(.cover), o);
                    self.cover = cv;
                    self.cover_seq += 1; // 换了像素，触发重画
                },
                .play_url => |pu| {
                    defer self.mb.free(o);
                    if (o.flag) {
                        // 预取下一首：append 进 mpv 播放列表
                        // （appendFile 对 MF 恒 false，pl_order 不动）
                        const qi = self.append_pending_q orelse return;
                        self.append_pending_q = null;
                        if (qi >= self.queue.items.len) return;
                        if (!self.player.started() or !self.player.available()) return;
                        const song2 = self.queue.items[qi];
                        const title2 = std.fmt.allocPrint(a, "{s} - {s}", .{ song2.title, song2.artist }) catch song2.title;
                        if (self.player.appendFile(pu.url, title2)) {
                            self.pl_order.append(self.arena(), qi) catch {};
                        }
                        return;
                    }
                    const qi = self.url_pending_q orelse return;
                    self.url_pending_q = null;
                    if (qi != (self.q_index orelse return)) return; // 已切歌
                    if (!self.player.started()) return; // 假进度（无播放后端）
                    const song = self.queue.items[qi];
                    const title = std.fmt.allocPrint(a, "{s} - {s}", .{ song.title, song.artist }) catch song.title;
                    if (!self.player.available()) {
                        // 后端还在连接：缓存到 connect 成功的 tick 再加载
                        self.pending_url = a.dupe(u8, pu.url) catch null;
                        self.pending_title = title;
                        return;
                    }
                    if (self.player.loadFile(pu.url, title)) {
                        self.loaded_key = self.songKey(song);
                        // SMTC 全量元数据（loadFile 里的 setTrack 是 " - " 启发式
                        // 拆分；这里用显式字段覆盖并补专辑/封面）
                        self.player.setSmtcMeta(song.title, song.artist, song.album, song.cover_url);
                        self.player.setVolume(self.volume);
                        self.player.setPause(!self.playing);
                        if (pu.preview_start_ms) |s| self.pos_ms = s;
                        // replace 清空了 mpv 播放列表：镜像重置为 [当前歌]，
                        // 单曲循环同步 mpv，再预取下一首 append
                        self.pl_order.clearRetainingCapacity();
                        self.pl_order.append(self.arena(), @intCast(qi)) catch {};
                        self.player.setLoopFile(self.pc.mode == .one);
                        self.syncNext();
                    } else {
                        self.setStatus("播放后端加载链接失败");
                    }
                },
                .health => |h| {
                    self.adoptSlot(kindIndex(.health), o);
                    self.health = h;
                },
                .liked => |songs| {
                    self.adoptSlot(kindIndex(.liked), o);
                    self.data.liked = songs;
                    return;
                },
                .like => |on| {
                    self.mb.free(o);
                    self.setStatus(if (on) "已添加到喜欢" else "已取消喜欢");
                    // 红心列表有上游缓存延迟，立即刷新可能还看不到，但 UI 侧先拉
                    self.kickJob(.{ .kind = .liked, .backend = self.backend });
                    return;
                },
                .radio => |songs| {
                    self.radio_pending = false;
                    defer self.mb.free(o);
                    // 去重后追加进队列（推荐流可能重复返回已在队列的歌）。
                    // 字符串经 queueSong 常驻化，outcome arena 用完即还。
                    const a2 = self.arena();
                    var fresh: std.ArrayList(model.Song) = .empty;
                    for (songs) |s| {
                        const key = self.songKey(s);
                        var dup = false;
                        for (self.queue.items) |q| {
                            if (std.mem.eql(u8, self.songKey(q), key)) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) fresh.append(a2, s) catch {};
                    }
                    if (fresh.items.len == 0) {
                        if (self.radio_mode) self.setStatus("电台暂时没有新歌，稍后自动重试");
                        return;
                    }
                    const was_empty = self.q_index == null;
                    self.queueAddSlice(fresh.items);
                    if (self.radio_mode) {
                        self.setStatus(std.fmt.allocPrint(a2, "电台 +{d} 首 · 队列共 {d}", .{ fresh.items.len, self.queue.items.len }) catch null);
                    }
                    // 电台拉起了第一首歌：直接开播
                    if (was_empty) {
                        self.q_index = 0;
                        self.playing = true;
                        const song = self.queue.items[0];
                        self.requestPlayback(song);
                        self.requestLyrics(song);
                        self.requestCover(song);
                    }
                },
                .library => |lib| {
                    self.adoptSlot(kindIndex(.library), o);
                    self.data.owned = lib.owned;
                    self.data.collected_playlists = lib.collected_playlists;
                    self.data.collected_albums = lib.collected_albums;
                },
                .login_qr => |qr| {
                    self.adoptSlot(kindIndex(.login_qr), o);
                    if (self.login) |*lf| {
                        lf.qr = qr;
                        lf.key = qr.key;
                        lf.phase = .qr;
                        lf.poll_ms = 0;
                    }
                },
                .login_check => |ck| {
                    self.adoptSlot(kindIndex(.login_check), o);
                    const lf = &(self.login orelse return);
                    switch (ck.state) {
                        .waiting => {},
                        .scanned => lf.message = "已扫码，请在手机上确认",
                        .expired => {
                            lf.phase = .choose;
                            lf.message = "二维码已过期，请重新选择音源获取";
                            lf.key = "";
                            lf.qr = null;
                        },
                        .confirmed => {
                            const backend = lf.backend;
                            self.login = null;
                            self.setStatus(if (ck.nickname.len > 0)
                                std.fmt.allocPrint(a, "已登录 {s} · {s}", .{ backend.label(), ck.nickname }) catch "登录成功"
                            else
                                std.fmt.allocPrint(a, "已登录 {s}", .{backend.label()}) catch "登录成功");
                            self.kickHealth();
                            if (backend == self.backend) {
                                self.kickExplore();
                                self.kickLibrary();
                            }
                        },
                    }
                },
            },
            .err => |e| {
                const label = switch (kind) {
                    .search => "搜索",
                    .explore => "探索页",
                    .detail => "歌单",
                    .lyrics => "歌词",
                    .play_url => "播放链接",
                    .health => "状态",
                    .library => "我的歌单",
                    .login_qr, .login_check => "登录",
                    .cover => "封面",
                    .liked => "我的喜欢",
                    .radio => "电台",
                    .like => "喜欢",
                };
                if (kind == .radio) {
                    // 电台失败：解除 pending 并整体关闭，避免每次续批都撞同一个错
                    self.radio_pending = false;
                    self.radio_mode = false;
                }
                if (self.login) |*lf| switch (kind) {
                    .login_qr => {
                        lf.phase = .choose;
                        lf.message = std.fmt.allocPrint(a, "获取二维码失败：{s}", .{e.message}) catch null;
                    },
                    .login_check => {
                        lf.message = std.fmt.allocPrint(a, "轮询失败：{s}", .{e.message}) catch null;
                    },
                    else => {},
                };
                self.setStatus(std.fmt.allocPrint(a, "{s}失败：{s}", .{ label, e.message }) catch "获取失败");
                self.mb.free(o);
            },
        }
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        // 位图能力惰性探测：update 时 terminal 已初始化完（init 时还是 null）。
        // Windows 目标整体移除封面组件——Windows 终端不支持位图协议，探测
        // 也省了（连带不取封面，省流量；播放页走无封面布局，见 pages.renderNow）
        if (self.bitmap_cover == null) {
            self.bitmap_cover = if (comptime builtin.os.tag == .windows) false else ctx.supportsImages();
            // 探测落地即刻补取当前歌封面——否则要等下一次切歌才会有
            if (self.bitmap_cover == true) {
                if (self.q_index) |qi| {
                    if (qi < self.queue.items.len and self.cover == null and self.cover_key.len == 0) {
                        self.requestCover(self.queue.items[qi]);
                    }
                }
            }
        }
        self.win_w = ctx.width;
        self.win_h = ctx.height;
        self.drainFetches();
        switch (msg) {
            .window_size => {
                // 尺寸变了：重测字格比（像素尺寸可能变），旧封面按新矩形
                // 拉伸会糊/浪费，清 key 重取
                widgets.probeCellRatio();
                self.cover_key = "";
                if (self.q_index) |qi| {
                    if (qi < self.queue.items.len) self.requestCover(self.queue.items[qi]);
                }
            },
            .tick => |t| self.onTick(t),
            .key => |k| {
                if (self.onKey(k, ctx.allocator)) |cmd| return cmd;
            },
            .mouse => |e| self.onMouse(e, ctx),
        }
        return self.coverCmd(ctx.allocator);
    }

    /// 位图封面：播放页画大封面（面板内框），其它页画侧栏底部小封面。
    /// 位置/尺寸或像素变化时 delete+重画；浮层打开时删除。
    /// 几何必须与 pages.renderNow / widgets.sidebar 保持逐行一致。
    const CoverRect = struct { row: usize, col: usize, cols: usize, rows: usize, bordered: bool };

    fn coverCmd(self: *Model, a: Allocator) zz.Cmd(Msg) {
        if (self.bitmap_cover != true) return .none;
        const target = self.coverTarget(a, false);
        if (target) |t| {
            const same = self.cover_shown and self.cover_rect.row == t.row and
                self.cover_rect.col == t.col and self.cover_rect.cols == t.cols and
                self.cover_rect.rows == t.rows and self.cover_seq == self.drawn_seq;
            if (same) return .none;
            self.cover_shown = true;
            self.cover_rect = t;
            self.drawn_seq = self.cover_seq;
            const cv = self.cover.?;
            const draw = zz.Cmd(Msg){ .image_data = .{
                .data = cv.pixels,
                .format = .rgb,
                .pixel_width = cv.w,
                .pixel_height = cv.h,
                // 有框画面板内框（+1 边框）；无框铺满整个矩形
                .width_cells = @intCast(if (t.bordered) t.cols -| 2 else t.cols),
                .height_cells = @intCast(if (t.bordered) t.rows -| 2 else t.rows),
                .placement = .top_left,
                .row = @intCast(t.row + @intFromBool(t.bordered)),
                .col = @intCast(t.col + @intFromBool(t.bordered)),
                .image_id = 1,
                .move_cursor = false,
                .z_index = 1, // 浮在占位面板上方
                .protocol = .auto,
            } };
            // 旧位置先删（kitty placement 持久，不移除会叠在旧处）
            const del = zz.Cmd(Msg){ .delete_image = .all };
            const cmds = a.alloc(zz.Cmd(Msg), 2) catch return draw;
            cmds[0] = del;
            cmds[1] = draw;
            return zz.command.batch(Msg, cmds);
        }
        if (self.cover_shown) {
            self.cover_shown = false;
            return .{ .delete_image = .all };
        }
        return .none;
    }

    /// 当前应显示封面的屏幕矩形（面板含边框），无则 null。
    /// force_now=true 时按播放页大封面的几何算（requestCover 取高清像素用）。
    fn coverTarget(self: *Model, a: Allocator, force_now: bool) ?CoverRect {
        // force_now（requestCover 量尺寸用）不看 cover 状态/浮层——只是要个几何
        if (!force_now) {
            if (self.login != null or self.help_visible or self.overlay_active) return null;
            if (self.cover == null) return null;
        }
        const i = self.q_index orelse return null;
        if (i >= self.queue.items.len) return null;
        const h: usize = self.bodyHeight();

        if (self.page == .now or force_now) {
            // 与 pages.renderNow 一致：外边距 mx/my + 整块居中
            const w: usize = self.win_w;
            const mx: usize = if (w >= 140) 4 else if (w >= 90) 3 else if (w >= 64) 2 else 1;
            const my: usize = if (h >= 34) 2 else if (h >= 24) 1 else 0;
            const cw = w -| (mx * 2);
            const ch = h -| (my * 2);
            if (cw < 72 and ch >= 14) {
                const rows_fit: usize = @max(@min(ch / 3, 14), 5);
                const cols: usize = @max(@min(rows_fit * 9 / 4, cw -| 4), 10);
                const rows: usize = widgets.coverRows(cols);
                return .{ .row = 1 + my, .col = mx + (cw -| cols) / 2, .cols = cols, .rows = rows, .bordered = false };
            }
            const cols: usize = @max(@min(@min((ch -| 8) * 9 / 4, 75), cw * 2 / 5), 12);
            const rows: usize = widgets.coverRows(cols);
            return .{ .row = 1 + my, .col = mx, .cols = cols, .rows = rows, .bordered = false };
        }

        // 其它页：侧栏底部小封面（widgets.sidebar 底部面板的几何）
        const sb_w: usize = if (self.win_w >= 110) 22 else if (self.win_w >= 64) 16 else 13;
        const nav_w = sb_w -| 1;
        const cols: usize = @min(nav_w -| 2, 16);
        const rows: usize = widgets.coverRows(cols);
        // 侧栏行数：4 页签 + 我的歌单 1 + n_show 歌单行；空间不够面板会被裁掉
        const n_show = @min(self.allPlaylists(a).len, h -| widgets.SB_PL_START);
        const lines: usize = widgets.Page.tabs.len + (if (h > widgets.SB_MYPL) @as(usize, 1) else 0) + n_show;
        if (h <= lines + rows + 1) return null;
        // 侧栏填充循环停在 len+rows+1==h（内容共 h-1 行，底行留空），
        // 面板顶行下标 = h-1-rows，屏幕行 = 顶栏1 + h-1-rows
        return .{
            .row = h - rows,
            .col = (nav_w -| cols) / 2,
            .cols = cols,
            .rows = rows,
            .bordered = true,
        };
    }

    /// 侧栏"我的歌单"列表：我创建 + 收藏的歌单 + 收藏的专辑
    fn allPlaylists(self: *const Model, a: Allocator) []const model.Playlist {
        var out: std.ArrayList(model.Playlist) = .empty;
        out.appendSlice(a, self.data.owned) catch {};
        out.appendSlice(a, self.data.collected_playlists) catch {};
        out.appendSlice(a, self.data.collected_albums) catch {};
        return out.items;
    }

    /// 进入"我的歌单"导航模式：直接展开当前歌单（没有就开第一个）
    fn openPicker(self: *Model) void {
        self.pl_picker = true;
        self.focus = .list;
    }

    /// "我的歌单"导航：切到第 delta 个歌单并直接展开（回绕），侧栏 ▎ 标记
    fn plCycle(self: *Model, a: Allocator, delta: usize) void {
        const pls = self.allPlaylists(a);
        const n = @min(pls.len, self.bodyHeight() -| widgets.SB_PL_START);
        if (n == 0) return;
        self.picker_cursor = @intCast((@as(usize, self.picker_cursor) + delta) % n);
        self.openDetail(pls[self.picker_cursor], a);
    }

    /// 歌曲进队前字符串常驻化：队列跨源保留，而 Song 的字符串可能住在
    /// outcome 的 arena 里（槽位被新结果替换时整体释放 → 悬垂指针）
    fn queueSong(self: *Model, song: model.Song) model.Song {
        // 队列内容要变：洗牌袋按 generation 检测重建（所有入队都过这里）
        self.pc.bumpQueue();
        const a = self.arena();
        var out = song;
        out.id = a.dupe(u8, song.id) catch song.id;
        out.title = a.dupe(u8, song.title) catch song.title;
        out.artist = a.dupe(u8, song.artist) catch song.artist;
        out.album = a.dupe(u8, song.album) catch song.album;
        out.song_mid = a.dupe(u8, song.song_mid) catch song.song_mid;
        out.media_mid = a.dupe(u8, song.media_mid) catch song.media_mid;
        out.cover_url = a.dupe(u8, song.cover_url) catch song.cover_url;
        return out;
    }

    fn queueAddSlice(self: *Model, list: []const model.Song) void {
        const a = self.arena();
        for (list) |song| self.queue.append(a, self.queueSong(song)) catch {};
    }

    /// 设置顶部提示并重置 5s 计时（null = 清除）
    fn setStatus(self: *Model, msg: ?[]const u8) void {
        self.status = msg;
        self.status_ms = 0;
    }

    fn toggleNow(self: *Model) void {
        if (self.page == .now) {
            self.page = self.prev_page;
        } else {
            self.prev_page = self.page;
            self.page = .now;
            self.focus = .list;
        }
    }

    fn closePlaylist(self: *Model) void {
        self.open_pl = null;
        self.pl_open = false;
        self.detail = .{};
        self.focus = .list;
    }

    /// Tab 循环导航：切到侧栏下一项（页签→我的歌单→回绕）并直接生效，
    /// 不需要再按 Enter
    fn tabNext(self: *Model) void {
        // Tab 逐项循环：页签 → 我的歌单（入口态，Enter 进入）→ 回绕
        const n = widgets.Page.tabs.len + 1;
        if (self.open_pl == null and !self.pl_picker) {
            // 从当前页对应的页签位起算（Page 枚举含 now，下标≠页签位）
            self.sb_sel = 0;
            for (widgets.Page.tabs, 0..) |p, i| {
                if (p == self.page) {
                    self.sb_sel = i;
                    break;
                }
            }
        }
        const next = (self.sb_sel + 1) % n;
        self.sb_sel = next;
        self.focus = .list;
        if (next < widgets.Page.tabs.len) {
            self.closePlaylist();
            self.pl_picker = false;
            self.page = widgets.Page.tabs[next];
        } else {
            self.openPicker();
        }
    }

    /// 把当前播放态整包发布进外部 API 快照（core/api_server.zig）。
    /// 每 tick 调一次（500ms）：pos/playing/歌词晚到都靠它收敛到最新，
    /// 不用散落各处挂钩子。歌的身份（backend:id|mid）变了 seq 自动 +1。
    fn apiPublish(self: *Model) void {
        if (self.api.thread == null) return;
        const i = self.q_index orelse {
            self.api.snap.publish(.stopped, 0, null);
            return;
        };
        if (i >= self.queue.items.len or self.queue.items.len == 0) {
            self.api.snap.publish(.stopped, 0, null);
            return;
        }
        const song = self.queue.items[i];
        var lins_buf: []api_server.LyricIn = &.{};
        if (self.lyrics) |ly| {
            if (self.gpa.alloc(api_server.LyricIn, ly.lines.len)) |buf| {
                for (ly.lines, 0..) |l, j| {
                    buf[j] = .{ .time_ms = l.time_ms, .text = l.text, .tr = l.translation };
                }
                lins_buf = buf;
            } else |_| {}
        }
        defer if (lins_buf.len > 0) self.gpa.free(lins_buf); // publish 内部已 dupe
        self.api.snap.publish(
            if (self.playing) .playing else .paused,
            self.pos_ms,
            .{
                .backend = @tagName(song.backend),
                .id = if (song.backend == .qq) song.song_mid else song.id,
                .title = song.title,
                .artist = song.artist,
                .album = song.album,
                .duration_s = song.duration_s,
                .lyrics = lins_buf,
            },
        );
    }

    fn onTick(self: *Model, t: zz.msg.Tick) void {
        // 外部 API 快照：tick 开头发布（用上一帧末的 pos/歌词，最多滞后一拍）
        self.apiPublish();
        // 顶部提示 5s 自动消失
        if (self.status != null) {
            self.status_ms += @min(t.delta / std.time.ns_per_ms, std.math.maxInt(u64) - self.status_ms);
            if (self.status_ms >= 5000) self.status = null;
        }

        // 歌词手动浏览：3 秒无操作回归跟随
        if (self.lyr_browse != null) {
            self.lyr_idle_ms += @min(t.delta / std.time.ns_per_ms, std.math.maxInt(u64) - self.lyr_idle_ms);
            if (self.lyr_idle_ms >= 3000) {
                self.lyr_browse = null;
                self.lyr_sel = null;
                self.lyr_idle_ms = 0;
            }
        }

        // 播放后端事件：无条件消费（放在 playing 守卫之前——暂停时
        // “恢复播放”事件也必须能到达，否则按了播放键永远救不回来）。
        // MF 后端在这里泵打开结果与事件队列 + SMTC（媒体键/时间线）。
        if (self.player.started() and self.player.available()) {
            var ev_pos: ?i64 = null;
            var ev_pause: ?bool = null;
            self.player.drain(&ev_pos, &ev_pause);
            if (ev_pause) |p| self.playing = !p; // 系统媒体键：mpv 是事实源
            if (ev_pos) |pos| self.onMpvPosChange(pos);
            // SMTC 媒体键（windows）：与本地按键同一条动作路径
            if (self.player.takeMediaButton()) |b| {
                switch (b) {
                    .play_pause => self.togglePlay(),
                    .next => self.nextSong(.user),
                    .prev => self.prevSong(),
                }
            }
        }

        // 登录二维码轮询（1.5s）
        if (self.login) |*lf| {
            if (lf.phase == .qr and lf.key.len > 0) {
                lf.poll_ms +|= @intCast(@min(t.delta / std.time.ns_per_ms, std.math.maxInt(u32)));
                if (lf.poll_ms >= 1500) {
                    lf.poll_ms = 0;
                    self.kickJob(.{ .kind = .login_check, .backend = lf.backend, .key = lf.key });
                }
            }
        }

        // 电台续批：剩余 ≤3 首时以当前歌为种子取下一批（append-only，不打断播放）
        if (self.radio_mode and !self.radio_pending) {
            const remaining: usize = if (self.q_index) |qi|
                self.queue.items.len -| (qi + 1)
            else
                0;
            if (remaining < 3) self.kickRadio();
        }

        // 播放后端连接：每 tick 至多一次尝试（编译期平台分流：windows MF /
        // posix mpv，无运行时降级链，见 core/player.zig）
        if (self.player.started() and !self.player.available()) {
            if (self.player.tickConnect()) {
                // 首播竞态补课：链接先到、连接后到，现在补加载
                if (self.pending_url) |u| {
                    const pu = u;
                    const title = self.pending_title;
                    self.pending_url = null;
                    if (self.player.loadFile(pu, title)) {
                        if (self.q_index) |qi| {
                            if (qi < self.queue.items.len) {
                                self.loaded_key = self.songKey(self.queue.items[qi]);
                                const song3 = self.queue.items[qi];
                                // 同上：显式字段覆盖 + 专辑/封面
                                self.player.setSmtcMeta(song3.title, song3.artist, song3.album, song3.cover_url);
                            }
                        }
                        self.player.setVolume(self.volume);
                        self.player.setPause(!self.playing);
                        self.pl_order.clearRetainingCapacity();
                        if (self.q_index) |qi| self.pl_order.append(self.arena(), qi) catch {};
                        self.syncNext();
                        // 播放真启动了：清掉残留的后端提示
                        const s = self.status orelse "";
                        if (std.mem.indexOf(u8, s, "后端") != null) self.status = null;
                    } else {
                        self.setStatus("播放后端加载链接失败");
                    }
                }
            } else if (self.player.gaveUp()) {
                // 重试用尽才真正降级；未用尽就继续等，不要提前报不可用
                self.player.reset();
                if (comptime builtin.os.tag == .windows) {
                    self.setStatus("播放后端初始化失败（COM 不可用？），播放为假进度");
                } else {
                    self.setStatus("未找到可用播放后端，播放为假进度（安装 mpv 后重启）");
                }
            }
        }

        const i = self.q_index orelse return;
        if (!self.playing or i >= self.queue.items.len) return;

        // 播放后端在管进度：轮询位置显示。mpv 的 eof 不在这里切歌：有下一首
        // 时 mpv 自动前进（事件回环处理）；MF 的 eof 在这里前进（无播放列表）
        if (self.player.started() and self.player.available() and !self.loading[kindIndex(.play_url)]) {
            if (self.player.status()) |st| {
                self.pos_ms = @intFromFloat(@min(@max(st.position_s * 1000, 0), std.math.maxInt(u32)));
                // MF 后端：eof 由 app 驱动前进（autoAdvances()=false）；
                // mpv 后端 autoAdvances()=true，走 playlist-pos 事件回环
                if (st.eof and !self.player.autoAdvances()) {
                    self.nextSong(.eof);
                    return;
                }
                return;
            }
            // mpv 掉线（传输断开；MF 的 status 永不为 null，天然不进这）：
            // 重置连接，tickConnect 自动重连；当前曲重新取链接
            self.player.dropConnection();
            self.setStatus("mpv 连接断开，重连中…");
            self.requestPlayback(self.queue.items[i]);
        }

        // 假进度（mock 模式 / mpv 不可用 / 播放链接未到）
        const song = self.queue.items[i];
        const dur_ms = song.duration_s * 1000;
        // t.delta 是纳秒（定时器间隔），pos_ms 是毫秒
        const delta_ms: u64 = t.delta / std.time.ns_per_ms;
        self.pos_ms +|= @intCast(@min(delta_ms, std.math.maxInt(u32)));
        if (dur_ms > 0 and self.pos_ms >= dur_ms) {
            // 播完自动切歌（走播放模式：单曲循环回自己，随机走洗牌袋）
            const next = self.pc.nextIndex(self.gpa, i, self.queue.items.len, .eof) orelse i;
            self.q_index = @intCast(next);
            self.pos_ms = 0;
            self.refreshLyrics();
        }
    }

    /// 返回 .quit 时由 update 透传给运行时
    fn onKey(self: *Model, k0: zz.KeyEvent, a: Allocator) ?zz.Cmd(Msg) {
        // kitty 键盘协议把 Shift 组合报成“基础键码 + shift 修饰位”
        // （? 是 shift+/，G 是 shift+g），先归一成最终字符再分发，
        // 否则 ? 会命中跳搜索的 / 分支
        var k = k0;
        if (k.modifiers.shift) switch (k.key) {
            .char => |c| k.key = .{ .char = if (c == '/')
                '?'
            else if (c >= 'a' and c <= 'z')
                c - 'a' + 'A'
            else
                c },
            else => {},
        };

        // 右键菜单独占按键：↑↓ 移动、Enter 执行、Esc/任意左键关闭
        if (self.ctx_menu != null) {
            switch (k.key) {
                .up => {
                    if (self.ctx_menu) |*m| {
                        m.sel = (m.sel + self.ctxActionCount() -| 1) % @max(self.ctxActionCount(), 1);
                    }
                    return null;
                },
                .down => {
                    if (self.ctx_menu) |*m| {
                        m.sel = (m.sel + 1) % @max(self.ctxActionCount(), 1);
                    }
                    return null;
                },
                .enter => {
                    self.ctxActivate(a);
                    return null;
                },
                .escape => {
                    self.ctx_menu = null;
                    return null;
                },
                else => {
                    self.ctx_menu = null; // 其他按键关闭菜单并照常处理
                },
            }
        }

        // 登录浮层独占按键
        if (self.login != null) return self.onLoginKey(k);

        // 浮层打开时独占按键
        if (self.help_visible) {
            switch (k.key) {
                .escape, .enter, .space => {},
                .char => |c| switch (c) {
                    '?', 'q', 'Q' => {},
                    else => return null,
                },
                else => return null,
            }
            self.help_visible = false;
            self.overlay_active = false;
            return null;
        }
        if (self.overlay_active) {
            self.onDetailKey(k, a);
            return null;
        }

        // 搜索输入框聚焦时独占
        if (self.page == .search and self.focus == .input) {
            switch (k.key) {
                .escape => {
                    self.search_input.blur();
                    self.focus = .list;
                },
                .enter => {
                    self.onSearchSubmit(a);
                },
                else => self.search_input.handleKey(k),
            }
            return null;
        }

        // 侧栏打开的歌单视图：↑↓/Enter/a 操作歌曲列表，Esc 返回
        if (self.pl_open) {
            const rows = pages.detailRows(a, self);
            switch (k.key) {
                .escape => self.closePlaylist(),
                .up => self.plMove(rows, -1),
                .down => self.plMove(rows, 1),
                .page_up => self.plMove(rows, -@as(i32, @intCast(self.bodyHeight()))),
                .page_down => self.plMove(rows, @intCast(self.bodyHeight())),
                .enter => self.plActivate(a),
                .tab => {
                    if (self.pl_picker) self.plCycle(a, 1) else self.tabNext();
                },
                .char => |c| switch (c) {
                    'k' => self.plMove(rows, -1),
                    'j' => self.plMove(rows, 1),
                    'q', 'Q' => return .quit,
                    'a' => {
                        if (self.detail.cursor < rows.len) switch (rows[self.detail.cursor]) {
                            .song => |ref| {
                                self.queue.append(self.arena(), self.queueSong(ref.list[ref.idx])) catch {};
                                self.setStatus("已加入队列");
                            },
                            else => {},
                        };
                    },
                    'v', 'V' => self.toggleNow(),
                    '1', '2', '3', '4' => {
                        self.closePlaylist();
                        self.pl_picker = false;
                        self.page = widgets.Page.tabs[c - '1'];
                    },
                    '5' => {
                        self.pl_picker = false;
                        self.closePlaylist();
                    },
                    '/' => {
                        self.closePlaylist();
                        self.pl_picker = false;
                        self.page = .search;
                        self.focus = .input;
                        self.search_input.focus();
                    },
                    else => {},
                },
                else => {},
            }
            self.followPlScroll();
            return null;
        }

        // 我的歌单入口态：Enter 进入歌单导航，Tab 回页签循环（回绕到 1），Esc/'5' 退出
        if (self.pl_picker) {
            switch (k.key) {
                .escape => self.pl_picker = false,
                .enter => self.plCycle(a, 0), // 展开当前（没开过的从头一个）
                .tab => self.tabNext(),
                .char => |c| switch (c) {
                    'q', 'Q' => return .quit,
                    'v', 'V' => self.toggleNow(),
                    '1', '2', '3', '4' => {
                        self.pl_picker = false;
                        self.page = widgets.Page.tabs[c - '1'];
                    },
                    '5' => self.pl_picker = false,
                    '/' => {
                        self.pl_picker = false;
                        self.page = .search;
                        self.focus = .input;
                        self.search_input.focus();
                    },
                    else => {},
                },
                else => {},
            }
            return null;
        }

        // 歌词页：↑↓ 选句、Enter 跳进度、Esc 取消（其余键走通用分发）
        if (self.page == .now) switch (k.key) {
            .up => {
                self.lyrMove(a, -1);
                return null;
            },
            .down => {
                self.lyrMove(a, 1);
                return null;
            },
            .enter => {
                self.lyrSeekSel(a);
                return null;
            },
            .escape => {
                self.lyr_sel = null;
                self.lyr_browse = null;
                return null;
            },
            else => {},
        };

        switch (k.key) {
            .up => self.moveCursor(a, -1),
            .down => self.moveCursor(a, 1),
            .page_up => self.moveCursor(a, -@as(i32, @intCast(self.bodyHeight()))),
            .page_down => self.moveCursor(a, @intCast(self.bodyHeight())),
            .home => self.jumpCursor(a, 0),
            .end => self.jumpCursor(a, std.math.maxInt(u16)),
            .enter => self.activate(a),
            .left => self.seekBy(-5),
            .right => self.seekBy(5),
            .tab => {
                // Tab：循环切到侧栏下一项并直接生效；页签直达用数字键 1-4
                if (self.page == .now) return null;
                self.tabNext();
            },
            .space => self.togglePlay(),
            .escape => {},
            .char => |c| switch (c) {
                'q', 'Q' => return .quit,
                '1', '2', '3', '4' => {
                    self.closePlaylist();
                    self.page = widgets.Page.tabs[c - '1'];
                    self.focus = .list;
                },
                '5' => {
                    // 我的歌单：进导航模式（直接展开当前歌单）；已在其中则退出
                    if (self.pl_picker) {
                        self.pl_picker = false;
                        self.closePlaylist();
                    } else {
                        self.openPicker();
                    }
                },
                'v', 'V' => self.toggleNow(),
                '/' => {
                    self.page = .search;
                    self.focus = .input;
                    self.search_input.focus();
                },
                '?' => {
                    self.help_visible = true;
                    self.overlay_active = true;
                },
                ' ' => self.togglePlay(),
                'n' => self.nextSong(.user),
                'p' => self.prevSong(),
                'r' => self.cyclePlayMode(),
                'a' => self.appendCurrent(a),
                'm' => self.toggleMute(),
                '-' => self.adjustVolume(-1),
                '=', '+' => self.adjustVolume(1),
                'j' => self.moveCursor(a, 1),
                'k' => self.moveCursor(a, -1),
                'g' => self.jumpCursor(a, 0),
                'G' => self.jumpCursor(a, std.math.maxInt(u16)),
                's', 'S' => self.switchBackend(a),
                'l', 'L' => self.openLogin(),
                'o', 'O' => self.toggleRadio(),
                else => {},
            },
            else => {},
        }
        return null;
    }

    // ── 光标滚动 ──

    pub fn bodyHeight(self: *const Model) u16 {
        const mini: u16 = if (self.win_h >= 30) 3 else if (self.win_h >= 20) 1 else 0;
        const h = self.win_h -| (4 + mini);
        return if (h < 1) 1 else h;
    }

    fn moveCursor(self: *Model, a: Allocator, delta: i32) void {
        const pi = @backingInt(self.page);
        const rows = pages.buildRows(a, self, self.page);
        const cur = self.cursors[pi];
        const target = moveSelectable(rows, cur, delta);
        if (target) |t| {
            self.cursors[pi] = t;
            self.followScroll(t);
        }
    }

    fn jumpCursor(self: *Model, a: Allocator, to: u16) void {
        const pi = @backingInt(self.page);
        const rows = pages.buildRows(a, self, self.page);
        if (rows.len == 0) return;
        var t: usize = @min(@as(usize, to), rows.len - 1);
        if (!pages.selectable(rows[t])) {
            const fwd = moveSelectable(rows, @intCast(t), 1);
            t = fwd orelse 0;
        }
        self.cursors[pi] = @intCast(t);
        self.followScroll(@intCast(t));
    }

    fn followScroll(self: *Model, cursor: u16) void {
        const pi = @backingInt(self.page);
        const h: usize = self.bodyHeight();
        const c: usize = cursor;
        if (c < self.scrolls[pi]) {
            self.scrolls[pi] = @intCast(c);
        } else if (c >= @as(usize, self.scrolls[pi]) + h) {
            self.scrolls[pi] = @intCast(c + 1 - h);
        }
    }

    // ── 侧栏歌单视图（open_pl）──

    fn plMove(self: *Model, rows: []pages.Row, delta: i32) void {
        self.detail.cursor = moveSelectable(rows, self.detail.cursor, delta) orelse self.detail.cursor;
        self.followPlScroll();
    }

    fn followPlScroll(self: *Model) void {
        const h: usize = self.bodyHeight();
        if (h == 0) return;
        const c: usize = self.detail.cursor;
        if (c < self.detail.scroll) {
            self.detail.scroll = @intCast(c);
        } else if (c >= self.detail.scroll + h) {
            self.detail.scroll = @intCast(c + 1 - h);
        }
    }

    fn plActivate(self: *Model, a: Allocator) void {
        const rows = pages.detailRows(a, self);
        if (rows.len == 0) return;
        const cur = self.detail.cursor;
        if (cur >= rows.len) return;
        switch (rows[cur]) {
            .song => |ref| self.playFrom(ref.list, ref.idx),
            else => {},
        }
    }

    // ── 鼠标 ──

    fn onMouse(self: *Model, e: zz.MouseEvent, ctx: *zz.Context) void {
        const a = ctx.allocator;
        const now_ms: u64 = ctx.elapsed / std.time.ns_per_ms;
        switch (e.button) {
            // SGR 模式下滚轮一格会发 press+release 两个事件，只认 press
            .wheel_up => if (e.event_type == .press) self.onWheel(a, -1, e, now_ms),
            .wheel_down => if (e.event_type == .press) self.onWheel(a, 1, e, now_ms),
            .left => if (e.event_type == .press) self.onClick(e, a, now_ms),
            .right => if (e.event_type == .press) self.onCtxMenu(e, a),
            else => {}, // 移动/拖动/释放/中键不处理
        }
    }

    fn onWheel(self: *Model, a: Allocator, dir: i32, e: zz.MouseEvent, now_ms: u64) void {
        // 高分辨率滚轮（kitty/触控板）一格会连发多个事件——100ms 节流，
        // 只吃窗口内第一发。记"下次允许的最早时间"，首事件天然通过。
        if (now_ms < self.wheel_gate_ms) return;
        self.wheel_gate_ms = now_ms + 100;
        if (self.help_visible or self.overlay_active) return;
        if (self.page == .now) {
            // 歌词浏览：滚轮滚窗口，3 秒无操作回归跟随
            // 基准用渲染帧缓存的窗口（首帧未渲染时退回现算）
            const lw: LyrWin = if (s_lyr_win.h != 0) s_lyr_win else blk: {
                const g = pages.lyricGeom(self, self.win_w, self.bodyHeight()) orelse return;
                const lv = pages.lyricView(self.arena(), self, g.lyr_h);
                break :blk .{ .start = lv.start, .y0 = g.y0, .x0 = g.x0, .x1 = g.x1, .h = g.lyr_h };
            };
            const base: usize = self.lyr_browse orelse @intCast(@max(lw.start, 0));
            const new_start: i64 = @as(i64, @intCast(base)) + dir * 3;
            self.lyr_browse = if (new_start < 0) 0 else @intCast(new_start);
            self.lyr_idle_ms = 0;
            return;
        }
        const body_row: i64 = @as(i64, e.y) - 1;
        const sb_w: usize = if (self.win_w >= 110) 22 else if (self.win_w >= 64) 16 else 13;
        if (body_row >= 0 and body_row < self.bodyHeight() and e.x < sb_w) {
            // 侧栏：滚轮移动侧栏条目游标
            const n = widgets.Page.tabs.len + 1;
            const s = @as(i64, @intCast(self.sb_sel)) + dir;
            self.sb_sel = @intCast(@max(@min(s, @as(i64, @intCast(n -| 1))), 0));
            return;
        }
        // 主区：滚动当前列表（歌单/选取视图打开时滚对应列表）
        if (self.pl_open) {
            self.plMove(pages.detailRows(a, self), dir);
            return;
        }
        self.moveCursor(a, @intCast(dir));
    }

    fn onClick(self: *Model, e: zz.MouseEvent, a: Allocator, now_ms: u64) void {
        const w: usize = self.win_w;
        const h: usize = self.win_h;
        const x: usize = e.x;
        const y: usize = e.y;
        if (y == 0 or w < 20 or h < 8) return;
        const body_h: usize = self.bodyHeight();

        // 右键菜单：点击项内 = 执行该项，点外 = 关闭
        if (self.ctx_menu != null) {
            const g = self.ctxGeom(a, w, h);
            const in_x = x >= g.x0 and x < g.x0 + g.bw;
            const in_y = y >= g.y0 and y < g.y0 + g.bh;
            if (in_x and in_y) {
                // 卡内结构：边框 1 + 内边距 1，其后是菜单项
                const rel = y - g.y0 - 2;
                if (rel < self.ctxActionCount()) {
                    if (self.ctx_menu) |*m| m.sel = rel;
                    self.ctxActivate(a);
                }
            } else {
                self.ctx_menu = null;
            }
            return;
        }

        // 帮助浮层：任意点击关闭
        if (self.help_visible) {
            self.help_visible = false;
            self.overlay_active = false;
            return;
        }

        // 详情浮层：卡内点行（单击选中/双击播放），卡外关闭
        if (self.overlay_active and self.detail.songs.len > 0) {
            const box_w = w -| 8;
            const inner_rows = h -| 9;
            const inner = pages.renderDetail(a, self, box_w -| 4, inner_rows);
            var lines: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, inner, '\n');
            while (it.next()) |l| lines.append(a, l) catch {};
            const title = std.fmt.allocPrint(a, "{s} · {s}", .{ self.detail.playlist.typeName(), self.detail.playlist.name }) catch "";
            const card_txt = widgets.card(a, box_w, title, lines.items);
            const card_h = zz.height(card_txt);
            const x0 = (w -| box_w) / 2;
            const y0 = (h -| card_h) / 2;
            if (x < x0 or x >= x0 + box_w or y < y0 or y >= y0 + card_h) {
                self.detail = .{};
                self.overlay_active = false;
                return;
            }
            // 卡内结构：边框 1 + 内边距 1 + 标题 1，其后是歌曲行
            const rel: i64 = @as(i64, @intCast(y)) - @as(i64, @intCast(y0)) - 3;
            if (rel >= 0) {
                const rows = pages.detailRows(a, self);
                const r: usize = @as(usize, @intCast(rel)) + self.detail.scroll;
                if (r < rows.len and pages.selectable(rows[r])) {
                    const dbl = self.clickAgain(1, r, now_ms);
                    self.detail.cursor = @intCast(r);
                    if (dbl) {
                        self.last_click.ms = 0;
                        self.plActivate(a);
                    }
                }
            }
            return;
        }

        // 播放栏信息行：点击 = 播放/暂停
        if (y == body_h + 1) {
            self.togglePlay();
            return;
        }
        // 进度条行：按列 seek
        if (y == body_h + 2) {
            self.seekFraction(x);
            return;
        }
        // 迷你歌词 / 状态行忽略
        if (y > body_h + 2) return;

        // ── 主体区 ──
        const body_row = y - 1;
        if (self.page == .now) {
            // 全屏播放页：鼠标不做歌词定位（屏幕几何与播放进度对不齐，
            // 进度跳转走键盘 ↑↓ 选句 + Enter，见 onKey 的 .now 分支）
            return;
        }

        const sb_w: usize = if (w >= 110) 22 else if (w >= 64) 16 else 13;
        if (x < sb_w) {
            const pls = self.allPlaylists(a);
            const n_disp = @min(pls.len, body_h -| widgets.SB_PL_START);
            if (widgets.sidebarHit(body_row, n_disp)) |item| {
                if (item < widgets.Page.tabs.len) {
                    self.closePlaylist();
                    self.pl_picker = false;
                    self.page = widgets.Page.tabs[item];
                    self.sb_sel = item;
                    self.focus = .list;
                } else if (item == widgets.Page.tabs.len) {
                    self.openPicker();
                } else {
                    self.openDetail(pls[item - widgets.Page.tabs.len - 1], a);
                }
            }
            return;
        }

        // ── 主区 ──
        if (self.pl_open) {
            const rows = pages.detailRows(a, self);
            if (body_row >= 3) {
                const r = (body_row - 3) + self.detail.scroll;
                self.plClick(a, rows, r, now_ms);
            }
            return;
        }

        if (self.page == .search) {
            // 搜索框带圆角边框，占 3 行（body_row 3..5），结果区从 body_row 7 起
            if (body_row >= 3 and body_row <= 5) {
                // 搜索框：点击聚焦
                self.focus = .input;
                self.search_input.focus();
                return;
            }
            if (body_row < 7) return;
            const rows = pages.buildRows(a, self, .search);
            const r = (body_row - 7) + self.scrolls[@backingInt(widgets.Page.search)];
            self.listClick(a, rows, r, now_ms);
            if (self.focus == .input) self.focus = .list;
            return;
        }

        const rows = pages.buildRows(a, self, self.page);
        if (body_row < 3) return;
        const r = (body_row - 3) + self.scrolls[@backingInt(self.page)];
        self.listClick(a, rows, r, now_ms);
    }

    /// 双击检测：450ms 内同一区域第二次左键（时钟来自 ctx.elapsed，单调）
    fn clickAgain(self: *Model, kind: u8, row: usize, now_ms: u64) bool {
        const dbl = self.last_click.kind == kind and self.last_click.row == row and
            now_ms -| self.last_click.ms < 450;
        self.last_click = .{ .kind = kind, .row = row, .ms = now_ms };
        return dbl;
    }

    fn listClick(self: *Model, a: Allocator, rows: []pages.Row, r: usize, now_ms: u64) void {
        if (r >= rows.len or !pages.selectable(rows[r])) return;
        const dbl = self.clickAgain(0, r, now_ms);
        self.cursors[@backingInt(self.page)] = @intCast(r);
        self.followScroll(@intCast(r));
        if (dbl) {
            self.last_click.ms = 0;
            self.activate(a);
        }
    }

    fn plClick(self: *Model, a: Allocator, rows: []pages.Row, r: usize, now_ms: u64) void {
        if (r >= rows.len or !pages.selectable(rows[r])) return;
        const dbl = self.clickAgain(1, r, now_ms);
        self.detail.cursor = @intCast(r);
        self.followPlScroll();
        if (dbl) {
            self.last_click.ms = 0;
            self.plActivate(a);
        }
    }

    /// 点击进度条：按列位置等比 seek（条从第 6 列起，长 w-14）
    /// 歌词页当前窗口高度（与渲染一致；未渲染过则现算）
    pub fn lyrH(self: *Model) usize {
        if (s_lyr_win.h != 0) return s_lyr_win.h;
        const g = pages.lyricGeom(self, self.win_w, self.bodyHeight()) orelse return 0;
        return g.lyr_h;
    }

    /// ↑↓ 移动歌词选句；浏览窗口跟着选区走（选区居中）
    fn lyrMove(self: *Model, a: Allocator, dir: i32) void {
        if (self.lyrics == null) return;
        const h = self.lyrH();
        if (h == 0) return;
        const lv = pages.lyricView(a, self, h);
        if (lv.rows.len == 0) return;
        const cur: i64 = @intCast(self.lyr_sel orelse lv.cur_disp);
        const new_sel = @max(@min(cur + dir, @as(i64, @intCast(lv.rows.len - 1))), 0);
        self.lyr_sel = @intCast(new_sel);
        const start: i64 = new_sel - @as(i64, @intCast(h / 2));
        self.lyr_browse = if (start <= 0) 0 else @intCast(@min(start, @as(i64, @intCast(lv.rows.len -| @min(lv.rows.len, h)))));
        self.lyr_idle_ms = 0;
    }

    /// Enter：跳到选中句的时间
    fn lyrSeekSel(self: *Model, a: Allocator) void {
        const sel = self.lyr_sel orelse {
            self.setStatus("先用 ↑↓ 选一句歌词");
            return;
        };
        const h = self.lyrH();
        if (h == 0) return;
        const lv = pages.lyricView(a, self, h);
        if (sel >= lv.rows.len) return;
        if (pages.lyricRowMs(self, lv, sel)) |msv| {
            self.seekAbsMs(msv);
            self.lyr_sel = null;
            self.lyr_browse = null;
            self.setStatus("已跳转到歌词位置");
        }
    }

    /// 绝对跳转（歌词双击）；播放后端与本地进度同步
    fn seekAbsMs(self: *Model, ms: u64) void {
        self.pos_ms = @intCast(@min(ms, std.math.maxInt(u32)));
        self.lyrFollow();
        if (self.player.started() and self.player.available()) {
            self.player.seekTo(@as(f64, @floatFromInt(self.pos_ms)) / 1000.0);
        }
    }

    fn seekFraction(self: *Model, x: usize) void {
        const i = self.q_index orelse return;
        if (i >= self.queue.items.len) return;
        const bar_w = self.win_w -| 14;
        if (bar_w < 4 or x < 6 or x >= 6 + bar_w) return;
        const dur_ms: u64 = @as(u64, self.queue.items[i].duration_s) * 1000;
        const frac = @as(u64, x - 6) * 1000 / bar_w;
        // 必须真 seek 后端：只改 pos_ms 会被下一 tick 的 status 轮询覆盖
        // （表现即"点进度条没反应"）
        self.seekAbsMs(dur_ms * frac / 1000);
    }

    // ── Enter / a 的行为 ──

    fn activate(self: *Model, a: Allocator) void {
        const pi = @backingInt(self.page);
        const rows = pages.buildRows(a, self, self.page);
        if (rows.len == 0) return;
        const cur = self.cursors[pi];
        if (cur >= rows.len) return;
        switch (rows[cur]) {
            .song => |ref| self.playFrom(ref.list, ref.idx),
            .playlist => |pl| self.openDetail(pl, a),
            else => {},
        }
    }

    fn appendCurrent(self: *Model, a: Allocator) void {
        const pi = @backingInt(self.page);
        const rows = pages.buildRows(a, self, self.page);
        if (rows.len == 0) return;
        const cur = self.cursors[pi];
        if (cur >= rows.len) return;
        switch (rows[cur]) {
            .song => |ref| {
                self.queue.append(self.arena(), self.queueSong(ref.list[ref.idx])) catch {};
                const msg = std.fmt.allocPrint(a, "已加入队列 · 共 {d} 首", .{self.queue.items.len}) catch "已加入队列";
                self.setStatus(msg);
            },
            else => {},
        }
    }

    fn playFrom(self: *Model, list: []const model.Song, idx: usize) void {
        if (list.ptr == self.queue.items.ptr) {
            // 队列页 Enter：list 就是队列自身，重建会 memcpy 自负；只跳转
            self.q_index = @intCast(idx);
            self.pos_ms = 0;
            self.playing = true;
            if (self.backend == .mock) {
                self.refreshLyrics();
            } else {
                const song = self.queue.items[idx];
                self.requestPlayback(song);
                self.requestLyrics(song);
                self.requestCover(song);
            }
            return;
        }
        self.queue.clearRetainingCapacity();
        self.queueAddSlice(list);
        self.q_index = @intCast(idx);
        self.pos_ms = 0;
        self.playing = true;
        if (self.backend == .mock) {
            self.refreshLyrics();
        } else {
            const song = self.queue.items[idx];
            self.requestPlayback(song);
            self.requestLyrics(song);
            self.requestCover(song);
            // mpv 尚未连接是首播正常路径（pending_url 机制会在 connect 后
            // 补 loadFile），不在这里报"不可用"——那是过时粘性提示的来源
        }
    }

    fn openDetail(self: *Model, pl: model.Playlist, a: Allocator) void {
        if (self.backend == .mock) {
            if (self.data.detail_songs.len == 0) {
                self.setStatus("演示数据缺 playlist_detail.json，无法打开详情");
                return;
            }
            self.detail = .{
                .playlist = pl,
                .songs = self.data.detail_songs,
                .cursor = 0,
                .scroll = 0,
            };
        } else {
            // 真实音源：先开（主区显示加载中），数据到了自动填充
            self.detail = .{ .playlist = pl, .songs = &.{} };
            self.kickDetail(pl);
        }
        // 在主区 frame 内展开。open_pl 是"我的歌单"▶ 标记：探索页推荐
        // 歌单不在其中，不能落到 0（否则右侧会跳到我的歌单第一项）
        self.pl_open = true;
        const pls = self.allPlaylists(a);
        for (pls, 0..) |p, i| {
            if (p.backend == pl.backend and std.mem.eql(u8, p.id, pl.id)) {
                self.open_pl = i;
                self.picker_cursor = @intCast(i);
                break;
            }
        }
        self.focus = .list;
    }

    fn onDetailKey(self: *Model, k: zz.KeyEvent, a: Allocator) void {
        const rows = pages.detailRows(a, self);
        const h = self.bodyHeight();
        switch (k.key) {
            .escape => {
                self.detail = .{};
                self.overlay_active = false;
                return;
            },
            .up => self.detail.cursor = moveSelectable(rows, self.detail.cursor, -1) orelse self.detail.cursor,
            .down => self.detail.cursor = moveSelectable(rows, self.detail.cursor, 1) orelse self.detail.cursor,
            .page_up => {
                const t = moveSelectable(rows, self.detail.cursor, -@as(i32, @intCast(h))) orelse self.detail.cursor;
                self.detail.cursor = t;
            },
            .page_down => {
                const t = moveSelectable(rows, self.detail.cursor, @intCast(h)) orelse self.detail.cursor;
                self.detail.cursor = t;
            },
            .enter => {
                if (rows.len == 0) return;
                const cur = self.detail.cursor;
                if (cur < rows.len) switch (rows[cur]) {
                    .song => |ref| self.playFrom(ref.list, ref.idx),
                    else => {},
                };
                self.detail = .{};
                self.overlay_active = false;
            },
            .char => |c| switch (c) {
                'a' => {
                    if (rows.len == 0) return;
                    const cur = self.detail.cursor;
                    if (cur < rows.len) switch (rows[cur]) {
                        .song => |ref| {
                            self.queue.append(self.arena(), self.queueSong(ref.list[ref.idx])) catch {};
                            self.setStatus("已加入队列");
                        },
                        else => {},
                    };
                },
                else => {},
            },
            else => {},
        }
        // 滚动跟随
        if (rows.len > 0) {
            const c: usize = self.detail.cursor;
            if (c < self.detail.scroll) {
                self.detail.scroll = @intCast(c);
            } else if (c >= @as(usize, self.detail.scroll) + h) {
                self.detail.scroll = @intCast(c + 1 - h);
            }
        }
    }

    // ── 播放控制 ──

    /// 播放侧动作（播放/暂停、seek、切歌）后歌词退出浏览、回归跟随
    fn lyrFollow(self: *Model) void {
        self.lyr_browse = null;
        self.lyr_idle_ms = 0;
    }

    fn togglePlay(self: *Model) void {
        const i = self.q_index orelse return;
        if (i >= self.queue.items.len) return;
        self.lyrFollow();
        if (self.backend == .mock) {
            self.playing = !self.playing;
            return;
        }
        // 后端里还没有当前曲（重启后首按/上次加载失败）：必须真实加载，
        // 只翻 playing 标志会得到无声假进度
        const song = self.queue.items[i];
        if (!self.playing and !std.mem.eql(u8, self.loaded_key, self.songKey(song))) {
            self.playing = true;
            self.requestPlayback(song);
            return;
        }
        self.playing = !self.playing;
        if (self.player.started() and self.player.available()) {
            self.player.setPause(!self.playing);
        }
    }

    /// 切歌统一走播放模式状态机：eof 触发时单曲循环回自己，
    /// 随机沿洗牌袋走。切完的播放动作与旧 nextSong/prevSong 相同。
    fn jumpTo(self: *Model, idx: usize) void {
        self.q_index = @intCast(idx);
        self.pos_ms = 0;
        self.lyrFollow();
        if (self.backend == .mock) {
            self.refreshLyrics();
        } else {
            self.playing = true;
            const song = self.queue.items[self.q_index.?];
            self.requestPlayback(song);
            self.requestLyrics(song);
            self.requestCover(song);
        }
    }

    fn nextSong(self: *Model, trigger: playmode.Trigger) void {
        const i = self.q_index orelse return;
        if (self.queue.items.len == 0) return;
        // mpv 在管播放：列表里有下一首就直接让 mpv 切（与系统媒体键完全
        // 同路径，事件回环统一收口）；没有下一首（预取失败/未就绪）走
        // TUI 计算并 loadfile 重建列表。MF 下 playlistPos 恒 null，直接走
        // 底下的 pc 状态机路径
        if (self.player.started() and self.player.available() and !self.loading[kindIndex(.play_url)]) {
            if (self.player.playlistPos()) |pos| {
                if (pos >= 0 and pos + 1 < @as(i64, @intCast(self.pl_order.items.len))) {
                    _ = self.player.playlistNext();
                    return;
                }
            }
        }
        const next = self.pc.nextIndex(self.gpa, i, self.queue.items.len, trigger) orelse return;
        self.jumpTo(next);
    }

    fn prevSong(self: *Model) void {
        const i = self.q_index orelse return;
        if (self.queue.items.len == 0) return;
        if (self.player.started() and self.player.available() and !self.loading[kindIndex(.play_url)]) {
            if (self.player.playlistPos()) |pos| {
                if (pos > 0) {
                    _ = self.player.playlistPrev();
                    return;
                }
            }
        }
        const prev = self.pc.prevIndex(self.gpa, i, self.queue.items.len) orelse return;
        self.jumpTo(prev);
    }

    /// r 键：列表循环 → 单曲循环 → 随机 → 列表循环。
    /// 切到随机时立即建洗牌袋（当前歌钉袋首）。
    fn cyclePlayMode(self: *Model) void {
        const len = self.queue.items.len;
        const cur: usize = if (self.q_index) |qi| @min(qi, len -| 1) else 0;
        const next = self.pc.mode.cycle();
        self.pc.setMode(self.gpa, next, cur, len);
        if (self.player.started() and self.player.available()) self.player.setLoopFile(next == .one);
        self.setStatus(std.fmt.allocPrint(self.arena(), "播放模式：{s}", .{next.label()}) catch null);
    }

    // ── 右键菜单 ──

    /// 菜单项（含文案），选中态由 CtxMenu.sel 索引。
    /// 歌曲：喜欢toggle / 下一首播放 / 加入队列；歌单：打开。
    pub fn ctxActionCount(self: *const Model) usize {
        const menu = &(self.ctx_menu orelse return 0);
        return if (menu.song != null) 3 else 1;
    }

    pub fn ctxItemLabel(self: *const Model, i: usize) []const u8 {
        const menu = &(self.ctx_menu orelse return "");
        if (menu.song != null) {
            return switch (i) {
                0 => if (self.backend == .qq) "添加到喜欢（该源暂不支持）" else if (menu.liked) "取消喜欢" else "添加到喜欢",
                1 => "下一首播放",
                2 => "追加到队列",
                else => "",
            };
        }
        return "打开歌单";
    }

    fn ctxTitle(self: *const Model) []const u8 {
        const menu = &(self.ctx_menu orelse return "");
        if (menu.song) |song| return song.title;
        if (menu.pl) |pl| return pl.name;
        return "";
    }

    /// Song 值随菜单复制进模型 arena（字符串逐字段 dupe）
    fn ctxSongCopy(self: *Model, song: model.Song) model.Song {
        const a = self.arena();
        var out = song;
        inline for (.{ "id", "title", "artist", "album", "song_mid", "media_mid", "cover_url" }) |f| {
            const v = @field(song, f);
            @field(out, f) = a.dupe(u8, v) catch v;
        }
        return out;
    }

    fn isLikedSong(self: *Model, song: model.Song) bool {
        const key = self.songKey(song);
        for (self.data.liked) |s| {
            if (std.mem.eql(u8, self.songKey(s), key)) return true;
        }
        return false;
    }

    fn onCtxMenu(self: *Model, e: zz.MouseEvent, a: Allocator) void {
        // 登录/帮助/详情浮层开着不开菜单
        if (self.login != null or self.help_visible or self.overlay_active) return;
        if (e.y == 0) return;
        const w: usize = self.win_w;
        const body_h: usize = self.bodyHeight();
        const body_row: usize = e.y - 1;
        const sb_w: usize = if (w >= 110) 22 else if (w >= 64) 16 else 13;

        // 侧栏歌单行 → 歌单菜单
        if (e.x < sb_w) {
            if (self.page == .now) return;
            const pls = self.allPlaylists(a);
            const n_disp = @min(pls.len, body_h -| widgets.SB_PL_START);
            if (widgets.sidebarHit(body_row, n_disp)) |item| {
                if (item > widgets.Page.tabs.len) {
                    self.ctx_menu = .{
                        .pl = pls[item - widgets.Page.tabs.len - 1],
                        .x = e.x,
                        .y = e.y,
                    };
                } else {
                    self.ctx_menu = null; // 页签/我的歌单没有可操作菜单
                }
            }
            return;
        }

        if (self.page == .now) return;
        // 主区行 → 歌曲菜单（命中判定与 onClick 逐行一致）
        var rows: []pages.Row = undefined;
        var r: usize = undefined;
        if (self.pl_open) {
            rows = pages.detailRows(a, self);
            if (body_row < 3) return;
            r = (body_row - 3) + self.detail.scroll;
        } else if (self.page == .search) {
            if (body_row < 7) return;
            rows = pages.buildRows(a, self, .search);
            r = (body_row - 7) + self.scrolls[@backingInt(widgets.Page.search)];
        } else {
            if (body_row < 3) return;
            rows = pages.buildRows(a, self, self.page);
            r = (body_row - 3) + self.scrolls[@backingInt(self.page)];
        }
        if (r >= rows.len) return;
        switch (rows[r]) {
            .song => |ref| {
                const song = ref.list[ref.idx];
                self.ctx_menu = .{
                    .song = self.ctxSongCopy(song),
                    .x = e.x,
                    .y = e.y,
                    .liked = self.isLikedSong(song),
                };
            },
            .playlist => |pl| {
                self.ctx_menu = .{ .pl = pl, .x = e.x, .y = e.y };
            },
            .section, .note => {},
        }
    }

    /// 执行选中菜单项并关闭菜单
    fn ctxActivate(self: *Model, a: Allocator) void {
        const menu = &(self.ctx_menu orelse return);
        if (menu.song) |song| {
            switch (menu.sel) {
                0 => {
                    // 喜欢 toggle（QQ 写接口未对接，服务端会报 unsupported）
                    const target = !menu.liked;
                    self.kickJob(.{
                        .kind = .like,
                        .backend = self.backend,
                        .id = self.arena().dupe(u8, song.id) catch song.id,
                        .mid = self.arena().dupe(u8, song.song_mid) catch song.song_mid,
                        .like = target,
                    });
                    self.setStatus(if (target) "正在添加到喜欢…" else "正在取消喜欢…");
                },
                1 => {
                    // 下一首播放：插到当前歌后面；没在播就直接追加
                    if (self.q_index) |qi| {
                        const idx = @min(qi + 1, self.queue.items.len);
                        self.queue.insert(self.arena(), idx, self.queueSong(song)) catch {
                            self.setStatus("内存不足，插入失败");
                            return;
                        };
                    } else {
                        self.queueAddSlice(&.{song});
                    }
                    self.setStatus("已设为下一首播放");
                },
                2 => {
                    self.queueAddSlice(&.{song});
                    self.setStatus("已加入队列");
                },
                else => {},
            }
        } else if (menu.pl) |pl| {
            self.openDetail(pl, a);
        }
        self.ctx_menu = null;
    }

    /// 菜单卡片几何（渲染与点击命中共用）。
    pub fn ctxGeom(self: *const Model, a: Allocator, w: usize, h: usize) struct { x0: usize, y0: usize, bw: usize, bh: usize, txt: []const u8 } {
        const menu = &(self.ctx_menu orelse return .{ .x0 = 0, .y0 = 0, .bw = 0, .bh = 0, .txt = "" });
        var lines: std.ArrayList([]const u8) = .empty;
        for (0..self.ctxActionCount()) |i| {
            const label = self.ctxItemLabel(i);
            const line = if (i == menu.sel)
                std.fmt.allocPrint(a, "▎{s}", .{label}) catch label
            else
                std.fmt.allocPrint(a, "  {s}", .{label}) catch label;
            lines.append(a, line) catch {};
        }
        const card_w = @min(w -| 4, 32);
        const title = std.fmt.allocPrint(a, "{s}", .{self.ctxTitle()}) catch "操作";
        const txt = widgets.card(a, card_w, title, lines.items);
        const bh = zz.height(txt);
        // 菜单贴着光标右下弹，贴边时往回钳
        const x0 = @min(menu.x +| 1, w -| card_w -| 1);
        const y0 = @min(menu.y +| 1, h -| bh -| 1);
        return .{ .x0 = x0, .y0 = y0, .bw = card_w, .bh = bh, .txt = txt };
    }

    fn seekBy(self: *Model, secs: i32) void {
        const i = self.q_index orelse return;
        if (i >= self.queue.items.len) return;
        const dur_ms: i64 = @as(i64, self.queue.items[i].duration_s) * 1000;
        var p: i64 = @as(i64, self.pos_ms) + @as(i64, secs) * 1000;
        if (p < 0) p = 0;
        if (p > dur_ms) p = dur_ms;
        self.pos_ms = @intCast(p);
        self.lyrFollow();
        if (self.player.started() and self.player.available()) {
            self.player.seekTo(@as(f64, @floatFromInt(p)) / 1000.0);
        }
    }

    fn toggleMute(self: *Model) void {
        self.mute = !self.mute;
        if (self.player.started() and self.player.available()) {
            self.player.setVolume(if (self.mute) 0 else self.volume);
        }
    }

    fn adjustVolume(self: *Model, delta: i32) void {
        var v: i32 = @as(i32, self.volume) + delta * 10;
        if (v < 0) v = 0;
        if (v > 100) v = 100;
        self.volume = @intCast(v);
        self.mute = false;
        if (self.player.started() and self.player.available()) {
            self.player.setVolume(self.volume);
        }
    }

    fn refreshLyrics(self: *Model) void {
        // mock 专用链路：testdata 的 base64 歌词
        self.lyrics = null;
        if (self.backend != .mock) return;
        const a = self.arena();
        const b64 = self.data.lyrics_b64 orelse return;
        const i = self.q_index orelse return;
        if (i >= self.queue.items.len) return;
        const song = self.queue.items[i];
        if (!std.mem.eql(u8, song.id, self.data.lyric_song_id)) return;
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch return;
        const raw = a.alloc(u8, n) catch return;
        dec.decode(raw, b64) catch return;
        self.lyrics = lyrics_mod.decodeAndParse(a, raw) catch null;
    }

    // ── 登录与音源切换 ──

    fn openLogin(self: *Model) void {
        if (self.backend == .mock) {
            self.setStatus("演示模式无登录（以 AM_BACKEND=bodian/netease/qq 启动启用真实音源）");
            return;
        }
        self.login = .{ .backend = self.backend, .phase = .choose };
        self.setStatus(null);
    }

    fn onLoginKey(self: *Model, k: zz.KeyEvent) ?zz.Cmd(Msg) {
        const lf = &(self.login orelse return null);
        switch (k.key) {
            .escape => {
                self.login = null;
                self.setStatus("已取消登录");
                return null;
            },
            .char => |c| switch (c) {
                'q', 'Q' => {
                    self.login = null;
                    self.setStatus("已取消登录");
                    return null;
                },
                '1', '2', '3' => {
                    if (lf.phase != .choose) return null;
                    const backend: model.Backend = switch (c) {
                        '1' => .bodian,
                        '2' => .netease,
                        else => .qq,
                    };
                    lf.backend = backend;
                    lf.phase = .qr;
                    lf.message = null;
                    self.kickJob(.{ .kind = .login_qr, .backend = backend });
                },
                else => {},
            },
            else => {},
        }
        return null;
    }

    // ── 音源偏好持久化（~/.config/alloymusic/backend，存枚举名一行）──

    /// 音源持久化目录（分平台）：unix ~/.config/alloymusic，Windows %HOME%\AlloyMusic
    fn backendDir(self: *const Model, buf: []u8) ?[]const u8 {
        if (self.home_dir.len == 0) return null;
        if (builtin.os.tag == .windows)
            return std.fmt.bufPrint(buf, "{s}/AlloyMusic", .{self.home_dir}) catch null;
        return std.fmt.bufPrint(buf, "{s}/.config/alloymusic", .{self.home_dir}) catch null;
    }

    fn backendFile(self: *const Model, buf: *[255:0]u8) ?[:0]const u8 {
        var dbuf: [512]u8 = undefined;
        const dn = self.backendDir(&dbuf) orelse return null;
        const n = std.fmt.bufPrint(buf, "{s}/backend", .{dn}) catch return null;
        return buf[0..n.len :0];
    }

    fn saveBackend(self: *Model, b: model.Backend) void {
        var dbuf: [512]u8 = undefined;
        const dn = self.backendDir(&dbuf) orelse return;
        var pbuf: [255:0]u8 = @splat(0);
        const path = self.backendFile(&pbuf) orelse return;
        // 跨平台：std.Io.Dir（绝对路径作为 cwd() 的子路径，unix/Windows 都成立）
        std.Io.Dir.cwd().createDirPath(self.io, dn) catch {};
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = @tagName(b) }) catch {};
    }

    fn loadBackend(self: *const Model) ?model.Backend {
        var pbuf: [255:0]u8 = @splat(0);
        const path = self.backendFile(&pbuf) orelse return null;
        var data: [32]u8 = undefined;
        const got = std.Io.Dir.cwd().readFile(self.io, path, &data) catch return null;
        const name = std.mem.trim(u8, got, " \t\r\n");
        if (name.len == 0 or std.mem.eql(u8, name, "mock")) return null; // 演示模式不持久化
        return std.meta.stringToEnum(model.Backend, name);
    }

    fn switchBackend(self: *Model, a: Allocator) void {
        _ = a; // 状态串必须进常驻 arena（帧分配器的字符串下一帧就是悬垂）
        // 只在已登录的音源里循环（波点→网易→QQ 顺序取 health 结果）
        const order = [3]model.Backend{ .bodian, .netease, .qq };
        var cands: [3]model.Backend = undefined;
        var n: usize = 0;
        for (order, 0..) |b, i| {
            if (self.health.logged_in[i]) {
                cands[n] = b;
                n += 1;
            }
        }
        if (n == 0) {
            self.setStatus("未登录任何音源：按 L 登录后可切换");
            return;
        }
        var next = cands[0];
        for (cands[0..n], 0..) |b, i| {
            if (b == self.backend and i + 1 < n) {
                next = cands[i + 1];
                break;
            }
        }
        self.saveBackend(next);
        self.epoch += 1; // 在途的旧音源结果作废
        self.backend = next;
        self.data = .{};
        self.detail = .{};
        self.open_pl = null;
        self.pl_open = false;
        self.overlay_active = false;
        self.search_done = false;
        self.cursors = @splat(0);
        self.scrolls = @splat(0);
        self.loading = @splat(false);
        // 封面跟歌走：队列跨源保留（歌曲自带音源标签），正在播放的歌
        // 封面不清空——清了没有任何 outcome 会再触发 requestCover（ explore
        // 只在队列空时补封面），封面就会消失到下一首歌。
        self.radio_mode = false; // 电台流跟源走：切源即关，重新按 o 开
        self.radio_pending = false;
        self.setStatus(std.fmt.allocPrint(self.arena(), "音源切换到 {s}，加载中…", .{next.label()}) catch "音源切换中…");
        self.kickExplore();
        self.kickHealth();
        self.kickLibrary();
        // 队列保留（歌曲自带音源标签，跨源播放不受影响）
    }

    fn onSearchSubmit(self: *Model, a: Allocator) void {
        const kw = std.mem.trim(u8, self.search_input.value.items, " \t\r\n");
        if (kw.len == 0) return;
        self.search_done = true;
        self.cursors[@backingInt(widgets.Page.search)] = 0;
        self.scrolls[@backingInt(widgets.Page.search)] = 0;
        if (self.backend == .mock) {
            self.setStatus("演示模式：任意关键词都返回同一份固定结果");
            return;
        }
        _ = a;
        self.setStatus(null);
        self.kickSearch(kw);
    }

    // ── view ──

    pub fn view(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        const a = ctx.allocator;
        const w: usize = ctx.width;
        const h: usize = ctx.height;
        if (w < 20 or h < 8) {
            return (zz.Style{}).fg(theme.warn).render(a, "终端太小，请至少 20x8") catch "";
        }

        const mini: usize = if (h >= 30 and self.page != .now) 3 else if (h >= 20 and self.page != .now) 1 else 0;
        const body_h = h -| (4 + mini); // 顶栏 1 + 播放栏 2 + 状态行 1

        const top = widgets.topBar(a, w, self.topBarLabel(a));

        // 正在播放页是全屏播放模式：无侧栏，主区占满整屏（参考 [V] 播放界面）
        const cover: ?model.Song = blk: {
            const i = self.q_index orelse break :blk null;
            if (i >= self.queue.items.len) break :blk null;
            break :blk self.queue.items[i];
        };
        const upper = if (self.page == .now)
            pages.renderPage(a, self, .now, w, body_h)
        else blk: {
            // 左侧导航栏 + 右侧主区；窄终端收窄侧栏
            const sb_w: usize = if (w >= 110) 22 else if (w >= 64) 16 else 13;
            const main_w = w -| sb_w;
            const nav = widgets.sidebar(a, sb_w, body_h, .{
                .page = self.page,
                .cover = cover,
                .playlists = self.allPlaylists(a),
                .selecting = self.pl_picker,
                .open_idx = self.open_pl,
            });
            const body = if (self.pl_open)
                pages.renderPlaylistView(a, self, main_w, body_h)
            else
                pages.renderPage(a, self, self.page, main_w, body_h);
            break :blk try zz.joinHorizontal(a, &.{ nav, body });
        };

        const cur: ?model.Song = cover;
        const dur_ms: u32 = if (cur) |s| s.duration_s * 1000 else 0;

        const info_line = widgets.playerInfoLine(a, w, .{
            .has_song = cur != null,
            .playing = self.playing,
            .title = if (cur) |s| s.title else "",
            .artist = if (cur) |s| s.artist else "",
            .vip = if (cur) |s| s.vip else false,
            .volume = self.volume,
            .mute = self.mute,
            .radio = self.radio_mode,
            .mode_label = self.pc.mode.label(),
        });
        const progress = widgets.progressBar(a, w, @min(self.pos_ms, dur_ms), dur_ms);

        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(a, top);
        try parts.append(a, upper);
        try parts.append(a, info_line);
        try parts.append(a, progress);
        if (mini > 0) try parts.append(a, self.miniLyrics(a, w, mini));
        // 按键提示常驻；异常/反馈消息由 toastTop 盖到顶栏中间，不再顶掉提示行
        try parts.append(a, widgets.statusLine(a, w, null, self.page));

        var frame = try zz.joinVertical(a, parts.items);

        // 浮层打开时底帧换纯暗背景：一是浮层的视觉惯例（压暗底），
        // 二是避免不透明卡片劈开底帧全角字符导致行宽错位
        if (self.login != null) {
            if (self.renderLoginCard(a, w, h, frame)) |card| {
                frame = card;
            }
        } else if (self.help_visible) {
            const card_w = @min(w -| 4, 88);
            const card_txt = widgets.card(a, card_w, "帮助", pages.helpLines(a, card_w -| 4));
            frame = centerFloat(a, frame, card_txt, w, h);
        } else if (self.overlay_active and self.detail.songs.len > 0) {
            const box_w = w -| 8;
            const inner_rows = h -| 9; // 边框 2 + 内边距 2 + 标题 1 + 上下余量
            var detail_lines: std.ArrayList([]const u8) = .empty;
            const inner = pages.renderDetail(a, self, box_w -| 4, inner_rows);
            var it = std.mem.splitScalar(u8, inner, '\n');
            while (it.next()) |l| try detail_lines.append(a, l);
            const title = try std.fmt.allocPrint(a, "{s} · {s} · 共 {d} 首", .{ self.detail.playlist.typeName(), self.detail.playlist.name, self.detail.songs.len });
            const card_txt = widgets.card(a, box_w, title, detail_lines.items);
            frame = centerFloat(a, frame, card_txt, w, h);
        } else if (self.overlay_active and self.loading[kindIndex(.detail)]) {
            // detail 加载中：悬浮加载卡片
            const box_w = @min(w -| 8, 56);
            const card_txt = widgets.card(a, box_w, "加载中", &.{"正在从音源拉取歌单…"});
            frame = centerFloat(a, frame, card_txt, w, h);
        }
        // 右键菜单：LayerStack 悬浮在原界面上（不清空、不压暗底）
        if (self.ctx_menu != null) {
            const g = self.ctxGeom(a, w, h);
            if (g.bh > 0) frame = floatingAt(a, frame, g.txt, w, h, g.x0, g.y0);
        }
        // 缓存本帧歌词窗口几何：点击命中必须用渲染时的窗口，不能用
        // 点击时刻重算的（播放中 pos 在走，两者会差出一两名）
        if (self.page == .now) {
            if (pages.lyricGeom(self, w, self.bodyHeight())) |g| {
                const lv = pages.lyricView(a, self, g.lyr_h);
                s_lyr_win = .{ .start = lv.start, .y0 = g.y0, .x0 = g.x0, .x1 = g.x1, .h = g.lyr_h };
            } else s_lyr_win = .{};
        } else s_lyr_win = .{};
        if (self.status) |msg| frame = toastTop(a, frame, w, msg);
        return frame;
    }

    /// 异常/反馈提示条：盖在顶栏正中（左侧徽标保留），不占底部按键提示行
    fn toastTop(a: Allocator, frame: []const u8, w: usize, msg: []const u8) []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, frame, '\n');
        const first = it.next() orelse return frame;
        const styled = theme.warnInline().render(a, msg) catch msg;
        const msg_w = @min(zz.width(styled), w);
        const x0 = (w -| msg_w) / 2;
        // 左段只是"被 toast 遮住"的顶栏，不用 .ellipsis（恰好占满时会
        // 凭空渲染出 "..."，看起来像通知开头多了省略号）
        const left = widgets.fitPlain(a, first, x0);
        const mid = widgets.fitPlain(a, styled, msg_w);
        const right = widgets.fitPlain(a, "", w -| x0 -| msg_w);
        lines.append(a, zz.joinHorizontal(a, &.{ left, mid, right }) catch first) catch return frame;
        while (it.next()) |l| lines.append(a, l) catch return frame;
        return zz.joinVertical(a, lines.items) catch frame;
    }

    fn topBarLabel(self: *const Model, a: Allocator) []const u8 {
        if (self.backend == .mock) return "演示模式 (L)";
        const idx = healthIndex(self.backend);
        const login_part = if (self.health.logged_in[idx]) blk: {
            const nick = self.health.nickname[idx];
            break :blk if (nick.len > 0)
                std.fmt.allocPrint(a, "已登录 {s}", .{nick}) catch "已登录"
            else
                "已登录";
        } else "未登录 (L)";
        return std.fmt.allocPrint(a, "音源 {s} · {s}", .{ self.backend.label(), login_part }) catch "音源";
    }

    // ── 登录浮层渲染 ──

    /// 登录浮层。选择音源阶段悬浮在原界面上；扫码阶段保持整屏暗底
    /// （二维码要突出的焦点场景，用户点名保留）。
    fn renderLoginCard(self: *const Model, a: Allocator, w: usize, h: usize, frame: []const u8) ?[]const u8 {
        const lf = self.login orelse return null;
        var lines: std.ArrayList([]const u8) = .empty;

        if (lf.phase == .choose) {
            lines.append(a, "") catch {};
            lines.append(a, theme.inlineBold(theme.text).render(a, "  1  波点（扫码登录）") catch "") catch {};
            lines.append(a, theme.inlineBold(theme.text).render(a, "  2  网易云（扫码登录）") catch "") catch {};
            lines.append(a, theme.inlineBold(theme.text).render(a, "  3  QQ音乐（扫码登录）") catch "") catch {};
            lines.append(a, "") catch {};
            lines.append(a, theme.note().render(a, "  数字键选择 · Esc 取消") catch "") catch {};
            if (lf.message) |msg| {
                lines.append(a, "") catch {};
                lines.append(a, theme.warnInline().render(a, std.fmt.allocPrint(a, "  {s}", .{msg}) catch "") catch "") catch {};
            }
            const card_w = @min(w -| 4, 56);
            const card_txt = widgets.card(a, card_w, "登录 · 选择音源", lines.items);
            return centerFloat(a, frame, card_txt, w, h);
        }

        // qr 阶段
        const qr = lf.qr orelse {
            const card_w = @min(w -| 4, 56);
            const card_txt = widgets.card(a, card_w, std.fmt.allocPrint(a, "登录 · {s}", .{lf.backend.label()}) catch "登录", &.{"正在获取二维码…"});
            return overlay(a, widgets.blankFrame(a, w, h), card_txt, w, h, card_w, zz.height(card_txt));
        };

        // 二维码：半块字符渲染（▀/▄/█），fg=黑模块、bg=白底。
        // 四周必须留 ≥4 模块的白色静区（quiet zone），否则手机相机无法
        // 定位——此前二维码直接贴着深色卡片背景，怎么都扫不出来。
        const qr_st = theme.inlineOn(zz.Color.color256(16), zz.Color.color256(231));
        const quiet: u32 = 4;
        var pad_buf: [192]u8 = undefined;
        @memset(&pad_buf, ' ');
        const pad_txt = pad_buf[0..@min(qr.size + 2 * quiet, pad_buf.len)];
        const quiet_row = if (pad_txt.len > 0) qr_st.render(a, pad_txt) catch "" else "";
        var y: u32 = 0;
        while (y < qr.size + 2 * quiet) : (y += 2) {
            var row_buf: std.Io.Writer.Allocating = .init(a);
            if (y < quiet or y >= qr.size + quiet) {
                // 静区行：整行白底
                if (quiet_row.len > 0) lines.append(a, quiet_row) catch {};
                continue;
            }
            var q: u32 = 0;
            while (q < quiet) : (q += 1) row_buf.writer.writeByte(' ') catch {};
            var x: u32 = 0;
            while (x < qr.size) : (x += 1) {
                const top = qr.rows[y - quiet][x] == '1';
                const bottom = if (y + 1 < qr.size + quiet and y + 1 >= quiet)
                    qr.rows[y + 1 - quiet][x] == '1'
                else
                    false;
                const ch: []const u8 = if (top and bottom)
                    "█"
                else if (top)
                    "▀"
                else if (bottom)
                    "▄"
                else
                    " ";
                row_buf.writer.writeAll(ch) catch {};
            }
            q = 0;
            while (q < quiet) : (q += 1) row_buf.writer.writeByte(' ') catch {};
            lines.append(a, qr_st.render(a, row_buf.written()) catch "") catch {};
        }
        lines.append(a, "") catch {};
        lines.append(a, theme.note().render(a, std.fmt.allocPrint(a, "  用 {s} App 扫码 · Esc 取消", .{lf.backend.label()}) catch "") catch "") catch {};
        if (lf.message) |msg| {
            lines.append(a, theme.warnInline().render(a, std.fmt.allocPrint(a, "  {s}", .{msg}) catch "") catch "") catch {};
        }

        const card_w = @min(w -| 4, qr.size + 12);
        const title = std.fmt.allocPrint(a, "登录 · {s}（扫码）", .{lf.backend.label()}) catch "登录";
        const card_txt = widgets.card(a, card_w, title, lines.items);
        return overlay(a, widgets.blankFrame(a, w, h), card_txt, w, h, card_w, zz.height(card_txt));
    }

    fn miniLyrics(self: *const Model, a: Allocator, w: usize, rows: usize) []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        const lyr = self.lyrics orelse {
            var i: usize = 0;
            while (i < rows) : (i += 1) lines.append(a, widgets.fit(a, "", w, null)) catch {};
            return zz.joinVertical(a, lines.items) catch "";
        };
        const cur = lyr.currentIndex(self.pos_ms);
        const center_idx: usize = cur orelse 0;
        // 以当前行为中心取 rows 行
        const half = rows / 2;
        var start: usize = 0;
        if (center_idx > half) start = center_idx - half;
        var i: usize = 0;
        while (i < rows) : (i += 1) {
            const li = start + i;
            if (li < lyr.lines.len) {
                const line = lyr.lines[li];
                const is_cur = (cur != null and li == cur.?);
                const txt = zz.measure.truncate(a, line.text, w -| 2) catch line.text;
                if (is_cur) {
                    const styled = theme.inlineBold(theme.pink).render(a, std.fmt.allocPrint(a, "♪ {s}", .{txt}) catch "") catch "";
                    lines.append(a, centerText(a, styled, w)) catch {};
                } else {
                    const styled = theme.inlineStyle(theme.dim).render(a, txt) catch "";
                    lines.append(a, centerText(a, styled, w)) catch {};
                }
            } else {
                lines.append(a, widgets.fit(a, "", w, null)) catch {};
            }
        }
        return zz.joinVertical(a, lines.items) catch "";
    }
};

fn centerText(a: Allocator, s: []const u8, w: usize) []const u8 {
    return zz.place.placeHorizontal(a, w, .center, s) catch s;
}

/// 把卡片叠在整帧中央（LayerStack 合成）
/// 浮层合成：把 card 盖在纯色底帧（widgets.blankFrame）正中。
/// 不走 zigzag LayerStack——其 SGR 状态是“整段替换”而非累积，fg/bg
/// 拆成两段序列的样式合成后前景色会丢（二维码/封面会花）。
/// 既然底帧是纯色，就不做逐 cell 合成：每行 = 左底色段 + 卡片行 + 右底色段。
/// overlay 的定位版：卡片放在 (x0,y0) 而非居中（右键菜单用）。
/// base 必须是 blankFrame 之类的均质底——按行拼 bg 色块，不做样式切片。
/// 渲染帧实际使用的歌词窗口几何（view 时写入，点击/滚轮时读取）。
/// 全局而非 Model 字段：view 是 *const，且单窗口单线程 UI 只有一份。
/// 播放中 pos 持续前进，若点击时重算窗口，看到的行和点到的行会差一两名。
var s_lyr_win: LyrWin = .{};

pub const LyrWin = struct {
    start: i64 = 0,
    y0: usize = 0,
    x0: usize = 0,
    x1: usize = 0,
    h: usize = 0,
};

/// 把 card 悬浮到 base 的 (x0,y0)。卡片占用的列被覆盖，同一行左右两侧
/// 的底帧内容原样保留（按显示列带样式切分原行），其余行不动。
/// 不用 LayerStack：底帧全角字符跨越卡片列边界时会留下空 continuation
/// cell，render 跳过它们导致整行左移错位（实测）。
fn floatingAt(a: Allocator, base: []const u8, card_txt: []const u8, w: usize, h: usize, x0: usize, y0: usize) []const u8 {
    const cw = zz.width(firstLine(card_txt));
    const x1 = @min(x0 + cw, w);
    var lines: std.ArrayList([]const u8) = .empty;
    var base_it = std.mem.splitScalar(u8, base, 10);
    var card_it = std.mem.splitScalar(u8, card_txt, 10);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        const base_line = base_it.next() orelse "";
        if (row < y0 or row >= y0 + zz.height(card_txt)) {
            lines.append(a, base_line) catch return base;
            continue;
        }
        const card_line = card_it.next() orelse "";
        const cut = cutRow(a, base_line, x0, x1);
        // 后缀按剩余列宽收敛（切点在宽字符上时可能有 ±1 偏差）
        const suffix_fit = zz.measure.truncate(a, cut.suffix, w -| x1) catch cut.suffix;
        const suffix_pad = padTo(a, suffix_fit, w -| x1);
        lines.append(a, zz.joinHorizontal(a, &.{ cut.prefix, card_line, suffix_pad }) catch base_line) catch return base;
    }
    return zz.joinVertical(a, lines.items) catch base;
}

/// 居中的悬浮卡片（帮助/详情/加载/登录选择等非焦点浮层用）
fn centerFloat(a: Allocator, frame: []const u8, card_txt: []const u8, w: usize, h: usize) []const u8 {
    const bw = zz.width(firstLine(card_txt));
    const bh = zz.height(card_txt);
    const x0 = (w -| bw) / 2;
    const y0 = (h -| bh) / 2;
    return floatingAt(a, frame, card_txt, w, h, x0, y0);
}

fn firstLine(s: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, s, 10) orelse s.len;
    return s[0..i];
}

fn padTo(a: Allocator, s: []const u8, n: usize) []const u8 {
    const w = zz.width(s);
    if (w >= n) return s;
    return zz.joinHorizontal(a, &.{ s, widgets.blankSpaces(a, n - w) }) catch s;
}

const RowCut = struct { prefix: []const u8, suffix: []const u8 };

/// 按显示列把一行（含 ANSI 样式）切成两段。切点落在宽字符上时该字符
/// 让位成一个空格（宁可缺一格也不错位）；后缀自带切点处的样式状态。
fn cutRow(a: Allocator, line: []const u8, cut_a: usize, cut_b: usize) RowCut {
    var prefix: std.Io.Writer.Allocating = .init(a);
    var suffix: std.Io.Writer.Allocating = .init(a);
    var col: usize = 0;
    var i: usize = 0;
    var ansi: []const u8 = ""; // 当前生效的 SGR（跨切点带给后缀）
    var phase: enum { pre, mid, post } = .pre;
    while (i < line.len) {
        // ANSI 转义序列：整体归入当前段，不占列
        if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
            const start = i;
            i += 2;
            while (i < line.len and line[i] != 'm' and line[i] != 'H' and line[i] != 'J' and line[i] != 'K') : (i += 1) {}
            if (i < line.len) {
                i += 1;
                const seq = line[start..i];
                // reset 清状态，其余记为当前样式
                if (seq.len == 3 and seq[2] == '0') ansi = "" else ansi = seq;
                switch (phase) {
                    .pre => prefix.writer.writeAll(seq) catch {},
                    .post => suffix.writer.writeAll(seq) catch {},
                    .mid => {},
                }
            }
            continue;
        }
        const char_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const end = @min(i + char_len, line.len);
        const ch = line[i..end];
        const cp: u21 = std.unicode.utf8Decode(ch) catch line[i];
        const cw_ch: usize = switch (cp) {
            0...0x1F => 0,
            else => if (cp >= 0x1100 and (cp <= 0x115F or (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0xFF00 and cp <= 0xFF60) or cp >= 0xFFE0)) 2 else 1,
        };
        i = end;
        if (cw_ch == 0) continue;
        // 宽字符跨越切点：让位成空格
        if (cw_ch == 2 and (col + 1 == cut_a or col + 1 == cut_b)) {
            switch (phase) {
                .pre => prefix.writer.writeAll(" ") catch {},
                else => {},
            }
            col += 2;
        } else {
            switch (phase) {
                .pre => prefix.writer.writeAll(ch) catch {},
                .post => suffix.writer.writeAll(ch) catch {},
                .mid => {},
            }
            col += cw_ch;
        }
        if (phase == .pre and col >= cut_a) {
            phase = .mid;
        }
        if (phase == .mid and col >= cut_b) {
            // 后缀从切点处的样式状态继续（mid 区间的转义没进输出，
            // 但 ansi 一直跟着更新）
            phase = .post;
            suffix.writer.writeAll("\x1b[0m") catch {};
            suffix.writer.writeAll(ansi) catch {};
        }
    }
    return .{ .prefix = prefix.written(), .suffix = suffix.written() };
}

fn overlay(a: Allocator, base: []const u8, card_txt: []const u8, w: usize, h: usize, card_w: usize, card_h: usize) []const u8 {
    _ = base;
    const x0 = (w -| card_w) / 2;
    const y0 = (h -| card_h) / 2;
    const bg = zz.Color.color256(234); // 与 blankFrame 一致
    const left = widgets.bgSpan(a, x0, bg);
    const right = widgets.bgSpan(a, w -| x0 -| card_w, bg);
    const blank_line = widgets.bgSpan(a, w, bg);

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, card_txt, '\n');
    var row: usize = 0;
    while (row < h) : (row += 1) {
        if (row < y0 or row >= y0 + card_h) {
            lines.append(a, blank_line) catch return card_txt;
            continue;
        }
        const raw = it.next() orelse "";
        // 卡片行补齐/截到 card_w，两侧接底色（bgSpan 自带 bg，无空格透明问题）
        const cl = widgets.fit(a, raw, card_w, null);
        lines.append(a, zz.joinHorizontal(a, &.{ left, cl, right }) catch cl) catch return card_txt;
    }
    return zz.joinVertical(a, lines.items) catch card_txt;
}

/// 在 rows 里从 cur 出发走 delta 步，跳过不可选行；到头返回 null
fn moveSelectable(rows: []pages.Row, cur: u16, delta: i32) ?u16 {
    if (rows.len == 0) return null;
    var i: i64 = @intCast(@min(@as(usize, cur), rows.len - 1));
    const step: i64 = if (delta > 0) 1 else -1;
    var left: i64 = @abs(delta);
    while (left > 0) {
        i += step;
        if (i < 0 or i >= rows.len) return null;
        if (pages.selectable(rows[@intCast(i)])) left -= 1;
    }
    return @intCast(i);
}

// ── 无终端冒烟测试：zz.testing.Harness 驱动完整 Model-Update-View ──

const testing = std.testing;

test "冒烟：六页切换、搜索、播放进度与歌词、帮助与退出" {
    var h = try zz.testing.Harness(Model).initWithModel(
        testing.allocator,
        testing.io,
        .{ .mock_dir = "testdata/mock" },
        .{},
    );
    defer h.deinit();
    try h.start();
    try h.resize(100, 30);

    // 探索页：分节 + 每日推荐歌曲就位
    try testing.expect(try h.viewContains("AlloyMusic"));
    try testing.expect(try h.viewContains("推荐歌单"));
    try testing.expect(try h.viewContains("海阔天空"));

    // 播放界面（v 切换的全屏模式）：启动即有当前曲（每日推荐第一首），歌词从头显示
    try h.pressChar('v');
    try testing.expect(h.model.page == .now);
    try testing.expect(try h.viewContains("乐与怒"));
    try testing.expect(try h.viewContains("今天我"));

    // 播放 → 进度走到第一句之后 → 第一句被 ▶ 高亮
    try h.pressChar(' ');
    try h.advance(25 * std.time.ns_per_s);
    try testing.expect(h.model.playing);
    try testing.expect(h.model.pos_ms >= 25_000);
    const v = try h.view();
    try testing.expect(std.mem.indexOf(u8, v, "▶ 今天我") != null);

    // 进度条时间跳到 00:25
    try testing.expect(try h.viewContains("00:25"));

    // v 返回列表（回到进入前的探索页），数字键 3 = 我的喜欢
    try h.pressChar('v');
    try testing.expect(h.model.page == .explore);
    try h.pressChar('3');
    try testing.expect(h.model.page == .liked);

    // 搜索页：/ 聚焦、输入、回车出固定结果
    try h.pressChar('2');
    try h.pressChar('/');
    try testing.expect(try h.viewContains("⌕")); // 搜索框提示符
    try h.typeText("海阔");
    try testing.expect(try h.viewContains("海阔")); // 输入回显
    try h.press(.{ .key = .enter });
    try testing.expect(h.model.search_done);
    try testing.expect(try h.viewContains("演示模式"));
    try h.press(.{ .key = .escape }); // 退出输入框，数字键才不被吃掉

    // 队列页签
    try h.pressChar('4');
    try testing.expect(try h.viewContains("Enter 跳转播放"));

    // 详情：探索页歌单行 Enter 在主区展开，Esc 返回
    try h.pressChar('1');
    try h.press(.{ .key = .down });
    try h.press(.{ .key = .enter });
    try testing.expect(h.model.open_pl != null);
    try testing.expect(try h.viewContains("岁月神偷"));
    try h.press(.{ .key = .escape });
    try testing.expect(h.model.open_pl == null);

    // Tab 逐项循环：探索→搜索→喜欢→队列→我的歌单（入口态）
    try h.pressChar('1');
    inline for (0..4) |_| try h.press(.{ .key = .tab });
    try testing.expect(h.model.pl_picker);
    try testing.expect(!h.model.pl_open); // 入口态：还没展开歌单
    // Enter 进入：展开第一个歌单
    try h.press(.{ .key = .enter });
    try testing.expect(h.model.pl_open);
    try testing.expect(try h.viewContains("Esc 返回"));
    // Tab 在歌单间切换
    try h.press(.{ .key = .tab });
    try testing.expect(h.model.pl_open);
    // Esc 退回入口态，再 Esc 退出；入口态 Tab 回绕到页签 1
    try h.press(.{ .key = .escape });
    try testing.expect(!h.model.pl_open);
    try testing.expect(h.model.pl_picker);
    try h.press(.{ .key = .escape });
    try testing.expect(!h.model.pl_picker);

    // 帮助浮层 + 退出
    try h.pressChar('?');
    try testing.expect(try h.viewContains("帮助"));
    try h.pressChar('q'); // 关帮助
    try testing.expect(!h.model.help_visible);
    try h.pressChar('q'); // 退出
    try testing.expect(h.hasQuit());
}

test "冒烟：mock 目录缺失时给出可读错误而非崩溃" {
    var h = try zz.testing.Harness(Model).initWithModel(
        testing.allocator,
        testing.io,
        .{ .mock_dir = "testdata/no-such-dir" },
        .{},
    );
    defer h.deinit();
    try h.start();
    try h.resize(80, 24);
    try testing.expect(h.model.data.errors.items.len > 0);
    try testing.expect(try h.viewContains("FileNotFound"));
    // 各页仍可正常渲染（空态）
    try h.pressChar('3');
    try testing.expect(try h.viewContains("我的喜欢"));
}

test "冒烟：鼠标——侧栏切页/开歌单、点行选中、双击播放、信息行暂停、进度条 seek、滚轮" {
    var h = try zz.testing.Harness(Model).initWithModel(
        testing.allocator,
        testing.io,
        .{ .mock_dir = "testdata/mock" },
        .{},
    );
    defer h.deinit();
    try h.start();
    try h.resize(110, 32);

    // 110x32：mini=3，body_h=25；信息行 y=26、进度条 y=27；
    // 侧栏：0-3 页签、4 "我的歌单"、5.. 歌单行（鼠标 y 为 0 基屏幕行）
    // 点侧栏第 2 项（搜索）
    try h.mouse(.{ .x = 5, .y = 2, .button = .left, .event_type = .press });
    try testing.expect(h.model.page == .search);

    // 点侧栏"我的歌单"→ 进入选取模式；点第一个歌单行 → 主区展开歌曲列表
    try h.mouse(.{ .x = 5, .y = 5, .button = .left, .event_type = .press });
    try testing.expect(h.model.pl_picker);
    try h.mouse(.{ .x = 5, .y = 6, .button = .left, .event_type = .press });
    try testing.expect(h.model.open_pl != null);
    try testing.expect(try h.viewContains("Esc 返回"));

    // 单击第一首歌（body_row 3）→ 选中；紧接着再点一次（双击）→ 播放
    try h.mouse(.{ .x = 30, .y = 4, .button = .left, .event_type = .press });
    try testing.expect(h.model.detail.cursor == 0);
    try h.mouse(.{ .x = 30, .y = 4, .button = .left, .event_type = .press });
    try testing.expect(h.model.playing);

    // 点播放栏信息行 → 暂停
    try h.mouse(.{ .x = 60, .y = 26, .button = .left, .event_type = .press });
    try testing.expect(!h.model.playing);

    // 点进度条第 55 列 → seek 到约 51%
    try h.mouse(.{ .x = 55, .y = 27, .button = .left, .event_type = .press });
    try testing.expect(h.model.pos_ms > 100_000);

    // 滚轮：歌单视图内向下 → 游标 +1；release 不重复计数
    // （SGR 模式下真实终端一格滚轮会发 press+release 两个事件）
    const cur0 = h.model.detail.cursor;
    try h.mouse(.{ .x = 30, .y = 10, .button = .wheel_down, .event_type = .press });
    try testing.expect(h.model.detail.cursor == cur0 + 1);
    try h.mouse(.{ .x = 30, .y = 10, .button = .wheel_down, .event_type = .release });
    try testing.expect(h.model.detail.cursor == cur0 + 1);
    // 高分辨率滚轮连发（100ms 节流窗口内）：只吃第一发
    try h.mouse(.{ .x = 30, .y = 10, .button = .wheel_down, .event_type = .press });
    try testing.expect(h.model.detail.cursor == cur0 + 1);
    try h.mouse(.{ .x = 30, .y = 10, .button = .wheel_down, .event_type = .press });
    try testing.expect(h.model.detail.cursor == cur0 + 1);

    // Esc 关闭歌单视图（回到选取视图）
    try h.press(.{ .key = .escape });
    try testing.expect(h.model.open_pl == null);
    try testing.expect(h.model.pl_picker);
}

test "右键菜单：歌曲目标弹出三项、下一首播放插队、Esc 关闭" {
    var h = try zz.testing.Harness(Model).initWithModel(
        testing.allocator,
        testing.io,
        .{ .mock_dir = "testdata/mock" },
        .{},
    );
    defer h.deinit();
    try h.start();
    try h.resize(110, 32);
    // init 已把探索页 fm 灌进队列（q_index=0）
    try testing.expect(h.model.queue.items.len >= 2);

    // 切到队列页（init 已灌好歌），右键第一个歌曲行（body_row 3 → 屏幕行 4）
    try h.pressChar('4');
    try h.mouse(.{ .x = 30, .y = 4, .button = .right, .event_type = .press });
    try testing.expect(h.model.ctx_menu != null);
    try testing.expect(h.model.ctx_menu.?.song != null);
    try testing.expectEqual(@as(usize, 3), h.model.ctxActionCount());

    // ↓ 移到“下一首播放”再 Enter：应插到当前歌（下标 0）后面
    const len_before = h.model.queue.items.len;
    const menu_song_id = h.model.ctx_menu.?.song.?.id;
    try h.press(.{ .key = .down });
    try h.press(.{ .key = .enter });
    try testing.expect(h.model.ctx_menu == null);
    try testing.expectEqual(len_before + 1, h.model.queue.items.len); // 队列 +1
    // 被点的歌插到了当前歌（下标 0）后面
    try testing.expect(std.mem.eql(u8, h.model.queue.items[1].id, menu_song_id));

    // 右键另一个歌单行/页签区域不弹菜单：点页签行
    try h.mouse(.{ .x = 5, .y = 1, .button = .right, .event_type = .press });
    try testing.expect(h.model.ctx_menu == null);

    // 再右键第二个歌曲行，Esc 关闭
    try h.mouse(.{ .x = 30, .y = 5, .button = .right, .event_type = .press });
    try testing.expect(h.model.ctx_menu != null);
    try h.press(.{ .key = .escape });
    try testing.expect(h.model.ctx_menu == null);
}

test "歌词页：当前行居中跟随、↑↓ 选句 Enter 跳进度、滚轮浏览 3 秒回归" {
    var h = try zz.testing.Harness(Model).initWithModel(
        testing.allocator,
        testing.io,
        .{ .mock_dir = "testdata/mock" },
        .{},
    );
    defer h.deinit();
    try h.start();
    try h.resize(110, 32);
    // 播放并进到歌中段
    try h.pressChar('4');
    try h.press(.{ .key = .enter });
    try h.pressChar('v');
    try h.advance(120 * std.time.ns_per_s);
    try testing.expect(h.model.lyr_browse == null); // 默认跟随

    // ↑ 选上一句（◇），浏览窗口跟随
    try h.press(.{ .key = .up });
    try testing.expect(h.model.lyr_sel != null);

    // Enter 跳到选中句时间
    h.nextFrame(0); // 渲染一帧，缓存窗口几何
    const lv = pages.lyricView(h.model.arena(), &h.model, h.model.lyrH());
    const sel = h.model.lyr_sel.?;
    if (sel < lv.rows.len) {
        const want = pages.lyricRowMs(&h.model, lv, sel).?;
        try h.press(.{ .key = .enter });
        try testing.expect(h.model.pos_ms == @as(u32, @intCast(want)));
        try testing.expect(h.model.lyr_sel == null); // 跳完回到跟随
    }

    // 滚轮浏览：lyr_browse 生效
    try h.mouse(.{ .x = 60, .y = 10, .button = .wheel_up, .event_type = .press });
    try testing.expect(h.model.lyr_browse != null);

    // 3 秒无操作 → 回归跟随
    try h.advance(3100 * std.time.ns_per_ms);
    try testing.expect(h.model.lyr_browse == null);
    try testing.expect(h.model.lyr_sel == null);
}
