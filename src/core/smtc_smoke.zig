const std = @import("std");
const builtin = @import("builtin");
const mf = @import("mf.zig");
const smtc = @import("smtc.zig");

// src/core/smtc_smoke.zig — SMTC 冒烟（仅 windows，无网络、无 UI）：
// 本地生成 3s WAV → MF 后端真播放（startAsync 内部 attach SMTC + 真音频流
// 注册媒体会话）→ SendInput 注入系统媒体键（播放/暂停、下一首、上一首）
// → 断言 takeMediaButton 依次收到对应事件。全过 exit 0。
//
// 与 amtui-mfsmoke 的区别：mfsmoke 验证的是播放链路（打开/时长/seek/EOF），
// 本冒烟验证「系统 fire → handler Invoke → 原子标志 → takeButton」的
// 媒体键事件链路——历史上该链路在 MC.dll fire 路径崩溃（见 smtc.zig 头注），
// 需要一个不依赖 TUI 与人工按键的确定性复现工具来迭代。

const SAMPLE_RATE: f64 = 44100.0;
const DURATION_S: f64 = 3.0;
const AMPLITUDE: f64 = 12000.0;

extern "kernel32" fn Sleep(milliseconds: u32) void;

const VK_MEDIA_PLAY_PAUSE: u16 = 0xB3;
const VK_MEDIA_NEXT_TRACK: u16 = 0xB0;
const VK_MEDIA_PREV_TRACK: u16 = 0xB1;
const INPUT_KEYBOARD: u32 = 1;
const KEYEVENTF_KEYUP: u32 = 2;

const KEYBDINPUT = extern struct { wVk: u16, wScan: u16, dwFlags: u32, time: u32, dwExtraInfo: usize };
const MOUSEINPUT = extern struct { dx: i32, dy: i32, mouseData: u32, dwFlags: u32, time: u32, dwExtraInfo: usize };
const HARDWAREINPUT = extern struct { uMsg: u32, wParamL: u16, wParamH: u16 };
const INPUT = extern struct {
    type: u32,
    u: extern union { ki: KEYBDINPUT, mi: MOUSEINPUT, hi: HARDWAREINPUT },
};

extern "user32" fn SendInput(inputs: u32, arr: [*]const INPUT, size: i32) u32;

extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: ?[*]u8, size: u32) u32;
fn GetEnvA(name: [*:0]const u8, buf: *[8]u8) bool {
    const n = GetEnvironmentVariableA(name, buf, buf.len);
    return n > 0 and n < buf.len;
}
fn EnvExists(name: [*:0]const u8) bool {
    return GetEnvironmentVariableA(name, null, 0) > 0;
}

/// 模拟一次媒体键按下+抬起（与真实键盘媒体键同一系统路径：
/// shell → 媒体会话基础设施 → 活动会话的 SMTC ButtonPressed）
fn tapMediaKey(vk: u16) void {
    const down = INPUT{ .type = INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = vk, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = 0 } } };
    const up = INPUT{ .type = INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = vk, .wScan = 0, .dwFlags = KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 } } };
    _ = SendInput(1, @ptrCast(&down), @sizeOf(INPUT));
    Sleep(30);
    _ = SendInput(1, @ptrCast(&up), @sizeOf(INPUT));
}

fn buildWav(gpa: std.mem.Allocator) ![]u8 {
    const n_samples: usize = @intFromFloat(SAMPLE_RATE * DURATION_S);
    const data_len = n_samples * 2;
    const buf = try gpa.alloc(u8, 44 + data_len);
    var w: usize = 0;
    const put = struct {
        fn tag(b: []u8, o: *usize, s: *const [4]u8) void {
            @memcpy(b[o.*..][0..4], s);
            o.* += 4;
        }
        fn u32le(b: []u8, o: *usize, v: u32) void {
            std.mem.writeInt(u32, b[o.*..][0..4], v, .little);
            o.* += 4;
        }
        fn u16le(b: []u8, o: *usize, v: u16) void {
            std.mem.writeInt(u16, b[o.*..][0..2], v, .little);
            o.* += 2;
        }
    };
    put.tag(buf, &w, "RIFF");
    put.u32le(buf, &w, @intCast(36 + data_len));
    put.tag(buf, &w, "WAVE");
    put.tag(buf, &w, "fmt ");
    put.u32le(buf, &w, 16);
    put.u16le(buf, &w, 1); // PCM
    put.u16le(buf, &w, 1); // mono
    put.u32le(buf, &w, @intFromFloat(SAMPLE_RATE));
    put.u32le(buf, &w, @intFromFloat(SAMPLE_RATE * 2));
    put.u16le(buf, &w, 2);
    put.u16le(buf, &w, 16);
    put.tag(buf, &w, "data");
    put.u32le(buf, &w, @intCast(data_len));
    var i: usize = 0;
    while (i < n_samples) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / SAMPLE_RATE;
        const v: i16 = @intFromFloat(AMPLITUDE * @sin(2.0 * std.math.pi * 440.0 * t));
        std.mem.writeInt(i16, buf[w..][0..2], v, .little);
        w += 2;
    }
    return buf;
}

