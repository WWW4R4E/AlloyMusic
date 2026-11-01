// src/core/api_server.zig — 内嵌 loopback HTTP API：第三方（OBS/桌面组件/脚本）
// 取当前播放歌的元数据、进度和歌词。监听 127.0.0.1（AM_API_PORT，默认 8790，
// 0 = 关闭；端口被占静默降级，绝不影响播放器本体）。
//
// 并发模型 = 快照法：UI 线程把当前状态 dupe 进 Snapshot（自旋锁保护），
// HTTP 线程只在锁内把 JSON 拼进请求专属 arena、放锁后写出。HTTP 线程
// 永不持有 Model 的指针——Model 的 arena 会被 outcome 交接换掉，pos_ms
// 每帧都在变，直接读会撕裂。
//
// 端点：
//   GET /now     JSON 快照（state/seq/position_ms/song/lyrics）
//   GET /lyrics  纯 LRC 文本（无歌词 = 空体 200，消费方不用处理错误分支）
//   GET /health  {"ok":true}
//
// seq 在"歌的身份"（backend+id）变化或停止时 +1；第三方看到 seq 变了
// 就丢弃手头旧数据，避免换歌瞬间的"新歌配旧进度"半拍。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Allocator = std.mem.Allocator;

/// 发布进快照的一行歌词（tr = 翻译轨，可空）。
pub const LyricIn = struct { time_ms: u32, text: []const u8, tr: ?[]const u8 = null };

pub const SongIn = struct {
    backend: []const u8,
    id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_s: u32,
    lyrics: []const LyricIn,
};

pub const State = enum { stopped, playing, paused };

/// 自旋锁：std.Thread.Mutex 在 0.17 已删，std.Io.Mutex 要 Io 参数、
/// 不适合裸线程；临界区只有几百字节的 dupe/拷贝，自旋足够。
const Spin = struct {
    locked: std.atomic.Value(bool) = .init(false),
    fn lock(s: *Spin) void {
        while (s.locked.swap(true, .acquire)) {
            if (builtin.os.tag != .windows) _ = posix.system.sched_yield();
        }
    }
    fn unlock(s: *Spin) void {
        s.locked.store(false, .release);
    }
};

pub const Snapshot = struct {
    mutex: Spin = .{},
    gpa: Allocator = undefined,

    seq: u64 = 0,
    state: State = .stopped,
    pos_ms: u32 = 0,
    duration_s: u32 = 0,
    /// 歌的身份（backend:id|mid），seq 按它的变化自增
    key: []const u8 = "",
    backend: []const u8 = "",
    song_id: []const u8 = "",
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
    lyrics: []Lyric = &.{},

    pub const Lyric = struct { time_ms: u32, text: []const u8, tr: ?[]const u8 };

    fn freeSong(self: *Snapshot) void {
        for (self.lyrics) |l| {
            self.gpa.free(l.text);
            if (l.tr) |t| self.gpa.free(t);
        }
        if (self.lyrics.len > 0) self.gpa.free(self.lyrics);
        inline for (.{ &self.key, &self.backend, &self.song_id, &self.title, &self.artist, &self.album }) |f| {
            if (f.len > 0) self.gpa.free(f.*);
            f.* = "";
        }
        self.lyrics = &.{};
    }

    /// UI 线程调用：整包替换快照（对齐 TUI 的 onTick 节奏，每帧都发）。
    /// 入参内存归调用方（可以是 arena 临时），这里全部 dupe。
    /// key 与上次不同（含 stopped 的空 key）→ seq +1。
    pub fn publish(self: *Snapshot, state: State, pos_ms: u32, song: ?SongIn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var new_key: []const u8 = "";
        if (song) |s| new_key = std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ s.backend, s.id }) catch "";
        defer if (new_key.len > 0) self.gpa.free(new_key);

        const changed = !std.mem.eql(u8, self.key, new_key);
        if (changed) {
            self.freeSong();
            self.seq +%= 1;
            self.key = self.gpa.dupe(u8, new_key) catch "";
        }
        self.state = state;
        self.pos_ms = pos_ms;
        self.duration_s = if (song) |s| s.duration_s else 0;

        // 同一首歌也可能歌词晚到：key 没变但 lyrics 内容变了要刷新。
        // 简化：publish 时总是重建歌词（几百字节/次，500ms 节奏无所谓）。
        if (song) |s| blk: {
            if (s.lyrics.len == 0) {
                // 该歌没歌词：清掉旧歌词（保持 song 元数据）
                for (self.lyrics) |l| {
                    self.gpa.free(l.text);
                    if (l.tr) |t| self.gpa.free(t);
                }
                if (self.lyrics.len > 0) self.gpa.free(self.lyrics);
                self.lyrics = &.{};
                break :blk;
            }
            if (!changed) {
                for (self.lyrics) |l| {
                    self.gpa.free(l.text);
                    if (l.tr) |t| self.gpa.free(t);
                }
                if (self.lyrics.len > 0) self.gpa.free(self.lyrics);
            }
            var lines: []Lyric = self.gpa.alloc(Lyric, s.lyrics.len) catch break :blk;
            var n: usize = 0;
            for (s.lyrics) |l| {
                const t = self.gpa.dupe(u8, l.text) catch continue;
                const tr: ?[]const u8 = if (l.tr) |tr| (self.gpa.dupe(u8, tr) catch null) else null;
                lines[n] = .{ .time_ms = l.time_ms, .text = t, .tr = tr };
                n += 1;
            }
            self.lyrics = lines[0..n];
        }

        if (song) |s| {
            if (changed) {
                self.backend = self.gpa.dupe(u8, s.backend) catch "";
                self.song_id = self.gpa.dupe(u8, s.id) catch "";
                self.title = self.gpa.dupe(u8, s.title) catch "";
                self.artist = self.gpa.dupe(u8, s.artist) catch "";
                self.album = self.gpa.dupe(u8, s.album) catch "";
            }
        }
    }
};

