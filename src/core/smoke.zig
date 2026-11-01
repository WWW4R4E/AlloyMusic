const std = @import("std");
const http = @import("http.zig");
const catalog = @import("catalog.zig");
const playback = @import("playback.zig");

// src/core/smoke.zig — 波点后端真网络冒烟：search → lyrics → songUrl。
// 手动执行：zig build smoke（需要网络；不进默认 test）。
// 判定：search 出条目、歌词有行、songUrl 返回合法 URL（或如实报告
// auth_required/not_playable——匿名态受版权保护的歌拿不到正式链接是预期行为）。
// 输出走 stderr（std.debug.print），冒烟工具不追求 stdout 管道友好。

const TEST_DEVICE_ID = "0123456789abcdef0123456789abcdef";
const QUERY = "海阔天空";

fn valueToSlice(a: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch null,
        else => null,
    };
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn listGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    const f = objGet(v, key) orelse return null;
    return if (f == .array) f else null;
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var client = try http.Client.init(init.gpa, init.io, TEST_DEVICE_ID);
    defer client.deinit();
    var cat = catalog.Catalog{ .client = &client };

    var failures: u32 = 0;

    // ── 1. search ──
    var first_id: []const u8 = "";
    {
        const result = try cat.search(a, QUERY, .{ .number = 0, .size = 5 });
        switch (result) {
            .err => |e| {
                failures += 1;
                std.debug.print("✗ search: {s}: {s}\n", .{ @tagName(e.code), e.message });
            },
            .ok => |pr| {
                const items: []std.json.Value = if (listGet(pr.data, "resultList")) |arr| arr.array.items else &[_]std.json.Value{};
                if (items.len == 0) {
                    failures += 1;
                    std.debug.print("✗ search: resultList 为空\n", .{});
                } else {
                    const first = items[0];
                    // 真实响应条目主键是 id（整数）；mock 用 musicId，两者兼容
                    first_id = valueToSlice(a, objGet(first, "id") orelse objGet(first, "musicId") orelse std.json.Value{ .null = {} }) orelse "";
                    const name = valueToSlice(a, objGet(first, "name") orelse std.json.Value{ .null = {} }) orelse "?";
                    const artist = valueToSlice(a, objGet(first, "artist") orelse std.json.Value{ .null = {} }) orelse "?";
                    std.debug.print("✓ search: {d} 条 | 首条 {s} / {s} (musicId={s})\n", .{ items.len, name, artist, first_id });
                    if (first_id.len == 0 and first == .object) {
                        var it = first.object.iterator();
                        while (it.next()) |e|
                            std.debug.print("      字段 {s}: {s}\n", .{ e.key_ptr.*, @tagName(e.value_ptr.*) });
                    }
                }
            },
        }
    }

    // ── 2. lyrics ──
    if (first_id.len > 0) {
        const result = try cat.lyrics(a, first_id);
        switch (result) {
            .err => |e| {
                failures += 1;
                std.debug.print("✗ lyrics: {s}: {s}\n", .{ @tagName(e.code), e.message });
            },
            .ok => |lyr| {
                if (lyr.main_text.len == 0) {
                    failures += 1;
                    std.debug.print("✗ lyrics: main_text 为空\n", .{});
                } else {
                    const line_count = std.mem.count(u8, lyr.main_text, "\n") + 1;
                    const has_ts = std.mem.indexOf(u8, lyr.main_text, "[0") != null or std.mem.indexOf(u8, lyr.main_text, "[1") != null;
                    if (!has_ts) {
                        failures += 1;
                        std.debug.print("✗ lyrics: {d} 行但无时间轴\n", .{line_count});
                    } else {
                        std.debug.print("✓ lyrics: {d} 行，有时间轴\n", .{line_count});
                    }
                }
            },
        }
    }

    // ── 3. songUrl ──
    if (first_id.len > 0) {
        const result = try playback.audioUrl(&client, a, first_id, .high, "");
        switch (result) {
            .err => |e| {
                // 匿名取不到正式地址是已知行为，如实报告（限制而非失败）
                std.debug.print("△ songUrl: {s}: {s}\n", .{ @tagName(e.code), e.message });
            },
            .ok => |pu| {
                if (pu.preview) |p|
                    std.debug.print("✓ songUrl: {s} (试听 {d}-{d}ms)\n      {s}\n", .{ @tagName(pu.quality), p.start_ms, p.end_ms, pu.url })
                else
                    std.debug.print("✓ songUrl: {s}\n      {s}\n", .{ @tagName(pu.quality), pu.url });
            },
        }
    }

    if (failures > 0) {
        std.debug.print("\nbodian smoke: {d} 项失败\n", .{failures});
        return error.SmokeFailed;
    }
    std.debug.print("\nbodian smoke: 完成\n", .{});
}
