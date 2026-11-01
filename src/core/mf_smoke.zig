const std = @import("std");
const builtin = @import("builtin");
const mf = @import("mf.zig");

// src/core/mf_smoke.zig — Media Foundation 冒烟（仅 windows，无网络）：
// 本地生成 3s 44.1kHz 正弦 WAV → MF 打开 → READY → 断言时长/位置推进/
// 暂停冻结/暂停态 seek/resume 前进/EOF/二次 loadFile 换曲，全过 exit 0。
// 真链接手动验收：./zig-out/bin/amtui-mfsmoke <url 或本地路径>

const SAMPLE_RATE: f64 = 44100.0;
const DURATION_S: f64 = 3.0;
const AMPLITUDE: f64 = 12000.0;

extern "kernel32" fn Sleep(milliseconds: u32) void;

fn buildWav(gpa: std.mem.Allocator, duration_s: f64) ![]u8 {
    const n_samples: usize = @intFromFloat(SAMPLE_RATE * duration_s);
    const data_len = n_samples * 2; // 16-bit mono
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
    put.u32le(buf, &w, @intFromFloat(SAMPLE_RATE * 2)); // byte rate
    put.u16le(buf, &w, 2); // block align
    put.u16le(buf, &w, 16); // bits per sample
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

fn fail(comptime fmt: []const u8, args: anytype) error{MfSmoke} {
    std.debug.print("mfsmoke: FAIL " ++ fmt ++ "\n", args);
    return error.MfSmoke;
}

fn near(v: f64, want: f64, tol: f64, what: []const u8) !void {
    if (@abs(v - want) > tol) return fail("{s}: {d:.3} 超出 {d:.3}±{d:.3}", .{ what, v, want, tol });
}

/// 泵一轮（收结果 + 捞事件）并读状态。MF 的 status 永不 null。
fn pump(p: *mf.Player) mf.Status {
    var epos: ?i64 = null;
    var epause: ?bool = null;
    p.drain(&epos, &epause);
    // 临时验证：消费 SMTC 媒体键，证明 路由→invoke→标志→takeMediaButton 全链路
    if (p.takeMediaButton()) |b| {
        std.debug.print("mfsmoke: MEDIA KEY {s}\n", .{switch (b) {
            .play_pause => "play_pause",
            .next => "next",
            .prev => "prev",
        }});
    }
    return p.status().?;
}

/// 等 duration 就绪（open + topology READY 完成），返回当时的 status。
/// eof 且无时长 = 打开/拓扑失败：立刻报错并带上 HRESULT。
fn waitDuration(p: *mf.Player, timeout_s: f64) !mf.Status {
    var elapsed: f64 = 0;
    while (elapsed < timeout_s) : (elapsed += 0.05) {
        const st = pump(p);
        if (st.duration_s > 0) return st;
        if (st.eof) {
            const le: u32 = @bitCast(p.last_error);
            if (le == 16)
                return fail("SetTopology 失败：HRESULT=0x{x:0>8}（负值查 MF 错误码）", .{@as(u32, @bitCast(p.topo_hr))});
            if (le > 0)
                return fail("拓扑构建失败：阶段码 {d}（1=取流数 2=无音频流 3=建拓扑 4/5=建节点 6=音频渲染激活 7=STREAMID 8=NOSHUTDOWN 9=SOURCE 10=PD 11=SD 12=SetObject 13/14=AddNode 15=ConnectOutput 16=SetTopology 17=无session）", .{le});
            return fail("打开失败：last_error=0x{x:0>8}", .{le});
        }
        Sleep(50);
    }
    return fail("{d:.0}s 内未拿到时长（open/READY 超时）eof={} last_error=0x{x:0>8}", .{ timeout_s, p.eof_seen, @as(u32, @bitCast(p.last_error)) });
}

fn waitPosAbove(p: *mf.Player, threshold: f64, timeout_s: f64, what: []const u8) !void {
    var elapsed: f64 = 0;
    var last = pump(p);
    var max_pos: f64 = 0;
    while (elapsed < timeout_s) : (elapsed += 0.05) {
        last = pump(p);
        max_pos = @max(max_pos, last.position_s);
        if (last.position_s > threshold) return;
        Sleep(50);
    }
    return fail("{s}: {d:.0}s 内位置未越过 {d:.3}（末次 pos={d:.2} max={d:.2} dur={d:.2} eof={} last_err=0x{x:0>8}）", .{ what, timeout_s, threshold, last.position_s, max_pos, last.duration_s, last.eof, @as(u32, @bitCast(p.last_error)) });
}

/// 暂停态断言：两次采样（间隔 200ms）位置几乎不动。
fn waitStable(p: *mf.Player, timeout_s: f64, what: []const u8) !void {
    var elapsed: f64 = 0;
    while (elapsed < timeout_s) : (elapsed += 0.2) {
        const a = pump(p).position_s;
        Sleep(200);
        const b = pump(p).position_s;
        if (a > 0.2 and @abs(b - a) < 0.05) return;
    }
    return fail("{s}: 位置仍在变化", .{what});
}

fn waitPosIn(p: *mf.Player, lo: f64, hi: f64, timeout_s: f64, what: []const u8) !void {
    var elapsed: f64 = 0;
    while (elapsed < timeout_s) : (elapsed += 0.05) {
        const st = pump(p);
        if (st.position_s >= lo and st.position_s <= hi) return;
        Sleep(50);
    }
    return fail("{s}: {d:.0}s 内位置未落到 [{d:.2},{d:.2}]", .{ what, timeout_s, lo, hi });
}

fn waitEof(p: *mf.Player, timeout_s: f64) !void {
    var elapsed: f64 = 0;
    while (elapsed < timeout_s) : (elapsed += 0.05) {
        if (pump(p).eof) return;
        Sleep(50);
    }
    return fail("{d:.0}s 内未收到 EOF", .{timeout_s});
}

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .windows) {
        @compileError("mfsmoke 仅 windows 目标（Media Foundation）");
    }

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // argv[0]
    if (args_it.next()) |target| return playExternal(init, target);
    return runBuiltIn(init);
}

