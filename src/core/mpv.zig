const std = @import("std");
const Allocator = std.mem.Allocator;
const ipc = @import("ipc.zig");

// src/core/mpv.zig — mpv 子进程播放器（JSON IPC：unix socket / Windows 命名管道，见 ipc.zig）。
//
// 启动：mpv --no-video --idle=yes --input-ipc-server=<sock>
//   --idle 播完（列表尾）转 idle 保活，由 playlist-pos=-1 事件感知；
//   不能用 --keep-open：它会禁用播放列表自动前进（实测）。
//   播放列表由 app 侧 append-only 维护（队列镜像），系统媒体键（MPRIS）
//   的 next/prev 直接驱动 mpv 内部列表，TUI 经 playlist-pos 事件同步。
// 协议：每行一个 JSON。请求带 request_id，读行直到 id 匹配（跳过事件行）。
// 所有 IPC 都在主线程 update() 里同步往返（本地 unix socket 亚毫秒），
// mpv 不在时全部接口安全降级（available=false，UI 走假进度）。
//
// 实现注意：IPC 的 socket 全程走 raw posix（socket/connect/read/write），
// 不经过 std.Io 派发——实测 io 派发的 unix connect 与并发 HTTP fetch
// 组合会偶发死锁（worker 全部 futex_wait），raw posix 无此问题。

pub const Status = struct {
    position_s: f64 = 0,
    duration_s: f64 = 0,
    eof: bool = false,
};

