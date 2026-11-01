const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const providers = @import("../core/providers/mod.zig");
const lyrics_mod = @import("lyrics.zig");

// src/ui/provider.zig — 数据提供方（取代 mock.zig 的翻译点角色，mock 仅离线测试用）。
//
// 职责：后台线程里直调 core/providers（三源纯 Zig）→ 把统一 JSON 翻译成
// ui/model 类型 → 结果经 Mailbox 投回主线程。所有产物分配在请求专属的
// ArenaAllocator 上，整个 arena 随 Outcome 交接；主线程消费后持有 arena，
// 同槽位替换时释放旧 arena —— 天然无锁、无拷贝。
//
// 线程模型（zigzag 是同步 update，卡住 update = 卡住界面）：
//   update() 里调 kick() 派后台线程；每次 update 开头 drain() 收结果。
//   单槽信箱：同槽位新结果覆盖旧结果（worker 覆盖时释放旧 arena）。

pub const Backend = model.Backend;

// ── 产物类型（切片全部在 outcome.arena 上）──

pub const SongPage = struct {
    songs: []model.Song,
    has_more: bool = false,
};

pub const Explore = struct {
    fm: []model.Song = &.{},
    recommend: []model.Playlist = &.{},
};

pub const Detail = struct {
    playlist: model.Playlist = .{},
    songs: []model.Song = &.{},
};

pub const PlayUrl = struct {
    url: []const u8,
    preview_start_ms: ?u32 = null,
    preview_end_ms: ?u32 = null,
};

pub const LoginState = enum {
    waiting,
    scanned,
    expired,
    confirmed,
};

pub const LoginQr = struct {
    key: []const u8,
    url: []const u8,
    size: u32,
    /// 每行一个 '0'/'1' 串，size×size
    rows: [][]const u8,
};

pub const LoginCheck = struct {
    state: LoginState,
    nickname: []const u8 = "",
};

pub const Library = struct {
    owned: []model.Playlist = &.{},
    collected_playlists: []model.Playlist = &.{},
    collected_albums: []model.Playlist = &.{},
};

pub const Health = struct {
    /// 与 Backend 枚举序对齐：[bodian, netease, qq]
    logged_in: [3]bool = @splat(false),
    nickname: [3][]const u8 = @splat(""),
};

/// 封面像素（RGB，行优先，len = w*h*3），half-block 渲染用
pub const Cover = struct {
    w: u32,
    h: u32,
    pixels: []u8,
};

pub const Kind = enum {
    search,
    explore,
    detail,
    lyrics,
    play_url,
    health,
    library,
    login_qr,
    login_check,
    cover,
    liked,
    /// 电台流：netease=心动模式(id 种子)、qq=刷歌(种子上游不支持，回落)、
    /// bodian=私人推荐(无种子)。种子能力差异在 sidecar 层吸收。
    radio,
    /// 喜欢/取消喜欢（job.like 带目标状态）。netease=like 模块 + 我喜欢的歌单
    /// 删曲；bodian=like_song；qq 写接口上游未对接，返回 unsupported。
    like,
};

pub const Ok = union(Kind) {
    search: SongPage,
    explore: Explore,
    detail: Detail,
    lyrics: lyrics_mod.Lyrics,
    play_url: PlayUrl,
    health: Health,
    library: Library,
    login_qr: LoginQr,
    login_check: LoginCheck,
    cover: Cover,
    liked: []model.Song,
    radio: []model.Song,
    like: bool,
};

pub const Outcome = struct {
    arena: *std.heap.ArenaAllocator,
    /// 派发时的 epoch：音源切换/新搜索后到达的旧结果按 stale 丢弃
    epoch: u64 = 0,
    /// Job 布尔参数的透传（play_url：true=预取下一首 append，false=当前歌）
    flag: bool = false,
    /// Mailbox 链表指针（push/take 维护）
    next: ?*Outcome = null,
    result: union(enum) {
        ok: Ok,
        err: struct { kind: Kind, message: []const u8 },
    },
};

// ── 单槽信箱 ──

