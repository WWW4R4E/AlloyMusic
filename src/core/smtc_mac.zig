// src/core/smtc_mac.zig — macOS SMTC（Now Playing）进程内实现。
//
// macOS 没有 Windows MC.dll 那个"进程内 fire 必崩"的 UAF，无需 relay
// 中转：直接在 amtui 进程内经 objc_msgSend 调 MediaPlayer 框架。
// 协议层与 Windows relay 共享（smtc.zig 的请求槽 + 位标志），底层从
// "写 TCP"换成 msgSend。链接要求：MediaPlayer framework + libobjc
// （vendor/Frameworks/ 下的 .tbd 存根，见 build.zig macos 分支）。
//
// 风险备忘：selector 拼写/类型错误运行时才暴露；本文件所有 selector
// 已对照 Apple 文档拼写，真机验收看菜单栏控制中心。

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const smtc = @import("smtc.zig");

const g_btn_flags = smtc.g_btn_flags_pub;
const TIMELINE_MIN_MS: i64 = 500;

var g_center: objc.Id = null;
var g_commands_ready = false;
var g_quit = std.atomic.Value(bool).init(false);
var g_last_tl_ms: i64 = 0;
var g_thread: ?std.Thread = null;

/// 0.17 无库层可用的跨平台 sleep/event，worker 用 usleep 轮询
extern "c" fn usleep(usec: u32) i32;

const Timeval = extern struct { sec: isize, usec: isize };
extern "c" fn gettimeofday(tv: *Timeval, tz: ?*anyopaque) i32;