// ── JSON 转义（歌名/歌词够用）──

pub fn jsonEscape(w: anytype, s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => w.writeAll("\\\"") catch {},
        '\\' => w.writeAll("\\\\") catch {},
        '\n' => w.writeAll("\\n") catch {},
        '\r' => w.writeAll("\\r") catch {},
        '\t' => w.writeAll("\\t") catch {},
        else => {
            if (c < 0x20) {
                w.print("\\u{x:0>4}", .{c}) catch {};
            } else {
                w.writeByte(c) catch {};
            }
        },
    };
}

pub const ApiServer = struct {
    snap: Snapshot = .{},
    listen_fd: i32 = -1,
    thread: ?std.Thread = null,
    running: bool = false,

    /// 起 listener + 线程。失败（端口占用/权限）返回 false，调用方静默降级。
    /// Windows 暂不启用（loopback HTTP 服务是可选附属功能，raw posix
    /// 实现要换 winsock；核心播放/浏览不受影响）。
    pub fn start(self: *ApiServer, gpa: Allocator, port: u16) bool {
        if (builtin.os.tag == .windows) return false;
        if (port == 0) return false;
        if (self.thread != null) return true;
        self.snap.gpa = gpa;

        const fd = posix.system.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        if (posix.errno(fd) != .SUCCESS) return false;
        const lfd: i32 = @intCast(fd);
        const reuse: c_int = 1;
        _ = posix.system.setsockopt(lfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));
        var addr: posix.sockaddr.in = .{
            .port = std.mem.bigToNative(u16, port),
            .addr = std.mem.bigToNative(u32, 127 << 24 | 1), // 127.0.0.1
        };
        if (posix.errno(posix.system.bind(lfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in))) != .SUCCESS) {
            _ = posix.system.close(lfd);
            return false;
        }
        if (posix.errno(posix.system.listen(lfd, 16)) != .SUCCESS) {
            _ = posix.system.close(lfd);
            return false;
        }
        self.listen_fd = lfd;
        self.running = true;
        self.thread = std.Thread.spawn(.{}, listenLoop, .{self}) catch {
            self.running = false;
            _ = posix.system.close(lfd);
            self.listen_fd = -1;
            return false;
        };
        return true;
    }

    pub fn deinit(self: *ApiServer) void {
        if (builtin.os.tag != .windows) if (self.thread) |t| {
            self.running = false;
            // 关监听 fd 唤醒阻塞在 accept 的线程（Linux 上返回 EBADF）
            if (self.listen_fd >= 0) _ = posix.system.close(self.listen_fd);
            self.listen_fd = -1;
            t.join();
            self.thread = null;
        };
        // 快照自持内存：UI 线程此后不再 publish，可以安全释放。
        // 只有 start 过才可能有分配（字段非空才 free，未 start 时全为空也安全）
        self.snap.freeSong();
        self.snap.gpa = undefined;
    }

    fn listenLoop(self: *ApiServer) void {
        while (self.running) {
            const cfd = posix.system.accept(self.listen_fd, null, null);
            if (posix.errno(cfd) != .SUCCESS) {
                if (!self.running) return;
                continue;
            }
            self.handleConn(@intCast(cfd)) catch {};
            _ = posix.system.close(@intCast(cfd));
        }
    }

    fn handleConn(self: *ApiServer, fd: posix.socket_t) !void {
        var buf: [4096]u8 = undefined;
        var n: usize = 0;
        while (n < buf.len) {
            const got = posix.read(fd, buf[n..]) catch return;
            if (got == 0) break;
            n += got;
            if (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") != null) break;
        }
        const line_end = std.mem.indexOf(u8, buf[0..n], "\r\n") orelse return;
        var it = std.mem.splitScalar(u8, buf[0..line_end], ' ');
        const method = it.next() orelse return;
        const path_full = it.next() orelse return;
        if (!std.mem.eql(u8, method, "GET")) {
            try writeResp(fd, "405 Method Not Allowed", "text/plain; charset=utf-8", "method not allowed\n");
            return;
        }
        const path = path_full[0..(std.mem.indexOfScalar(u8, path_full, '?') orelse path_full.len)];

        if (std.mem.eql(u8, path, "/health")) {
            try writeResp(fd, "200 OK", "application/json; charset=utf-8", "{\"ok\":true}\n");
        } else if (std.mem.eql(u8, path, "/lyrics")) {
            try self.serveLyrics(fd);
        } else if (std.mem.eql(u8, path, "/now")) {
            try self.serveNow(fd);
        } else {
            try writeResp(fd, "404 Not Found", "application/json; charset=utf-8", "{\"ok\":false,\"code\":\"not_found\"}\n");
        }
    }

    fn serveNow(self: *ApiServer, fd: posix.socket_t) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const Ctx = struct {
            a: Allocator,
            err: bool = false,
            body: []const u8 = "",
            fn build(ctx: *@This(), s: *const Snapshot) void {
                var buf = std.Io.Writer.Allocating.init(ctx.a);
                const w = &buf.writer;
                w.writeAll("{\"ok\":true,\"state\":\"") catch {
                    ctx.err = true;
                    return;
                };
                w.writeAll(@tagName(s.state)) catch return;
                w.print("\",\"seq\":{d},\"position_ms\":{d},", .{ s.seq, s.pos_ms }) catch return;
                if (s.title.len == 0) {
                    w.writeAll("\"song\":null,\"lyrics\":null}\n") catch return;
                    ctx.body = buf.written();
                    return;
                }
                w.writeAll("\"song\":{\"backend\":\"") catch return;
                jsonEscape(w, s.backend);
                w.writeAll("\",\"id\":\"") catch return;
                jsonEscape(w, s.song_id);
                w.writeAll("\",\"title\":\"") catch return;
                jsonEscape(w, s.title);
                w.writeAll("\",\"artist\":\"") catch return;
                jsonEscape(w, s.artist);
                w.writeAll("\",\"album\":\"") catch return;
                jsonEscape(w, s.album);
                w.print("\",\"duration_s\":{d}}},\"lyrics\":", .{s.duration_s}) catch return;
                if (s.lyrics.len == 0) {
                    w.writeAll("null}\n") catch return;
                } else {
                    w.writeAll("{\"format\":\"lrc\",\"lines\":[") catch return;
                    for (s.lyrics, 0..) |l, i| {
                        if (i > 0) w.writeByte(',') catch return;
                        w.print("{{\"time_ms\":{d},\"text\":\"", .{l.time_ms}) catch return;
                        jsonEscape(w, l.text);
                        if (l.tr) |tr| {
                            w.writeAll("\",\"tr\":\"") catch return;
                            jsonEscape(w, tr);
                        }
                        w.writeAll("\"}") catch return;
                    }
                    w.writeAll("]}}\n") catch return;
                }
                ctx.body = buf.written();
            }
        };
        var ctx = Ctx{ .a = a };
        {
            self.snap.mutex.lock();
            defer self.snap.mutex.unlock();
            ctx.build(&self.snap);
        }
        if (ctx.err) return error.BuildFailed;
        try writeResp(fd, "200 OK", "application/json; charset=utf-8", ctx.body);
    }

    fn serveLyrics(self: *ApiServer, fd: posix.socket_t) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const Ctx = struct {
            a: Allocator,
            body: []const u8 = "",
            fn build(ctx: *@This(), s: *const Snapshot) void {
                var buf = std.Io.Writer.Allocating.init(ctx.a);
                const w = &buf.writer;
                for (s.lyrics) |l| {
                    const total = l.time_ms / 1000;
                    w.print("[{d:0>2}:{d:0>2}.{d:0>2}]{s}\n", .{
                        total / 60, total % 60, (l.time_ms % 1000) / 10, l.text,
                    }) catch return;
                    if (l.tr) |tr| w.print("/{s}\n", .{tr}) catch return;
                }
                ctx.body = buf.written();
            }
        };
        var ctx = Ctx{ .a = a };
        {
            self.snap.mutex.lock();
            defer self.snap.mutex.unlock();
            ctx.build(&self.snap);
        }
        try writeResp(fd, "200 OK", "text/plain; charset=utf-8", ctx.body);
    }
};

