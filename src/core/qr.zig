// src/core/qr.zig — QR 码编码器（替代 npm qrcode 包；算法按 Nayuki QR-Code-generator，
// MIT，按接口协议重写）。仅 byte 模式、UTF-8 输入、自动版本/掩码。
//
// 输出模块矩阵（true=深色），供 TUI 半块字符渲染；与 sidecar/auth.cjs 的
// qrMatrix(text)（errorCorrectionLevel M）同语义。

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ecc = enum(u2) {
    low = 0,
    medium = 1, // 默认：与 qrcode 包 'M' 一致
    quartile = 2,
    high = 3,
};

pub const Matrix = struct {
    size: u32,
    /// 行优先，true = 深色模块
    modules: []bool,
};

pub const Error = error{ TextTooLong, OutOfMemory };

// ── 版本表（Nayuki qrcodegen 标准表，索引 0 占位）──

const ECC_CODEWORDS_PER_BLOCK = [4][41]i16{
    .{ -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // low
    .{ -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 }, // medium
    .{ -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // quartile
    .{ -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }, // high
};

const NUM_ECC_BLOCKS = [4][41]i16{
    .{ -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 }, // low
    .{ -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 }, // medium
    .{ -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 }, // quartile
    .{ -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 }, // high
};

fn rawDataModules(ver: u8) i32 {
    var result: i32 = (16 * @as(i32, ver) + 128) * @as(i32, ver) + 64;
    if (ver >= 2) {
        const num_align: i32 = @divTrunc(@as(i32, ver), 7) + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (ver >= 7) result -= 36;
    }
    return result;
}

fn dataCodewords(ver: u8, ecc: Ecc) i32 {
    const e: usize = @intFromEnum(ecc);
    return @divTrunc(rawDataModules(ver), 8) - ECC_CODEWORDS_PER_BLOCK[e][ver] * NUM_ECC_BLOCKS[e][ver];
}

// ── Reed-Solomon（GF(2^8)，本原多项式 0x11D）──

fn rsMultiply(x: u8, y: u8) u8 {
    var z: u16 = 0;
    var i: i8 = 7;
    while (i >= 0) : (i -= 1) {
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= @as(u16, ((y >> @as(u3, @intCast(i))) & 1)) * x;
    }
    return @truncate(z);
}

fn rsComputeDivisor(degree: usize, a: Allocator) ![]u8 {
    var result = try a.alloc(u8, degree);
    @memset(result, 0);
    result[degree - 1] = 1; // 首项 1
    var root: u8 = 1;
    for (0..degree) |_| {
        var i: usize = 0;
        while (i < degree) : (i += 1) {
            result[i] = rsMultiply(result[i], root);
            if (i + 1 < degree) result[i] ^= result[i + 1];
        }
        root = rsMultiply(root, 0x02);
    }
    return result;
}

fn rsAddRemainder(data: []const u8, divisor: []const u8, a: Allocator) ![]u8 {
    var result = try a.alloc(u8, divisor.len);
    @memset(result, 0);
    for (data) |b| {
        const factor = b ^ result[0];
        std.mem.copyForwards(u8, result[0 .. result.len - 1], result[1..]);
        result[result.len - 1] = 0;
        for (result, 0..) |*r, i| {
            r.* ^= rsMultiply(divisor[i], factor);
        }
    }
    return result;
}

// ── 位流 ──

const BitBuf = struct {
    bits: std.ArrayList(u8) = .empty,
    len: usize = 0,

    fn append(self: *BitBuf, a: Allocator, val: u32, nbits: usize) !void {
        var i: usize = nbits;
        while (i > 0) {
            i -= 1;
            try self.bits.append(a, @intCast((val >> @as(u5, @intCast(i))) & 1));
            self.len += 1;
        }
    }
};

/// 位流 → 分块 → 每块 RS 纠错 → 交织（Nayuki addEccAndInterleave）
fn encodeCodewords(a: Allocator, ver: u8, ecc: Ecc, data_bits: []const u8) ![]u8 {
    const e: usize = @intFromEnum(ecc);
    const num_data: usize = @intCast(dataCodewords(ver, ecc));
    const num_blocks: usize = @intCast(NUM_ECC_BLOCKS[e][ver]);
    const block_ecc: usize = @intCast(ECC_CODEWORDS_PER_BLOCK[e][ver]);
    const raw_cw: usize = num_data + block_ecc * num_blocks;
    const short_block_len: usize = num_data / num_blocks;
    const num_short: usize = num_blocks - num_data % num_blocks;

    // 位流拷进码字缓冲（终止符与补位都是 0 位，零缓冲天然满足）
    var cw = try a.alloc(u8, num_data);
    @memset(cw, 0);
    for (data_bits, 0..) |bit, i| {
        cw[i >> 3] |= bit << @intCast(7 - (i & 7));
    }
    // 补位字节 0xEC/0x11 交替（从数据位流结束的下一个整字节起）
    var byte_i = (data_bits.len + 7) / 8;
    var pad: u8 = 0xEC;
    while (byte_i < num_data) : (byte_i += 1) {
        cw[byte_i] = pad;
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }

    // 每块算纠错码字
    const divisor = try rsComputeDivisor(block_ecc, a);
    defer a.free(divisor);
    const ecc_cw = try a.alloc(u8, block_ecc * num_blocks);
    {
        var k: usize = 0;
        for (0..num_blocks) |b| {
            const data_len = short_block_len + (if (b < num_short) @as(usize, 0) else 1);
            const rem = try rsAddRemainder(cw[k .. k + data_len], divisor, a);
            @memcpy(ecc_cw[b * block_ecc .. (b + 1) * block_ecc], rem);
            k += data_len;
        }
    }

    // 交织：数据按列（短块在前，长块补位列跳过），纠错同样按列交织——
    // 此前纠错按块整段拼接，与 spec/Nayuki 不符：≥2 块的版本（v4+）
    // 纠错字节顺序全错，手机端 RS 校验失败，二维码永远扫不出来；
    // 单块版本恰好一致所以小码能扫，极具迷惑性。
    var result = try a.alloc(u8, raw_cw);
    var idx: usize = 0;
    for (0..short_block_len + 1) |j| {
        for (0..num_blocks) |b| {
            if (j == short_block_len and b < num_short) continue;
            const block_start: usize = blk: {
                var start: usize = 0;
                for (0..b) |bb| {
                    start += short_block_len + (if (bb < num_short) @as(usize, 0) else 1);
                }
                break :blk start;
            };
            result[idx] = cw[block_start + j];
            idx += 1;
        }
    }
    var ej: usize = 0;
    while (ej < block_ecc) : (ej += 1) {
        for (0..num_blocks) |b| {
            result[idx] = ecc_cw[b * block_ecc + ej];
            idx += 1;
        }
    }
    std.debug.assert(idx == raw_cw);
    return result;
}

// ── 图案 ──

fn alignmentPositions(a: Allocator, ver: u8) ![]u8 {
    if (ver == 1) return a.alloc(u8, 0);
    const num_align: usize = ver / 7 + 2;
    const step: u32 = if (ver == 32)
        26
    else
        (@as(u32, ver) * 4 + @as(u32, @intCast(num_align)) * 2 + 1) / (@as(u32, @intCast(num_align)) * 2 - 2) * 2;
    var result = try a.alloc(u8, num_align);
    result[0] = 6;
    var pos: u32 = @as(u32, ver) * 4 + 10; // size - 7
    var i: usize = num_align - 1;
    while (i >= 1) : (i -= 1) {
        result[i] = @intCast(pos);
        if (i == 1) break;
        pos -= step;
    }
    return result;
}

pub fn encode(a: Allocator, text: []const u8, ecc: Ecc) Error!Matrix {
    // 1. 选最小可容纳版本。注意 byte 模式长度字段落位宽依赖版本：
    //    v1-9 用 8 位、v10+ 必须 16 位（spec），选版本按对应位宽算需求。
    var ver: u8 = 1;
    while (true) {
        const lb: usize = if (ver < 10) 8 else 16;
        const cap_bits: usize = @intCast(dataCodewords(ver, ecc) * 8);
        const need = 4 + lb + text.len * 8;
        if (need <= cap_bits) break;
        if (ver == 40) return error.TextTooLong;
        ver += 1;
    }
    const len_bits: u6 = if (ver < 10) 8 else 16;
    const size: u32 = @as(u32, ver) * 4 + 17;

    // 2. 数据位流：mode(4) + 长度 + 字节
    var bits: BitBuf = .{};
    try bits.append(a, 0b0100, 4);
    try bits.append(a, @intCast(text.len), len_bits);
    for (text) |b| try bits.append(a, b, 8);

    const all_cw = try encodeCodewords(a, ver, ecc, bits.bits.items);

    // 3. 画布 + 功能图案
    var modules = try a.alloc(bool, @as(usize, size) * size);
    const is_function = try a.alloc(bool, @as(usize, size) * size);
    @memset(modules, false);
    @memset(is_function, false);
    try drawFunctionPatterns(modules, is_function, size, ver, ecc, a);

    // 4. 数据锯齿形放置（右→左，跳过第 6 列时序线）
    var bit_i: usize = 0;
    var i: i32 = @intCast(size - 1);
    while (i >= 1) : (i -= 2) {
        if (i == 6) i = 5;
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            for (0..2) |c| {
                const x: i32 = i - @as(i32, @intCast(c));
                const upward = (@as(u32, @intCast(i)) + 1) & 2 == 0;
                const y: i32 = if (upward) @as(i32, @intCast(size)) - 1 - j else j;
                const idx: usize = @intCast(y * @as(i32, @intCast(size)) + x);
                if (!is_function[idx]) {
                    const dark = bit_i < all_cw.len * 8 and (all_cw[bit_i >> 3] >> @intCast(7 - (bit_i & 7)) & 1) != 0;
                    modules[idx] = dark;
                    bit_i += 1;
                }
            }
        }
    }

    // 5. 掩码：8 个都试，按惩罚分选最优
    const masked = try a.alloc(bool, modules.len); // 返回值：调用方 arena 管生命周期
    var best_mask: u3 = 0;
    var best_penalty: i64 = std.math.maxInt(i64);
    for (0..8) |m| {
        @memcpy(masked, modules);
        applyMask(masked, is_function, size, @intCast(m));
        drawFormatBits(masked, is_function, size, ecc, @intCast(m));
        const penalty = penaltyScore(masked, size);
        if (penalty < best_penalty) {
            best_penalty = penalty;
            best_mask = @intCast(m);
        }
    }
    @memcpy(masked, modules);
    applyMask(masked, is_function, size, best_mask);
    drawFormatBits(masked, is_function, size, ecc, best_mask);
    a.free(modules);
    a.free(is_function);
    return .{ .size = size, .modules = masked };
}

fn setFn(modules: []bool, is_function: []bool, size: u32, x: i32, y: i32, dark: bool) void {
    if (x < 0 or y < 0 or x >= size or y >= size) return;
    const idx: usize = @intCast(y * @as(i32, @intCast(size)) + x);
    modules[idx] = dark;
    is_function[idx] = true;
}

fn drawFunctionPatterns(modules: []bool, is_function: []bool, size: u32, ver: u8, ecc: Ecc, a: Allocator) !void {
    // 时序线
    for (0..size) |i| {
        setFn(modules, is_function, size, 6, @intCast(i), i % 2 == 0);
        setFn(modules, is_function, size, @intCast(i), 6, i % 2 == 0);
    }
    // 定位图案 + 分隔（3x3 黑心，5x5 白环，7x7 黑框）
    drawFinder(modules, is_function, size, 3, 3);
    drawFinder(modules, is_function, size, @as(i32, @intCast(size)) - 4, 3);
    drawFinder(modules, is_function, size, 3, @as(i32, @intCast(size)) - 4);
    // 校正图案
    const aligns = try alignmentPositions(a, ver);
    defer a.free(aligns);
    for (aligns) |ay| {
        for (aligns) |ax| {
            if ((ax == 6 and ay == 6) or (ax == size - 7 and ay == 6) or (ax == 6 and ay == size - 7)) continue;
            var dy: i32 = -2;
            while (dy <= 2) : (dy += 1) {
                var dx: i32 = -2;
                while (dx <= 2) : (dx += 1) {
                    const d = @max(@abs(dx), @abs(dy));
                    setFn(modules, is_function, size, @as(i32, ax) + dx, @as(i32, ay) + dy, d != 1);
                }
            }
        }
    }
    // 版本信息（ver>=7，BCH(18,6)）
    if (ver >= 7) {
        var rem: u32 = @as(u32, ver);
        for (0..12) |_| {
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        }
        const vinfo = (@as(u32, ver) << 12) | rem;
        for (0..18) |i| {
            const bit = (vinfo >> @intCast(i)) & 1 != 0;
            const ax: i32 = @intCast(size - 11 + i % 3);
            const ay: i32 = @intCast(i / 3);
            setFn(modules, is_function, size, ax, ay, bit);
            setFn(modules, is_function, size, ay, ax, bit);
        }
    }
    // 恒黑模块（左下格式区旁）
    setFn(modules, is_function, size, 8, @intCast(size - 8), true);
    // 格式位先按 mask 0 占位：关键是把这 30 个格式格子标成 is_function，
    // 数据锯齿放置才会跳过它们——此前漏了这步，码字写进格式区、整体
    // 错位，QR 永远扫不出来；最终格式位在掩码选定后重画。
    drawFormatBits(modules, is_function, size, ecc, 0);
}

fn drawFinder(modules: []bool, is_function: []bool, size: u32, cx: i32, cy: i32) void {
    var dy: i32 = -4;
    while (dy <= 4) : (dy += 1) {
        var dx: i32 = -4;
        while (dx <= 4) : (dx += 1) {
            const dist = @max(@abs(dx), @abs(dy));
            setFn(modules, is_function, size, cx + dx, cy + dy, dist != 2 and dist != 4);
        }
    }
}

fn formatBits(ecc: Ecc, mask: u3) u32 {
    // 纠错级别指示位按 spec 编码：L=01、M=00、Q=11、H=10——
    // 不能直接用枚举值（那只是 ECC 表的行索引），写错解码器读不出级别
    const fmt: u32 = switch (ecc) {
        .low => 0b01,
        .medium => 0b00,
        .quartile => 0b11,
        .high => 0b10,
    };
    const data: u32 = (fmt << 3) | mask;
    var rem: u32 = data;
    for (0..10) |_| {
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    return ((data << 10) | rem) ^ 0x5412;
}

fn drawFormatBits(modules: []bool, is_function: []bool, size: u32, ecc: Ecc, mask: u3) void {
    const bits = formatBits(ecc, mask);
    // 绕左上角一圈
    for (0..6) |i| setFn(modules, is_function, size, 8, @intCast(i), (bits >> @intCast(i)) & 1 != 0);
    setFn(modules, is_function, size, 8, 7, (bits >> 6) & 1 != 0);
    setFn(modules, is_function, size, 8, 8, (bits >> 7) & 1 != 0);
    setFn(modules, is_function, size, 7, 8, (bits >> 8) & 1 != 0);
    for (9..15) |i| setFn(modules, is_function, size, @intCast(14 - i), 8, (bits >> @intCast(i)) & 1 != 0);
    // 右上 + 左下副本
    for (0..8) |i| setFn(modules, is_function, size, @intCast(size - 1 - i), 8, (bits >> @intCast(i)) & 1 != 0);
    for (8..15) |i| setFn(modules, is_function, size, 8, @intCast(size - 15 + i), (bits >> @intCast(i)) & 1 != 0);
}

fn applyMask(modules: []bool, is_function: []const bool, size: u32, mask: u3) void {
    for (0..size) |y| {
        for (0..size) |x| {
            const idx = y * size + x;
            if (is_function[idx]) continue;
            const invert = switch (mask) {
                0 => (x + y) % 2 == 0,
                1 => y % 2 == 0,
                2 => x % 3 == 0,
                3 => (x + y) % 3 == 0,
                4 => (x / 3 + y / 2) % 2 == 0,
                5 => x * y % 2 + x * y % 3 == 0,
                6 => (x * y % 2 + x * y % 3) % 2 == 0,
                7 => ((x + y) % 2 + x * y % 3) % 2 == 0,
            };
            if (invert) modules[idx] = !modules[idx];
        }
    }
}

fn penaltyScore(m: []const bool, size: u32) i64 {
    var result: i64 = 0;
    // 规则 1：行/列连续同色（≥5 起罚）
    for (0..size) |y| {
        var run_color = m[y * size];
        var run: i64 = 1;
        for (1..size) |x| {
            if (m[y * size + x] == run_color) {
                run += 1;
                if (run == 5) {
                    result += 3;
                } else if (run > 5) {
                    result += 1;
                }
            } else {
                run_color = m[y * size + x];
                run = 1;
            }
        }
    }
    for (0..size) |x| {
        var run_color = m[x];
        var run: i64 = 1;
        for (1..size) |y| {
            if (m[y * size + x] == run_color) {
                run += 1;
                if (run == 5) {
                    result += 3;
                } else if (run > 5) {
                    result += 1;
                }
            } else {
                run_color = m[y * size + x];
                run = 1;
            }
        }
    }
    // 规则 2：2x2 同色块
    for (0..size - 1) |y| {
        for (0..size - 1) |x| {
            const c = m[y * size + x];
            if (c == m[y * size + x + 1] and c == m[(y + 1) * size + x] and c == m[(y + 1) * size + x + 1])
                result += 3;
        }
    }
    // 规则 4：深色占比偏离 50%
    var dark: i64 = 0;
    for (m) |b| dark += @intFromBool(b);
    const percent = @divTrunc(dark * 100, @as(i64, @intCast(m.len)));
    const prev5 = @divTrunc(percent - 5, 5);
    const next5 = @divTrunc(percent + 5, 5);
    result += 10 * @as(i64, @intCast(@min(@abs(prev5), @abs(next5))));
    return result;
}

// ── 测试 ──

test "qr：URL 编码出带定位角的矩阵" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try encode(a, "https://bodian-oia.kuwo.cn/bodian/download.html?pageName=login_pc&pt=3&id=abc", .medium);
    try std.testing.expect(m.size >= 21);
    // 三个定位角外框角落全黑
    try std.testing.expect(m.modules[0]); // 左上角
    try std.testing.expect(m.modules[(m.size - 7) * m.size]); // 右上角
    try std.testing.expect(m.modules[m.size - 1]); // 左下角
    // 时序线在 6 行 8..size-8 段交替
    for (8..m.size - 8) |i| {
        try std.testing.expectEqual(i % 2 == 0, m.modules[6 * m.size + i]);
    }
}

test "qr：版本边界与长文本" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    _ = try encode(a, "", .medium);
    const long = try a.alloc(u8, 3000);
    @memset(long, 'a');
    try std.testing.expectError(error.TextTooLong, encode(a, long, .high));
    _ = try encode(a, long[0..1000], .low);
    _ = try encode(a, "https://y.qq.com/", .high);
}

