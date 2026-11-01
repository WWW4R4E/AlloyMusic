// src/ui/playmode.zig — 播放模式纯逻辑（列表循环/单曲循环/随机），零 IO 可离线测试。
//
// 设计要点：
//   1. 队列（Song 列表）与播放顺序（下标访问次序）分离——模式只是
//      "给定 cursor，下一首/上一首是谁"的纯函数 + 一点随机状态。
//   2. 随机用"洗牌袋"而非每次随机抽：一次 Fisher-Yates 洗出完整顺序，
//      走完一遍前绝不重复。当前歌固定在袋首，激活随机时从袋二开始。
//   3. 单曲循环：eof 触发的下一首 = 自己；用户手动切歌 = 正常切下一首
//      （网易云等所有主流播放器都是这个语义）。
//   4. 队列变化（增删歌）由调用方 bump generation，shuffle 检测到后重建
//      洗牌袋（当前歌仍钉在袋首，不会打断正在听的歌）。
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mode = enum {
    sequence, // 列表循环：到尾绕回头
    one, // 单曲循环
    shuffle, // 随机播放（洗牌袋）

    pub fn cycle(self: Mode) Mode {
        return switch (self) {
            .sequence => .one,
            .one => .shuffle,
            .shuffle => .sequence,
        };
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .sequence => "列表循环",
            .one => "单曲循环",
            .shuffle => "随机",
        };
    }
};

/// 什么触发了切歌：eof（自然播完）或 user（手动 n/p 键）。
/// 单曲循环只拦 eof；手动切永远前进。
pub const Trigger = enum { eof, user };

pub const Shuffle = struct {
    /// 队列下标的一个排列。order[pos] = 当前正播的队列下标。
    order: []u32,
    pos: usize = 0,
    /// 重建时 PlayControl.queue_gen 的快照，用于检测队列变化。
    gen: u64 = 0,
};