fn writeResp(fd: posix.socket_t, status: []const u8, ctype: []const u8, body: []const u8) !void {
    var head_buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "HTTP/1.1 {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n", .{ status, ctype, body.len });
    try writeAllRaw(fd, head);
    try writeAllRaw(fd, body);
}

fn writeAllRaw(fd: posix.socket_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = posix.system.write(fd, bytes.ptr + off, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

// ── 单测：快照换歌 seq 语义 + JSON 转义 ──

const testing = std.testing;

test "Snapshot：换歌 seq+1、同歌只推进度、歌词晚到刷新、停止清空" {
    var s = Snapshot{ .gpa = testing.allocator };
    defer s.freeSong();

    s.publish(.playing, 0, .{
        .backend = "netease",
        .id = "1",
        .title = "甲",
        .artist = "乙",
        .album = "丙",
        .duration_s = 100,
        .lyrics = &.{.{ .time_ms = 0, .text = "词" }},
    });
    try testing.expectEqual(@as(u64, 1), s.seq);
    try testing.expectEqualStrings("netease:1", s.key);

    // 同一首歌：seq 不动、pos 更新
    s.publish(.paused, 500, .{
        .backend = "netease",
        .id = "1",
        .title = "甲",
        .artist = "乙",
        .album = "丙",
        .duration_s = 100,
        .lyrics = &.{.{ .time_ms = 0, .text = "词" }},
    });
    try testing.expectEqual(@as(u64, 1), s.seq);
    try testing.expectEqual(@as(u32, 500), s.pos_ms);
    try testing.expect(s.state == .paused);

    // 歌词晚到（同 key，多一行）：seq 不动、歌词刷新
    s.publish(.paused, 500, .{
        .backend = "netease",
        .id = "1",
        .title = "甲",
        .artist = "乙",
        .album = "丙",
        .duration_s = 100,
        .lyrics = &.{ .{ .time_ms = 0, .text = "词" }, .{ .time_ms = 3000, .text = "词2" } },
    });
    try testing.expectEqual(@as(u64, 1), s.seq);
    try testing.expectEqual(@as(usize, 2), s.lyrics.len);

    // 换歌：seq+1、旧字符串被释放换新
    s.publish(.playing, 0, .{
        .backend = "qq",
        .id = "002",
        .title = "丁",
        .artist = "",
        .album = "",
        .duration_s = 200,
        .lyrics = &.{},
    });
    try testing.expectEqual(@as(u64, 2), s.seq);
    try testing.expectEqualStrings("qq:002", s.key);
    try testing.expectEqual(@as(usize, 0), s.lyrics.len);

    // 停止：song=null → key 变空 → seq+1、元数据清空
    s.publish(.stopped, 0, null);
    try testing.expectEqual(@as(u64, 3), s.seq);
    try testing.expectEqualStrings("", s.key);
    try testing.expectEqualStrings("", s.title);
}

test "jsonEscape：引号反斜杠与控制字符" {
    var buf: [128]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&buf);
    jsonEscape(&fbs, "a\"b\\c\nd\x01");
    try testing.expectEqualStrings("a\\\"b\\\\c\\nd\\u0001", fbs.buffered());
}