pub const Mailbox = struct {
    gpa: Allocator,
    // 原子自旋锁（临界区极短；Io.Mutex 需要 io 参数，不便跨线程用）
    locked: std.atomic.Value(bool) = .init(false),
    // 多槽链表：worker 逐个 push，主线程逐个 take——单槽会在主线程
    // 两次 drain 之间丢失后到的结果（实测 explore 被 health 覆盖）
    head: ?*Outcome = null,
    tail: ?*Outcome = null,

    pub fn init(gpa: Allocator) Mailbox {
        return .{ .gpa = gpa };
    }

    fn acquire(self: *Mailbox) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn release(self: *Mailbox) void {
        self.locked.store(false, .release);
    }

    /// worker 调：追加到队尾。结果绝不互相覆盖。
    pub fn push(self: *Mailbox, outcome: *Outcome) void {
        outcome.next = null;
        self.acquire();
        defer self.release();
        if (self.tail) |t| t.next = outcome else self.head = outcome;
        self.tail = outcome;
    }

    /// 主线程调：弹队头。取走后所有权归调用方（消费完调 free）。
    pub fn take(self: *Mailbox) ?*Outcome {
        self.acquire();
        defer self.release();
        const s = self.head orelse return null;
        self.head = s.next;
        if (self.head == null) self.tail = null;
        s.next = null;
        return s;
    }

    /// 释放一个 Outcome（arena deinit + struct destroy）。主线程、worker 都可用。
    pub fn free(self: *Mailbox, o: *Outcome) void {
        o.arena.deinit();
        self.gpa.destroy(o.arena);
        self.gpa.destroy(o);
    }
};

// ── 请求派发 ──

