// src/core/ipc.zig — mpv IPC 传输抽象（分平台编译）。
//
// mpv 的 --input-ipc-server：unix 上是 unix socket，Windows 上是命名管道。
// 两端都是"连接→写字节→读字节→探测可读→关闭"，本文件给出统一接口，
// 平台实现用 comptime 分支选择——调用方（mpv.zig）零平台分支。
//
// 原始 posix/socket 实现来自 mpv.zig 时代（保留语义）：不经过 std.Io
// 派发——实测 io 派发的 unix connect 与并发 HTTP fetch 组合会偶发死锁，
// raw syscall 无此问题。Windows 管道同样走 raw extern 调用。

const std = @import("std");
const builtin = @import("builtin");

pub fn currentPid() u32 {
    if (builtin.os.tag == .windows) return GetCurrentProcessId();
    return @intCast(std.os.linux.getpid());
}

extern "kernel32" fn GetCurrentProcessId() u32;

/// IPC 服务名（不含平台前缀）。
pub fn serverName(buf: []u8, pid: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "alloymusic-mpv-{d}", .{pid}) catch null;
}

pub const Conn = switch (builtin.os.tag) {
    .windows => PipeConn,
    else => UnixConn,
};

/// unix：/tmp/<name>.sock；windows：\\.\pipe\<name>
pub fn serverArgPath(buf: []u8, name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fmt.bufPrint(buf, "\\\\.\\" ++ "pipe\\{s}", .{name}) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/{s}.sock", .{name}) catch null;
}

/// 清理服务端遗留（unix socket 文件）；windows 管道随进程消失，无操作。
pub fn cleanupServer(path: []const u8) void {
    if (builtin.os.tag == .windows) return;
    var pbuf: [128:0]u8 = @splat(0);
    if (path.len >= pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    _ = std.posix.system.unlink(&pbuf);
}

// ── unix：unix socket（raw syscall，不经 std.Io 派发）──

pub const UnixConn = struct {
    fd: std.posix.socket_t,

    pub fn connect(name: []const u8) ?UnixConn {
        var pbuf: [108:0]u8 = @splat(0);
        const full = std.fmt.bufPrint(&pbuf, "/tmp/{s}.sock", .{name}) catch return null;
        const posix = std.posix;
        const flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
        var fd: posix.socket_t = undefined;
        while (true) {
            const rc = posix.system.socket(posix.AF.UNIX, flags, 0);
            switch (posix.errno(rc)) {
                .SUCCESS => fd = @intCast(rc),
                .INTR => continue,
                else => return null,
            }
        }
        var addr: posix.sockaddr.un = .{ .path = @splat(0) };
        const n = @min(full.len, addr.path.len);
        @memcpy(addr.path[0..n], full[0..n]);
        const crc = posix.system.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        switch (posix.errno(crc)) {
            .SUCCESS => {},
            else => {
                _ = posix.system.close(fd);
                return null;
            },
        }
        return .{ .fd = fd };
    }

    pub fn writeAll(self: *UnixConn, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.posix.system.write(self.fd, bytes.ptr + off, bytes.len - off);
            switch (std.posix.errno(rc)) {
                .SUCCESS => off += @intCast(rc), // mac 的 write 返 isize，linux 返 usize
                .INTR => continue,
                else => return false,
            }
        }
        return true;
    }

    /// 阻塞读。返回 null = 对端关闭/错误。
    pub fn read(self: *UnixConn, buf: []u8) ?usize {
        while (true) {
            const n = std.posix.read(self.fd, buf) catch return null;
            if (n == 0) return null;
            return n;
        }
    }

    /// 非阻塞探测：是否有数据可读（poll 超时 0）
    pub fn hasData(self: *UnixConn) bool {
        const posix = std.posix;
        var pfd: [1]posix.pollfd = .{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&pfd, 0) catch return false;
        if (n == 0) return false;
        return pfd[0].revents & posix.POLL.IN != 0;
    }

    pub fn close(self: *UnixConn) void {
        _ = std.posix.system.close(self.fd);
    }
};

// ── windows：命名管道客户端（kernel32 raw extern）──

pub const PipeConn = struct {
    handle: std.os.windows.HANDLE,

    pub fn connect(name: []const u8) ?PipeConn {
        var pbuf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "\\\\.\\pipe\\{s}", .{name}) catch return null;
        var wbuf: [128]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path) catch return null;
        wbuf[wlen] = 0;
        const h = CreateFileW(
            @ptrCast(&wbuf),
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (h == INVALID_HANDLE_VALUE) return null;
        return .{ .handle = h };
    }

    pub fn writeAll(self: *PipeConn, bytes: []const u8) bool {
        var off: usize = 0;
        while (off < bytes.len) {
            var written: u32 = 0;
            const ok = WriteFile(self.handle, bytes.ptr + off, @intCast(bytes.len - off), &written, null);
            if (ok == 0) return false;
            if (written == 0) return false;
            off += written;
        }
        return true;
    }

    /// 阻塞读。返回 null = 对端关闭/错误。
    pub fn read(self: *PipeConn, buf: []u8) ?usize {
        var got: u32 = 0;
        const ok = ReadFile(self.handle, buf.ptr, @intCast(buf.len), &got, null);
        if (ok == 0) return null;
        if (got == 0) return null;
        return got;
    }

    /// 非阻塞探测：PeekNamedPipe 看缓冲里有没有字节
    pub fn hasData(self: *PipeConn) bool {
        var avail: u32 = 0;
        const ok = PeekNamedPipe(self.handle, null, 0, null, &avail, null);
        if (ok == 0) return false;
        return avail > 0;
    }

    pub fn close(self: *PipeConn) void {
        _ = CloseHandle(self.handle);
    }
};

// ── windows extern 声明与常量 ──

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const OPEN_EXISTING: u32 = 3;
const INVALID_HANDLE_VALUE: std.os.windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));

extern "kernel32" fn CreateFileW(
    lpName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?std.os.windows.HANDLE,
) std.os.windows.HANDLE;

extern "kernel32" fn ReadFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: *u32,
    lpOverlapped: ?*anyopaque,
) u32;

extern "kernel32" fn WriteFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*anyopaque,
) u32;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: std.os.windows.HANDLE,
    lpBuffer: ?[*]u8,
    nBufferSize: u32,
    lpBytesRead: ?*u32,
    lpTotalBytesAvail: *u32,
    lpBytesLeftThisMessage: ?*u32,
) u32;

extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) u32;
