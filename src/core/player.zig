const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const mpv_mod = @import("mpv.zig");
const mf_mod = @import("mf.zig");

// src/core/player.zig — 播放后端派发层：暴露统一 API，按平台编译期定死后端，
// 无运行时探测/降级链。
//
//   windows → Media Foundation（core/mf.zig，系统 COM，零外部依赖）
//   posix   → mpv（core/mpv.zig --input-ipc-server，IO 抽象注入便于测试）
//
// Windows 二进制里从不 spawn/探测 mpv；posix 二进制不分析 MF 分支
// （mf.zig 的 `Player = if (supported)` 已保证非 windows 下零分析，
// .mf 派发臂引用同形 stub UnsupportedPlayer，switch 各臂任意平台可编译）。
// 都不可用（COM 失败 / mpv spawn 失败）→ 假进度兜底，UI 完整。

pub const Status = mpv_mod.Status;
pub const Kind = enum(u8) { none, mpv, mf };

/// 系统媒体键（windows SMTC，见 core/smtc.zig）。posix 恒 null（mpv 自带
/// 系统集成，不经此通道）。
pub const MediaButton = mf_mod.MediaButton;

pub const Player = struct {
    mpv: mpv_mod.Player,
    mf: mf_mod.Player,
    kind: Kind = .none,

    pub fn init(gpa: Allocator, io: std.Io) Player {
        if (comptime builtin.os.tag == .windows) {
            return .{
                .mpv = undefined, // windows 不编译 mpv 路径，此字段恒不触碰
                .mf = mf_mod.Player.init(gpa),
                .kind = .none,
            };
        }
        return .{
            .mpv = mpv_mod.Player.init(gpa, io),
            .mf = mf_mod.Player.init(gpa), // stub，零分析
            .kind = .none,
        };
    }

    pub fn deinit(self: *Player) void {
        if (comptime builtin.os.tag == .windows) {
            self.mf.deinit();
            return;
        }
        self.mpv.deinit();
        self.mf.deinit();
    }

    /// 已尝试过启动（后端已定，无论成败）。
    pub fn started(self: *const Player) bool {
        return self.kind != .none;
    }

    /// 后端可受理命令（mpv 已连上 / MF 会话已建）。
    pub fn available(self: *const Player) bool {
        return switch (self.kind) {
            .none => false,
            .mpv => self.mpv.available,
            .mf => comptime mf_mod.supported, // startAsync 成功即 available
        };
    }

    /// 后端放弃（mpv 连接用尽 / COM 初始化失败）：UI 走假进度。
    pub fn gaveUp(self: *const Player) bool {
        return switch (self.kind) {
            .none => false,
            .mf => false, // COM 失败时 kind 不会置 .mf（startAsync false）
            .mpv => self.mpv.child == null,
        };
    }

    /// mpv 有播放列表、播完自动前进；MF 没有，eof 由 app 驱动（status().eof
    /// 时调 nextSong(.eof)）。
    pub fn autoAdvances(self: *const Player) bool {
        return self.kind == .mpv;
    }

    /// 全后端放弃后复位到未启动态：下次 requestPlayback 重新 startAsync
    /// （用户装好 mpv 后无需重启）。
    pub fn reset(self: *Player) void {
        self.kind = .none;
        if (comptime builtin.os.tag != .windows) self.mpv.dropConnection();
    }

    /// 启动后端（异步，幂等）。编译期平台分流：windows 只试 MF，
    /// posix 只试 mpv。成功返回 true（不代表已能播放）。
    pub fn startAsync(self: *Player) bool {
        if (self.kind != .none) return true;
        if (comptime builtin.os.tag == .windows) {
            if (self.mf.startAsync()) {
                self.kind = .mf;
                return true;
            }
            return false;
        }
        if (self.mpv.startAsync()) {
            self.kind = .mpv;
            return true;
        }
        return false;
    }

    /// 每 tick 至多一次连接尝试。.mf 分支恒 true（无连接过程）；
    /// windows 上 .mpv 臂不可达（kind 不会被置 .mpv）。
    pub fn tickConnect(self: *Player) bool {
        switch (self.kind) {
            .none => return false,
            .mf => return true,
            .mpv => {
                if (comptime builtin.os.tag == .windows) return false; // 不可达
                if (self.mpv.tickConnect()) return true;
                return false;
            },
        }
    }

    pub fn loadFile(self: *Player, url: []const u8, title: []const u8) bool {
        return switch (self.kind) {
            .none => false,
            .mpv => self.mpv.loadFile(url, title),
            .mf => self.mf.loadFile(url, title),
        };
    }

    pub fn appendFile(self: *Player, url: []const u8, title: []const u8) bool {
        return switch (self.kind) {
            .none, .mf => false, // MF 无播放列表：预取 append 恒失败
            .mpv => self.mpv.appendFile(url, title),
        };
    }

    /// 全量系统媒体集成元数据（SMTC T/C 行）。仅 MF 后端消费；mpv 后端走
    /// mpv 自己的 MPRIS 通路，none 无后端。app 在 loadFile 成功后调用。
    pub fn setSmtcMeta(self: *Player, title: []const u8, artist: []const u8, album: []const u8, cover_url: []const u8) void {
        switch (self.kind) {
            .none, .mpv => {},
            .mf => self.mf.setSmtcMeta(title, artist, album, cover_url),
        }
    }

    pub fn setPause(self: *Player, paused: bool) void {
        switch (self.kind) {
            .none => {},
            .mpv => self.mpv.setPause(paused),
            .mf => self.mf.setPause(paused),
        }
    }

    pub fn setVolume(self: *Player, volume: u8) void {
        switch (self.kind) {
            .none => {},
            .mpv => self.mpv.setVolume(volume),
            .mf => self.mf.setVolume(volume),
        }
    }

    pub fn setLoopFile(self: *Player, loop: bool) void {
        switch (self.kind) {
            .none => {},
            .mpv => self.mpv.setLoopFile(loop),
            .mf => self.mf.setLoopFile(loop),
        }
    }

    pub fn seekTo(self: *Player, secs: f64) void {
        switch (self.kind) {
            .none => {},
            .mpv => self.mpv.seekTo(secs),
            .mf => self.mf.seekTo(secs),
        }
    }

    /// .none/.mpv 掉线时返回 null；.mf 永不 null（无传输层死亡概念）。
    pub fn status(self: *Player) ?Status {
        return switch (self.kind) {
            .none => null,
            .mpv => self.mpv.status(),
            .mf => self.mf.status(),
        };
    }

    pub fn playlistPos(self: *Player) ?i64 {
        return switch (self.kind) {
            .none, .mf => null,
            .mpv => self.mpv.playlistPos(),
        };
    }

    pub fn playlistNext(self: *Player) bool {
        return switch (self.kind) {
            .none, .mf => false,
            .mpv => self.mpv.playlistNext(),
        };
    }

    pub fn playlistPrev(self: *Player) bool {
        return switch (self.kind) {
            .none, .mf => false,
            .mpv => self.mpv.playlistPrev(),
        };
    }

    pub fn dropConnection(self: *Player) void {
        switch (self.kind) {
            .none, .mf => {},
            .mpv => self.mpv.dropConnection(),
        }
    }

    /// app 每 tick 调用：mpv 捞属性事件；MF 借此泵结果/事件队列（输出恒 null）。
    pub fn drain(self: *Player, out_pos: *?i64, out_pause: *?bool) void {
        switch (self.kind) {
            .none => {},
            .mpv => self.mpv.drain(out_pos, out_pause),
            .mf => self.mf.drain(out_pos, out_pause),
        }
    }

    /// 取走一次系统媒体键事件（windows SMTC；posix 恒 null）。
    /// app 侧映射：play_pause → togglePlay，next/prev → nextSong/prevSong。
    pub fn takeMediaButton(self: *Player) ?MediaButton {
        return switch (self.kind) {
            .none, .mpv => null,
            .mf => self.mf.takeMediaButton(),
        };
    }
};
