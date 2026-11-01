// src/core/cover.zig — 封面取回 + 解码 + box 缩放（sidecar/cover.cjs 的 Zig 移植）。
//
// 语义对齐：已知音源图床域 .webp 换 .jpg（kuwo 图床全是 webp）、域白名单
// （http 仅白名单放行）、w/h 上限 640/1280、8MB 上限、box 平均缩放、
// 输出 RGB 行优先 base64。JPEG 用本目录 jpeg.zig，PNG 解码内置（8bit
// 非交织 灰度/RGB/RGBA，与 cover.cjs 同子集，不含调色板）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const jpeg = @import("jpeg.zig");

pub const Error = error{
    Unsupported, // 域/参数越界
    Network,
    InvalidResponse,
    OutOfMemory,
};

const IMG_HOSTS = [_][]const u8{ "music.126.net", "kuwo.cn", "gtimg.cn", "qq.com" };
// .webp 可换 .jpg 的域（kuwo fm 封面全是 webp）
const WEBP_HOSTS = [_][]const u8{ "kuwo.cn", "gtimg.cn", "music.126.net" };

fn hostMatches(host: []const u8, list: []const []const u8) bool {
    for (list) |suffix| {
        if (std.mem.eql(u8, host, suffix)) return true;
        if (host.len > suffix.len and std.mem.endsWith(u8, host, suffix) and host[host.len - suffix.len - 1] == '.') return true;
    }
    return false;
}

pub const Result = struct {
    w: u32,
    h: u32,
    pixels_b64: []const u8,
};

/// 封面主流程（sidecar cover() 同语义）。产物全在 arena。
pub fn cover(gpa: Allocator, io: std.Io, arena: Allocator, url: []const u8, w: u32, h: u32) Error!Result {
    _ = gpa;
    if (w == 0 or h == 0 or w > 640 or h > 1280) return error.Unsupported;

    // URL 解析 + 白名单 + webp→jpg 改写
    const uri = std.Uri.parse(url) catch return error.Unsupported;
    if (uri.host == null) return error.Unsupported;
    var host_buf: [256]u8 = undefined;
    const host_raw = switch (uri.host.?) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    if (host_raw.len > host_buf.len) return error.Unsupported;
    const host = std.ascii.lowerString(&host_buf, host_raw);
    const scheme_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const known = hostMatches(host, &IMG_HOSTS);
    if (!scheme_https and !(std.ascii.eqlIgnoreCase(uri.scheme, "http") and known)) return error.Unsupported;

    var path: []const u8 = switch (uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };
    var path_buf: [512]u8 = undefined;
    if (std.mem.endsWith(u8, path, ".webp") and hostMatches(host, &WEBP_HOSTS)) {
        // ".webp"(5) → ".jpg"(4)：新长度 = 原 len - 1
        if (path.len > 512 - 1) return error.Unsupported;
        @memcpy(path_buf[0 .. path.len - 5], path[0 .. path.len - 5]);
        @memcpy(path_buf[path.len - 5 ..][0..4], ".jpg");
        path = path_buf[0 .. path.len - 1];
    }
    const query: []const u8 = if (uri.query) |q| switch (q) {
        .raw => |qq| qq,
        .percent_encoded => |qq| qq,
    } else "";
    const full_url = if (query.len > 0)
        std.fmt.allocPrint(arena, "{s}://{s}{s}?{s}", .{ if (scheme_https) "https" else "http", host, path, query }) catch return error.OutOfMemory
    else
        std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ if (scheme_https) "https" else "http", host, path }) catch return error.OutOfMemory;

    // 下载（8s 超时语义：std.http.Client 无显式超时，尺寸上限兜底）
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const res = client.fetch(.{
        .location = .{ .url = full_url },
        .response_writer = &aw.writer,
    }) catch return error.Network;
    switch (res.status.class()) {
        .success => {},
        else => return error.Network,
    }
    const buf = aw.written();
    if (buf.len > 8 * 1024 * 1024) return error.InvalidResponse;

    // 解码 + 缩放
    const img = decode(arena, buf) catch return error.InvalidResponse;
    if (img.width == 0 or img.height == 0) return error.InvalidResponse;
    const rgb = resize(arena, img, w, h) catch return error.OutOfMemory;
    const enc = std.base64.standard.Encoder;
    const b64 = arena.alloc(u8, enc.calcSize(rgb.len)) catch return error.OutOfMemory;
    _ = enc.encode(b64, rgb);
    return .{ .w = w, .h = h, .pixels_b64 = b64 };
}

const Img = struct {
    width: u32,
    height: u32,
    /// RGB 行优先
    data: []u8,
};

fn decode(a: Allocator, buf: []const u8) Error!Img {
    if (buf.len >= 2 and buf[0] == 0xFF and buf[1] == 0xD8) {
        const img = jpeg.decode(a, buf) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponse,
        };
        return .{ .width = img.width, .height = img.height, .data = img.data };
    }
    return decodePng(a, buf);
}

fn paeth(a_: u16, b_: u16, c_: u16) u16 {
    const p = @as(i32, a_) + @as(i32, b_) - @as(i32, c_);
    const pa = @abs(p - @as(i32, a_));
    const pb = @abs(p - @as(i32, b_));
    const pc = @abs(p - @as(i32, c_));
    if (pa <= pb and pa <= pc) return a_;
    if (pb <= pc) return b_;
    return c_;
}