pub const Player = struct {
    gpa: Allocator,
    io: std.Io,
    child: ?std.process.Child = null,
    // IPC 服务名与其 argv 参数串都存在自有缓冲里，免堆分配、免释放
    name_buf: [48]u8 = @splat(0),
    path_buf: [96]u8 = undefined,
    opt_buf: [128]u8 = undefined,
    server_name: []const u8 = "",
    server_path: []const u8 = "",
    conn: ?ipc.Conn = null,
    // 行缓冲（socket 是流式字节，常驻缓冲攒行）
    rbuf: [8192]u8 = undefined,
    rlen: usize = 0,
    // 每次往返的临时分配（JSON 行、响应解析）走这里，往返前重置，
    // 不泄漏进调用方的 arena
    scratch: std.heap.ArenaAllocator = undefined,
    available: bool = false,
    request_seq: u32 = 0,
    connect_tries: u32 = 0,
    // observe_property 事件（request 往返途中捎带解析，app 每 tick 消费）
    pending_pos: ?i64 = null, // playlist-pos（-1 = idle：列表尾/无文件）
    pending_pause: ?bool = null,
    observed: bool = false, // 当前连接是否已挂 observe（重连后要重挂）

    pub fn init(gpa: Allocator, io: std.Io) Player {
        return .{ .gpa = gpa, .io = io, .scratch = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Player) void {
        if (self.conn) |*c| c.close();
        self.conn = null;
        if (self.child) |*c| c.kill(self.io);
        self.child = null;
        self.available = false;
        // spawn 成功过才会设服务名；mpv 启动即建 socket/管道，
        // 连不上放弃（tickConnect 置 child=null）时也可能已建出
        if (self.server_path.len > 0) ipc.cleanupServer(self.server_path);
        self.scratch.deinit();
    }

    /// 派生 mpv 子进程（只 spawn，不等待 socket——实测 spawn 后阻塞会与
    /// 并发 HTTP fetch 偶发死锁，connect 改由 tickConnect 逐 tick 尝试）。
    /// spawn 失败（如无 mpv）返回 false，UI 永久降级假进度。
    pub fn startAsync(self: *Player) bool {
        if (self.child != null) return true;
        self.server_name = ipc.serverName(&self.name_buf, ipc.currentPid()) orelse return false;
        self.server_path = ipc.serverArgPath(&self.path_buf, self.server_name) orelse return false;
        const opt = std.fmt.bufPrint(&self.opt_buf, "--input-ipc-server={s}", .{self.server_path}) catch return false;
        self.child = std.process.spawn(self.io, .{
            .argv = &.{
                "mpv",
                "--no-video",
                "--idle=yes",
                "--really-quiet",
                "--no-terminal",
                opt,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {
            self.child = null;
            return false;
        };
        return true;
    }

    /// 每个 tick 至多一次 connect 尝试（无阻塞循环）。成功转 available。
    /// 返回 true = 已连接；false = 未就绪（继续下个 tick 试，或用尽重试次数放弃）。
    pub fn tickConnect(self: *Player) bool {
        if (self.available) {
            self.ensureObserved();
            return true;
        }
        if (self.child == null) return false;
        if (self.connect()) {
            self.ensureObserved();
            return true;
        }
        self.connect_tries += 1;
        if (self.connect_tries >= 20) self.child = null; // ~10s 放弃
        return false;
    }

    /// 连接建立（或重连）后挂属性订阅。幂等：observed 置位后跳过。
    /// observe_property 的 id 必须是 JSON 数字（字符串实测报 invalid
    /// parameter），request() 的字符串数组会全部加引号，这里手拼原始行。
    fn ensureObserved(self: *Player) void {
        if (self.observed or self.conn == null) return;
        self.request_seq += 1;
        const seq1 = self.request_seq;
        var buf: [128]u8 = undefined;
        const line1 = std.fmt.bufPrint(&buf, "{{\"command\":[\"observe_property\",1,\"playlist-pos\"],\"request_id\":{d}}}\n", .{seq1}) catch return;
        if (!self.conn.?.writeAll(line1)) return;
        self.request_seq += 1;
        const seq2 = self.request_seq;
        const line2 = std.fmt.bufPrint(&buf, "{{\"command\":[\"observe_property\",2,\"pause\"],\"request_id\":{d}}}\n", .{seq2}) catch return;
        if (!self.conn.?.writeAll(line2)) return;
        // 同步把两条响应读掉；事件行/迟到的响应由后续 request()/drain() 路由
        _ = self.scratch.reset(.retain_capacity);
        const a = self.scratch.allocator();
        var got: u32 = 0;
        while (got < 2) : (got += 1) {
            const raw = self.readLine(a) orelse break;
            _ = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch continue;
        }
        self.observed = true;
    }

    /// 一次 IPC 连接尝试（unix socket / 命名管道，raw 系统调用，
    /// 不经 std.Io 派发——见 ipc.zig 注释）。
    fn connect(self: *Player) bool {
        if (self.conn != null) return true;
        self.conn = ipc.Conn.connect(self.server_name) orelse return false;
        self.available = true;
        self.rlen = 0;
        self.observed = false;
        return true;
    }

    /// 从 fd 攒一行（不含换行）。EOF/错误返回 null。
    fn readLine(self: *Player, arena: Allocator) ?[]const u8 {
        var conn = &(self.conn orelse return null);
        while (true) {
            if (std.mem.indexOfScalar(u8, self.rbuf[0..self.rlen], '\n')) |i| {
                const line = arena.dupe(u8, self.rbuf[0..i]) catch return null;
                const rest = self.rlen - i - 1;
                std.mem.copyForwards(u8, self.rbuf[0..rest], self.rbuf[i + 1 .. self.rlen]);
                self.rlen = rest;
                return line;
            }
            if (self.rlen == self.rbuf.len) return null; // 行超长，放弃
            const n = conn.read(self.rbuf[self.rlen..]) orelse return null;
            if (n == 0) return null; // 对端关闭
            self.rlen += n;
        }
    }

    /// 一条 IPC 往返的结果，区分两种失败：
    /// .mpv_err = mpv 在线但命令/属性不可用（如 idle 时取 playback-time
    ///           报 property unavailable）——不算掉线
    /// .dead    = 传输层断开（写失败/对端关闭/行超长）——只有这才算掉线
    const RequestResult = union(enum) {
        ok: ?std.json.Value, // success；data 可空（无返回值的命令）
        mpv_err,
        dead,
    };

    /// 临时分配全部走自有 scratch（往返前重置）；需要留存的返回值由调用方立即提取。
    fn request(self: *Player, cmd: []const []const u8) RequestResult {
        if (self.conn == null) return .dead;
        self.request_seq += 1;
        const seq = self.request_seq;

        _ = self.scratch.reset(.retain_capacity);
        const a = self.scratch.allocator();
        var line: std.Io.Writer.Allocating = .init(a);
        line.writer.writeAll("{\"command\":") catch return .dead;
        std.json.Stringify.value(cmd, .{}, &line.writer) catch return .dead;
        line.writer.print(",\"request_id\":{d}}}\n", .{seq}) catch return .dead;
        if (!self.conn.?.writeAll(line.written())) return .dead;

        // 读行直到拿到匹配 request_id 的响应。事件行没有 request_id：
        // 关注的属性事件记到 pending_*，其余丢弃
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const raw = self.readLine(a) orelse return .dead;
            if (raw.len == 0) continue;
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch continue;
            if (v != .object) continue;
            if (v.object.get("event") != null) {
                self.stashLine(raw, a);
                continue;
            }
            const rid = v.object.get("request_id") orelse continue;
            if (rid != .integer or rid.integer != seq) continue;
            const err = v.object.get("error") orelse continue;
            if (err != .string or !std.mem.eql(u8, err.string, "success")) return .mpv_err;
            return .{ .ok = v.object.get("data") };
        }
        return .mpv_err;
    }

    /// 掉线后重置连接（fd 关闭、available 清零），保留 mpv 进程与 socket
    /// 路径，tickConnect 自动重试 connect。注意新连接不继承播放状态，
    /// 重连成功后需要重新 loadFile 当前曲。
    pub fn dropConnection(self: *Player) void {
        if (self.conn) |*c| c.close();
        self.conn = null;
        self.available = false;
        self.connect_tries = 0;
        self.rlen = 0;
    }

    /// 解析一行，属性事件记到 pending_*（响应行/其他事件忽略）。
    /// request() 与 drain() 共用。
    fn stashLine(self: *Player, raw: []const u8, a: Allocator) void {
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return;
        if (v != .object) return;
        const ev = v.object.get("event") orelse return;
        if (ev != .string or !std.mem.eql(u8, ev.string, "property-change")) return;
        const id = v.object.get("id") orelse return;
        if (id != .integer) return;
        const data = v.object.get("data") orelse return;
        switch (id.integer) {
            1 => {
                if (data == .integer) self.pending_pos = data.integer;
            },
            2 => {
                if (data == .bool) self.pending_pause = data.bool;
            },
            else => {},
        }
    }

    /// app 每 tick 调用：非阻塞捞掉 socket 里积压的事件行（暂停期间没有
    /// 往返请求，事件只能在这里读），再交出暂存的属性事件。
    pub fn drain(self: *Player, out_pos: *?i64, out_pause: *?bool) void {
        if (self.conn != null) {
            _ = self.scratch.reset(.retain_capacity);
            const a = self.scratch.allocator();
            var tries: u32 = 0;
            while (tries < 32) : (tries += 1) {
                if (!self.conn.?.hasData()) break;
                const raw = self.readLine(a) orelse break;
                self.stashLine(raw, a);
            }
        }
        out_pos.* = self.pending_pos;
        out_pause.* = self.pending_pause;
        self.pending_pos = null;
        self.pending_pause = null;
    }

    /// 追加到播放列表尾部（队列镜像；url 取链接由调用方先拿好）。
    pub fn appendFile(self: *Player, url: []const u8, title: []const u8) bool {
        _ = self.request(&.{ "set_property", "force-media-title", title });
        return self.request(&.{ "loadfile", url, "append" }) == .ok;
    }

    /// 单曲循环开/关（模式切换与换曲时同步；inf 下 eof 不触发自动前进，
    /// 但 MPRIS Next 的 playlist-next force 仍能切下一首——实测）。
    pub fn setLoopFile(self: *Player, loop: bool) void {
        _ = self.request(&.{ "set_property", "loop-file", if (loop) "inf" else "no" });
    }

    /// 当前播放列表下标（idle 时 -1）。传输断开返回 null。
    pub fn playlistPos(self: *Player) ?i64 {
        return switch (self.request(&.{ "get_property", "playlist-pos" })) {
            .ok => |v| if (v) |d| (if (d == .integer) d.integer else null) else null,
            .mpv_err => null,
            .dead => null,
        };
    }

    pub fn playlistNext(self: *Player) bool {
        return self.request(&.{ "playlist-next", "force" }) == .ok;
    }

    pub fn playlistPrev(self: *Player) bool {
        return self.request(&.{ "playlist-prev" }) == .ok;
    }

    /// loadfile 并设媒体标题（MPRIS/桌面通知显示“歌名 - 歌手”而非 URL）。
    /// 标题单独 set_property——loadfile 的 options 参数是逗号分隔的
    /// "k=v,k=v" 串，歌名含逗号会劈断它（%len% 转义只是 input.conf 语法，
    /// JSON IPC 不认，曾导致标题带逗号的歌 loadfile 永远失败）。
    pub fn loadFile(self: *Player, url: []const u8, title: []const u8) bool {
        _ = self.request(&.{ "set_property", "force-media-title", title });
        return self.request(&.{ "loadfile", url, "replace" }) == .ok;
    }

    pub fn setPause(self: *Player, paused: bool) void {
        _ = self.request(&.{ "set_property", "pause", if (paused) "yes" else "no" });
    }

    pub fn setVolume(self: *Player, volume: u8) void {
        const v = std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{volume}) catch return;
        _ = self.request(&.{ "set_property", "volume", v });
    }

    pub fn seekTo(self: *Player, secs: f64) void {
        const v = std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{secs}) catch return;
        _ = self.request(&.{ "seek", v, "absolute" });
    }

    /// 轮询播放状态。属性不可用（未加载文件）按 0 处理，只有传输断开
    /// 才返回 null（调用方据此判定掉线）。
    pub fn status(self: *Player) ?Status {
        var st = Status{};
        switch (self.request(&.{ "get_property", "playback-time" })) {
            .ok => |v| if (v) |pos| {
                st.position_s = jsonNum(pos) orelse 0;
            },
            .mpv_err => {},
            .dead => return null,
        }
        switch (self.request(&.{ "get_property", "duration" })) {
            .ok => |v| if (v) |d| {
                st.duration_s = jsonNum(d) orelse 0;
            },
            else => {},
        }
        switch (self.request(&.{ "get_property", "eof-reached" })) {
            .ok => |v| if (v) |e| {
                st.eof = e == .bool and e.bool;
            },
            else => {},
        }
        return st;
    }

    fn jsonNum(v: std.json.Value) ?f64 {
        return switch (v) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }
};