pub const PlayControl = struct {
    mode: Mode = .sequence,
    /// 洗牌随机源。默认种子在 Model 字面量初始化时即可用（comptime 常量）。
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15),
    /// 队列内容版本号：入队/删歌/清空时由调用方 +1，shuffle 据此重建。
    queue_gen: u64 = 0,
    shuffle: ?Shuffle = null,

    pub fn deinit(self: *PlayControl, gpa: Allocator) void {
        if (self.shuffle) |s| gpa.free(s.order);
        self.shuffle = null;
    }

    /// 队列内容变了必须调用（增删歌、清空、整体替换）。
    pub fn bumpQueue(self: *PlayControl) void {
        self.queue_gen += 1;
    }

    /// 切模式。切到随机时立即建袋（当前歌钉袋首）。
    pub fn setMode(self: *PlayControl, gpa: Allocator, m: Mode, cursor: usize, queue_len: usize) void {
        if (m == .shuffle and self.mode != .shuffle) {
            self.rebuildShuffle(gpa, cursor, queue_len);
        }
        self.mode = m;
    }

    /// 重建洗牌袋：当前歌钉在袋首，其余 Fisher-Yates。
    fn rebuildShuffle(self: *PlayControl, gpa: Allocator, cursor: usize, queue_len: usize) void {
        if (self.shuffle) |s| gpa.free(s.order);
        if (queue_len == 0) {
            self.shuffle = null;
            return;
        }
        const order = gpa.alloc(u32, queue_len) catch {
            self.shuffle = null;
            return;
        };
        for (order, 0..) |*v, i| v.* = @intCast(i);
        // 当前歌换到 0 号位
        const cur: u32 = @intCast(@min(cursor, queue_len - 1));
        order[cur] = 0;
        order[0] = cur;
        // 其余部分 Fisher-Yates（i 从 len-1 到 2，j ∈ [1,i) 保证 0 号位
        // 的当前歌不被换走）
        var i: usize = order.len - 1;
        while (i > 1) : (i -= 1) {
            const j = self.rng.random().uintLessThan(usize, i - 1) + 1; // j ∈ [1, i)
            std.mem.swap(u32, &order[i], &order[j]);
        }
        self.shuffle = .{ .order = order, .pos = 0, .gen = self.queue_gen };
    }

    /// 计算下一首的队列下标。返回 null = 停止（队列空）。
    /// trigger=eof 时单曲循环返回 cursor 自己。
    /// eof 在随机模式下走完一袋 = 重头再洗（随机视为无限循环）。
    pub fn nextIndex(self: *PlayControl, gpa: Allocator, cursor: usize, queue_len: usize, trigger: Trigger) ?usize {
        if (queue_len == 0) return null;
        switch (self.mode) {
            // 单曲循环只拦 eof；用户手动切歌走底部的通用前进逻辑
            .one => if (trigger == .eof) return @min(cursor, queue_len - 1),
            .sequence => {
                const cur = @min(cursor, queue_len - 1);
                return if (cur + 1 >= queue_len) 0 else cur + 1;
            },
            .shuffle => {
                var sh = &(self.shuffle orelse blk: {
                    self.rebuildShuffle(gpa, cursor, queue_len);
                    break :blk (self.shuffle orelse return null);
                });
                // 队列变过（generation 或长度）→ 重建（当前歌钉袋首）
                if (sh.gen != self.queue_gen or sh.order.len != queue_len) {
                    const cur_idx = sh.order[@min(sh.pos, sh.order.len - 1)];
                    self.rebuildShuffle(gpa, cur_idx, queue_len);
                    sh = &(self.shuffle orelse return null);
                }
                if (sh.pos + 1 < sh.order.len) {
                    sh.pos += 1;
                    return sh.order[sh.pos];
                }
                // 一袋走完：重洗，当前歌钉新袋首，跳到袋二（避免重播当前歌）
                const cur_idx = sh.order[sh.pos];
                self.rebuildShuffle(gpa, cur_idx, queue_len);
                const sh2 = &(self.shuffle orelse return null);
                if (sh2.order.len > 1) {
                    sh2.pos = 1;
                    return sh2.order[1];
                }
                return sh2.order[0];
            },
        }
        // .one + user 手动切歌：按列表循环前进
        const cur = @min(cursor, queue_len - 1);
        return if (cur + 1 >= queue_len) 0 else cur + 1;
    }

    /// 上一首。随机模式下沿洗牌袋回退；袋首再按 p 则重建一袋
    /// （当前歌钉新袋首，跳到袋二）。
    pub fn prevIndex(self: *PlayControl, gpa: Allocator, cursor: usize, queue_len: usize) ?usize {
        if (queue_len == 0) return null;
        switch (self.mode) {
            .sequence => {
                const cur = @min(cursor, queue_len - 1);
                return if (cur == 0) queue_len - 1 else cur - 1;
            },
            .one => return @min(cursor, queue_len - 1), // 单曲循环 p 也回自己
            .shuffle => {
                const sh = &(self.shuffle orelse {
                    self.rebuildShuffle(gpa, cursor, queue_len);
                    // 新袋袋首就是当前歌，p 无处可退
                    return cursor;
                });
                if (sh.pos > 0) {
                    sh.pos -= 1;
                    return sh.order[sh.pos];
                }
                // 袋首：重建，跳到新袋的第二首（第一首是自己）
                const cur_idx = sh.order[0];
                self.rebuildShuffle(gpa, cur_idx, queue_len);
                const sh2 = &(self.shuffle orelse return null);
                if (sh2.order.len > 1) {
                    sh2.pos = 1;
                    return sh2.order[1];
                }
                return sh2.order[0];
            },
        }
    }
};

// ── 测试 ──