fn nowMs() i64 {
    var tv: Timeval = undefined;
    _ = gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

// ── 请求槽（与 smtc.zig 同构；独立一份避免和 Windows 路径共享全局）──
const TrackReq = struct {
    pending: bool = false,
    title: [160]u8 = undefined,
    title_len: u16 = 0,
    artist: [160]u8 = undefined,
    artist_len: u16 = 0,
    album: [160]u8 = undefined,
    album_len: u16 = 0,
    cover: [768]u8 = undefined,
    cover_len: u16 = 0,
};
const PauseReq = struct { pending: bool = false, paused: bool = false };
const TimelineReq = struct { pending: bool = false, pos_s: f64 = 0, dur_s: f64 = 0 };

var g_mutex: std.atomic.Mutex = .unlocked;
var g_track: TrackReq = .{};
var g_pause: PauseReq = .{};
var g_timeline: TimelineReq = .{};

pub fn attach(io: std.Io) void {
    g_io = io;
    if (g_thread != null) return;
    g_quit.store(false, .release);
    objcSetup();
    g_thread = std.Thread.spawn(.{}, workerMain, .{}) catch return;
}

pub fn detach() void {
    g_quit.store(true, .release);
    if (g_thread) |t| t.join();
    g_thread = null;
    // 清 Now Playing 卡片
    if (g_center != null) setInfo(null);
}

pub fn setTrackMeta(title: []const u8, artist_: []const u8, album: []const u8, cover_url: []const u8) void {
    if (g_thread == null) return;
    while (!g_mutex.tryLock()) std.atomic.spinLoopHint();
    defer g_mutex.unlock();
    g_track = .{};
    g_track.title_len = @intCast(@min(title.len, g_track.title.len));
    @memcpy(g_track.title[0..g_track.title_len], title[0..g_track.title_len]);
    g_track.artist_len = @intCast(@min(artist_.len, g_track.artist.len));
    @memcpy(g_track.artist[0..g_track.artist_len], artist_[0..g_track.artist_len]);
    g_track.album_len = @intCast(@min(album.len, g_track.album.len));
    @memcpy(g_track.album[0..g_track.album_len], album[0..g_track.album_len]);
    g_track.cover_len = @intCast(@min(cover_url.len, g_track.cover.len));
    @memcpy(g_track.cover[0..g_track.cover_len], cover_url[0..g_track.cover_len]);
    g_track.pending = true;
}

pub fn setPaused(paused: bool) void {
    if (g_thread == null) return;
    while (!g_mutex.tryLock()) std.atomic.spinLoopHint();
    defer g_mutex.unlock();
    g_pause = .{ .pending = true, .paused = paused };
}

pub fn pump(pos_s: f64, dur_s: f64) void {
    if (g_thread == null) return;
    while (!g_mutex.tryLock()) std.atomic.spinLoopHint();
    defer g_mutex.unlock();
    if (g_track.pending or g_pause.pending) return; // 事件类请求优先（同 Windows 语义）
    g_timeline = .{ .pending = true, .pos_s = pos_s, .dur_s = dur_s };
}

pub fn takeButton() ?smtc.MediaButton {
    const flags = g_btn_flags.swap(0, .acq_rel);
    if (flags & 1 != 0) return .play_pause;
    if (flags & 2 != 0) return .next;
    if (flags & 4 != 0) return .prev;
    return null;
}

// ── worker 线程：等请求 → objc 应用 ──
fn workerMain() void {
    var track: TrackReq = .{};
    var pause: PauseReq = .{};
    var tl: TimelineReq = .{};
    while (!g_quit.load(.acquire)) {
        _ = usleep(50_000); // 50ms 轮询：按键走 block 即时通道，不受此延迟影响
        if (g_quit.load(.acquire)) break;
        while (!g_mutex.tryLock()) std.atomic.spinLoopHint();
        if (g_track.pending) {
            track = g_track;
            g_track.pending = false;
        } else track.pending = false;
        if (g_pause.pending) {
            pause = g_pause;
            g_pause.pending = false;
        } else pause.pending = false;
        if (g_timeline.pending) {
            tl = g_timeline;
            g_timeline.pending = false;
        } else tl.pending = false;
        g_mutex.unlock();
        if (!track.pending and !pause.pending and !tl.pending) continue;

        if (track.pending) {
            applyTrack(track.title[0..track.title_len], track.artist[0..track.artist_len], track.album[0..track.album_len]);
            if (track.cover_len > 0) applyArtwork(track.cover[0..track.cover_len]);
        }
        if (tl.pending) {
            const now = nowMs();
            if (now -| g_last_tl_ms < TIMELINE_MIN_MS) continue;
            g_last_tl_ms = @intCast(@max(now, 0));
            g_tl_pos = tl.pos_s;
            g_tl_dur = tl.dur_s;
            g_tl_dirty = true;
            pushInfo();
        }
        if (pause.pending) {
            g_paused = pause.paused;
            pushInfo();
        }
    }
}

var g_paused = true;
var g_tl_pos: f64 = 0;
var g_tl_dur: f64 = 0;
var g_tl_dirty = false;
var g_now_title: [256]u8 = undefined;
var g_now_title_len: usize = 0;
var g_now_artist: [256]u8 = undefined;
var g_now_artist_len: usize = 0;
var g_now_album: [256]u8 = undefined;
var g_now_album_len: usize = 0;
var g_artwork: objc.Id = null;
var g_artwork_img: objc.Id = null; // requestHandler block 的返回值缓存
var g_pa = std.heap.page_allocator;
var g_io: std.Io = undefined;

// ── objc 层 ──
const NSString = objc.Id;

fn nsString(s: []const u8) NSString {
    // stringWithUTF8String 需 0 结尾：页分配器拷贝（生命周期到进程尾，
    // 系统侧持有的字符串由其自身管理，这里泄漏级大小可接受）
    var buf = g_pa.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(buf[0..s.len], s);
    return objc.send(fn (objc.Class, objc.Sel, [*:0]const u8) callconv(.c) NSString)(
        objc.getClass("NSString"), objc.sel("stringWithUTF8String:"), buf.ptr);
}

fn nsNumber(v: f64) objc.Id {
    return objc.send(fn (objc.Class, objc.Sel, f64) callconv(.c) objc.Id)(
        objc.getClass("NSNumber"), objc.sel("numberWithDouble:"), v);
}

fn setInfo(dict: objc.Id) void {
    objc.send(fn (objc.Id, objc.Sel, objc.Id) callconv(.c) void)(
        g_center, objc.sel("setNowPlayingInfo:"), @as(objc.Id, dict));
}

fn applyTrack(t: []const u8, a: []const u8, al: []const u8) void {
    g_now_title_len = @min(t.len, g_now_title.len);
    @memcpy(g_now_title[0..g_now_title_len], t[0..g_now_title_len]);
    g_now_artist_len = @min(a.len, g_now_artist.len);
    @memcpy(g_now_artist[0..g_now_artist_len], a[0..g_now_artist_len]);
    g_now_album_len = @min(al.len, g_now_album.len);
    @memcpy(g_now_album[0..g_now_album_len], al[0..g_now_album_len]);
    g_artwork = null; // 新歌先清封面，等下载（对齐 Windows 语义）
    g_tl_pos = 0; // 新歌归零（对齐 Windows 语义）
    pushInfo();
}

/// 下载封面（worker 线程内阻塞，串行无并发 std.http——README 的死锁是
/// 并发 fetch，单 worker 单请求不受影响），NSData → NSImage → 挂进
/// 下一次 pushInfo 的字典。
fn applyArtwork(url: []const u8) void {
    var client = std.http.Client{ .allocator = g_pa, .io = g_io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(g_pa);
    defer aw.deinit();
    _ = client.fetch(.{
        .location = .{ .url = g_pa.dupe(u8, url) catch return },
        .method = .GET,
        .response_writer = &aw.writer,
    }) catch return;
    const body = aw.written();
    if (body.len == 0) return;

    const data = objc.send(fn (objc.Class, objc.Sel, [*]const u8, usize) callconv(.c) objc.Id)(
        objc.getClass("NSData"), objc.sel("dataWithBytes:length:"), body.ptr, body.len);
    if (data == null) return;
    const img = objc.send(fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id)(
        data, objc.sel("initWithData:"), data);
    if (img == null) return;
    g_artwork_img = img;
    // [[MPMediaItemArtwork alloc] initWithBoundsSize:requestHandler:]
    const art = objc.send(fn (objc.Id, objc.Sel, CGSize, *objc.Block) callconv(.c) objc.Id)(
        objc.send(fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
            objc.getClass("MPMediaItemArtwork"), objc.sel("alloc")),
        objc.sel("initWithBoundsSize:requestHandler:"),
        .{ .w = 600, .h = 600 },
        &ArtBlock.inst);
    g_artwork = art; // handler 闭包引用 g_artwork_img
}

// artwork 的 requestHandler block：签名 (CGSize) -> NSImage，
// 系统随时回调取图——直接返回缓存的 g_artwork_img。
const CGSize = extern struct { w: f64, h: f64 };
const ArtBlock = struct {
    const desc = objc.BlockDescriptor{ .size = @sizeOf(objc.Block) };
    var inst = objc.Block{
        .isa = objc.block_isa,
        .invoke = &inv,
        .descriptor = &desc,
    };
    fn inv(_b: *objc.Block, size: CGSize) callconv(.c) objc.Id {
        _ = _b;
        _ = size;
        return g_artwork_img;
    }
};

// ── Now Playing 字典组装（应用状态 → NSMutableDictionary）──
fn pushInfo() void {
    if (g_center == null) return;
    const dict = objc.send(fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.getClass("NSMutableDictionary"), objc.sel("dictionary"));
    const k_title = nsString("title");
    const k_artist = nsString("artist");
    const k_album = objc.send(fn (objc.Class, objc.Sel, [*:0]const u8) callconv(.c) NSString)(
        objc.getClass("NSString"), objc.sel("stringWithUTF8String:"), "album");
    setObj(dict, k_title, nsString(g_now_title[0..g_now_title_len]));
    setObj(dict, k_artist, nsString(g_now_artist[0..g_now_artist_len]));
    setObj(dict, k_album, nsString(g_now_album[0..g_now_album_len]));
    setObj(dict, nsString("duration"), nsNumber(g_tl_dur));
    const drift: f64 = if (g_paused) 0 else -g_last_update_s();
    setObj(dict, nsString("elapsed"), nsNumber(@max(0, g_tl_pos + drift)));
    setObj(dict, nsString("rate"), nsNumber(if (g_paused) 0 else 1));
    if (g_artwork) |art| setObj(dict, nsString("artwork"), art);
    setInfo(dict);
}

var g_last_push_ms: i64 = 0;
fn g_last_update_s() f64 {
    const now: f64 = @floatFromInt(nowMs());
    const last: f64 = @floatFromInt(g_last_push_ms);
    return @max(0, now - last) / 1000;
}

fn setObj(dict: objc.Id, key: objc.Id, value: objc.Id) void {
    objc.send(fn (objc.Id, objc.Sel, objc.Id, objc.Id) callconv(.c) void)(
        dict, objc.sel("setObject:forKey:"), value, key);
}

fn objcSetup() void {
    g_center = objc.send(fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.getClass("MPNowPlayingInfoCenter"), objc.sel("defaultCenter"));
    if (g_center == null or g_commands_ready) return;
    const cc = objc.send(fn (objc.Class, objc.Sel) callconv(.c) objc.Id)(
        objc.getClass("MPRemoteCommandCenter"), objc.sel("sharedCommandCenter"));
    if (cc == null) return;
    inline for (.{
        .{ "togglePlayPauseCommand", @as(i64, 0) },
        .{ "playCommand", @as(i64, 0) },
        .{ "pauseCommand", @as(i64, 1) },
        .{ "nextTrackCommand", @as(i64, 6) },
        .{ "previousTrackCommand", @as(i64, 7) },
    }) |pair| {
        const cmd = objc.send(fn (objc.Id, objc.Sel) callconv(.c) objc.Id)(cc, objc.sel(pair[0]));
        if (cmd != null) {
            const blk = objc.commandBlock(objc.Id, pair[1], onCommand);
            _ = objc.send(fn (objc.Id, objc.Sel, *objc.Block) callconv(.c) objc.Id)(
                cmd, objc.sel("addTarget:"), blk);
        }
    }
    g_commands_ready = true;
}

fn onCommand(n: i64, event: objc.Id) void {
    _ = event;
    switch (n) {
        0 => _ = g_btn_flags.fetchOr(1, .acq_rel),
        6 => _ = g_btn_flags.fetchOr(2, .acq_rel),
        7 => _ = g_btn_flags.fetchOr(4, .acq_rel),
        else => {},
    }
}
