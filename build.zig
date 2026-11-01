const std = @import("std");

/// 配置期同步编译 relay 并把 exe 字节生成为 src/core/relay_embed.zig 字面量。
/// csc 必须先于 Zig 编译运行（嵌入内容是编译输入），graph 内的 step 做不到
/// "configure 前执行"，故在此同步调用（csc 耗时 ~0.2s，可接受）。
fn buildEmbedRelay(b: *std.Build, is_windows: bool) void {
    const io = b.graph.io;
    const dir = std.Io.Dir.cwd();
    const gpa = b.graph.arena;
    const out_path = "src/core/relay_embed.zig";
    const stub = "pub const exe_bytes: []const u8 = \"\";\n";
    if (!is_windows) {
        // 非 Windows 目标：SMTC/relay 不参与编译路径，生成空桩保证 @import 可解析
        dir.writeFile(io, .{ .sub_path = out_path, .data = stub }) catch {};
        return;
    }
    dir.createDirPath(io, "zig-out/relay-stage") catch {};
    // WinRT 元数据：统一用 SDK UnionMetadata 的 Windows.winmd 聚合引用
    // （System32 单个 winmd 与聚合并用会类型冲突 CS0433；聚合里包含
    // Foundation/Media/Storage 全部投影，AsRandomAccessStream 的
    // facade↔winmd 类型也能对上）。SDK 版本按本机安装探测（CI 与本机
    // 装的 SDK 版本可能不同）
    const winmd = blk: {
        for ([_][]const u8{
            "C:\\Program Files (x86)\\Windows Kits\\10\\UnionMetadata\\10.0.26100.0\\Windows.winmd",
            "C:\\Program Files (x86)\\Windows Kits\\10\\UnionMetadata\\10.0.22621.0\\Windows.winmd",
            "C:\\Program Files (x86)\\Windows Kits\\10\\UnionMetadata\\10.0.19041.0\\Windows.winmd",
        }) |c| {
            if (std.Io.Dir.cwd().access(io, c, .{})) |_| {
                break :blk c;
            } else |_| {}
        }
        std.debug.print("build: 未找到 UnionMetadata Windows.winmd（需要 Windows 10 SDK）\n", .{});
        std.process.exit(1);
    };
    var ref_buf: [256]u8 = undefined;
    const ref = std.fmt.bufPrint(&ref_buf, "/r:{s}", .{winmd}) catch unreachable;
    const csc = std.process.run(gpa, io, .{
        .argv = &.{
            "C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
            "/nologo",
            "/optimize+", // csc 的 release 优化（无 /debug，无 pdb）
            "/out:zig-out\\relay-stage\\AlloyMusic-SMTC.exe",
            "/r:System.Runtime.dll",
            "/r:System.Drawing.dll",
            "/r:System.Runtime.WindowsRuntime.dll",
            "/r:System.Runtime.InteropServices.WindowsRuntime.dll",
            ref,
            // 注意 csc 的选项前缀也是 '/'——源文件路径必须用反斜杠
            "relay\\AlloyMusic-SMTC.cs",
        },
    }) catch {
        std.debug.print("build: csc 启动失败（.NET Framework 4.x 缺失？）\n", .{});
        std.process.exit(1);
    };
    const exe_path = "zig-out/relay-stage/AlloyMusic-SMTC.exe";
    const bytes = blk: {
        if (csc.term == .exited and csc.term.exited == 0) {
            break :blk dir.readFileAlloc(io, exe_path, gpa, .limited(1 << 20)) catch {
                std.debug.print("build: relay 产物读取失败\n", .{});
                std.process.exit(1);
            };
        }
        // csc 失败：有旧产物则复用（大声警告——静默复用曾导致"改了 .cs
        // 却一直跑旧 relay"的排查事故），否则终止
        if (dir.readFileAlloc(io, exe_path, gpa, .limited(1 << 20))) |old| {
            std.debug.print("⚠⚠⚠ build: csc 编译失败，正在复用旧 relay 产物（.cs 改动未生效！）错误如下：\n{s}{s}\n", .{ csc.stdout, csc.stderr });
            break :blk old;
        } else |_| {}
        std.debug.print("build: csc 失败：\n{s}{s}", .{ csc.stdout, csc.stderr });
        std.process.exit(1);
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "pub const exe_bytes: []const u8 = \"") catch std.process.exit(1);
    for (bytes) |c| {
        switch (c) {
            '"' => buf.appendSlice(gpa, "\\\"") catch std.process.exit(1),
            '\\' => buf.appendSlice(gpa, "\\\\") catch std.process.exit(1),
            '\n' => buf.appendSlice(gpa, "\\n") catch std.process.exit(1),
            '\r' => buf.appendSlice(gpa, "\\r") catch std.process.exit(1),
            else => {
                if (c >= 0x20 and c < 0x7f) {
                    buf.append(gpa, c) catch std.process.exit(1);
                } else {
                    var hex: [4]u8 = undefined;
                    _ = std.fmt.bufPrint(&hex, "\\x{x:0>2}", .{c}) catch unreachable;
                    buf.appendSlice(gpa, &hex) catch std.process.exit(1);
                }
            },
        }
    }
    buf.appendSlice(gpa, "\";\n") catch std.process.exit(1);
    dir.writeFile(io, .{ .sub_path = out_path, .data = buf.items }) catch {
        std.debug.print("build: {s} 写入失败\n", .{out_path});
        std.process.exit(1);
    };
}

