const std = @import("std");
const builtin = @import("builtin");
const zz = @import("zigzag");
const app = @import("ui/app.zig");

// 两种运行方式：
//
//   amtui                     正常进入 TUI
//   amtui snap [选项]        截帧模式（给开发/验收用）：无终端驱动 Model，
//                             把按键序列作用后的最终渲染帧写进文件。
//
// snap 选项：
//   --size 110x32   终端尺寸（默认 110x32）
//   --keys  序列    逗号分隔：enter/esc/space/tab/up/down/left/right/pgup/pgdn/
//                   home/end、wait=<秒>（推进假进度）、text=<串>（连续输入）、
//                   其余按单个字符（如 3、?、/）
//   --out 路径      输出文件（默认 frame.ansi）
//   --plain         输出去除 ANSI 颜色的纯文本（默认带色）

pub fn main(init: std.process.Init) !void {
    // Windows 上 Args.Iterator.init 是编译错误，必须用 initAllocator（跨平台）
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // argv[0]
    const sub = args_it.next();
    if (sub) |s| {
        if (std.mem.eql(u8, s, "snap")) return snap(init, &args_it);
    }

    // 音源选择：AM_BACKEND=bodian|netease|qq|mock（默认 netease，匿名即全功能）；
    // 外部歌词/状态接口：AM_API_PORT（默认 8790，0=关闭，只绑 127.0.0.1）
    // 封面方格比例：先 ioctl 实测终端像素尺寸，AM_CELL_RATIO 手动覆盖
    @import("ui/widgets.zig").probeCellRatio();
    zz_setCellRatio(init.environ_map.get("AM_CELL_RATIO"));
    const backend = std.meta.stringToEnum(app.Backend, init.environ_map.get("AM_BACKEND") orelse "netease") orelse .netease;
    const api_port: u16 = if (init.environ_map.get("AM_API_PORT")) |v|
        (std.fmt.parseInt(u16, v, 10) catch 8790)
    else
        8790;

    var program = zz.Program(app.Model).initWithModel(init.gpa, init.io, init.environ_map, .{
        .mock_dir = init.environ_map.get("AM_MOCK_DIR") orelse "testdata/mock",
        .backend = backend,
        .api_port = api_port,
    }, .{
        .alt_screen = true,
        .title = "AlloyMusic",
        .mouse = true,
        // windows 上用全量重绘：conhost 写满最后一格立即换行（pty 是延迟
        // 换行），diff 渲染碰到右下角会让整屏错位；且 conhost 对 DEC 2026
        // 同步输出转发不完整，切页大帧会被分段上屏出现闪帧。全量重绘 +
        // 绝对寻址让每帧自洽。posix 终端没有这两个问题，保留 diff 省带宽。
        .render_mode = if (builtin.os.tag == .windows) .full else .diff,
    });
    defer program.deinit();
    try program.run();
}

// 测试收集：test 构建不分析 main()，`app` 若只在 main 里引用，UI 层
// （及其传递 import 的所有文件）的 test 块根本不会进测试图——所有
// zig build test 都是空跑。这里显式拉进来。
test {
    _ = app;
}

