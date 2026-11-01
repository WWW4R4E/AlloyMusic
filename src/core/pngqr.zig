// src/core/pngqr.zig — PNG → 灰度 → 二维码模块矩阵（sidecar/pngqr.cjs 的 Zig 移植）。
//
// 思路抄自 qq-music-tui 的 qr.go（GPL-3.0，按接口协议重写）：
// 不解码二维码内容，只还原模块网格——二维码四角必有定位图案，
// 深色像素包围盒就是符号边界，边长只会是 21+4k，逐一试出让
// 「像素宽 ≈ 整数倍缩放」误差最小的 N，再逐模块取中心像素判深浅。
//
// PNG 支持子集：非交织、灰度（1/2/4/8bit）或 RGB/RGBA 8bit（ptqrshow
// 实测是 1-bit 灰度 111x111，但留宽一点兼容 JPEG 转码等情况）。
// 带_ALPHA 变体与 tRNS 调色板不做——上游用不到。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Gray = struct {
    width: u32,
    height: u32,
    /// 行优先，len = w*h，0..255 亮度
    gray: []u8,
};

pub const Matrix = struct {
    size: u32,
    /// 每行一个 '0'/'1' 串，size×size
    rows: [][]const u8,
};

pub const Error = error{
    NotPng,
    InterlacedUnsupported,
    ColorTypeUnsupported,
    BitDepthUnsupported,
    InflateFailed,
    Truncated,
    NoDarkPixels,
    CannotInferModuleCount,
    OutOfMemory,
};

fn paeth(a: u16, b: u16, c: u16) u16 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn readU32be(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

/// PNG 字节 → 灰度图。全部产物分配在 a 上（调用方用 arena 即可整体释放）。
pub fn decodeGray(a: Allocator, buf: []const u8) Error!Gray {
    if (buf.len < 8 or readU32be(buf) != 0x89504e47) return error.NotPng;
    var off: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var idat: std.ArrayList([]const u8) = .empty;
    defer idat.deinit(a);
    while (off + 12 <= buf.len) {
        const len = readU32be(buf[off..]);
        if (off + 12 + len > buf.len) return error.Truncated;
        const typ = buf[off + 4 .. off + 8];
        const data = buf[off + 8 .. off + 8 + len];
        if (std.mem.eql(u8, typ, "IHDR")) {
            width = readU32be(data);
            height = readU32be(data[4..]);
            bit_depth = data[8];
            color_type = data[9];
            interlace = data[12];
        } else if (std.mem.eql(u8, typ, "IDAT")) {
            try idat.append(a, data);
        } else if (std.mem.eql(u8, typ, "IEND")) {
            break;
        }
        off += 12 + len;
    }
    if (interlace != 0) return error.InterlacedUnsupported;
    const channels: u8 = switch (color_type) {
        0 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return error.ColorTypeUnsupported,
    };
    if (channels == 1) switch (bit_depth) {
        1, 2, 4, 8 => {},
        else => return error.BitDepthUnsupported,
    };
    if (channels > 2 and bit_depth != 8) return error.BitDepthUnsupported;

    // 每行原始字节数（filter 字节之外）
    const bits_per_channel: u32 = @as(u32, channels) * bit_depth;
    const row_bytes = (width * bits_per_channel + 7) / 8;

    // zlib inflate：拼接 IDAT，喂给 flate Decompress（.zlib 容器）
    const concatenated = try a.alloc(u8, blk: {
        var total: usize = 0;
        for (idat.items) |c| total += c.len;
        break :blk total;
    });
    var pos: usize = 0;
    for (idat.items) |c| {
        @memcpy(concatenated[pos .. pos + c.len], c);
        pos += c.len;
    }
    var in_reader: std.Io.Reader = .fixed(concatenated);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var decomp: std.compress.flate.Decompress = .init(&in_reader, .zlib, window);
    const raw = decomp.reader.allocRemaining(a, .unlimited) catch return error.InflateFailed;

    const out = try a.alloc(u8, @as(usize, width) * height);
    const prev = try a.alloc(u8, row_bytes);
    const cur = try a.alloc(u8, row_bytes);
    @memset(prev, 0);

    var src: usize = 0;
    for (0..height) |y| {
        if (src + 1 + row_bytes > raw.len) return error.Truncated;
        const filter = raw[src];
        src += 1;
        // 反滤波：cur 原地展开
        @memcpy(cur, raw[src .. src + row_bytes]);
        src += row_bytes;
        for (0..row_bytes) |i| {
            const left: u16 = if (i > 0) cur[i - 1] else 0;
            const up: u16 = prev[i];
            const ul: u16 = if (i > 0) prev[i - 1] else 0;
            const v: u16 = switch (filter) {
                1 => @as(u16, cur[i]) + left,
                2 => @as(u16, cur[i]) + up,
                3 => @as(u16, cur[i]) + (left + up) >> 1,
                4 => @as(u16, cur[i]) + paeth(left, up, ul),
                else => @as(u16, cur[i]),
            };
            cur[i] = @truncate(v);
        }
        @memcpy(prev, cur);

        // 展开为亮度
        for (0..width) |x| {
            var g: u8 = 0;
            if (channels >= 3) {
                const r = cur[x * 3];
                const gg = cur[x * 3 + 1];
                const b = cur[x * 3 + 2];
                g = @intCast((@as(u32, r) + gg + b) / 3);
            } else if (bit_depth == 8) {
                g = cur[x];
            } else {
                // 少于 8bit 的灰度：从字节里抠位（MSB 优先），按满量程折算
                const bit_start = @as(u32, @intCast(x)) * bit_depth;
                const byte = cur[bit_start >> 3];
                const shift: u3 = @intCast(8 - bit_depth - (bit_start & 7));
                const max_val: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;
                const v = (byte >> shift) & max_val;
                g = @intCast(@as(u32, v) * 255 / max_val);
            }
            out[y * width + x] = g;
        }
    }
    return .{ .width = width, .height = height, .gray = out };
}

/// PNG 字节 → { size, rows }；失败返回 Error
pub fn pngToQrMatrix(a: Allocator, png_bytes: []const u8) Error!Matrix {
    const img = try decodeGray(a, png_bytes);
    const width = img.width;
    const height = img.height;
    const gray = img.gray;
    // 深色包围盒（<128 视为深）
    var min_x = width;
    var min_y = height;
    var found = false;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (gray[y * width + x] < 128) {
                found = true;
                if (x < min_x) min_x = @intCast(x);
                if (x > max_x) max_x = @intCast(x);
                if (y < min_y) min_y = @intCast(y);
                if (y > max_y) max_y = @intCast(y);
            }
        }
    }
    if (!found) return error.NoDarkPixels;
    const w = max_x - min_x + 1;
    const h = max_y - min_y + 1;

    // 候选模块数 N=21+4k，让包围盒边长最接近 N 的整数倍
    var best_n: u32 = 0;
    var best_err: f64 = std.math.floatMax(f64);
    var n: u32 = 21;
    while (n <= 177) : (n += 4) {
        const est = @round(@as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(n)));
        if (est < 1) break;
        const wf: f64 = @floatFromInt(w);
        const hf: f64 = @floatFromInt(h);
        const nf: f64 = @floatFromInt(n);
        const err = @abs(wf - est * nf) + @abs(hf - est * nf);
        if (err < best_err) {
            best_err = err;
            best_n = n;
        }
    }
    if (best_n == 0) return error.CannotInferModuleCount;
    const scale = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(best_n));

    const rows = try a.alloc([]const u8, best_n);
    for (0..best_n) |j| {
        const row = try a.alloc(u8, best_n);
        const cy = @min(
            @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(min_y)) + (@as(f64, @floatFromInt(j)) + 0.5) * scale))),
            max_y,
        );
        for (0..best_n) |i| {
            const cx = @min(
                @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(min_x)) + (@as(f64, @floatFromInt(i)) + 0.5) * scale))),
                max_x,
            );
            row[i] = if (gray[cy * width + cx] < 128) '1' else '0';
        }
        rows[j] = row;
    }
    return .{ .size = best_n, .rows = rows };
}