pub const Job = struct {
    kind: Kind,
    backend: Backend,
    gpa: Allocator = undefined,
    io: std.Io = undefined,
    mb: *Mailbox = undefined,
    // 参数（切片来自调用方 arena/常量，跨线程只读）
    kw: []const u8 = "",
    id: []const u8 = "",
    mid: []const u8 = "",
    key: []const u8 = "",
    url: []const u8 = "",
    page: u32 = 0,
    source: ?u32 = null,
    /// like op 的目标状态（true=加红心 false=取消）
    like: bool = false,
    /// play_url 用途：false=当前歌（loadfile replace），true=预取下一首（append）
    append: bool = false,
    cover_w: u32 = 0,
    cover_h: u32 = 0,
    // execute 失败时带出人类可读 message（协议错误走这里，程序错误走 @errorName）
    err_message: []const u8 = "",
    /// 派发时的数据纪元（app 侧维护），随 Outcome 带回
    epoch: u64 = 0,
    next: ?*Job = null,

    fn run(self: *Job) void {
        const arena = self.gpa.create(std.heap.ArenaAllocator) catch {
            self.gpa.destroy(self);
            return;
        };
        arena.* = std.heap.ArenaAllocator.init(self.gpa);
        const a = arena.allocator();

        const outcome = self.gpa.create(Outcome) catch {
            arena.deinit();
            self.gpa.destroy(arena);
            self.gpa.destroy(self);
            return;
        };
        var result: @TypeOf(outcome.result) = undefined;
        if (self.execute(a)) |ok| {
            result = .{ .ok = ok };
        } else |e| {
            result = .{ .err = .{
                .kind = self.kind,
                .message = a.dupe(u8, if (self.err_message.len > 0) self.err_message else @errorName(e)) catch @errorName(e),
            } };
        }
        outcome.* = .{
            .arena = arena,
            .epoch = self.epoch,
            .flag = self.append,
            .result = result,
        };
        self.mb.push(outcome);
        self.gpa.destroy(self);
    }

    fn execute(self: *Job, a: Allocator) !Ok {
        switch (self.kind) {
            .search => {
                const r = try self.envelope(a, self.apiCall(a, "search", &.{
                    .{ .name = "kw", .value = self.kw },
                    .{ .name = "page", .value = try std.fmt.allocPrint(a, "{d}", .{self.page}) },
                    .{ .name = "size", .value = "50" },
                }));
                const songs = try parseSongs(a, r, self.backend);
                return .{ .search = .{ .songs = songs, .has_more = boolOf(r, "hasMore") } };
            },
            .explore => {
                // 两个请求串行（fm 失败不影响 recommend，反之亦然）
                var out = Explore{};
                if (self.apiCall(a, "fm", &.{})) |r| {
                    if (try self.maybeEnvelope(a, r)) |data| out.fm = try parseSongs(a, data, self.backend);
                } else |_| {}
                if (self.apiCall(a, "recommend", &.{})) |r| {
                    if (try self.maybeEnvelope(a, r)) |data| out.recommend = try parsePlaylists(a, data, self.backend);
                } else |_| {}
                return .{ .explore = out };
            },
            .detail => {
                const r = try self.envelope(a, self.apiCall(a, "playlist", &.{
                    .{ .name = "id", .value = self.id },
                }));
                var detail = Detail{};
                if (objField(r, "playlist")) |pl| {
                    detail.playlist = parsePlaylist(pl, self.backend) orelse .{ .id = self.id, .backend = self.backend };
                } else {
                    detail.playlist = .{ .id = self.id, .backend = self.backend };
                }
                const tr = self.apiCall(a, "playlistTracks", &.{
                    .{ .name = "id", .value = self.id },
                    .{ .name = "page", .value = "0" },
                    .{ .name = "size", .value = "50" },
                });
                if (tr) |r2| {
                    if (try self.maybeEnvelope(a, r2)) |data2| detail.songs = try parseSongs(a, data2, self.backend);
                } else |_| {}
                return .{ .detail = detail };
            },
            .lyrics => {
                const r = try self.envelope(a, self.apiCall(a, "lyrics", &.{
                    .{ .name = if (self.backend == .qq) "mid" else "id", .value = if (self.backend == .qq) self.mid else self.id },
                }));
                const lrc = strOf(r, "lrc") orelse return error.InvalidResponse;
                var lyrics = try lyrics_mod.parse(a, lrc);
                const tlyric = strOf(r, "tlyric") orelse "";
                if (tlyric.len > 0) mergeTranslations(a, &lyrics, tlyric) catch {};
                return .{ .lyrics = lyrics };
            },
            .play_url => {
                const r = try self.envelope(a, self.apiCall(a, "songUrl", &.{
                    .{ .name = if (self.backend == .qq) "mid" else "id", .value = if (self.backend == .qq) self.mid else self.id },
                }));
                const url = strOf(r, "url") orelse return error.InvalidResponse;
                var pu = PlayUrl{ .url = url };
                if (objField(r, "preview")) |p| {
                    pu.preview_start_ms = uintOf(p, "startMs");
                    pu.preview_end_ms = uintOf(p, "endMs");
                }
                return .{ .play_url = pu };
            },
            .library => {
                const r = try self.envelope(a, self.apiCall(a, "library", &.{}));
                var lib = Library{};
                if (arrField(r, "owned")) |v| lib.owned = try parsePlaylistsObj(a, v, self.backend);
                if (arrField(r, "collectedPlaylists")) |v| lib.collected_playlists = try parsePlaylistsObj(a, v, self.backend);
                if (arrField(r, "collectedAlbums")) |v| lib.collected_albums = try parsePlaylistsObj(a, v, self.backend);
                return .{ .library = lib };
            },
            .health => {
                // 进程内直读登录态（sidecar /health 本地化），序 [波点,网易,QQ]
                const src = try providers.health(a, self.io, providers.paths.authPath(self.io, a));
                var h = Health{};
                h.logged_in = src.logged_in;
                h.nickname = src.nickname;
                return .{ .health = h };
            },
            .login_qr => {
                const r = try self.envelope(a, self.apiCall(a, "loginQrKey", &.{}));
                const rows_field = arrField(r, "rows") orelse return error.InvalidResponse;
                var rows = try a.alloc([]const u8, rows_field.array.items.len);
                for (rows_field.array.items, 0..) |item, i| {
                    rows[i] = if (item == .string) item.string else "";
                }
                return .{ .login_qr = .{
                    .key = strOf(r, "key") orelse "",
                    .url = strOf(r, "url") orelse "",
                    .size = uintOf(r, "size") orelse 0,
                    .rows = rows,
                } };
            },
            .login_check => {
                const r = try self.envelope(a, self.apiCall(a, "loginQrCheck", &.{
                    .{ .name = "key", .value = self.key },
                }));
                const state_str = strOf(r, "state") orelse return error.InvalidResponse;
                const state = std.meta.stringToEnum(LoginState, state_str) orelse return error.InvalidResponse;
                var check = LoginCheck{ .state = state };
                if (objField(r, "user")) |u| {
                    check.nickname = strOf(u, "nickname") orelse "";
                }
                return .{ .login_check = check };
            },
            .liked => {
                const r = try self.envelope(a, self.apiCall(a, "liked", &.{
                    .{ .name = "size", .value = "100" },
                }));
                return .{ .liked = try parseSongs(a, r, self.backend) };
            },
            .radio => {
                // 种子：qq 用 songMid，netease 用数字 id，bodian 无参忽略
                const r = try self.envelope(a, self.apiCall(a, "radio", &.{
                    .{ .name = if (self.backend == .qq) "mid" else "id", .value = if (self.backend == .qq) self.mid else self.id },
                }));
                return .{ .radio = try parseSongs(a, r, self.backend) };
            },
            .like => {
                // 结果只回 ack；红心列表刷新由 app 侧再 kick .liked
                _ = try self.envelope(a, self.apiCall(a, "like", &.{
                    .{ .name = if (self.backend == .qq) "mid" else "id", .value = if (self.backend == .qq) self.mid else self.id },
                    .{ .name = "like", .value = if (self.like) "true" else "false" },
                }));
                return .{ .like = self.like };
            },
            .cover => {
                // 进程内直调（cover.cjs 移植）；失败带人类可读 message
                const cover_mod = @import("../core/cover.zig");
                const r = cover_mod.cover(self.gpa, self.io, a, self.url, self.cover_w, self.cover_h) catch |e| switch (e) {
                    error.Unsupported => {
                        self.err_message = a.dupe(u8, "仅允许音源图床地址（w/h 上限 640/1280）") catch "";
                        return error.SidecarError;
                    },
                    error.Network => {
                        self.err_message = a.dupe(u8, "封面下载失败") catch "";
                        return error.SidecarError;
                    },
                    error.InvalidResponse => {
                        self.err_message = a.dupe(u8, "封面解码失败（仅支持 JPEG/PNG）") catch "";
                        return error.SidecarError;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(r.pixels_b64) catch return error.InvalidResponse;
                if (n != @as(usize, r.w) * r.h * 3) return error.InvalidResponse;
                const px = try a.alloc(u8, n);
                dec.decode(px, r.pixels_b64) catch return error.InvalidResponse;
                return .{ .cover = .{ .w = r.w, .h = r.h, .pixels = px } };
            },
        }
    }

    /// provider 数据面统一入口：三源均已纯 Zig 直调（core/providers）。
    /// op/参数/返回 envelope 沿用 sidecar 时代的形状，调用点无感知。
    fn apiCall(self: *Job, a: Allocator, op: []const u8, params: []const providers.Param) !providers.Result(std.json.Value) {
        const name: providers.Name = switch (self.backend) {
            .bodian => .bodian,
            .netease => .netease,
            .qq => .qq,
            .mock => unreachable, // 演示模式不走 provider
        };
        return (try providers.call(self.gpa, self.io, a, name, op, params)).?;
    }

    /// 协议错误（Result.err）→ 记 message + error.SidecarError；程序错误（OOM 等）直接上抛。
    /// r 是 client.call 的返回（错误 union 包着 Result 信封），anytype 里逐层拆。
    fn envelope(self: *Job, a: Allocator, r: anytype) !std.json.Value {
        const v = try r;
        return switch (v) {
            .err => |e| {
                self.err_message = a.dupe(u8, e.message) catch e.message;
                return error.SidecarError;
            },
            .ok => |ok| ok,
        };
    }

    /// explore/detail 的容错变体（调用点已用 if-unwrap 拿到 Result）：
    /// 协议错误记 message 但返回 null，继续别的分节。
    fn maybeEnvelope(self: *Job, a: Allocator, r: providers.Result(std.json.Value)) !?std.json.Value {
        return switch (r) {
            .err => |e| {
                self.err_message = a.dupe(u8, e.message) catch e.message;
                return null;
            },
            .ok => |ok| ok,
        };
    }
};

// ── 串行取数队列 ──
//
// 实测并发多个 std.http.Client fetch 会偶发死锁（worker 全部 futex_wait，
// 与分配器/io 派发方式无关），改为单 worker 串行执行：kick 只入队，
// 队列线程逐个跑。慢请求（QQ 搜索风控退避）会短暂排队，可接受。

pub const FetchQueue = struct {
    gpa: Allocator,
    io: std.Io,
    mb: *Mailbox,
    locked: std.atomic.Value(bool) = .init(false),
    head: ?*Job = null,
    tail: ?*Job = null,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, io: std.Io, mb: *Mailbox) FetchQueue {
        return .{ .gpa = gpa, .io = io, .mb = mb };
    }

    /// 主线程调：入队 + 惰性启动队列线程（整个生命周期只有这一个 worker）。
    pub fn kick(self: *FetchQueue, job_in: Job) void {
        const j = self.gpa.create(Job) catch return;
        j.* = job_in;
        j.gpa = self.gpa;
        j.io = self.io;
        j.mb = self.mb;
        j.next = null;

        self.acquire();
        if (self.tail) |t| t.next = j else self.head = j;
        self.tail = j;
        const need_start = self.thread == null;
        self.release();

        if (need_start) {
            self.thread = std.Thread.spawn(.{}, queueLoop, .{self}) catch {
                // 起不了线程：同步兜底，直接在当前线程跑完这个 job
                self.acquire();
                const one = self.pop();
                self.release();
                if (one) |job| job.run();
                return;
            };
        }
    }

    fn pop(self: *FetchQueue) ?*Job {
        const j = self.head orelse return null;
        self.head = j.next;
        if (self.head == null) self.tail = null;
        return j;
    }

    fn acquire(self: *FetchQueue) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn release(self: *FetchQueue) void {
        self.locked.store(false, .release);
    }

    fn queueLoop(self: *FetchQueue) void {
        while (!self.stop.load(.acquire)) {
            var worked = false;
            self.acquire();
            const j = self.pop();
            self.release();
            if (j) |job| {
                worked = true;
                job.run();
            }
            if (!worked) {
                // 空转节流；stop 时尽快退出
                var slept: u32 = 0;
                while (slept < 20 and !self.stop.load(.acquire)) : (slept += 1) {
                    var req: std.os.linux.timespec = .{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
                    _ = std.os.linux.nanosleep(&req, null);
                    self.acquire();
                    const more = self.head != null;
                    self.release();
                    if (more) break;
                }
            }
        }
    }

    pub fn deinit(self: *FetchQueue) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        // 清掉没跑的任务
        self.acquire();
        var j = self.head;
        while (j) |job| {
            const next = job.next;
            self.gpa.destroy(job);
            j = next;
        }
        self.head = null;
        self.tail = null;
        self.release();
    }
};

// ── JSON → model 翻译 ──

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn objField(v: std.json.Value, key: []const u8) ?std.json.Value {
    const f = get(v, key) orelse return null;
    return if (f == .object) f else null;
}

fn arrField(v: std.json.Value, key: []const u8) ?std.json.Value {
    const f = get(v, key) orelse return null;
    return if (f == .array) f else null;
}

fn strOf(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn uintOf(v: std.json.Value, key: []const u8) ?u32 {
    const f = get(v, key) orelse return null;
    return switch (f) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        .float => |fl| if (fl >= 0 and fl == @trunc(fl) and fl <= std.math.maxInt(u32)) @intFromFloat(fl) else null,
        .string, .number_string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}

fn boolOf(v: std.json.Value, key: []const u8) bool {
    const f = get(v, key) orelse return false;
    return f == .bool and f.bool;
}

fn idString(a: Allocator, v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch null,
        else => null,
    };
}

fn parseSongs(a: Allocator, data: std.json.Value, backend: Backend) ![]model.Song {
    const list = arrField(data, "songs") orelse return &.{};
    var out: std.ArrayList(model.Song) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const id = idString(a, get(item, "id") orelse continue) orelse continue;
        const title = strOf(item, "title") orelse continue;
        var song = model.Song{
            .id = id,
            .title = title,
            .artist = strOf(item, "artist") orelse "未知歌手",
            .album = strOf(item, "album") orelse "未知专辑",
            .duration_s = uintOf(item, "durationS") orelse 0,
            .vip = boolOf(item, "vip"),
            .backend = backend,
        };
        if (strOf(item, "songMid")) |m| song.song_mid = m;
        if (strOf(item, "mediaMid")) |m| song.media_mid = m;
        if (strOf(item, "coverUrl")) |c| song.cover_url = c;
        try out.append(a, song);
    }
    return out.toOwnedSlice(a);
}

