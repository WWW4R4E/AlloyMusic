// src/core/paths.zig — 运行时数据文件定位（auth.json 等）。
//
// 安装模式：固定用户数据目录（winget/AUR/绿包统一行为）
//   Windows: %APPDATA%\AlloyMusic\auth.json
//   unix:    $XDG_CONFIG_HOME|~/.config /alloy-music/auth.json
//
// 卸载语义：包管理器卸载只删 exe/链接，数据目录留给用户（内含登录
// 凭证，覆盖删会丢登录态）；彻底删除请手动删数据目录（同 Chrome/VSCode）。
//
// 返回绝对路径——cwd 基的文件 API（readFileAlloc 等）对绝对 sub_path
// 在两平台都按字面解析，调用点零改动成本。进程内解析一次缓存
// （page_allocator 持有；arena 传入也不悬垂）。

const std = @import("std");
const builtin = @import("builtin");

var cached: ?[]const u8 = null;

pub fn authPath(io: std.Io, gpa: std.mem.Allocator) []const u8 {
    if (cached) |p| return p;
    const pa = std.heap.page_allocator;
    const p = resolve(io, pa) catch
        pa.dupe(u8, "auth.json") catch "auth.json"; // 彻底兜底：沿用旧行为（cwd）
    cached = p;
    _ = gpa;
    return p;
}

fn resolve(io: std.Io, pa: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try getEnvWin(pa, "APPDATA");
        defer pa.free(appdata);
        return try dataDirFile(io, pa, appdata, "AlloyMusic", '\\');
    }
    const home = try getEnvPosix(pa, "HOME");
    defer pa.free(home);
    const xdg = getEnvPosix(pa, "XDG_CONFIG_HOME") catch
        try std.mem.concat(pa, u8, &.{ home, "/.config" });
    if (xdg.len == 0) {
        pa.free(xdg);
        return try dataDirFile(io, pa, home, ".config/alloy-music", '/');
    }
    defer pa.free(xdg);
    return try dataDirFile(io, pa, xdg, "alloy-music", '/');
}

// 0.17 的 env 走 std.process.Init.environ_map（main 专属），库模块拿不到——
// 这里直接用平台 extern，两行各覆盖一个平台
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) u32;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn getEnvWin(pa: std.mem.Allocator, name: []const u8) ![]u8 {
    var name_buf: [64]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&name_buf, name) catch return error.InvalidUtf8;
    name_buf[n] = 0;
    var size = GetEnvironmentVariableW(@ptrCast(&name_buf), null, 0);
    if (size == 0) return error.EnvNotFound;
    var buf = try pa.alloc(u16, size);
    size = GetEnvironmentVariableW(@ptrCast(&name_buf), buf.ptr, size);
    return std.unicode.utf16LeToUtf8Alloc(pa, buf[0..size]);
}

fn getEnvPosix(pa: std.mem.Allocator, name: []const u8) ![]u8 {
    var name_buf: [64]u8 = undefined;
    if (name.len >= name_buf.len) return error.EnvNotFound;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const v = getenv(@ptrCast(&name_buf)) orelse return error.EnvNotFound;
    return pa.dupe(u8, std.mem.span(v));
}

fn dataDirFile(io: std.Io, pa: std.mem.Allocator, base: []const u8, sub: []const u8, sep: u8) ![]const u8 {
    const d = try std.mem.concat(pa, u8, &.{ base, &[1]u8{sep}, sub });
    std.Io.Dir.cwd().createDirPath(io, d) catch {}; // 已存在/失败→createFile 兜底报错
    return std.mem.concat(pa, u8, &.{ d, &[1]u8{sep}, "auth.json" });
}