test "pngToQrMatrix: 合成二维码位图还原网格" {
    // 合成一张 8x8 像素/模块、N=21 的伪二维码：深色包围盒 21*8=168，
    // 三个角定位图案保证包围盒正确。这里只验证 N 推断与中心取样。
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const n = 21;
    const scale_px = 8;
    const dim = n * scale_px;
    const px = try a.alloc(u8, dim * dim);
    @memset(px, 255);
    // 深色模块：三个定位角 + 一条对角线（保证包围盒覆盖全图）
    for (0..7) |j| for (0..7) |i| {
        const solid = (i == 0 or i == 6 or j == 0 or j == 6 or (i >= 2 and i <= 4 and j >= 2 and j <= 4));
        if (!solid) continue;
        for (0..scale_px) |dy| for (0..scale_px) |dx| {
            px[(j * scale_px + dy) * dim + i * scale_px + dx] = 0;
        };
    };
    for (0..7) |k| {
        for (0..scale_px) |dy| for (0..scale_px) |dx| {
            px[((14 + k) * scale_px + dy) * dim + (14 + k) * scale_px + dx] = 0;
        };
    }
    const png = try encodeMinimalPng(a, dim, dim, px);
    const m = try pngToQrMatrix(a, png);
    try std.testing.expectEqual(@as(u32, 21), m.size);
    try std.testing.expectEqual(@as(u8, '1'), m.rows[0][0]);
    try std.testing.expectEqual(@as(u8, '1'), m.rows[20][20]);
}

/// 测试专用：手写无压缩 PNG 编码（灰度 8bit）
fn encodeMinimalPng(a: Allocator, w: u32, h: u32, gray: []const u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    for (0..h) |y| {
        try raw.append(a, 0); // filter none
        try raw.appendSlice(a, gray[y * w .. (y + 1) * w]);
    }
    var zlib: std.Io.Writer.Allocating = .init(a);
    try zlib.writer.ensureUnusedCapacity(64); // Compress.init 断言输出缓冲 >8
    var window2: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&zlib.writer, &window2, .zlib, .default);
    try compressor.writer.writeAll(raw.items);
    try compressor.finish();

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
    // IHDR
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, 13)));
    try out.appendSlice(a, "IHDR");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 0; // grayscale
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try out.appendSlice(a, &ihdr);
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Crc32.hash(&ihdr))));
    // IDAT
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(zlib.written().len))));
    try out.appendSlice(a, "IDAT");
    try out.appendSlice(a, zlib.written());
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Crc32.hash(zlib.written()))));
    // IEND
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
    try out.appendSlice(a, "IEND");
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, std.hash.Crc32.hash("IEND"))));
    return out.toOwnedSlice(a);
}
