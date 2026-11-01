// src/core/objc.zig — ObjC runtime 最小绑定（macOS SMTC 用）。
//
// 部分实现 derived from mitchellh/zig-objc (MIT License, Copyright (c) 2022
// Mitchell Hashimoto)——只抽取本项目需要的 msgSend/sel/class/Block 最小集。
//
// libobjc 随系统存在（zig 的 macOS libc 桩内含符号），无需额外链接。
// 注意：selector 名拼写错误是运行时才炸（返回 nil / 静默无效），编译期
// 只查参数类型。
//
// 0.17 移除了 @Type（不能 comptime 拼函数类型），msgSend 采用调用点显式
// 签名风格：
//   const F = *const fn (objc.Id, objc.Sel, objc.Id) callconv(.c) objc.Id;
//   objc.send(F)(obj, objc.sel("init"), arg);

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.os.tag != .macos) @compileError("objc.zig 仅 macOS 目标");
}

pub const Id = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Class = ?*anyopaque;

extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;

const msg_send: *const anyopaque = @extern(*const anyopaque, .{ .name = "objc_msgSend" });

pub inline fn getClass(comptime name: [:0]const u8) Class {
    return objc_getClass(name);
}

pub inline fn sel(comptime name: [:0]const u8) Sel {
    return sel_registerName(name);
}

/// 把 objc_msgSend cast 成调用点声明的完整签名（第一个参数必须是 receiver,
/// 第二个 _sel）。传函数类型 fn (...) callconv(.c) Ret（不带指针）。
pub inline fn send(comptime F: type) *const F {
    const info = @typeInfo(F).@"fn";
    if (info.return_type == null) @compileError("msgSend 需要具名返回类型");
    return @ptrCast(@alignCast(msg_send));
}

// ── ObjC Block（addTarget: 闭包用）──
// 栈上 block：isa 指向 _NSConcreteStackBlock，生命周期由调用方帧保证——
// 只把 block 立刻传给 addTarget:（系统会 copy 到堆上），符合约定。

pub const block_isa: *const anyopaque = @extern(*const anyopaque, .{ .name = "_NSConcreteStackBlock" });

pub const BlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize,
    copy: ?*const anyopaque = null,
    dispose: ?*const anyopaque = null,
};

pub const Block = extern struct {
    isa: *const anyopaque,
    flags: i32 = 0x50000000, // BLOCK_IS_GLOBAL|BLOCK_HAS_SIGNATURE 惯用组合
    reserved: i32 = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
};

/// 构造一个 (Id, EventArg) -> Id 的 block，转发到编译期固化的 handler。
/// n 是编译期常量（每个远程命令一个 block，按钮号 comptime 固化）。
pub fn commandBlock(
    comptime EventArg: type,
    comptime n: i64,
    comptime handler: fn (n: i64, event: EventArg) void,
) *Block {
    const S = struct {
        const desc = BlockDescriptor{ .size = @sizeOf(Block) };
        var inst = Block{
            .isa = block_isa,
            .invoke = &invoke,
            .descriptor = &desc,
        };
        fn invoke(_block: *Block, _self: Id, event: EventArg) callconv(.c) Id {
            _ = _block;
            _ = _self;
            handler(n, event);
            return null;
        }
    };
    return &S.inst;
}