/// 手动模式：播放给定 url / 本地路径，到 EOF 或 60s 超时退出。
fn playExternal(init: std.process.Init, target: []const u8) !void {
    var p = mf.Player.init(init.gpa);
    defer p.deinit();
    if (!p.startAsync()) return fail("startAsync 失败（COM/MF 初始化不可用）", .{});
    if (!p.loadFile(target, "manual")) return fail("loadFile 失败", .{});
    std.debug.print("mfsmoke: 播放 {s}（到 EOF 或 60s 超时）\n", .{target});
    var elapsed: f64 = 0;
    while (elapsed < 60.0) : (elapsed += 0.1) {
        const st = pump(&p);
        if (st.duration_s > 0) {
            std.debug.print("\r[{d:6.1}/{d:6.1}s]   ", .{ st.position_s, st.duration_s });
        }
        if (st.eof) {
            std.debug.print("\nmfsmoke: PASS（播放到 EOF）\n", .{});
            return;
        }
        Sleep(100);
    }
    std.debug.print("\n", .{});
    return fail("60s 内未到 EOF", .{});
}

fn runBuiltIn(init: std.process.Init) !void {
    // 1. 生成 WAV 写进 cwd（绝对路径喂 MF，SourceResolver 接受文件路径）
    const wav = try buildWav(init.gpa, DURATION_S);
    defer init.gpa.free(wav);
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "mfsmoke_tmp.wav", .data = wav }) catch {
        return fail("写 mfsmoke_tmp.wav 失败", .{});
    };
    defer std.Io.Dir.cwd().deleteFile(init.io, "mfsmoke_tmp.wav") catch {};
    const wav_path: []const u8 = blk: {
        const cwd = std.process.currentPathAlloc(init.io, init.gpa) catch break :blk "mfsmoke_tmp.wav";
        defer init.gpa.free(cwd);
        break :blk std.fmt.allocPrint(init.gpa, "{s}\\mfsmoke_tmp.wav", .{cwd}) catch "mfsmoke_tmp.wav";
    };
    defer if (wav_path.ptr != "mfsmoke_tmp.wav".ptr) init.gpa.free(wav_path);

    // 2. 启动 + 加载
    var p = mf.Player.init(init.gpa);
    defer p.deinit();
    if (!p.startAsync()) return fail("startAsync 失败（COM/MF 初始化不可用）", .{});
    std.debug.print("mfsmoke: {s}\n", .{wav_path});
    if (!p.loadFile(wav_path, "smoke")) return fail("loadFile 失败", .{});

    // 3. open → READY：时长 ≈ 3.0s
    const st = try waitDuration(&p, 10.0);
    try near(st.duration_s, DURATION_S, 0.25, "duration");

    // 4. 位置前进 > 0.5s（证明 Start 真发生）
    try waitPosAbove(&p, 0.5, 10.0, "位置前进");

    // 5. 暂停 → 位置冻结
    p.setPause(true);
    try waitStable(&p, 2.0, "暂停冻结");

    // 6. 暂停态 seek 到 1.0 → 位置落到 [0.9, 1.4]（暂停中位置只被 seek 推动）
    p.seekTo(1.0);
    try waitPosIn(&p, 0.9, 1.4, 3.0, "seek");

    // 7. resume → 位置继续前进
    p.setPause(false);
    try waitPosAbove(&p, 1.6, 5.0, "resume 前进");

    // 8. EOF（从 ~1s 处播到 3s 曲终）
    try waitEof(&p, 10.0);

    // 9. 换曲（SetTopology 替换路径）：换成**时长不同**的另一文件（6s）。
    // 用不同文件是为了让断言无歧义：旧 bug（MESessionEnded 不 Stop，时钟停
    // 在 A 末尾 ≈3s，B 的 Start(VT_EMPTY) 从旧位置续播）下 B 的位置会是
    // ~3.0 且时长还是读 B 自己的 6s——两个断言一起抓。
    const wav2 = try buildWav(init.gpa, 6.0);
    defer init.gpa.free(wav2);
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "mfsmoke_tmp2.wav", .data = wav2 }) catch {
        return fail("写 mfsmoke_tmp2.wav 失败", .{});
    };
    defer std.Io.Dir.cwd().deleteFile(init.io, "mfsmoke_tmp2.wav") catch {};
    const wav2_path: []const u8 = blk: {
        const cwd = std.process.currentPathAlloc(init.io, init.gpa) catch break :blk "mfsmoke_tmp2.wav";
        defer init.gpa.free(cwd);
        break :blk std.fmt.allocPrint(init.gpa, "{s}\\mfsmoke_tmp2.wav", .{cwd}) catch "mfsmoke_tmp2.wav";
    };
    defer if (wav2_path.ptr != "mfsmoke_tmp2.wav".ptr) init.gpa.free(wav2_path);

    if (!p.loadFile(wav2_path, "smoke2")) return fail("二次 loadFile 失败", .{});
    const st2 = try waitDuration(&p, 10.0);
    // 9.5 EOF→换曲后：时长必须是 B 自己的 ≈6s（证明加载的是新文件），
    // 且位置必须归零。回归断言（2026-10-30 真机 bug）：此前 MESessionEnded
    // 未 Stop，时钟停在旧曲末尾，B 的 Start(VT_EMPTY) 从旧位置续播——位置
    // 跨拓扑残留、短歌秒进 EOF 连跳、seek 落在坏状态失效。
    try near(st2.duration_s, 6.0, 0.4, "换曲后时长（应为新文件 6s）");
    if (st2.position_s > 1.5)
        return fail("换曲后位置残留 {d:.2}s（MESessionEnded 未归零时钟）", .{st2.position_s});
    try waitPosAbove(&p, 0.3, 10.0, "二次播放推进");

    // 10. 播放中切歌（用户按 n 的路径）：SetTopology 必须 IMMEDIATE 立即
    // 切换、且新歌从 0 起。回归点（2026-10-31）：flags=0 是"排队"语义
    // （等 A 放完自动接上，时钟连续），切歌会延迟到曲末且 B 继承 A 的
    // 末尾位置——TUI 表现即"B 直接继承上一首的进度条"。
    if (!p.loadFile(wav_path, "mid-switch-A")) return fail("中途 loadFile(A) 失败", .{});
    _ = try waitDuration(&p, 10.0);
    try waitPosAbove(&p, 0.8, 10.0, "A 起播");
    if (!p.loadFile(wav2_path, "mid-switch-B")) return fail("中途 loadFile(B) 失败", .{});
    // B 必须从 0 起播：READY 后首个样本位置 ≤0.5（排除旧时钟位续播/跨会话
    // 残留），且随后推进。旧 bug 下 B 会从 A 的末尾位置续播。
    // （勿先等位置落回 [0,0.5] 再断言推进：B 起播后位置一路上涨，只有
    // 自然 EOF 归零后才 ≤0.5——旧断言顺序恰好等到 B 放完，必然假失败。）
    const st3 = try waitDuration(&p, 10.0);
    try near(st3.duration_s, 6.0, 0.4, "中途切歌时长（应为 B 自己 6s）");
    if (st3.position_s > 0.5)
        return fail("中途切歌位置残留 {d:.2}s（换曲未归零）", .{st3.position_s});
    try waitPosAbove(&p, 0.8, 10.0, "中途切歌推进");

    std.debug.print("mfsmoke: PASS（打开/时长/推进/暂停/seek/resume/EOF/换曲/中途切歌 全过）\n", .{});
}
