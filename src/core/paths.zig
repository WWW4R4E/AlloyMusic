// src/core/paths.zig — 运行时数据文件定位（auth.json 等）。
//
// 安装模式：固定用户数据目录（winget/AUR/绿包统一行为）
//   Windows: %APPDATA%\AlloyMusic\auth.json
//   unix:    $XDG_CONFIG_HOME|~/.config /alloy-music/auth.json
//
// 卸载语义：包管理器卸载只删 exe/链接，数据目录留给用户（内含登录
// 凭证，覆盖删会丢登录态）；彻底删除请手动删数据目录。
//
// 环境变量由 main 启动时注入（std.process.Init.environ_map），库模块
// 不自带平台 extern——能用 std 就不引外部。返回绝对路径——cwd 基的
// 文件 API 对绝对 sub_path 两平台都按字面解析。进程内解析一次缓存。

const std = @import("std");
const builtin = @import("builtin");

var environ: ?*const std.process.Environ.Map = null;
var cached: ?[]const u8 = null;

/// main 启动时调用（run 与 snap 两个入口都要）
pub fn setEnviron(map: *const std.process.Environ.Map) void {
    environ = map;
}

pub fn authPath(io: std.Io, gpa: std.mem.Allocator) []const u8 {
    if (cached) |p| return p;
    const pa = std.heap.page_allocator;
    const p = resolve(io, pa) catch
        pa.dupe(u8, "auth.json") catch "auth.json"; // 兜底：env 缺失等怪环境（cwd）
    cached = p;
    _ = gpa;
    return p;
}

fn resolve(io: std.Io, pa: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try getEnv(pa, "APPDATA");
        defer pa.free(appdata);
        return try dataDirFile(io, pa, appdata, "AlloyMusic", '\\');
    }
    const home = try getEnv(pa, "HOME");
    defer pa.free(home);
    const xdg = try getEnv(pa, "XDG_CONFIG_HOME");
    defer pa.free(xdg);
    if (xdg.len == 0) {
        return try dataDirFile(io, pa, home, ".config/alloy-music", '/');
    }
    return try dataDirFile(io, pa, xdg, "alloy-music", '/');
}

fn getEnv(pa: std.mem.Allocator, key: []const u8) ![]const u8 {
    const m = environ orelse return error.EnvNotFound;
    const v = m.get(key) orelse return error.EnvNotFound;
    return pa.dupe(u8, v);
}

fn dataDirFile(io: std.Io, pa: std.mem.Allocator, base: []const u8, sub: []const u8, sep: u8) ![]const u8 {
    const d = try std.mem.concat(pa, u8, &.{ base, &[1]u8{sep}, sub });
    std.Io.Dir.cwd().createDirPath(io, d) catch {}; // 已存在/失败→createFile 兜底报错
    return std.mem.concat(pa, u8, &.{ d, &[1]u8{sep}, "auth.json" });
}