fn fail(comptime fmt: []const u8, args: anytype) error{SmtcSmoke} {
    std.debug.print("smtcsmoke: FAIL " ++ fmt ++ "\n", args);
    return error.SmtcSmoke;
}

/// 泵一轮并顺带消费媒体键（收到的键由 expectKey 主导断言，这里只保底消费）。
var g_stray: ?mf.MediaButton = null;

fn pumpOnce(p: *mf.Player) mf.Status {
    var epos: ?i64 = null;
    var epause: ?bool = null;
    p.drain(&epos, &epause);
    if (g_stray == null) g_stray = p.takeMediaButton();
    return p.status().?;
}

/// 注入一个媒体键并在超时内等 takeMediaButton 报出对应事件。
/// 期间持续 pump（SMTC 泵靠这个推进）。
fn expectKey(p: *mf.Player, want: mf.MediaButton, vk: u16, timeout_s: f64) !void {
    const label: []const u8 = switch (want) {
        .play_pause => "play_pause",
        .next => "next",
        .prev => "prev",
    };
    g_stray = null;
    tapMediaKey(vk);
    var elapsed: f64 = 0;
    while (elapsed < timeout_s) : (elapsed += 0.05) {
        _ = pumpOnce(p);
        if (g_stray) |b| {
            g_stray = null;
            if (b == want) {
                std.debug.print("smtcsmoke: {s} OK（{d:.2}s）\n", .{ label, elapsed });
                return;
            }
            std.debug.print("smtcsmoke: 收到意外的键 {s}（等 {s}）\n", .{ @tagName(b), label });
        }
        Sleep(50);
    }
    return fail("注入 {s} 后 {d:.0}s 内未收到事件（系统媒体会话可能被其他播放器占用，或 fire→Invoke 链路仍断）", .{ label, timeout_s });
}

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .windows) {
        @compileError("smtcsmoke 仅 windows 目标");
    }

    // MIN 模式（AM_SMTC_MIN=1）：完全绕开 MF/MTA——进程内只有 SMTC 的 STA
    // （MusicPlayer2 同形态单 STA）。用于判别崩溃是否由进程内其他 COM
    // 初始化（MF 的 MTA / 初始化顺序）污染。播放状态直接 setPaused(false)。
    const no_mf = blk: {
        var eb: [8]u8 = undefined;
        break :blk GetEnvA("AM_SMTC_MIN", &eb);
    };
    if (no_mf) {
        var sess = smtc.Session{};
        sess.attach(init.gpa);
        sess.setTrack("Smoke Track - Smoke Artist");
        sess.setPaused(false);
        Sleep(1500); // STA 消化请求 → SMTC 进入 Playing
        std.debug.print("smtcsmoke: MIN 模式（无 MF/MTA），注入媒体键\n", .{});
        inline for (.{ .{ mf.MediaButton.play_pause, VK_MEDIA_PLAY_PAUSE }, .{ mf.MediaButton.next, VK_MEDIA_NEXT_TRACK }, .{ mf.MediaButton.prev, VK_MEDIA_PREV_TRACK } }) |kc| {
            const label = @tagName(kc[0]);
            g_stray = null;
            tapMediaKey(kc[1]);
            var got: bool = false;
            var el: f64 = 0;
            while (el < 6.0) : (el += 0.1) {
                if (g_stray == null) g_stray = sess.takeButton();
                if (g_stray) |b| {
                    if (b == kc[0]) {
                        std.debug.print("smtcsmoke: {s} OK（{d:.1}s）\n", .{ label, el });
                        got = true;
                    } else {
                        std.debug.print("smtcsmoke: 收到意外的键 {s}（等 {s}）\n", .{ @tagName(b), label });
                        got = true; // 收到了别的键也算 fire 通了，继续下一个
                    }
                    g_stray = null;
                }
                if (got) break;
                Sleep(100);
            }
            if (!got) return fail("MIN 模式 {s} 未达（fire 链路断）", .{label});
        }
        std.debug.print("smtcsmoke: PASS（MIN 模式全链路到达）\n", .{});
        return;
    }

    // 1. 生成 WAV 写进 cwd，取绝对路径喂 MF
    const wav = try buildWav(init.gpa);
    defer init.gpa.free(wav);
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "smtcsmoke_tmp.wav", .data = wav }) catch {
        return fail("写 smtcsmoke_tmp.wav 失败", .{});
    };
    defer std.Io.Dir.cwd().deleteFile(init.io, "smtcsmoke_tmp.wav") catch {};
    const wav_path: []const u8 = blk: {
        const cwd = std.process.currentPathAlloc(init.io, init.gpa) catch break :blk "smtcsmoke_tmp.wav";
        defer init.gpa.free(cwd);
        break :blk std.fmt.allocPrint(init.gpa, "{s}\\smtcsmoke_tmp.wav", .{cwd}) catch "smtcsmoke_tmp.wav";
    };
    defer if (wav_path.ptr != "smtcsmoke_tmp.wav".ptr) init.gpa.free(wav_path);

    // 2. MF 后端启动（内部 attach SMTC）+ 真播放
    var p = mf.Player.init(init.gpa);
    defer p.deinit();
    if (!p.startAsync()) return fail("startAsync 失败（COM/MF 不可用）", .{});
    std.debug.print("smtcsmoke: {s}\n", .{wav_path});
    if (!p.loadFile(wav_path, "Smoke Track - Smoke Artist")) return fail("loadFile 失败", .{});

    // 3. 等真播放推进（有真音频流的会话才会被系统认作活动媒体会话）
    p.setPause(false); // SMTC 状态 Playing：按键路由只挑活动会话
    var elapsed: f64 = 0;
    while (elapsed < 10.0) : (elapsed += 0.05) {
        if (pumpOnce(&p).position_s > 0.5) break;
        Sleep(50);
    } else return fail("10s 内未开始播放（MF 链路问题，先跑 zig build mfsmoke）", .{});

    // NO_HOTKEY 模式（AM_SMTC_NO_HOTKEY=1）：热键已关、handler 默认不注册
    // （MC.dll fire UAF，见 smtc.zig 头注）——此模式验证「按键进 SMTC 路由
    // 也不崩」的防崩回归；AM_SMTC_BTNEVENTS=1 时 fire 全链路恢复，仍按断言
    // 走。浸润 8s：三键各注入两轮，进程活着 + SMTC 会话仍在 = PASS。
    if (EnvExists("AM_SMTC_NO_HOTKEY")) {
        const btn_events = EnvExists("AM_SMTC_BTNEVENTS");
        if (!btn_events) {
            std.debug.print("smtcsmoke: 防崩浸润（无热键无 handler），注入媒体键\n", .{});
            var t: f64 = 0;
            while (t < 8.0) : (t += 1.0) {
                tapMediaKey(VK_MEDIA_PLAY_PAUSE);
                tapMediaKey(VK_MEDIA_NEXT_TRACK);
                tapMediaKey(VK_MEDIA_PREV_TRACK);
                Sleep(1000);
                _ = pumpOnce(&p); // 保活泵
            }
            if (p.status() == null) return fail("浸润中播放器状态丢失", .{});
            std.debug.print("smtcsmoke: PASS（浸润 8s 无崩溃——MC.dll fire UAF 未触发）\n", .{});
            return;
        }
    }
    std.debug.print("smtcsmoke: 播放中，注入媒体键\n", .{});

    // 4. 三键矩阵（每键注入后独立等待）
    try expectKey(&p, .play_pause, VK_MEDIA_PLAY_PAUSE, 6.0);
    try expectKey(&p, .next, VK_MEDIA_NEXT_TRACK, 6.0);
    try expectKey(&p, .prev, VK_MEDIA_PREV_TRACK, 6.0);

    std.debug.print("smtcsmoke: PASS（play_pause/next/prev 全链路到达）\n", .{});
}
