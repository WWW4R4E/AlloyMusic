// src/core/jpeg.zig — 基线 JPEG（SOF0/1 顺序 DCT、Huffman）解码器，输出 RGB。
// 替代 npm jpeg-js（封面图全是 CDN 基线 JPEG；渐进式 SOF2 不支持，如实报错）。
//
// 实现：标准 JPEG 流——DQT/SOF0/DHT/DRI/SOS，MCU 按采样因子遍历，
// Zig-Zag 反扫描 + 反量化 + 分离式 IDCT（直接余弦和，封面尺寸下足够快），
// YCbCr→BT.601 转 RGB，色度分量按采样因子最近邻上采样。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGB 行优先，len = w*h*3
    data: []u8,
};

pub const Error = error{
    NotJpeg,
    Unsupported, // 渐进式/算术编码等
    Truncated,
    BadData,
    OutOfMemory,
};

const Component = struct {
    id: u8 = 0,
    h: u8 = 1,
    v: u8 = 1,
    tq: u8 = 0,
    td: u8 = 0,
    ta: u8 = 0,
    dc_pred: i32 = 0,
    plane: []u8 = &.{},
    plane_w: u32 = 0,
    plane_h: u32 = 0,
};

const HuffTable = struct {
    counts: [17]u8 = @splat(0),
    symbols: [256]u8 = @splat(0),
    mincode: [17]i32 = @splat(0),
    maxcode: [17]i32 = @splat(-1),
    valptr: [17]i32 = @splat(0),

    fn build(self: *HuffTable) void {
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..17) |l| {
            self.valptr[l] = k;
            self.mincode[l] = code;
            code += self.counts[l];
            k += self.counts[l];
            self.maxcode[l] = code - 1;
            code <<= 1;
        }
    }
};

/// 位队列：u64 缓冲，stall（marker/EOF）后无限补 1（规范兜底，解码自然收 EOB）
const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    bits: u64 = 0,
    nbits: u8 = 0,
    stalled: bool = false,

    /// 保证 1 位可用；stall（marker/EOF）后持续补 1 字节（规范兜底，解码自然收 EOB）
    fn bit(self: *BitReader) !u1 {
        if (self.nbits == 0) {
            var push: u8 = 0xFF; // stall 补全 1
            if (self.pos < self.data.len and !self.stalled) {
                const b = self.data[self.pos];
                self.pos += 1;
                if (b == 0xFF and self.pos < self.data.len) {
                    const next = self.data[self.pos];
                    if (next == 0x00) {
                        self.pos += 1; // 0xFF00 → 字面 0xFF
                    } else {
                        self.stalled = true;
                    }
                } else if (b == 0xFF) {
                    self.stalled = true;
                } else {
                    push = b;
                }
            } else {
                self.stalled = true;
            }
            self.bits = (self.bits << 8) | push;
            self.nbits += 8;
        }
        self.nbits -= 1;
        return @intCast((self.bits >> @intCast(self.nbits)) & 1);
    }

    fn reset(self: *BitReader) void {
        self.nbits = 0;
        self.stalled = false;
    }

    fn receive(self: *BitReader, n: u5) !i32 {
        var v: i32 = 0;
        for (0..n) |_| {
            v = (v << 1) | @as(i32, try self.bit());
        }
        return v;
    }

    fn decodeHuff(self: *BitReader, t: *const HuffTable) !u8 {
        var code: i32 = 0;
        var l: usize = 1;
        while (l < 17) : (l += 1) {
            code = (code << 1) | @as(i32, try self.bit());
            if (t.counts[l] != 0 and code <= t.maxcode[l]) {
                const idx: usize = @intCast(t.valptr[l] + code - t.mincode[l]);
                if (idx >= 256) return error.BadData;
                return t.symbols[idx];
            }
        }
        return error.BadData;
    }
};

fn extend(v: i32, n: u5) i32 {
    if (n == 0) return 0;
    return if (v < (@as(i32, 1) << @intCast(n - 1))) v - (@as(i32, 1) << @intCast(n)) + 1 else v;
}

