const std = @import("std");
const qq = @import("providers/qq.zig");
const Param = @import("providers/mod.zig").Param;

// src/core/qq_smoke.zig — QQ 直调实现冒烟：跑核心 op，与 sidecar fixtures 对照。
// 手动执行：zig build qqsmoke -- <op> [arg]
//   search 海阔天空 | lyrics <mid> | songUrl <mid> | radio | library | liked
// 判定走 stderr；退出码 0 = 信封 ok，2 = err。

fn show(a: std.mem.Allocator, v: std.json.Value) void {
    const s = std.json.Stringify.valueAlloc(a, v, .{}) catch return;
    const n = @min(s.len, 100000);
    std.debug.print("{s}{s}\n", .{ s[0..n], if (s.len > n) "…" else "" });
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next();
    const op = args_it.next() orelse "search";
    const arg1 = args_it.next() orelse "";

    var buf: [4]Param = undefined;
    var n: usize = 0;
    if (arg1.len > 0) {
        if (std.mem.eql(u8, op, "search")) {
            buf[n] = .{ .name = "kw", .value = arg1 };
            n += 1;
            buf[n] = .{ .name = "page", .value = "0" };
            n += 1;
            buf[n] = .{ .name = "size", .value = "5" };
            n += 1;
        } else {
            buf[n] = .{ .name = "mid", .value = arg1 };
            n += 1;
            buf[n] = .{ .name = "id", .value = arg1 };
            n += 1;
        }
    }
    const params = buf[0..n];

    const r = (try qq.call(init.gpa, init.io, a, op, params)).?;
    switch (r) {
        .ok => |v| {
            std.debug.print("[ok ] {s}\n", .{op});
            show(a, v);
        },
        .err => |e| {
            std.debug.print("[err] {s}: {s} — {s}\n", .{ op, @tagName(e.code), e.message });
            std.process.exit(2);
        },
    }
}