test "qr：数据区格子数恰好等于码字位数（格式位必须预留）" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try encode(a, "https://music.163.com/login?codekey=0123456789abcdef0123456789abcdef", .medium);
    const ver: u8 = @intCast((m.size - 17) / 4);
    // 重建功能图案层，统计非功能（数据区）格子数
    const n: usize = @as(usize, m.size) * m.size;
    const blank = try a.alloc(bool, n);
    const isfn = try a.alloc(bool, n);
    @memset(blank, false);
    @memset(isfn, false);
    try drawFunctionPatterns(blank, isfn, m.size, ver, .medium, a);
    var free_cells: usize = 0;
    for (isfn) |f| {
        if (!f) free_cells += 1;
    }
    // 若格式位未预留，这里会多出 30 个格子（码字写进格式区、整体错位）
    try std.testing.expectEqual(@as(usize, @intCast(rawDataModules(ver))), free_cells);
}

/// 全链路自校验：encode → 读格式位（双副本一致+候选匹配）→ 反掩码 →
/// 锯齿收集码字 → 反交织 → 每块 RS 余式复算比对 → 解析 mode/长度/内容。
/// 格式位未预留、级别指示位写错、纠错未按列交织这三类 bug 都会被抓住。
fn roundtripCheck(a: Allocator, text: []const u8, ecc: Ecc) !void {
    const m = try encode(a, text, ecc);
    const ver: u8 = @intCast((m.size - 17) / 4);
    const size_i: i32 = @intCast(m.size);
    const n: usize = @as(usize, m.size) * m.size;

    // 1. 读两份格式位并匹配 (ecc, mask) 候选
    const readFmt = struct {
        fn go(mod: []const bool, sz: u32, copy: usize) u32 {
            var bits: u32 = 0;
            switch (copy) {
                0 => { // 绕左上角
                    for (0..6) |i| bits |= @as(u32, @intFromBool(mod[i * sz + 8])) << @intCast(i);
                    bits |= @as(u32, @intFromBool(mod[7 * sz + 8])) << 6;
                    bits |= @as(u32, @intFromBool(mod[8 * sz + 8])) << 7;
                    bits |= @as(u32, @intFromBool(mod[8 * sz + 7])) << 8;
                    for (9..15) |i| bits |= @as(u32, @intFromBool(mod[8 * sz + (14 - i)])) << @intCast(i);
                },
                else => { // 右上 + 左下
                    for (0..8) |i| bits |= @as(u32, @intFromBool(mod[8 * sz + (sz - 1 - i)])) << @intCast(i);
                    for (8..15) |i| bits |= @as(u32, @intFromBool(mod[(sz - 15 + i) * sz + 8])) << @intCast(i);
                },
            }
            return bits;
        }
    }.go;
    const f1 = readFmt(m.modules, m.size, 0);
    const f2 = readFmt(m.modules, m.size, 1);
    try std.testing.expectEqual(f1, f2);
    var found: ?struct { ecc: Ecc, mask: u3 } = null;
    inline for (.{ Ecc.low, Ecc.medium, Ecc.quartile, Ecc.high }) |e| {
        for (0..8) |mk| {
            if (formatBits(e, @intCast(mk)) == f1) {
                try std.testing.expect(found == null); // 编码必须唯一
                found = .{ .ecc = e, .mask = @intCast(mk) };
            }
        }
    }
    const fm = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ecc, fm.ecc);

    // 2. 重建功能层，反掩码后按锯齿序收集码字位
    const blank = try a.alloc(bool, n);
    const isfn = try a.alloc(bool, n);
    @memset(blank, false);
    @memset(isfn, false);
    try drawFunctionPatterns(blank, isfn, m.size, ver, ecc, a);
    const plain = try a.alloc(bool, n);
    @memcpy(plain, m.modules);
    applyMask(plain, isfn, m.size, fm.mask);

    // stream 按位存（每字节 1 位）。长度取自由格数（=rawDataModules，未必
    // 字节对齐）：锯齿收集走满全部自由格，码字位只占前 raw_cw*8 位
    const free_bits: usize = @intCast(rawDataModules(ver));
    const stream = try a.alloc(u8, free_bits); // 每字节存 1 位
    var bit_i: usize = 0;
    var i: i32 = size_i - 1;
    while (i >= 1) : (i -= 2) {
        if (i == 6) i = 5;
        var j: i32 = 0;
        while (j < size_i) : (j += 1) {
            for (0..2) |c| {
                const x: i32 = i - @as(i32, @intCast(c));
                const upward = (@as(u32, @intCast(i)) + 1) & 2 == 0;
                const y: i32 = if (upward) size_i - 1 - j else j;
                const idx: usize = @intCast(y * size_i + x);
                if (!isfn[idx]) {
                    stream[bit_i] = @intFromBool(plain[idx]);
                    bit_i += 1;
                }
            }
        }
    }
    try std.testing.expectEqual(free_bits, bit_i);

    // 3. 反交织 + 每块 RS 余式复算
    const e: usize = @intFromEnum(ecc);
    const num_data: usize = @intCast(dataCodewords(ver, ecc));
    const num_blocks: usize = @intCast(NUM_ECC_BLOCKS[e][ver]);
    const block_ecc: usize = @intCast(ECC_CODEWORDS_PER_BLOCK[e][ver]);
    const short_len: usize = num_data / num_blocks;
    const num_short: usize = num_blocks - num_data % num_blocks;
    const divisor = try rsComputeDivisor(block_ecc, a);
    const data_bytes = try a.alloc(u8, num_data);
    var didx: usize = 0;
    for (0..num_blocks) |b| {
        const dlen = short_len + (if (b < num_short) @as(usize, 0) else 1);
        // 数据块 b 的第 j 字节在交织流里的位置：j*num_blocks + b；
        // 长块补位列（j == short_len）前移到短块之后
        var tmp = try a.alloc(u8, dlen);
        for (0..dlen) |j| {
            const pos = if (j < short_len) j * num_blocks + b else short_len * num_blocks + (b - num_short);
            tmp[j] = streamBitToByte(stream, pos * 8);
        }
        const rem = try rsAddRemainder(tmp, divisor, a);
        for (0..block_ecc) |ej| {
            const pos = (num_data + ej * num_blocks + b) * 8;
            var eb: u8 = 0;
            for (0..8) |t| eb = (eb << 1) | @as(u8, @intCast(stream[pos + t]));
            try std.testing.expectEqual(eb, rem[ej]);
        }
        @memcpy(data_bytes[didx .. didx + dlen], tmp);
        didx += dlen;
    }
    try std.testing.expectEqual(num_data, didx);

    // 4. 解析位流：mode=0100 + 长度 + 内容
    const lb: usize = if (ver < 10) 8 else 16;
    var mode: u32 = 0;
    for (0..4) |t| mode = (mode << 1) | data_bitsAt(data_bytes, t);
    try std.testing.expectEqual(@as(u32, 0b0100), mode);
    var length: usize = 0;
    for (4..4 + lb) |t| length = (length << 1) | data_bitsAt(data_bytes, t);
    try std.testing.expectEqual(text.len, length);
    for (text, 0..) |ch, k| {
        var v: u8 = 0;
        for (0..8) |t| v = (v << 1) | @as(u8, @intCast(data_bitsAt(data_bytes, 4 + lb + k * 8 + t)));
        try std.testing.expectEqual(ch, v);
    }
}

fn streamBitToByte(bits: []const u8, from: usize) u8 {
    var v: u8 = 0;
    for (0..8) |t| v = (v << 1) | @as(u8, @intCast(bits[from + t]));
    return v;
}

fn data_bitsAt(bytes: []const u8, bit: usize) u32 {
    return (bytes[bit >> 3] >> @intCast(7 - (bit & 7))) & 1;
}

test "qr：v10+ 使用 16 位长度字段" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var text: [210]u8 = undefined;
    @memcpy(text[0..21], "https://example.com/?");
    @memset(text[21..], 'a');
    try roundtripCheck(a, &text, .medium); // v10-M：覆盖 16 位长度 + 5 块交织
}

test "qr：回路校验（v5 双块 + v2 单块 + 各纠错级别）" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try roundtripCheck(a, "https://music.163.com/login?codekey=0123456789abcdef0123456789abcdef", .medium);
    try roundtripCheck(a, "https://y.qq.com/", .high);
    try roundtripCheck(a, "https://bodian-oia.kuwo.cn/bodian/download.html?pageName=login_pc&pt=3&id=abc", .low);
    try roundtripCheck(a, "HELLO", .quartile);
}