const ZigZag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// 预计算 IDCT 余弦表：cos_tab[u][x] = alpha(u) * cos((2x+1) u pi / 16)
const alpha: [8]f32 = blk: {
    var a: [8]f32 = undefined;
    a[0] = @sqrt(1.0 / 8.0);
    for (1..8) |u| a[u] = @sqrt(2.0 / 8.0);
    break :blk a;
};
const cos_tab: [8][8]f32 = blk: {
    var t: [8][8]f32 = undefined;
    for (0..8) |u| {
        for (0..8) |x| {
            const angle = (2 * @as(f32, @floatFromInt(x)) + 1) * @as(f32, @floatFromInt(u)) * std.math.pi / 16.0;
            t[u][x] = alpha[u] * @cos(angle);
        }
    }
    break :blk t;
};

fn idct1d(s: *const [8]f32, out: *[8]f32) void {
    for (0..8) |x| {
        var sum: f32 = 0;
        for (0..8) |u| sum += s[u] * cos_tab[u][x];
        out[x] = sum;
    }
}

fn idctBlock(block: *[64]f32) void {
    var tmp: [64]f32 = undefined;
    for (0..8) |y| {
        idct1d(block[y * 8 ..][0..8], tmp[y * 8 ..][0..8]);
    }
    for (0..8) |x| {
        var col: [8]f32 = undefined;
        var out: [8]f32 = undefined;
        for (0..8) |yy| col[yy] = tmp[yy * 8 + x];
        idct1d(&col, &out);
        for (0..8) |yy| block[yy * 8 + x] = out[yy];
    }
}