// smoke 系工具的公共挂法：默认 install 不含它们（发布产物只有 amtui +
// relay），`zig build <name>` 时才装进 zig-out/bin 并从那里运行——从
// zig-out/bin 跑是为了让 smtcsmoke 能发现同目录的 relay exe。
fn smokeStep(
    b: *std.Build,
    comptime step_name: []const u8,
    comptime exe_name: []const u8,
    comptime desc: []const u8,
    exe: *std.Build.Step.Compile,
    also_install: bool,
) void {
    const inst = b.addInstallArtifact(exe, .{});
    const step = b.step(step_name, desc);
    if (also_install) step.dependOn(b.getInstallStep());
    const run = b.addSystemCommand(&.{"./zig-out/bin/" ++ exe_name});
    run.step.dependOn(&inst.step);
    step.dependOn(&run.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // relay 嵌入：Windows 目标编译 C# 并生成字面量，其他目标生成空桩。
    // 必须在任何引用 relay_embed 的模块编译前做。
    buildEmbedRelay(b, target.result.os.tag == .windows);
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "amtui", .root_module = exe_mod });

    const zigzag = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigzag", zigzag.module("zigzag"));

    b.installArtifact(exe);
    // `zig build run`：直接启动 TUI（三源已纯 Zig 直调，无 Node sidecar）
    const run_step = b.step("run", "launch amtui");
    const run_cmd = b.addSystemCommand(&.{"./zig-out/bin/amtui"});
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // 波点后端真网络冒烟：zig build smoke（需要网络，不进默认 test）
    const smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/core/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    const smoke = b.addExecutable(.{ .name = "amtui-smoke", .root_module = smoke_mod });

    // test 步骤必须在所有平台 early-return 之前注册（此前 Windows 原生
    // `zig build test` 因 return 根本没有 test 步骤——见 docs §7 修的 bug）
    const test_step = b.step("test", "run unit tests");
    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    if (target.result.os.tag == .windows) {
        // MF 冒烟：本地 WAV 真播放断言（无网络），Media Foundation 后端里程碑
        const mfsmoke_mod = b.createModule(.{
            .root_source_file = b.path("src/core/mf_smoke.zig"),
            .target = target,
            .optimize = optimize,
        });
        const mfsmoke = b.addExecutable(.{ .name = "amtui-mfsmoke", .root_module = mfsmoke_mod });
        smokeStep(b, "mfsmoke", "amtui-mfsmoke", "run the Media Foundation playback smoke test (local WAV)", mfsmoke, false);
        // SMTC 冒烟：SendInput 注入媒体键，验证 系统→handler→takeButton 全链路
        const smtcsmoke_mod = b.createModule(.{
            .root_source_file = b.path("src/core/smtc_smoke.zig"),
            .target = target,
            .optimize = optimize,
        });
        const smtcsmoke = b.addExecutable(.{ .name = "amtui-smtcsmoke", .root_module = smtcsmoke_mod });
        // also_install=true：smoke 从 zig-out/bin 跑，确保发布产物（amtui，
        // 内含嵌入 relay）已就绪
        smokeStep(b, "smtcsmoke", "amtui-smtcsmoke", "run the SMTC media-key smoke test (SendInput injected)", smtcsmoke, true);
        // C# SMTC 中转（csc 零依赖编译——Windows 10/11 自带 .NET Framework 4.x）。
        // 它独占 SMTC 会话（展示 + ButtonPressed，躲开 MC.dll fire UAF，见
        // src/core/smtc.zig 头注释）；amtui 经 TCP 127.0.0.1:47821 行协议交互。
        //
        // 单文件分发：relay 不再单独安装，而是在【配置期】同步跑 csc（必须先于
        // Zig 编译产出嵌入内容），把产物字节以字面量生成进 src/core/relay_embed.zig，
        // amtui 运行时若同目录无 relay exe 则解包到 %TEMP% 再 spawn（smtc.zig）。
        // /optimize+ 即 csc 的 release 优化（无 /debug，无 pdb）。
        // Windows 目标不跑网络冒烟
        return;
    }
    smokeStep(b, "smoke", "amtui-smoke", "run the bodian backend network smoke test", smoke, false);

    // QQ/波点/网易直调真网络冒烟：zig build {qqsmoke,bodsmoke,netsmoke} <op> [arg]
    // （开发工具，用了 unix 语义的 init.allocator——Windows 目标跳过）
    if (target.result.os.tag != .windows) {
        inline for (.{ .{ "qqsmoke", "src/core/qq_smoke.zig", "amtui-qqsmoke" }, .{ "bodsmoke", "src/core/bodian_smoke.zig", "amtui-bodsmoke" }, .{ "netsmoke", "src/core/netease_smoke.zig", "amtui-netsmoke" } }) |sm| {
            const sm_mod = b.createModule(.{
                .root_source_file = b.path(sm[1]),
                .target = target,
                .optimize = optimize,
            });
            const sm_exe = b.addExecutable(.{ .name = sm[2], .root_module = sm_mod });
            smokeStep(b, sm[0], sm[2], "build+run " ++ sm[2], sm_exe, false);
        }
    }
}