/// 数组本体直接是歌单列表（library 的 owned/collected* 字段）
fn parsePlaylistsObj(a: Allocator, arr: std.json.Value, backend: Backend) ![]model.Playlist {
    if (arr != .array) return &.{};
    var out: std.ArrayList(model.Playlist) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const pl = parsePlaylist(item, backend) orelse continue;
        out.append(a, pl) catch {};
    }
    return out.toOwnedSlice(a);
}

fn parsePlaylists(a: Allocator, data: std.json.Value, backend: Backend) ![]model.Playlist {
    const list = arrField(data, "playlists") orelse return &.{};
    var out: std.ArrayList(model.Playlist) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const pl = parsePlaylist(item, backend) orelse continue;
        try out.append(a, pl);
    }
    return out.toOwnedSlice(a);
}

fn parsePlaylist(v: std.json.Value, backend: Backend) ?model.Playlist {
    if (v != .object) return null;
    const id = strOf(v, "id") orelse return null;
    const kind_str = strOf(v, "kind") orelse "playlist";
    return .{
        .id = id,
        .name = strOf(v, "name") orelse "",
        .track_count = uintOf(v, "trackCount") orelse 0,
        .kind = if (std.mem.eql(u8, kind_str, "album")) .album else .playlist,
        .backend = backend,
    };
}