pub fn decode(a: Allocator, buf: []const u8) Error!Image {
    if (buf.len < 4 or buf[0] != 0xFF or buf[1] != 0xD8) return error.NotJpeg;

    var qt: [4][64]f32 = @splat(@splat(0));
    var huff_dc: [4]HuffTable = @splat(.{});
    var huff_ac: [4]HuffTable = @splat(.{});
    var components: [4]Component = @splat(.{});
    var ncomp: u8 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var restart_interval: u32 = 0;
    var hmax: u8 = 1;
    var vmax: u8 = 1;

    var off: usize = 2;
    while (off + 4 <= buf.len) {
        if (buf[off] != 0xFF) {
            off += 1;
            continue;
        }
        const marker = buf[off + 1];
        off += 2;
        if (marker == 0xD8 or (marker >= 0xD0 and marker <= 0xD7) or marker == 0x01) continue; // 无长度段
        if (marker == 0xD9) break; // EOI
        if (off + 2 > buf.len) return error.Truncated;
        const seg_len = (@as(usize, buf[off]) << 8) | buf[off + 1];
        if (seg_len < 2 or off + seg_len > buf.len) return error.Truncated;
        const seg = buf[off + 2 .. off + seg_len];

        switch (marker) {
            0xDB => { // DQT
                var p: usize = 0;
                while (p < seg.len) {
                    const pq = seg[p] >> 4; // 0=8bit 1=16bit
                    const tq = seg[p] & 0xF;
                    p += 1;
                    if (tq >= 4) return error.BadData;
                    for (0..64) |i| {
                        if (pq == 1) {
                            if (p + 1 >= seg.len) return error.Truncated;
                            qt[tq][ZigZag[i]] = @floatFromInt((@as(u32, seg[p]) << 8) | seg[p + 1]);
                            p += 2;
                        } else {
                            if (p >= seg.len) return error.Truncated;
                            qt[tq][ZigZag[i]] = @floatFromInt(seg[p]);
                            p += 1;
                        }
                    }
                }
            },
            0xC0, 0xC1 => { // SOF0/1 基线
                if (seg.len < 6) return error.Truncated;
                ncomp = seg[5];
                if (ncomp != 1 and ncomp != 3) return error.Unsupported;
                height = (@as(u32, seg[1]) << 8) | seg[2];
                width = (@as(u32, seg[3]) << 8) | seg[4];
                if (width == 0 or height == 0) return error.BadData;
                var ci: u8 = 0;
                while (ci < ncomp) : (ci += 1) {
                    const base = 6 + @as(usize, ci) * 3;
                    if (base + 2 >= seg.len) return error.Truncated;
                    components[ci].id = seg[base];
                    components[ci].h = seg[base + 1] >> 4;
                    components[ci].v = seg[base + 1] & 0xF;
                    components[ci].tq = seg[base + 2];
                    if (components[ci].h == 0 or components[ci].v == 0) return error.BadData;
                    hmax = @max(hmax, components[ci].h);
                    vmax = @max(vmax, components[ci].v);
                }
            },
            0xC2, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
            0xC4 => { // DHT
                var p: usize = 0;
                while (p + 17 <= seg.len) {
                    const tc = seg[p] >> 4;
                    const th = seg[p] & 0xF;
                    p += 1;
                    if (th >= 4) return error.BadData;
                    var table = if (tc == 0) &huff_dc[th] else &huff_ac[th];
                    var total: usize = 0;
                    for (0..16) |l| {
                        table.counts[l + 1] = seg[p + l];
                        total += seg[p + l];
                    }
                    p += 16;
                    if (p + total > seg.len) return error.Truncated;
                    for (0..total) |i| table.symbols[i] = seg[p + i];
                    p += total;
                    table.build();
                }
            },
            0xDD => { // DRI
                if (seg.len < 2) return error.Truncated;
                restart_interval = (@as(u32, seg[0]) << 8) | seg[1];
            },
            0xDA => { // SOS：扫描解码主循环
                if (width == 0 or ncomp == 0) return error.BadData;
                if (seg.len < 1 + @as(usize, ncomp) * 2 + 3) return error.Truncated;
                var ci: u8 = 0;
                while (ci < ncomp) : (ci += 1) {
                    const base = 1 + @as(usize, ci) * 2;
                    const cid = seg[base];
                    var found = false;
                    for (0..ncomp) |j| {
                        if (components[j].id == cid) {
                            components[j].td = seg[base + 1] >> 4;
                            components[j].ta = seg[base + 1] & 0xF;
                            found = true;
                        }
                    }
                    if (!found) return error.BadData;
                }

                // 分量平面：全分辨率（含 MCU 余量）
                const mcu_w: u32 = @as(u32, hmax) * 8;
                const mcu_h: u32 = @as(u32, vmax) * 8;
                const mcus_x = (width + mcu_w - 1) / mcu_w;
                const mcus_y = (height + mcu_h - 1) / mcu_h;
                for (0..ncomp) |j| {
                    const c = &components[j];
                    const pw = mcus_x * @as(u32, c.h) * 8;
                    const ph = mcus_y * @as(u32, c.v) * 8;
                    c.plane = a.alloc(u8, @as(usize, pw) * ph) catch return error.OutOfMemory;
                    c.plane_w = pw;
                    c.plane_h = ph;
                    c.dc_pred = 0;
                }

                var block: [64]f32 = undefined;
                var br = BitReader{ .data = buf[off + seg_len ..] };
                var mcu_count: u32 = 0;
                var rst_pending: u32 = restart_interval;

                mcu: for (0..mcus_y) |my| {
                    for (0..mcus_x) |mx| {
                        if (restart_interval != 0 and rst_pending == 0) {
                            // 吃掉 RSTn marker
                            br.reset();
                            var pos = br.pos;
                            while (pos + 1 < buf.len) {
                                if (buf[pos] == 0xFF and buf[pos + 1] >= 0xD0 and buf[pos + 1] <= 0xD7) {
                                    pos += 2;
                                    break;
                                }
                                pos += 1;
                            }
                            br.pos = pos;
                            br.stalled = false;
                            for (0..ncomp) |j| components[j].dc_pred = 0;
                            rst_pending = restart_interval;
                        }
                        for (0..ncomp) |j| {
                            const c = &components[j];
                            for (0..@as(u32, c.v)) |by| {
                                for (0..@as(u32, c.h)) |bx| {
                                    // 解码一个 8x8 块
                                    @memset(&block, 0);
                                    const t = br.decodeHuff(&huff_dc[c.td]) catch return error.Truncated;
                                    const diff = extend(br.receive(@intCast(t)) catch return error.Truncated, @intCast(t));
                                    c.dc_pred += diff;
                                    block[0] = @as(f32, @floatFromInt(c.dc_pred)) * qt[c.tq][0];
                                    var k: usize = 1;
                                    while (k < 64) {
                                        const rs = br.decodeHuff(&huff_ac[c.ta]) catch return error.Truncated;
                                        const r = rs >> 4;
                                        const s = rs & 0xF;
                                        if (s == 0) {
                                            if (r == 15) {
                                                k += 16;
                                                continue;
                                            }
                                            break; // EOB
                                        }
                                        k += r;
                                        if (k > 63) return error.BadData;
                                        const zz = ZigZag[k];
                                        const val = extend(br.receive(@intCast(s)) catch return error.Truncated, @intCast(s));
                                        block[zz] = @as(f32, @floatFromInt(val)) * qt[c.tq][zz];
                                        k += 1;
                                    }
                                    idctBlock(&block);
                                    // 写入分量平面
                                    const px = mx * @as(u32, c.h) * 8 + @as(u32, @intCast(bx)) * 8;
                                    const py = my * @as(u32, c.v) * 8 + @as(u32, @intCast(by)) * 8;
                                    for (0..8) |yy| {
                                        for (0..8) |xx| {
                                            const v = block[yy * 8 + xx] + 128;
                                            const vv: u8 = if (v < 0) 0 else if (v > 255) 255 else @intFromFloat(v);
                                            c.plane[(py + @as(u32, @intCast(yy))) * c.plane_w + px + @as(u32, @intCast(xx))] = vv;
                                        }
                                    }
                                }
                            }
                        }
                        mcu_count += 1;
                        if (restart_interval != 0) rst_pending -= 1;
                        if (br.stalled and mcu_count > 0) {
                            // 流提前结束：剩余 MCU 保持 128（灰）
                            break :mcu;
                        }
                    }
                }

                // 组装 RGB（色度最近邻上采样到 plane_w/plane_h，再裁剪 width/height）
                const out = a.alloc(u8, @as(usize, width) * height * 3) catch return error.OutOfMemory;
                if (ncomp == 1) {
                    const c = &components[0];
                    for (0..height) |y| {
                        for (0..width) |x| {
                            const sy = @min(y * c.plane_h / height, c.plane_h - 1);
                            const sx = @min(x * c.plane_w / width, c.plane_w - 1);
                            const g = c.plane[sy * c.plane_w + sx];
                            const o = (y * width + x) * 3;
                            out[o] = g;
                            out[o + 1] = g;
                            out[o + 2] = g;
                        }
                    }
                } else {
                    const cy = &components[0];
                    const cb = &components[1];
                    const cr = &components[2];
                    for (0..height) |y| {
                        for (0..width) |x| {
                            const sy = @min(y * cy.plane_h / height, cy.plane_h - 1);
                            const sx = @min(x * cy.plane_w / width, cy.plane_w - 1);
                            const sb_y = @min(y * cb.plane_h / height, cb.plane_h - 1);
                            const sb_x = @min(x * cb.plane_w / width, cb.plane_w - 1);
                            const Y: f32 = @floatFromInt(cy.plane[sy * cy.plane_w + sx]);
                            const Cb: f32 = @as(f32, @floatFromInt(cb.plane[sb_y * cb.plane_w + sb_x])) - 128.0;
                            const Cr: f32 = @as(f32, @floatFromInt(cr.plane[sb_y * cr.plane_w + sb_x])) - 128.0;
                            const r = Y + 1.402 * Cr;
                            const g = Y - 0.344136 * Cb - 0.714136 * Cr;
                            const b = Y + 1.772 * Cb;
                            const o = (y * width + x) * 3;
                            out[o] = clamp8(r);
                            out[o + 1] = clamp8(g);
                            out[o + 2] = clamp8(b);
                        }
                    }
                }
                return .{ .width = width, .height = height, .data = out };
            },
            else => {}, // APPn/COM 等：跳过
        }
        off += seg_len;
    }
    return error.Truncated;
}

fn clamp8(v: f32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intFromFloat(v);
}

// ── 测试 ──

test "jpeg：非 JPEG 拒绝" {
    try std.testing.expectError(error.NotJpeg, decode(std.testing.allocator, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }));
}
