// src/core/providers/mod.zig — 进程内 provider 直调层（zig-sidecar-port 迁移缝）。
//
// 每个 backend 一个子模块，op 签名对齐 sidecar envelope（{ok:true,...} /
// {ok:false,code,message}，见 sidecar/server.cjs 头注释）。尚未移植的 backend
// `available = false`、call 返回 null，ui/provider.zig 回落 sidecar HTTP；
// 移植完成一个改一个 available，全部完成后 sidecar 整体删除。
//
// op 名沿用 sidecar 时代：search/songUrl/lyrics/playlist/playlistTracks/
// recommend/fm/radio/library/liked/like + 登录类 loginQrKey/loginQrCheck/logout。

pub const paths = @import("../paths.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const bodian = @import("bodian.zig");
pub const netease = @import("netease.zig");
pub const qq = @import("qq.zig");

pub const Param = @import("../http.zig").Param;
pub const Result = @import("../http.zig").Result;
pub const ErrorCode = @import("../http.zig").ErrorCode;

pub const Name = enum { bodian, netease, qq };

/// 该 backend 的 op 是否已有纯 Zig 实现。
pub fn hasDirect(name: Name) bool {
    return switch (name) {
        .bodian => bodian.available,
        .netease => netease.available,
        .qq => qq.available,
    };
}

/// 直调入口。返回 null = 该 backend 尚无 Zig 实现，调用方回落 sidecar。
/// 参数 params 与 sidecar 同形（name/value 字符串对），移植后的实现自行解析。
/// gpa/io 供实现自建 HTTP 客户端；arena 约束所有产物分配（随 Outcome 交接）。
pub fn call(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    name: Name,
    op: []const u8,
    params: []const Param,
) Allocator.Error!?Result(std.json.Value) {
    return switch (name) {
        .bodian => try bodian.call(gpa, io, arena, op, params),
        .netease => try netease.call(gpa, io, arena, op, params),
        .qq => try qq.call(gpa, io, arena, op, params),
    };
}

pub const Health = struct {
    /// 数组序 [bodian, netease, qq]（与 ui/model Backend 枚举序一致）
    logged_in: [3]bool = .{ false, false, false },
    nickname: [3][]const u8 = .{ "", "", "" },
    user_id: [3][]const u8 = .{ "", "", "" },
};

/// 登录态快照（sidecar /health 的本地化替代）：直接读 auth.json。
pub fn health(arena: Allocator, io: std.Io, auth_path: []const u8) Allocator.Error!Health {
    var h = Health{};
    const raw = std.Io.Dir.cwd().readFileAlloc(io, auth_path, arena, .limited(1 << 20)) catch
        return h;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return h;
    if (v != .object) return h;

    if (v.object.get("netease")) |n| {
        const cookie = if (n == .object) (n.object.get("cookie") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
        if (cookie == .string and cookie.string.len > 0) h.logged_in[1] = true;
    }
    if (v.object.get("bodian")) |b| {
        if (b == .object) {
            h.logged_in[0] = true;
            if (b.object.get("user")) |u| {
                if (u == .object) {
                    if (u.object.get("nickname")) |nk| {
                        if (nk == .string and nk.string.len > 0) h.nickname[0] = nk.string;
                    }
                    if (u.object.get("id")) |id| {
                        if (id == .string and id.string.len > 0) h.user_id[0] = id.string;
                    }
                }
            }
        }
    }
    if (v.object.get("qq")) |q| {
        if (q == .object) {
            if (q.object.get("cookie")) |c| {
                if (c == .string and c.string.len > 0) {
                    h.logged_in[2] = true;
                    if (q.object.get("nickname")) |nk| {
                        if (nk == .string and nk.string.len > 0) h.nickname[2] = nk.string;
                    }
                    if (q.object.get("uin")) |u| {
                        if (u == .string and u.string.len > 0) h.user_id[2] = u.string;
                    }
                }
            }
        }
    }
    return h;
}

test "hasDirect 与迁移进度一致" {
    // 阶段3后：三源全部直调
    try std.testing.expect(hasDirect(.qq));
    try std.testing.expect(hasDirect(.bodian));
    try std.testing.expect(hasDirect(.netease));
}