/// netease 独立翻译轨：按时间戳配对挂到主行（bodian 的翻译混在正文里，tlyric 恒空）
fn mergeTranslations(a: Allocator, lyrics: *lyrics_mod.Lyrics, tlyric: []const u8) !void {
    const trans = try lyrics_mod.parse(a, tlyric);
    for (trans.lines) |t| {
        for (lyrics.lines) |*line| {
            if (line.time_ms == t.time_ms and line.translation == null) {
                line.translation = t.text;
                break;
            }
        }
    }
}

// ── 离线测试 ──

test "parseSongs: 统一 schema 翻译进 model.Song" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const data = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{ "ok": true, "songs": [
        \\  { "id": "4835784", "backend": "qq", "songMid": "001yS0N33yPm1B", "title": "海阔天空",
        \\    "artist": "BEYOND", "album": "乐与怒", "durationS": 324, "vip": true },
        \\  { "id": 1357375695, "title": "海阔天空", "artist": "Beyond",
        \\    "album": "乐与怒", "durationS": 326, "vip": false }
        \\] }
    , .{});
    const songs = try parseSongs(a, data, .qq);
    try std.testing.expectEqual(@as(usize, 2), songs.len);
    try std.testing.expectEqualStrings("4835784", songs[0].id);
    try std.testing.expectEqualStrings("001yS0N33yPm1B", songs[0].song_mid);
    try std.testing.expect(songs[0].vip);
    try std.testing.expectEqual(Backend.qq, songs[0].backend);
    // 数字 id 翻译成字符串
    try std.testing.expectEqualStrings("1357375695", songs[1].id);
    try std.testing.expectEqual(Backend.qq, songs[1].backend);
}

test "mergeTranslations: 按时间戳配对" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var lyrics = try lyrics_mod.parse(a, "[00:01.00]第一句\n[00:05.00]第二句");
    try mergeTranslations(a, &lyrics, "[00:01.00]line one");
    try std.testing.expectEqualStrings("line one", lyrics.lines[0].translation.?);
    try std.testing.expect(lyrics.lines[1].translation == null);
}