/// PNG（8bit 非交织 灰度/灰度+alpha/RGB/RGBA → RGB）
fn decodePng(a: Allocator, buf: []const u8) Error!Img {
    if (buf.len < 33 or std.mem.readInt(u32, buf[0..4], .big) != 0x89504e47) return error.InvalidResponse;
    var off: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: u8 = 0;
    var idat: std.ArrayList([]const u8) = .empty;
    while (off + 12 <= buf.len) {
        const len = std.mem.readInt(u32, buf[off..][0..4], .big);
        if (off + 12 + len > buf.len) return error.InvalidResponse;
        const typ = buf[off + 4 .. off + 8];
        if (std.mem.eql(u8, typ, "IHDR")) {
            width = std.mem.readInt(u32, buf[off + 8 ..][0..4], .big);
            height = std.mem.readInt(u32, buf[off + 12 ..][0..4], .big);
            if (buf[off + 16] != 8) return error.InvalidResponse; // 仅 8bit
            color_type = buf[off + 17];
            if (buf[off + 20] != 0) return error.InvalidResponse; // 非交织
        } else if (std.mem.eql(u8, typ, "IDAT")) {
            idat.append(a, buf[off + 8 .. off + 8 + len]) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, typ, "IEND")) {
            break;
        }
        off += 12 + len;
    }
    if (width == 0 or height == 0) return error.InvalidResponse;
    const channels: u8 = switch (color_type) {
        0 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return error.InvalidResponse, // 调色板不支持（音源封面没有）
    };
    const total: usize = blk: {
        var t: usize = 0;
        for (idat.items) |c| t += c.len;
        break :blk t;
    };
    const concatenated = a.alloc(u8, total) catch return error.OutOfMemory;
    var pos: usize = 0;
    for (idat.items) |c| {
        @memcpy(concatenated[pos .. pos + c.len], c);
        pos += c.len;
    }
    var in_reader: std.Io.Reader = .fixed(concatenated);
    const window = a.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
    var decomp: std.compress.flate.Decompress = .init(&in_reader, .zlib, window);
    const raw = decomp.reader.allocRemaining(a, .unlimited) catch return error.InvalidResponse;

    const stride = @as(usize, width) * channels;
    const px = a.alloc(u8, @as(usize, width) * height * 3) catch return error.OutOfMemory;
    const prev = a.alloc(u8, stride) catch return error.OutOfMemory;
    const cur = a.alloc(u8, stride) catch return error.OutOfMemory;
    @memset(prev, 0);
    var src: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        if (src + 1 + stride > raw.len) break; // 截断：剩余保持黑
        const filter = raw[src];
        src += 1;
        @memcpy(cur, raw[src .. src + stride]);
        src += stride;
        for (0..stride) |i| {
            const left: u16 = if (i >= channels) cur[i - channels] else 0;
            const up: u16 = prev[i];
            const ul: u16 = if (i >= channels) prev[i - channels] else 0;
            const v: u16 = switch (filter) {
                1 => @as(u16, cur[i]) + left,
                2 => @as(u16, cur[i]) + up,
                3 => @as(u16, cur[i]) + ((left + up) >> 1),
                4 => @as(u16, cur[i]) + paeth(left, up, ul),
                else => @as(u16, cur[i]),
            };
            cur[i] = @truncate(v);
        }
        @memcpy(prev, cur);
        for (0..width) |x| {
            const si = x * channels;
            const di = (y * width + x) * 3;
            if (channels >= 3) {
                px[di] = cur[si];
                px[di + 1] = cur[si + 1];
                px[di + 2] = cur[si + 2];
            } else {
                px[di] = cur[si];
                px[di + 1] = cur[si];
                px[di + 2] = cur[si];
            }
        }
    }
    return .{ .width = width, .height = height, .data = px };
}

/// box 平均缩放到精确 w×h（cover.cjs resize 同语义）
fn resize(a: Allocator, img: Img, w: u32, h: u32) Error![]u8 {
    const out = a.alloc(u8, @as(usize, w) * h * 3) catch return error.OutOfMemory;
    for (0..h) |y| {
        const y0 = y * img.height / h;
        var y1 = (y + 1) * img.height / h;
        if (y1 <= y0) y1 = y0 + 1;
        for (0..w) |x| {
            const x0 = x * img.width / w;
            var x1 = (x + 1) * img.width / w;
            if (x1 <= x0) x1 = x0 + 1;
            var r: u64 = 0;
            var g: u64 = 0;
            var b: u64 = 0;
            var n: u64 = 0;
            var sy = y0;
            while (sy < @min(y1, img.height)) : (sy += 1) {
                var sx = x0;
                while (sx < @min(x1, img.width)) : (sx += 1) {
                    const i = (sy * img.width + sx) * 3;
                    r += img.data[i];
                    g += img.data[i + 1];
                    b += img.data[i + 2];
                    n += 1;
                }
            }
            const o = (y * w + x) * 3;
            out[o] = @intCast(r / n);
            out[o + 1] = @intCast(g / n);
            out[o + 2] = @intCast(b / n);
        }
    }
    return out;
}

// ── 离线测试 ──

test "cover：参数/域校验" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // w/h 越界
    try std.testing.expectError(error.Unsupported, cover(std.testing.allocator, undefined, a, "https://img4.kuwo.cn/a.jpg", 0, 10));
    try std.testing.expectError(error.Unsupported, cover(std.testing.allocator, undefined, a, "https://img4.kuwo.cn/a.jpg", 700, 10));
    // 非白名单 http
    try std.testing.expectError(error.Unsupported, cover(std.testing.allocator, undefined, a, "http://evil.example.com/a.jpg", 24, 24));
}