test "sequence: 到尾绕回，user/eof 同语义" {
    var pc: PlayControl = .{};
    defer pc.deinit(std.testing.allocator);
    try expectNext(&pc, 0, 3, .eof, 1);
    try expectNext(&pc, 2, 3, .user, 0); // 尾→头
    try expectPrev(&pc, 0, 3, 2); // 头→尾
}

test "one: eof 回自己，user 正常前进" {
    var pc: PlayControl = .{ .mode = .one };
    defer pc.deinit(std.testing.allocator);
    try expectNext(&pc, 1, 3, .eof, 1);
    try expectNext(&pc, 1, 3, .user, 2);
    try expectPrev(&pc, 1, 3, 1);
}

test "shuffle: 一袋内不重复且全覆盖" {
    var pc: PlayControl = .{ .mode = .shuffle };
    defer pc.deinit(std.testing.allocator);
    const n: usize = 8;
    var seen: [n]bool = @splat(false);
    seen[0] = true; // 当前歌 0 已播
    var cursor: usize = 0;
    var steps: usize = 0;
    while (steps < n - 1) : (steps += 1) {
        cursor = (pc.nextIndex(std.testing.allocator, cursor, n, .user) orelse return error.Failed);
        try std.testing.expect(!seen[cursor]);
        seen[cursor] = true;
    }
    // 再走一步 = 新一袋（可能任意歌，但不能崩）
    _ = pc.nextIndex(std.testing.allocator, cursor, n, .user);
}

test "shuffle: prev 沿袋回退" {
    var pc: PlayControl = .{ .mode = .shuffle };
    defer pc.deinit(std.testing.allocator);
    const n: usize = 5;
    const a = (pc.nextIndex(std.testing.allocator, 0, n, .user) orelse return error.Failed);
    const b = (pc.nextIndex(std.testing.allocator, a, n, .user) orelse return error.Failed);
    const back = (pc.prevIndex(std.testing.allocator, b, n) orelse return error.Failed);
    try std.testing.expectEqual(a, back); // 上一首确实是刚播过的 a
}

test "shuffle: 队列变长后重建不崩、当前歌在袋首" {
    var pc: PlayControl = .{ .mode = .shuffle };
    defer pc.deinit(std.testing.allocator);
    _ = pc.nextIndex(std.testing.allocator, 0, 3, .user);
    pc.bumpQueue(); // 模拟入队
    const cur = pc.shuffle.?.order[pc.shuffle.?.pos];
    const nxt = pc.nextIndex(std.testing.allocator, cur, 5, .user) orelse return error.Failed;
    try std.testing.expect(nxt < 5);
}

test "shuffle: 长度不变但 bump 过也重建（同长度换内容）" {
    var pc: PlayControl = .{ .mode = .shuffle };
    defer pc.deinit(std.testing.allocator);
    _ = pc.nextIndex(std.testing.allocator, 0, 4, .user);
    const before = pc.shuffle.?.gen;
    pc.bumpQueue();
    try std.testing.expect(before != pc.queue_gen);
    // 同长度：靠 gen 而不是 len 检测
    _ = pc.nextIndex(std.testing.allocator, 1, 4, .user);
    try std.testing.expectEqual(pc.queue_gen, pc.shuffle.?.gen);
}

test "mode.cycle 与 label" {
    try std.testing.expectEqual(Mode.one, Mode.sequence.cycle());
    try std.testing.expectEqual(Mode.shuffle, Mode.one.cycle());
    try std.testing.expectEqual(Mode.sequence, Mode.shuffle.cycle());
}

fn expectNext(pc: *PlayControl, cursor: usize, len: usize, t: Trigger, want: usize) !void {
    const got = pc.nextIndex(std.testing.allocator, cursor, len, t) orelse return error.NoNext;
    try std.testing.expectEqual(want, got);
}

fn expectPrev(pc: *PlayControl, cursor: usize, len: usize, want: usize) !void {
    const got = pc.prevIndex(std.testing.allocator, cursor, len) orelse return error.NoPrev;
    try std.testing.expectEqual(want, got);
}