fn snap(init: std.process.Init, it: *std.process.Args.Iterator) !void {
    var width: u16 = 110;
    var height: u16 = 32;
    var keys: []const u8 = "";
    var out_path: []const u8 = "frame.ansi";
    var plain = false;
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--size=")) {
            const size = arg["--size=".len..];
            const x = std.mem.indexOfScalar(u8, size, 'x') orelse return usageError("--size 需要 WxH 形式");
            width = std.fmt.parseInt(u16, size[0..x], 10) catch return usageError("--size 宽度不合法");
            height = std.fmt.parseInt(u16, size[x + 1 ..], 10) catch return usageError("--size 高度不合法");
        } else if (std.mem.startsWith(u8, arg, "--keys=")) {
            keys = arg["--keys=".len..];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            out_path = arg["--out=".len..];
        } else if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
        } else {
            return usageError("未知参数");
        }
    }

    var h = try zz.testing.Harness(app.Model).initWithModel(init.gpa, init.io, .{
        .mock_dir = init.environ_map.get("AM_MOCK_DIR") orelse "testdata/mock",
        // AM_BACKEND 可指定真源——但 Harness 是假 Io，不支持真实网络，
        // 真源请求会永远挂起；真源链路验收用 amtui-{qq,nets,bod}smoke 或真实终端。
        .backend = std.meta.stringToEnum(app.Backend, init.environ_map.get("AM_BACKEND") orelse "mock") orelse .mock,
    }, .{});
    defer h.deinit();
    try h.start();
    try h.resize(width, height);

    var tok = std.mem.splitScalar(u8, keys, ',');
    while (tok.next()) |t| {
        if (t.len == 0) continue;
        if (std.mem.eql(u8, t, "enter")) {
            try h.press(.{ .key = .enter });
        } else if (std.mem.eql(u8, t, "esc")) {
            try h.press(.{ .key = .escape });
        } else if (std.mem.eql(u8, t, "space")) {
            try h.press(.{ .key = .space });
        } else if (std.mem.eql(u8, t, "tab")) {
            try h.press(.{ .key = .tab });
        } else if (std.mem.eql(u8, t, "up")) {
            try h.press(.{ .key = .up });
        } else if (std.mem.eql(u8, t, "down")) {
            try h.press(.{ .key = .down });
        } else if (std.mem.eql(u8, t, "left")) {
            try h.press(.{ .key = .left });
        } else if (std.mem.eql(u8, t, "right")) {
            try h.press(.{ .key = .right });
        } else if (std.mem.eql(u8, t, "pgup")) {
            try h.press(.{ .key = .page_up });
        } else if (std.mem.eql(u8, t, "pgdn")) {
            try h.press(.{ .key = .page_down });
        } else if (std.mem.eql(u8, t, "home")) {
            try h.press(.{ .key = .home });
        } else if (std.mem.eql(u8, t, "end")) {
            try h.press(.{ .key = .end });
        } else if (std.mem.startsWith(u8, t, "text=")) {
            try h.typeText(t["text=".len..]);
        } else if (std.mem.startsWith(u8, t, "wait=")) {
            const secs = std.fmt.parseFloat(f64, t["wait=".len..]) catch return usageError("wait 秒数不合法");
            try h.advance(@intFromFloat(secs * std.time.ns_per_s));
        } else if (std.mem.startsWith(u8, t, "click=")) {
            // 模拟鼠标左键单击，格式 click=<x>x<y>（keys 按逗号切分，坐标内不能用逗号）
            const pos = t["click=".len..];
            const sep = std.mem.indexOfScalar(u8, pos, 'x') orelse return usageError("click 格式: click=x行x列，如 click=30x4");
            const mx = std.fmt.parseInt(u16, pos[0..sep], 10) catch return usageError("click x 不合法");
            const my = std.fmt.parseInt(u16, pos[sep + 1 ..], 10) catch return usageError("click y 不合法");
            try h.mouse(.{ .x = mx, .y = my, .button = .left, .event_type = .press });
        } else {
            const cp = std.unicode.utf8Decode(t) catch return usageError("按键必须是单字符或保留名");
            try h.pressChar(cp);
        }
    }

    const frame = if (plain) try h.plainView() else try h.view();
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = frame,
    });
}

fn zz_setCellRatio(v: ?[]const u8) void {
    const widgets = @import("ui/widgets.zig");
    widgets.setCellRatio(v);
}

fn usageError(msg: []const u8) error{Usage} {
    std.debug.print("snap: {s}\n用法: amtui snap --size 110x32 --keys \"3,space,wait=5,click=30,4\" --out frame.ansi [--plain]\n", .{msg});
    return error.Usage;
}
