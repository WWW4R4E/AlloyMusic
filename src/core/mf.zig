const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const mpv_mod = @import("mpv.zig");
const smtc_mod = @import("smtc.zig");

// src/core/mf.zig — Media Foundation 播放后端（Windows COM，零外部二进制）。
//
// 设计见 docs/media-foundation-plan.md：MFCreateMediaSession + 手搓 COM vtable
// + 每 tick 轮询事件队列（无回调）。所有 GUID / 枚举 / vtable 槽位序均对照
// 本机 Windows SDK 10.0.22621 的 um/*.idl 核实（文档 §3），改前先对照文档。
//
// 平台编译门：`supported` 是 comptime 已知，非 windows 目标下 MfPlayer 整体
// 不被语义分析（Player 类型选择直接落到 UnsupportedPlayer），extern 声明与
// COM 调用在 linux/mac 上零分析、零链接引用。MfPlayer 方法体首行的
// `if (comptime !supported)` 是双保险：直接引用 MfPlayer 也不会碰 extern。
//
// 线程模型：常驻 worker 打开源（CreateObjectFromURL 对 http 是同步阻塞调用，
// 不能占主线程 tick）；session/clock/音量只在主线程（app tick 内）碰。
// 同步原语：std.atomic.Value（quit/gen）+ std.atomic.Mutex（指针槽发布）；
// worker 节流用 kernel32 Sleep（Zig 0.17 无 std.Thread.sleep）。

pub const Status = mpv_mod.Status;

/// 系统媒体键（SMTC；见 core/smtc.zig）
pub const MediaButton = smtc_mod.MediaButton;

pub const supported = builtin.os.tag == .windows;

pub const Player = if (supported) MfPlayer else UnsupportedPlayer;

// ────────────────────────── 基础类型 ──────────────────────────

const HRESULT = i32;
const GUID = std.os.windows.GUID;

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;

const COINIT_MULTITHREADED: u32 = 0x0;
const MF_VERSION: u32 = 0x00020070; // MF_SDK_VERSION 0x0002 << 16 | MF_API_VERSION 0x0070
const MF_RESOLUTION_MEDIASOURCE: u32 = 0x1;
const MF_EVENT_FLAG_NO_WAIT: u32 = 0x1;
const MF_E_NO_EVENTS_AVAILABLE: HRESULT = @bitCast(@as(u32, 0xC00D3E80));

const MF_TOPOLOGY_OUTPUT_NODE: u32 = 0;
const MF_TOPOLOGY_SOURCESTREAM_NODE: u32 = 1;
const MF_TOPOSTATUS_READY: u32 = 100;

const MFCLOCK_INVALID: u32 = 0;
const MFCLOCK_RUNNING: u32 = 1;
const MFCLOCK_STOPPED: u32 = 2;
const MFCLOCK_PAUSED: u32 = 3;

const VT_I8: u16 = 20;

const MF_OBJECT_MEDIASOURCE: u32 = 0;
const MF_OBJECT_BYTESTREAM: u32 = 1;

// MediaEventType（只列用到的；全集见 mfobjects.h）
const ME_ERROR: u32 = 1;
const ME_SESSION_TOPOLOGY_SET: u32 = 101;
const ME_SESSION_TOPOLOGIES_CLEARED: u32 = 102;
const ME_SESSION_STARTED: u32 = 103;
const ME_SESSION_PAUSED: u32 = 104;
const ME_SESSION_STOPPED: u32 = 105;
const ME_SESSION_CLOSED: u32 = 106;
const ME_SESSION_ENDED: u32 = 107;
const ME_SESSION_TOPOLOGY_STATUS: u32 = 111;

// ── IID / GUID（文档 §3.1-3.2 已核实；GUID.parse 必须带花括号）──

const IID_IMFMediaSession = GUID.parse("{90377834-21D0-4dee-8214-BA2E3E6C1127}");
const IID_IMFMediaSource = GUID.parse("{279a808d-aec7-40c8-9c6b-a6b492c78a66}");
const IID_IMFTopology = GUID.parse("{83CF873A-F6DA-4bc8-823F-BACFD55DC433}");
const IID_IMFTopologyNode = GUID.parse("{83CF873A-F6DA-4bc8-823F-BACFD55DC430}");
const IID_IMFPresentationClock = GUID.parse("{868CE85C-8EA9-4f55-AB82-B009A910A805}");
const IID_IMFPresentationDescriptor = GUID.parse("{03cb2711-24d7-4db6-a17f-f3a7a479a536}");
const IID_IMFStreamDescriptor = GUID.parse("{56c03d9c-9dbb-45f5-ab4b-d80f47c05938}");
const IID_IMFMediaTypeHandler = GUID.parse("{e93dcf6c-4b07-4e1e-8123-aa16ed6eadf5}");
const IID_IMFAttributes = GUID.parse("{2cd2d921-c447-44a7-a13c-4adabfc247e3}");
const IID_IMFMediaEvent = GUID.parse("{DF598932-F10C-4E39-BBA2-C308F101DAA3}");
const IID_IMFMediaEventGenerator = GUID.parse("{2CD0BD52-BCD5-4B89-B62C-EADC0C031E7D}");
const IID_IMFSimpleAudioVolume = GUID.parse("{089EDF13-CF71-4338-8D13-9E569DBDC319}");
const IID_IMFActivate = GUID.parse("{7FEE9E9A-4A89-47a6-899C-B6A53A70FB67}");

const MF_TOPONODE_SOURCE = GUID.parse("{835c58ec-e075-4bc7-bcba-4de000df9ae6}");
const MF_TOPONODE_PRESENTATION_DESCRIPTOR = GUID.parse("{835c58ed-e075-4bc7-bcba-4de000df9ae6}");
const MF_TOPONODE_STREAM_DESCRIPTOR = GUID.parse("{835c58ee-e075-4bc7-bcba-4de000df9ae6}");
const MF_TOPONODE_STREAMID = GUID.parse("{14932f9b-9087-4bb4-8412-5167145cbe04}");
const MF_TOPONODE_NOSHUTDOWN_ON_REMOVE = GUID.parse("{14932f9c-9087-4bb4-8412-5167145cbe04}");
const MF_PD_DURATION = GUID.parse("{6c990d33-bb8e-477a-8598-0d5d96fcd88a}");
const MF_EVENT_TOPOLOGY_STATUS = GUID.parse("{30C5018D-9A53-454b-AD9E-6D5F8FA7C43B}");
const MR_POLICY_VOLUME_SERVICE = GUID.parse("{1abaa2ac-9d3b-47c6-ab48-c5950606de78}");
const MFMediaType_Audio = GUID.parse("{73647561-0000-0010-8000-00AA00389B71}");

const GUID_NULL = GUID{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = @splat(0) };

/// std 无 PROPVARIANT：C 布局 24 字节 8 对齐（vt + 3×u16 保留 + 16 字节联合）。
const PROPVARIANT = extern struct {
    vt: u16 = VT_EMPTY,
    reserved: [3]u16 = @splat(0),
    val: extern union {
        i64: i64,
        u32: u32,
        ptr: ?*anyopaque,
        bytes: [16]u8, // 凑齐 C 的 24 字节（blob 成员在 x64 是 16 字节）
    } = .{ .i64 = 0 },
};

const VT_EMPTY: u16 = 0;

// ────────────────────────── COM 接口声明 ──────────────────────────
// 扁平 vtable：槽位 = 文档 §3.4 的下标。不调用的方法用 Pad 占位
// （尺寸正确即可）。继承链槽位 = 父接口全部槽位 + 自身方法。

const Pad = *const anyopaque;

const IUnknown = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };
};

/// 任意 MF/COM 接口指针 → IUnknown 视角（首 3 槽布局全 COM 通用）
inline fn asUnknown(p: anytype) *IUnknown {
    return @ptrCast(p);
}

inline fn unkRelease(p: anytype) void {
    const u: *IUnknown = asUnknown(p);
    _ = u.vtbl.Release(u);
}

fn queryInterface(comptime T: type, unk: *IUnknown, iid: *const GUID) ?*T {
    var out: ?*anyopaque = null;
    if (unk.vtbl.QueryInterface(unk, iid, &out) != S_OK) return null;
    return @ptrCast(@alignCast(out.?));
}

const IMFSourceResolver = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // 槽 0-9
        QueryInterface: *const fn (*IMFSourceResolver, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFSourceResolver) callconv(.winapi) u32,
        Release: *const fn (*IMFSourceResolver) callconv(.winapi) u32,
        CreateObjectFromURL: *const fn (*IMFSourceResolver, [*:0]const u16, u32, ?*const anyopaque, *u32, *?*IUnknown) callconv(.winapi) HRESULT, // 3
        CreateObjectFromByteStream: Pad, // 4
        BeginCreateObjectFromURL: Pad, // 5
        EndCreateObjectFromURL: Pad, // 6
        BeginCreateObjectFromByteStream: Pad, // 7
        EndCreateObjectFromByteStream: Pad, // 8
        CancelObjectCreation: Pad, // 9
    };
};

const IMFMediaSource = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // 槽 0-12（eventgen 7 槽 + 自身 6）
        QueryInterface: *const fn (*IMFMediaSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFMediaSource) callconv(.winapi) u32,
        Release: *const fn (*IMFMediaSource) callconv(.winapi) u32,
        GetEvent: Pad, // 3
        BeginGetEvent: Pad, // 4
        EndGetEvent: Pad, // 5
        QueueEvent: Pad, // 6
        GetCharacteristics: Pad, // 7
        CreatePresentationDescriptor: *const fn (*IMFMediaSource, *?*IMFPresentationDescriptor) callconv(.winapi) HRESULT, // 8
        Start: Pad, // 9
        Stop: Pad, // 10
        Pause: Pad, // 11
        Shutdown: Pad, // 12
    };
};

const IMFPresentationDescriptor = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // attrs 33 槽（0-32）+ 自身 5（33-37）
        QueryInterface: *const fn (*IMFPresentationDescriptor, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFPresentationDescriptor) callconv(.winapi) u32,
        Release: *const fn (*IMFPresentationDescriptor) callconv(.winapi) u32,
        GetItem: Pad, // 3
        GetItemType: Pad, // 4
        CompareItem: Pad, // 5
        Compare: Pad, // 6
        GetUINT32: Pad, // 7
        GetUINT64: *const fn (*IMFPresentationDescriptor, *const GUID, *u64) callconv(.winapi) HRESULT, // 8
        GetDouble: Pad, // 9
        GetGUID: Pad, // 10
        GetStringLength: Pad, // 11
        GetString: Pad, // 12
        GetAllocatedString: Pad, // 13
        GetBlobSize: Pad, // 14
        GetBlob: Pad, // 15
        GetAllocatedBlob: Pad, // 16
        GetUnknown: Pad, // 17
        SetItem: Pad, // 18
        DeleteItem: Pad, // 19
        DeleteAllItems: Pad, // 20
        SetUINT32: Pad, // 21
        SetUINT64: Pad, // 22
        SetDouble: Pad, // 23
        SetGUID: Pad, // 24
        SetString: Pad, // 25
        SetBlob: Pad, // 26
        SetUnknown: Pad, // 27
        LockStore: Pad, // 28
        UnlockStore: Pad, // 29
        GetCount: Pad, // 30
        GetItemByIndex: Pad, // 31
        CopyAllItems: Pad, // 32
        GetStreamDescriptorCount: *const fn (*IMFPresentationDescriptor, *u32) callconv(.winapi) HRESULT, // 33
        GetStreamDescriptorByIndex: *const fn (*IMFPresentationDescriptor, u32, *i32, *?*IMFStreamDescriptor) callconv(.winapi) HRESULT, // 34（BOOL* 出参）
        SelectStream: *const fn (*IMFPresentationDescriptor, u32) callconv(.winapi) HRESULT, // 35（单参数）
        DeselectStream: *const fn (*IMFPresentationDescriptor, u32) callconv(.winapi) HRESULT, // 36
        Clone: Pad, // 37
    };
};

const IMFStreamDescriptor = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // attrs 33 槽（0-32）+ 自身 2（33-34）
        QueryInterface: *const fn (*IMFStreamDescriptor, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFStreamDescriptor) callconv(.winapi) u32,
        Release: *const fn (*IMFStreamDescriptor) callconv(.winapi) u32,
        GetItem: Pad, // 3
        GetItemType: Pad, // 4
        CompareItem: Pad, // 5
        Compare: Pad, // 6
        GetUINT32: Pad, // 7
        GetUINT64: Pad, // 8
        GetDouble: Pad, // 9
        GetGUID: Pad, // 10
        GetStringLength: Pad, // 11
        GetString: Pad, // 12
        GetAllocatedString: Pad, // 13
        GetBlobSize: Pad, // 14
        GetBlob: Pad, // 15
        GetAllocatedBlob: Pad, // 16
        GetUnknown: Pad, // 17
        SetItem: Pad, // 18
        DeleteItem: Pad, // 19
        DeleteAllItems: Pad, // 20
        SetUINT32: Pad, // 21
        SetUINT64: Pad, // 22
        SetDouble: Pad, // 23
        SetGUID: Pad, // 24
        SetString: Pad, // 25
        SetBlob: Pad, // 26
        SetUnknown: Pad, // 27
        LockStore: Pad, // 28
        UnlockStore: Pad, // 29
        GetCount: Pad, // 30
        GetItemByIndex: Pad, // 31
        CopyAllItems: Pad, // 32
        GetStreamIdentifier: Pad, // 33
        GetMediaTypeHandler: *const fn (*IMFStreamDescriptor, *?*IMFMediaTypeHandler) callconv(.winapi) HRESULT, // 34
    };
};

const IMFMediaTypeHandler = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // 槽 0-8
        QueryInterface: *const fn (*IMFMediaTypeHandler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFMediaTypeHandler) callconv(.winapi) u32,
        Release: *const fn (*IMFMediaTypeHandler) callconv(.winapi) u32,
        IsMediaTypeSupported: Pad, // 3
        GetMediaTypeCount: Pad, // 4
        GetMediaTypeByIndex: Pad, // 5
        SetCurrentMediaType: Pad, // 6
        GetCurrentMediaType: Pad, // 7
        GetMajorType: *const fn (*IMFMediaTypeHandler, *GUID) callconv(.winapi) HRESULT, // 8
    };
};

const IMFTopology = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // attrs 33 槽（0-32）+ 自身 10（33-42）
        QueryInterface: *const fn (*IMFTopology, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFTopology) callconv(.winapi) u32,
        Release: *const fn (*IMFTopology) callconv(.winapi) u32,
        GetItem: Pad, // 3
        GetItemType: Pad, // 4
        CompareItem: Pad, // 5
        Compare: Pad, // 6
        GetUINT32: Pad, // 7
        GetUINT64: Pad, // 8
        GetDouble: Pad, // 9
        GetGUID: Pad, // 10
        GetStringLength: Pad, // 11
        GetString: Pad, // 12
        GetAllocatedString: Pad, // 13
        GetBlobSize: Pad, // 14
        GetBlob: Pad, // 15
        GetAllocatedBlob: Pad, // 16
        GetUnknown: Pad, // 17
        SetItem: Pad, // 18
        DeleteItem: Pad, // 19
        DeleteAllItems: Pad, // 20
        SetUINT32: Pad, // 21
        SetUINT64: Pad, // 22
        SetDouble: Pad, // 23
        SetGUID: Pad, // 24
        SetString: Pad, // 25
        SetBlob: Pad, // 26
        SetUnknown: Pad, // 27
        LockStore: Pad, // 28
        UnlockStore: Pad, // 29
        GetCount: Pad, // 30
        GetItemByIndex: Pad, // 31
        CopyAllItems: Pad, // 32
        GetTopologyID: Pad, // 33
        AddNode: *const fn (*IMFTopology, *IMFTopologyNode) callconv(.winapi) HRESULT, // 34
        RemoveNode: Pad, // 35
        GetNodeCount: Pad, // 36
        GetNode: Pad, // 37
        Clear: Pad, // 38
        CloneFrom: Pad, // 39
        GetNodeByID: Pad, // 40
        GetSourceNodeCollection: Pad, // 41
        GetOutputNodeCollection: Pad, // 42
    };
};

const IMFTopologyNode = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // attrs 33 槽（0-32）+ 自身 16（33-48）
        QueryInterface: *const fn (*IMFTopologyNode, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFTopologyNode) callconv(.winapi) u32,
        Release: *const fn (*IMFTopologyNode) callconv(.winapi) u32,
        GetItem: Pad, // 3
        GetItemType: Pad, // 4
        CompareItem: Pad, // 5
        Compare: Pad, // 6
        GetUINT32: *const fn (*IMFTopologyNode, *const GUID, *u32) callconv(.winapi) HRESULT, // 7（未用，留签名防手滑）
        GetUINT64: Pad, // 8
        GetDouble: Pad, // 9
        GetGUID: Pad, // 10
        GetStringLength: Pad, // 11
        GetString: Pad, // 12
        GetAllocatedString: Pad, // 13
        GetBlobSize: Pad, // 14
        GetBlob: Pad, // 15
        GetAllocatedBlob: Pad, // 16
        GetUnknown: Pad, // 17
        SetItem: Pad, // 18
        DeleteItem: Pad, // 19
        DeleteAllItems: Pad, // 20
        SetUINT32: *const fn (*IMFTopologyNode, *const GUID, u32) callconv(.winapi) HRESULT, // 21
        SetUINT64: Pad, // 22
        SetDouble: Pad, // 23
        SetGUID: Pad, // 24
        SetString: Pad, // 25
        SetBlob: Pad, // 26
        SetUnknown: *const fn (*IMFTopologyNode, *const GUID, ?*IUnknown) callconv(.winapi) HRESULT, // 27
        LockStore: Pad, // 28
        UnlockStore: Pad, // 29
        GetCount: Pad, // 30
        GetItemByIndex: Pad, // 31
        CopyAllItems: Pad, // 32
        SetObject: *const fn (*IMFTopologyNode, ?*IUnknown) callconv(.winapi) HRESULT, // 33
        GetObject: Pad, // 34
        GetNodeType: Pad, // 35
        GetTopoNodeID: Pad, // 36
        SetTopoNodeID: Pad, // 37
        GetInputCount: Pad, // 38
        GetOutputCount: Pad, // 39
        ConnectOutput: *const fn (*IMFTopologyNode, u32, *IMFTopologyNode, u32) callconv(.winapi) HRESULT, // 40
        DisconnectOutput: Pad, // 41
        GetInput: Pad, // 42
        GetOutput: Pad, // 43
        SetOutputPrefType: Pad, // 44
        GetOutputPrefType: Pad, // 45
        SetInputPrefType: Pad, // 46
        GetInputPrefType: Pad, // 47
        CloneFrom: Pad, // 48
    };
};

const IMFMediaSession = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // eventgen 7 槽（0-6）+ 自身 10（7-16）
        QueryInterface: *const fn (*IMFMediaSession, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFMediaSession) callconv(.winapi) u32,
        Release: *const fn (*IMFMediaSession) callconv(.winapi) u32,
        GetEvent: *const fn (*IMFMediaSession, u32, *?*IMFMediaEvent) callconv(.winapi) HRESULT, // 3
        BeginGetEvent: Pad, // 4
        EndGetEvent: Pad, // 5
        QueueEvent: Pad, // 6
        SetTopology: *const fn (*IMFMediaSession, u32, *IMFTopology) callconv(.winapi) HRESULT, // 7
        ClearTopologies: Pad, // 8
        Start: *const fn (*IMFMediaSession, ?*const GUID, ?*const PROPVARIANT) callconv(.winapi) HRESULT, // 9
        Pause: *const fn (*IMFMediaSession) callconv(.winapi) HRESULT, // 10
        Stop: *const fn (*IMFMediaSession) callconv(.winapi) HRESULT, // 11
        Close: *const fn (*IMFMediaSession) callconv(.winapi) HRESULT, // 12
        Shutdown: *const fn (*IMFMediaSession) callconv(.winapi) HRESULT, // 13
        GetClock: *const fn (*IMFMediaSession, *?*IMFClock) callconv(.winapi) HRESULT, // 14
        GetSessionCapabilities: Pad, // 15
        GetFullTopology: Pad, // 16
    };
};

const IMFClock = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // 槽 0-7
        QueryInterface: *const fn (*IMFClock, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFClock) callconv(.winapi) u32,
        Release: *const fn (*IMFClock) callconv(.winapi) u32,
        GetClockCharacteristics: Pad, // 3
        GetCorrelatedTime: Pad, // 4
        GetContinuityKey: Pad, // 5
        GetState: *const fn (*IMFClock, u32, *u32) callconv(.winapi) HRESULT, // 6（dwFlags 传 0）
        GetProperties: Pad, // 7
    };
};

const IMFPresentationClock = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // IMFClock 5 槽（3-7）+ 自身（8-15，头文件 mfidl.h IMFClock/IMFPresentationClock 顺序）
        QueryInterface: *const fn (*IMFPresentationClock, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFPresentationClock) callconv(.winapi) u32,
        Release: *const fn (*IMFPresentationClock) callconv(.winapi) u32,
        GetClockCharacteristics: Pad, // 3
        GetCorrelatedTime: Pad, // 4
        GetContinuityKey: Pad, // 5
        GetState: *const fn (*IMFPresentationClock, u32, *u32) callconv(.winapi) HRESULT, // 6（dwFlags 传 0）
        GetProperties: Pad, // 7
        SetTimeSource: Pad, // 8
        GetTimeSource: Pad, // 9
        GetTime: *const fn (*IMFPresentationClock, *i64) callconv(.winapi) HRESULT, // 10（100ns）
        AddClockStateSink: Pad, // 11
        RemoveClockStateSink: Pad, // 12
        Start: Pad, // 13
        Stop: Pad, // 14
        Pause: Pad, // 15
    };
};

const IMFSimpleAudioVolume = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // 槽 0-6
        QueryInterface: *const fn (*IMFSimpleAudioVolume, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFSimpleAudioVolume) callconv(.winapi) u32,
        Release: *const fn (*IMFSimpleAudioVolume) callconv(.winapi) u32,
        SetMasterVolume: *const fn (*IMFSimpleAudioVolume, f32) callconv(.winapi) HRESULT, // 3
        GetMasterVolume: Pad, // 4
        SetMute: Pad, // 5
        GetMute: Pad, // 6
    };
};

const IMFMediaEvent = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct { // attrs 33 槽（0-32）+ 自身 3（33-35）
        QueryInterface: *const fn (*IMFMediaEvent, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMFMediaEvent) callconv(.winapi) u32,
        Release: *const fn (*IMFMediaEvent) callconv(.winapi) u32,
        GetItem: Pad, // 3
        GetItemType: Pad, // 4
        CompareItem: Pad, // 5
        Compare: Pad, // 6
        GetUINT32: *const fn (*IMFMediaEvent, *const GUID, *u32) callconv(.winapi) HRESULT, // 7
        GetUINT64: Pad, // 8
        GetDouble: Pad, // 9
        GetGUID: Pad, // 10
        GetStringLength: Pad, // 11
        GetString: Pad, // 12
        GetAllocatedString: Pad, // 13
        GetBlobSize: Pad, // 14
        GetBlob: Pad, // 15
        GetAllocatedBlob: Pad, // 16
        GetUnknown: Pad, // 17
        SetItem: Pad, // 18
        DeleteItem: Pad, // 19
        DeleteAllItems: Pad, // 20
        SetUINT32: Pad, // 21
        SetUINT64: Pad, // 22
        SetDouble: Pad, // 23
        SetGUID: Pad, // 24
        SetString: Pad, // 25
        SetBlob: Pad, // 26
        SetUnknown: Pad, // 27
        LockStore: Pad, // 28
        UnlockStore: Pad, // 29
        GetCount: Pad, // 30
        GetItemByIndex: Pad, // 31
        CopyAllItems: Pad, // 32
        GetType: *const fn (*IMFMediaEvent, *u32) callconv(.winapi) HRESULT, // 33
        GetStatus: *const fn (*IMFMediaEvent, *HRESULT) callconv(.winapi) HRESULT, // 34
        GetValue: Pad, // 35
    };
};

// ────────────────────────── DLL 导出（文档 §3.5-3.6）──────────────────────────

extern "mfplat" fn MFStartup(version: u32, flags: u32) HRESULT;
extern "mfplat" fn MFShutdown() HRESULT;
extern "mf" fn MFCreateMediaSession(config: ?*const anyopaque, session: *?*IMFMediaSession) HRESULT;
extern "mf" fn MFCreateSourceResolver(resolver: *?*IMFSourceResolver) HRESULT;
extern "mf" fn MFCreateTopology(topology: *?*IMFTopology) HRESULT;
extern "mf" fn MFCreateTopologyNode(node_type: u32, node: *?*IMFTopologyNode) HRESULT;
extern "mf" fn MFCreateAudioRendererActivate(activate: *?*IUnknown) HRESULT;
extern "mf" fn MFGetService(unk: *IUnknown, service: *const GUID, iid: *const GUID, out: *?*anyopaque) HRESULT;
// ── 临时调试：eof 溯源（定位换曲 EOF，调试完删除）──
const dbg_on = true;
const dbg_path_w = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\123\\AppData\\Local\\Temp\\amtui_mf_dbg.log");
var dbg_file: ?*anyopaque = null;
var dbg_mutex: std.atomic.Mutex = .unlocked;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(f: *anyopaque, buf: [*]const u8, len: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
fn dbgLog(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const pre = std.fmt.bufPrint(&buf, "t={d} ", .{GetTickCount64() % 100000}) catch return;
    const line = std.fmt.bufPrint(buf[pre.len..], fmt ++ "\n", args) catch return;
    const total = pre.len + line.len;
    while (!dbg_mutex.tryLock()) std.atomic.spinLoopHint();
    defer dbg_mutex.unlock();
    if (dbg_file == null) {
        const f = CreateFileW(dbg_path_w.ptr, 0x4004, 0x1, null, 4, 0x80, null);
        if (f == null) return;
        dbg_file = f;
    }
    var written: u32 = 0;
    _ = WriteFile(dbg_file.?, &buf, @intCast(total), &written, null);
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "ole32" fn CoInitializeEx(reserved: ?*const anyopaque, coinit: u32) HRESULT;
extern "ole32" fn CoUninitialize() void;
extern "kernel32" fn Sleep(milliseconds: u32) void;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: ?[*]u8, size: u32) callconv(.winapi) u32;

/// 状态机的纯决策（单测友好）：事件类型 → 要执行的动作。
/// topo_status 仅对 MESessionTopologyStatus 有意义：该事件在整个拓扑
/// 生命周期会发多条（READY=100、STARTED_SOURCE=200、SINK_SWITCHED=300、
/// ENDED=400、FLUSHED=450……），只有 READY 才能触发 Start——此前把每条
/// 都当 READY，播放中反复重置回 0，永远播不出声。
fn eventAction(event_type: u32, topo_status: u32, ready_seen: bool) enum { none, ready, pause_if_wanted, mark_eof } {
    return switch (event_type) {
        ME_ERROR => .none, // 只记错误码，不改状态机
        ME_SESSION_TOPOLOGY_STATUS => if (topo_status == MF_TOPOSTATUS_READY) .ready else .none,
        ME_SESSION_STARTED => .pause_if_wanted,
        ME_SESSION_ENDED => if (ready_seen) .mark_eof else .none,
        else => .none,
    };
}

// ────────────────────────── MfPlayer ──────────────────────────

/// 自旋锁加锁：临界区都是纳秒级指针槽操作（文档 §3.7 约定），自旋即可。
inline fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

pub const MfPlayer = struct {
    gpa: Allocator,

    // ── 启动态（startAsync 建立，主线程独占）──
    session: ?*IMFMediaSession = null,
    clock: ?*IMFPresentationClock = null,
    audio_volume: ?*IMFSimpleAudioVolume = null,
    com_inited: bool = false,
    mf_inited: bool = false,

    // ── worker（打开网络/本地源；生命周期 = player 生命周期）──
    worker: ?std.Thread = null,
    quit: std.atomic.Value(u32) = .init(0),
    // 打开命令槽：cmd_mutex 保护；url 所有权——在槽里归主线程，被 worker
    // 取走后归 worker（用完即 free）。gen 值 = cmd_gen 快照。
    cmd_mutex: std.atomic.Mutex = .unlocked,
    cmd_url: ?[]u8 = null,
    cmd_gen: std.atomic.Value(u32) = .init(0),
    // 打开结果槽：res_mutex 保护；COM 引用所有权随槽——被覆盖或取走前
    // 归槽，覆盖者/取走者负责 Release。
    res_mutex: std.atomic.Mutex = .unlocked,
    res: ?OpenResult = null,

    // ── 播放态（主线程独占）──
    smtc: smtc_mod.Impl = .{}, // 系统媒体集成（SMTC），attach 于 startAsync 成功后
    load_gen: u32 = 0, // 最近一次 loadFile 的代（drain 只收匹配的结果）
    ready_seen: bool = false, // 当前载入已收到 TOPOLOGY READY（loadFile 翻假）
    want_paused: bool = false, // 暂停意图：loading 期只记，READY/Start 后落实
    eof_seen: bool = false,
    await_stop: bool = false, // Stop→MESessionStopped 期间挂起结果采纳
    await_stop_ms: u64 = 0, // 兜底超时（事件丢失时 3s 后放行）
    duration_s: f64 = 0,
    volume: u8 = 80,
    last_error: HRESULT = 0,
    topo_hr: HRESULT = S_OK, // 拓扑阶段最后一次失败的原始 HRESULT（诊断用）

    const OpenResult = struct {
        gen: u32 = 0,
        src: ?*IMFMediaSource = null,
        pd: ?*IMFPresentationDescriptor = null,
        duration_s: f64 = 0,
        hr: HRESULT = S_OK,
    };

    pub fn init(gpa: Allocator) MfPlayer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MfPlayer) void {
        if (comptime !supported) return;
        // 先停 worker（可能还在网络打开里阻塞，join 等它退出，杜绝 UAF）
        self.quit.store(1, .release);
        if (self.worker) |w| w.join();
        self.worker = null;
        // 丢弃还没收走的结果引用与未取走的命令
        lockSpin(&self.res_mutex);
        if (self.res) |r| self.releaseResult(r);
        self.res = null;
        self.res_mutex.unlock();
        lockSpin(&self.cmd_mutex);
        if (self.cmd_url) |u| self.gpa.free(u);
        self.cmd_url = null;
        self.cmd_mutex.unlock();
        // SMTC：移除事件委托、释放 WinRT 引用、销毁窗口（须在 COM 卸载前）
        self.smtc.detach();
        // 会话：先 Close 后 Shutdown，再放引用
        if (self.session) |s| {
            _ = s.vtbl.Close(s);
            _ = s.vtbl.Shutdown(s);
            unkRelease(s);
            self.session = null;
        }
        if (self.audio_volume) |v| {
            unkRelease(v);
            self.audio_volume = null;
        }
        if (self.clock) |c| {
            unkRelease(c);
            self.clock = null;
        }
        self.comDeinit();
    }

    /// CoInitializeEx(MTA) + MFStartup + MFCreateMediaSession。全本地快速
    /// 调用，成功即 available（session 已建）。
    pub fn startAsync(self: *MfPlayer) bool {
        if (comptime !supported) return false;
        if (self.session != null) return true;
        // 进程首个 COM 初始化必须走 RoInitialize（见 smtc.ensureWinrtMta 注释），
        // combase 加载失败才回退纯 CoInitializeEx
        var com_ok = smtc_mod.ensureWinrtMta();
        if (!com_ok) {
            const cr = CoInitializeEx(null, COINIT_MULTITHREADED);
            com_ok = (cr == S_OK or cr == S_FALSE);
        }
        if (!com_ok) return false;
        self.com_inited = true;
        // 实验开关 AM_SMTC_PREINIT=1：SMTC attach 提前到 MFStartup 之前——
        // 让 MC.dll 的 GIT/handler 状态在 MF(MTA) 污染进程前建立。
        // 配合 AM_SMTC_NORELAY=1 走进程内回退路径。
        {
            var pre_buf: [8]u8 = undefined;
            if (GetEnvironmentVariableA("AM_SMTC_PREINIT", &pre_buf, pre_buf.len) > 0)
                self.smtc.attach(self.gpa);
        }
        if (MFStartup(MF_VERSION, 0) != S_OK) {
            self.comDeinit();
            return false;
        }
        self.mf_inited = true;
        var session: ?*IMFMediaSession = null;
        if (MFCreateMediaSession(null, &session) != S_OK or session == null) {
            self.comDeinit();
            return false;
        }
        self.session = session;
        self.quit.store(0, .release);
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch {
            if (self.session) |s| {
                _ = s.vtbl.Shutdown(s);
                unkRelease(s);
                self.session = null;
            }
            self.comDeinit();
            return false;
        };
        // SMTC attach（COM 已就绪；失败静默——增强功能）
        self.smtc.attach(self.gpa);
        return true;
    }

    /// startAsync 成功即 available（session 已建，无逐 tick 连接过程）。
    pub fn tickConnect(self: *MfPlayer) bool {
        if (comptime !supported) return false;
        return self.session != null;
    }

    pub fn dropConnection(self: *MfPlayer) void {
        // MF 无传输层连接概念
        if (comptime !supported) return;
        _ = self;
    }

    /// dup url 发 worker（gen+1）；清 eof/时长/就绪态。随时可打断旧打开。
    pub fn loadFile(self: *MfPlayer, url: []const u8, title: []const u8) bool {
        if (comptime !supported) return false;
        // SMTC 元数据："歌名 - 歌手"（app 侧组装格式）
        self.smtc.setTrack(title);
        if (self.session == null) return false;
        // 换曲 = 重建会话。MF session 的时钟跨拓扑连续，而 SetTopology 的
        // 各种语义组合全是坑（实测）：flags=0 排队切换会继承旧位置（换曲
        // 继承上一首进度条）、IMMEDIATE 在 stopped 会话上 READY 永远不来、
        // Stop(中途) 后 SetTopology 直接卡死。全部规避：旧会话 Shutdown、
        // 新会话从头建——时钟恒 0 起，拓扑即换即播。EOF 已停的场合
        // （mark_eof 已 Stop）同样走重建，代价只是几毫秒的设备重挂。
        if (self.ready_seen or self.eof_seen) {
            dbgLog("load rebuild ready={} eof={}", .{ self.ready_seen, self.eof_seen });
            const olds = self.session.?;
            _ = olds.vtbl.Stop(olds);
            _ = olds.vtbl.Shutdown(olds);
            unkRelease(olds);
            self.session = null;
            if (self.clock) |c| {
                unkRelease(c);
                self.clock = null;
            }
            if (self.audio_volume) |v| {
                unkRelease(v);
                self.audio_volume = null; // READY 后按新会话重取
            }
            self.ready_seen = false;
            self.await_stop = false;
            var ns: ?*IMFMediaSession = null;
            if (MFCreateMediaSession(null, &ns) != S_OK or ns == null) return false;
            self.session = ns;
        }
        const dup = self.gpa.dupe(u8, url) catch return false;
        {
            lockSpin(&self.cmd_mutex);
            if (self.cmd_url) |old| self.gpa.free(old); // worker 还没取走的旧命令
            self.cmd_url = dup;
            self.load_gen +%= 1;
            self.cmd_gen.store(self.load_gen, .release);
            self.cmd_mutex.unlock();
        }
        self.ready_seen = false;
        self.want_paused = false;
        self.eof_seen = false;
        self.duration_s = 0;
        return true;
    }

    /// MF 无播放列表概念：恒 false（app 侧因此跳过预取 append）。
    pub fn appendFile(self: *MfPlayer, url: []const u8, title: []const u8) bool {
        if (comptime !supported) return false;
        _ = self;
        _ = url;
        _ = title;
        return false;
    }

    /// 全量 SMTC 元数据（relay 模式走 T+C 行；STA 回退仅标题/歌手/专辑，
    /// 封面只有 relay 消费）。app 在 loadFile 成功后调用。
    pub fn setSmtcMeta(self: *MfPlayer, title: []const u8, artist: []const u8, album: []const u8, cover_url: []const u8) void {
        if (comptime !supported) return;
        self.smtc.setTrackMeta(title, artist, album, cover_url);
    }

    pub fn setPause(self: *MfPlayer, paused: bool) void {
        if (comptime !supported) return;
        self.want_paused = paused;
        self.smtc.setPaused(paused); // SMTC 状态即时反馈（loading 期也无妨）
        const s = self.session orelse return;
        if (!self.ready_seen) return; // loading 期只记意图
        if (paused) {
            if (self.clockState() == MFCLOCK_RUNNING) _ = s.vtbl.Pause(s);
        } else {
            const st = self.clockState();
            if (st == MFCLOCK_PAUSED or st == MFCLOCK_STOPPED) {
                // 从未 Start 过（STOPPED）→ Start 当前位置（0）等效从头播
                self.startAt(self.clockTime100ns());
            }
        }
    }

    pub fn setVolume(self: *MfPlayer, volume: u8) void {
        if (comptime !supported) return;
        self.volume = volume;
        const v = self.audio_volume orelse return; // 服务未就绪：只缓存，READY 后补
        _ = v.vtbl.SetMasterVolume(v, @as(f32, @floatFromInt(volume)) / 100.0);
    }

    /// no-op：app 的 eof 前进路径天然支持单曲循环（代价是循环时重取链接）。
    pub fn setLoopFile(self: *MfPlayer, loop: bool) void {
        if (comptime !supported) return;
        _ = self;
        _ = loop;
    }

    /// Start(GUID_NULL, VT_I8)；暂停态下 Start 后立即补 Pause（位置保持）。
    pub fn seekTo(self: *MfPlayer, secs: f64) void {
        if (comptime !supported) return;
        if (!self.ready_seen) return; // 未就绪：与 mpv seek 失败同级，丢弃
        const t: i64 = @intFromFloat(@max(secs, 0) * 1e7);
        self.startAt(t);
        if (self.want_paused) {
            if (self.session) |s| _ = s.vtbl.Pause(s);
        }
    }

    /// 永不返回 null（mpv 用 null 表示传输层死亡，MF 无此概念）。
    pub fn status(self: *MfPlayer) ?Status {
        if (comptime !supported) return null;
        return .{
            .position_s = @as(f64, @floatFromInt(self.clockTime100ns())) / 1e7,
            .duration_s = self.duration_s,
            .eof = self.eof_seen,
        };
    }

    pub fn playlistPos(self: *MfPlayer) ?i64 {
        if (comptime !supported) return null;
        _ = self;
        return null; // 无播放列表：触发 app 走 pc 状态机换曲路径
    }

    pub fn playlistNext(self: *MfPlayer) bool {
        if (comptime !supported) return false;
        _ = self;
        return false;
    }

    pub fn playlistPrev(self: *MfPlayer) bool {
        if (comptime !supported) return false;
        _ = self;
        return false;
    }

    /// app 每 tick 调用（无条件泵）：收 worker 结果（建拓扑）+ 捞事件队列
    /// + 泵 SMTC（消息 + 节流时间线）。无传输层事件，输出恒 null。
    pub fn drain(self: *MfPlayer, out_pos: *?i64, out_pause: *?bool) void {
        if (comptime !supported) return;
        out_pos.* = null;
        out_pause.* = null;
        // await_stop（Stop→MESessionStopped 窗口）期间只泵事件不采纳：
        // MESessionStopped 在这里被消费并放行门控；SetTopology 过早（stop
        // 过渡态）会卡死会话（READY 永远不来，实测）。3s 超时兜底。
        if (self.await_stop) {
            self.pumpEvents();
            if (self.await_stop and GetTickCount64() - self.await_stop_ms < 3000) {
                self.smtc.pump(0, 0);
                return;
            }
            self.await_stop = false;
        }
        var r: ?OpenResult = null;
        {
            lockSpin(&self.res_mutex);
            r = self.res;
            self.res = null;
            self.res_mutex.unlock();
        }
        if (r) |res| {
            defer self.releaseResult(res);
            if (res.gen == self.load_gen) {
                if (res.hr != S_OK) {
                    self.last_error = res.hr;
                    self.eof_seen = true; // 打开失败：eof 兜底让 app 跳过坏链
                } else if (res.src != null and res.pd != null) {
                    const stage = self.buildAndSetTopology(res.src.?, res.pd.?);
                    if (stage == 0) {
                        self.duration_s = res.duration_s;
                    } else {
                        // 阶段码（1-16 正数）存进 last_error 供诊断；
                        // 与负数 HRESULT 天然不冲突
                        dbgLog("eof topo-fail stage={d}", .{stage});
                        self.last_error = @intCast(stage);
                        self.eof_seen = true; // 无音频流/拓扑失败：同上
                    }
                } else {
                    dbgLog("eof no-src", .{});
                    self.eof_seen = true;
                }
            }
            // gen 过期：引用已 release，直接丢弃
        }
        self.pumpEvents();
        // SMTC：泵窗口消息 + 节流刷时间线（位置/时长）
        self.smtc.pump(@as(f64, @floatFromInt(self.clockTime100ns())) / 1e7, self.duration_s);
    }

    /// 取走一次系统媒体键事件（SMTC；主线程）。
    pub fn takeMediaButton(self: *MfPlayer) ?smtc_mod.MediaButton {
        if (comptime !supported) return null;
        return self.smtc.takeButton();
    }

    // ── 内部 ──

    fn comDeinit(self: *MfPlayer) void {
        if (self.mf_inited) _ = MFShutdown();
        self.mf_inited = false;
        if (self.com_inited) CoUninitialize();
        self.com_inited = false;
    }

    fn releaseResult(self: *MfPlayer, r: OpenResult) void {
        _ = self;
        if (r.src) |s| unkRelease(s);
        if (r.pd) |p| unkRelease(p);
    }

    fn publish(self: *MfPlayer, r: OpenResult) void {
        lockSpin(&self.res_mutex);
        if (self.res) |old| self.releaseResult(old); // 主线程没收走的旧结果
        self.res = r;
        self.res_mutex.unlock();
    }

    /// worker 主循环：每 16ms 醒一次取命令；打开是同步阻塞调用（秒级），
    /// 期间新命令排队（旧结果 gen 过期被主线程丢弃）。v1 不做打开取消。
    fn workerMain(self: *MfPlayer) void {
        // 本线程自己的 COM/MF 初始化（MTA 不需要消息泵；MFStartup 进程内
        // 引用计数，需配对 Shutdown）
        var thread_com = false;
        var thread_mf = false;
        const cr = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (cr == S_OK or cr == S_FALSE) thread_com = true;
        if (thread_com and MFStartup(MF_VERSION, 0) == S_OK) thread_mf = true;
        defer {
            if (thread_mf) _ = MFShutdown();
            if (thread_com) CoUninitialize();
        }
        while (self.quit.load(.acquire) == 0) {
            var url: ?[]u8 = null;
            var gen: u32 = 0;
            {
                lockSpin(&self.cmd_mutex);
                if (self.cmd_url) |u| {
                    url = u;
                    self.cmd_url = null;
                    gen = self.cmd_gen.load(.acquire);
                }
                self.cmd_mutex.unlock();
            }
            if (url) |u| {
                self.openOne(u, gen); // 自由释放 url
                continue;
            }
            Sleep(16);
        }
    }

    /// CreateObjectFromURL（同步网络调用）→ QI IMFMediaSource → PD → 时长。
    /// 结果发布到 res 槽（含失败），url 与临时宽串就地释放。
    fn openOne(self: *MfPlayer, url: []u8, gen: u32) void {
        defer self.gpa.free(url);
        var r = OpenResult{ .gen = gen };
        defer self.publish(r); // 最后执行：此时 r 的字段已定
        const wurl = std.unicode.utf8ToUtf16LeAllocZ(self.gpa, url) catch {
            r.hr = 1; // 非 HRESULT 的通用失败标记（只用于日志）
            return;
        };
        defer self.gpa.free(wurl);
        var resolver: ?*IMFSourceResolver = null;
        if (MFCreateSourceResolver(&resolver) != S_OK or resolver == null) {
            r.hr = 1;
            return;
        }
        defer unkRelease(resolver.?);
        var obj: ?*IUnknown = null;
        var otype: u32 = 0;
        r.hr = resolver.?.vtbl.CreateObjectFromURL(
            resolver.?,
            wurl.ptr,
            MF_RESOLUTION_MEDIASOURCE,
            null,
            &otype,
            &obj,
        );
        if (r.hr != S_OK) return;
        if (otype != MF_OBJECT_MEDIASOURCE) {
            unkRelease(obj.?);
            r.hr = 1;
            return;
        }
        const src = queryInterface(IMFMediaSource, obj.?, &IID_IMFMediaSource) orelse {
            unkRelease(obj.?);
            r.hr = 1;
            return;
        };
        unkRelease(obj.?); // QI 已拿了自己的引用，掉掉原件这份
        var pd: ?*IMFPresentationDescriptor = null;
        r.hr = src.vtbl.CreatePresentationDescriptor(src, &pd);
        if (r.hr != S_OK or pd == null) {
            unkRelease(src);
            return;
        }
        var dur100: u64 = 0;
        if (pd.?.vtbl.GetUINT64(pd.?, &MF_PD_DURATION, &dur100) == S_OK)
            r.duration_s = @as(f64, @floatFromInt(dur100)) / 1e7; // 100ns → s
        r.src = src;
        r.pd = pd;
    }

    /// 主线程：选音频流 → 建拓扑 → SetTopology。返回 0 = 成功，非 0 = 失败
    /// 阶段码（记入 last_error 供诊断；HRESULT 均为负数，正数不冲突）。
    /// 成功后 session 侧持有全部引用（NOSHUTDOWN_ON_REMOVE=0 保证换拓扑时
    /// 自动 Shutdown 旧源）；src/pd 由调用方 Release（drain 的 defer）。
    fn buildAndSetTopology(self: *MfPlayer, src: *IMFMediaSource, pd: *IMFPresentationDescriptor) u32 {
        const s = self.session orelse return 17;

        // 选流：遍历流描述符，取主类型为音频的流；非音频流取消选中
        var count: u32 = 0;
        if (pd.vtbl.GetStreamDescriptorCount(pd, &count) != S_OK) return 1;
        var audio_sd: ?*IMFStreamDescriptor = null;
        var audio_idx: u32 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var selected: i32 = 0;
            var sd: ?*IMFStreamDescriptor = null;
            if (pd.vtbl.GetStreamDescriptorByIndex(pd, i, &selected, &sd) != S_OK) continue;
            const sdp = sd orelse continue;
            var is_audio = false;
            var handler: ?*IMFMediaTypeHandler = null;
            if (sdp.vtbl.GetMediaTypeHandler(sdp, &handler) == S_OK and handler != null) {
                var major = GUID_NULL;
                if (handler.?.vtbl.GetMajorType(handler.?, &major) == S_OK)
                    is_audio = std.meta.eql(major, MFMediaType_Audio);
                unkRelease(handler.?);
            }
            if (is_audio and audio_sd == null) {
                audio_sd = sdp; // 留引用给拓扑
                audio_idx = i;
            } else {
                if (selected != 0) _ = pd.vtbl.DeselectStream(pd, i);
                unkRelease(sdp);
            }
        }
        const sd = audio_sd orelse return 2; // 无音频流 → 打开失败
        defer unkRelease(sd);
        _ = pd.vtbl.SelectStream(pd, audio_idx);

        // 建拓扑：source 节点（源 + 流描述符 + NOSHUTDOWN=0）→ 音频渲染节点
        var topo: ?*IMFTopology = null;
        if (MFCreateTopology(&topo) != S_OK or topo == null) return 3;
        defer unkRelease(topo.?);
        var src_node: ?*IMFTopologyNode = null;
        if (MFCreateTopologyNode(MF_TOPOLOGY_SOURCESTREAM_NODE, &src_node) != S_OK or src_node == null) return 4;
        defer unkRelease(src_node.?);
        var out_node: ?*IMFTopologyNode = null;
        if (MFCreateTopologyNode(MF_TOPOLOGY_OUTPUT_NODE, &out_node) != S_OK or out_node == null) return 5;
        defer unkRelease(out_node.?);
        var activate: ?*IUnknown = null; // IMFActivate 只当 IUnknown 传，不调方法
        if (MFCreateAudioRendererActivate(&activate) != S_OK or activate == null) return 6;
        defer unkRelease(activate.?);

        const sn = src_node.?;
        const on = out_node.?;
        if (sn.vtbl.SetUINT32(sn, &MF_TOPONODE_STREAMID, 0) != S_OK) return 7;
        if (sn.vtbl.SetUINT32(sn, &MF_TOPONODE_NOSHUTDOWN_ON_REMOVE, 0) != S_OK) return 8;
        if (sn.vtbl.SetUnknown(sn, &MF_TOPONODE_SOURCE, asUnknown(src)) != S_OK) return 9;
        // 源节点必须同时挂 presentation descriptor，否则 SetTopology 返回
        // 0xC00D5217 MF_E_TOPO_MISSING_PRESENTATION_DESCRIPTOR
        if (sn.vtbl.SetUnknown(sn, &MF_TOPONODE_PRESENTATION_DESCRIPTOR, asUnknown(pd)) != S_OK) return 10;
        if (sn.vtbl.SetUnknown(sn, &MF_TOPONODE_STREAM_DESCRIPTOR, asUnknown(sd)) != S_OK) return 11;
        if (on.vtbl.SetObject(on, activate) != S_OK) return 12;
        if (topo.?.vtbl.AddNode(topo.?, sn) != S_OK) return 13;
        if (topo.?.vtbl.AddNode(topo.?, on) != S_OK) return 14;
        if (sn.vtbl.ConnectOutput(sn, 0, on, 0) != S_OK) return 15;
        {
            // flags=0（勿改 IMMEDIATE）：loadFile 已先 Stop（时钟归零、
            // 会话已停），stopped 会话上 flags=0 的拓扑就是立即生效。
            // 实测 IMMEDIATE 在 stopped 会话上 READY 事件永远不来（拓扑
            // 挂死）；running 会话上 IMMEDIATE 又是"时钟连续排队"语义，
            // 新歌会继承旧位置。两者都被 loadFile 的前置 Stop 规避。
            const hr = s.vtbl.SetTopology(s, 0, topo.?);
            if (hr != S_OK) {
                self.topo_hr = hr; // 原始错误码留给诊断（smoke/状态栏打印）
                return 16;
            }
        }
        return 0;
    }

    /// 事件轮询：每 tick 最多捞 16 条（NO_WAIT，队空即返）。
    fn pumpEvents(self: *MfPlayer) void {
        const s = self.session orelse return;
        var n: u32 = 0;
        while (n < 16) : (n += 1) {
            var ev: ?*IMFMediaEvent = null;
            if (s.vtbl.GetEvent(s, MF_EVENT_FLAG_NO_WAIT, &ev) != S_OK) break; // 队空/错误
            const e = ev.?;
            defer unkRelease(e);
            var etype: u32 = 0;
            if (e.vtbl.GetType(e, &etype) != S_OK) continue;
            // MESessionTopologyStatus 必须解出事件的拓扑状态值再决策
            var topo_status: u32 = 0;
            if (etype == ME_SESSION_TOPOLOGY_STATUS)
                _ = e.vtbl.GetUINT32(e, &MF_EVENT_TOPOLOGY_STATUS, &topo_status);
            if (etype == ME_SESSION_STOPPED and self.await_stop) {
                self.await_stop = false; // Stop 序列完成，放行下一条拓扑
            }
            dbgLog("ev etype={d} topo={d} ready={}", .{ etype, topo_status, self.ready_seen });
            switch (eventAction(etype, topo_status, self.ready_seen)) {
                .none => {
                    if (etype == ME_ERROR) {
                        var hr: HRESULT = S_OK;
                        _ = e.vtbl.GetStatus(e, &hr);
                        self.last_error = hr; // 打日志/状态栏用
                    }
                },
                .ready => self.onTopologyReady(),
                .pause_if_wanted => {
                    // 链接到达前用户按了暂停：Start 是异步的，Started 到达时补 Pause
                    if (self.want_paused) _ = s.vtbl.Pause(s);
                },
                .mark_eof => {
                    dbgLog("mark_eof etype={d} ready={}", .{ etype, self.ready_seen });
                    self.eof_seen = true;
                    // MF 规范（Playback 样例同款）：会话 Ended 后时钟停在旧曲
                    // 末尾（暂停态），不 Stop 的话下一首拓扑 READY 后的
                    // Start(VT_EMPTY) 会从旧位置续播——位置跨拓扑残留、秒进
                    // EOF 连跳、seek 落在坏状态里失效。Stop 把时钟归零。
                    _ = s.vtbl.Stop(s);
                },
            }
        }
    }

    /// TOPOLOGY READY：取时钟（首个 READY，session 时钟跨拓扑复用）→
    /// 取音量服务并套用当前音量 → want_paused 为假才 Start。
    fn onTopologyReady(self: *MfPlayer) void {
        const s = self.session orelse return;
        if (self.clock == null) {
            var clk: ?*IMFClock = null;
            if (s.vtbl.GetClock(s, &clk) == S_OK and clk != null) {
                self.clock = queryInterface(IMFPresentationClock, asUnknown(clk.?), &IID_IMFPresentationClock);
                unkRelease(clk.?);
            }
        }
        self.ready_seen = true;
        self.acquireVolume(); // 每个 READY 重取（换拓扑后旧服务失效），套用缓存音量
        dbgLog("topoREADY wp={}", .{self.want_paused});
        if (!self.want_paused) {
            // 显式从 0 开始（GUID_NULL + VT_I8 0）。不能用 VT_EMPTY：它的
            // 语义是"从当前位置续播"，而 session 时钟跨拓扑连续——手动切歌
            // 或排队切换都会把旧曲位置带进新拓扑（进度条残留 bug）。
            // 本 app 的每次 loadFile 都是新歌从头播，恒 0 起无歧义。
            const start_pv = PROPVARIANT{ .vt = VT_I8, .val = .{ .i64 = 0 } };
            _ = s.vtbl.Start(s, &GUID_NULL, &start_pv);
        }
    }

    fn acquireVolume(self: *MfPlayer) void {
        if (self.audio_volume) |v| {
            unkRelease(v);
            self.audio_volume = null;
        }
        const s = self.session orelse return;
        var out: ?*anyopaque = null;
        if (MFGetService(asUnknown(s), &MR_POLICY_VOLUME_SERVICE, &IID_IMFSimpleAudioVolume, &out) != S_OK) return;
        if (out) |o| self.audio_volume = @ptrCast(@alignCast(o));
        self.setVolume(self.volume);
    }

    fn startAt(self: *MfPlayer, pos100ns: i64) void {
        const s = self.session orelse return;
        if (pos100ns <= 0) {
            _ = s.vtbl.Start(s, null, &PROPVARIANT{}); // VT_EMPTY = 从头播
        } else {
            const pv = PROPVARIANT{ .vt = VT_I8, .val = .{ .i64 = pos100ns } };
            _ = s.vtbl.Start(s, &GUID_NULL, &pv);
        }
    }

    fn clockState(self: *MfPlayer) u32 {
        const c = self.clock orelse return MFCLOCK_INVALID;
        var st: u32 = MFCLOCK_INVALID;
        if (c.vtbl.GetState(c, 0, &st) != S_OK) return MFCLOCK_INVALID;
        return st;
    }

    fn clockTime100ns(self: *MfPlayer) i64 {
        const c = self.clock orelse return 0;
        var t: i64 = 0;
        if (c.vtbl.GetTime(c, &t) != S_OK) return 0;
        return t;
    }
};

// ────────────────────────── 非 windows 占位 ──────────────────────────

/// 与 MfPlayer 同形的 stub（非 windows 目标下 player.zig 的 .mf 分支引用它，
/// 全部方法返回默认值；MfPlayer 整体不参与语义分析）。
pub const UnsupportedPlayer = struct {
    pub fn init(gpa: Allocator) UnsupportedPlayer {
        _ = gpa;
        return .{};
    }
    pub fn deinit(self: *UnsupportedPlayer) void {
        _ = self;
    }
    pub fn startAsync(self: *UnsupportedPlayer) bool {
        _ = self;
        return false;
    }
    pub fn tickConnect(self: *UnsupportedPlayer) bool {
        _ = self;
        return false;
    }
    pub fn dropConnection(self: *UnsupportedPlayer) void {
        _ = self;
    }
    pub fn loadFile(self: *UnsupportedPlayer, url: []const u8, title: []const u8) bool {
        _ = self;
        _ = url;
        _ = title;
        return false;
    }
    pub fn setSmtcMeta(self: *UnsupportedPlayer, title: []const u8, artist: []const u8, album: []const u8, cover_url: []const u8) void {
        _ = self;
        _ = title;
        _ = artist;
        _ = album;
        _ = cover_url;
    }
    pub fn appendFile(self: *UnsupportedPlayer, url: []const u8, title: []const u8) bool {
        _ = self;
        _ = url;
        _ = title;
        return false;
    }
    pub fn setPause(self: *UnsupportedPlayer, paused: bool) void {
        _ = self;
        _ = paused;
    }
    pub fn setVolume(self: *UnsupportedPlayer, volume: u8) void {
        _ = self;
        _ = volume;
    }
    pub fn setLoopFile(self: *UnsupportedPlayer, loop: bool) void {
        _ = self;
        _ = loop;
    }
    pub fn seekTo(self: *UnsupportedPlayer, secs: f64) void {
        _ = self;
        _ = secs;
    }
    pub fn status(self: *UnsupportedPlayer) ?Status {
        _ = self;
        return null;
    }
    pub fn playlistPos(self: *UnsupportedPlayer) ?i64 {
        _ = self;
        return null;
    }
    pub fn playlistNext(self: *UnsupportedPlayer) bool {
        _ = self;
        return false;
    }
    pub fn playlistPrev(self: *UnsupportedPlayer) bool {
        _ = self;
        return false;
    }
    pub fn drain(self: *UnsupportedPlayer, out_pos: *?i64, out_pause: *?bool) void {
        _ = self;
        _ = out_pos;
        _ = out_pause;
    }
    pub fn takeMediaButton(self: *UnsupportedPlayer) ?smtc_mod.MediaButton {
        _ = self;
        return null;
    }
};

// ────────────────────────── 测试 ──────────────────────────

test "GUID 常量 comptime 解析且抽查正确" {
    comptime {
        if (IID_IMFMediaSession.Data1 != 0x90377834) @compileError("IMFMediaSession IID 错");
        if (IID_IMFMediaSession.Data2 != 0x21D0) @compileError("IMFMediaSession IID 错");
        if (IID_IMFMediaSession.Data4[0] != 0x82 or IID_IMFMediaSession.Data4[1] != 0x14) @compileError("IMFMediaSession Data4 错");
        if (MFMediaType_Audio.Data1 != 0x73647561) @compileError("MFMediaType_Audio 错");
        // 文档 §3.2 里 MR_POLICY_VOLUME_SERVICE 的尾组是 c5950606de78（原文档尾组
        // 多打了个 4d，14 位非法；按 SDK mfidl.h 的 DEFINE_GUID 为准）
        if (MR_POLICY_VOLUME_SERVICE.Data4[6] != 0xde or MR_POLICY_VOLUME_SERVICE.Data4[7] != 0x78) @compileError("MR_POLICY_VOLUME_SERVICE 错");
        if (MF_TOPONODE_STREAM_DESCRIPTOR.Data1 != 0x835c58ee) @compileError("TOPONODE_STREAM_DESCRIPTOR 错");
        // 与 SDK 三连组一致：SOURCE=58ec / PRESENTATION_DESCRIPTOR=58ed / STREAM_DESCRIPTOR=58ee
        if (MF_TOPONODE_SOURCE.Data1 != 0x835c58ec) @compileError("TOPONODE_SOURCE 错");
        if (MF_TOPONODE_PRESENTATION_DESCRIPTOR.Data1 != 0x835c58ed) @compileError("TOPONODE_PRESENTATION_DESCRIPTOR 错");
    }
}

test "COM vtable 槽位数与 SDK 一致" {
    // 非 windows 不分析含 callconv(.winapi) 的类型（平台门语义与运行时一致）
    if (comptime !supported) return error.SkipZigTest;
    const usize8 = @sizeOf(usize);
    try std.testing.expectEqual(3 * usize8, @sizeOf(IUnknown.VTable));
    try std.testing.expectEqual(10 * usize8, @sizeOf(IMFSourceResolver.VTable));
    try std.testing.expectEqual(13 * usize8, @sizeOf(IMFMediaSource.VTable));
    try std.testing.expectEqual(38 * usize8, @sizeOf(IMFPresentationDescriptor.VTable));
    try std.testing.expectEqual(35 * usize8, @sizeOf(IMFStreamDescriptor.VTable));
    try std.testing.expectEqual(9 * usize8, @sizeOf(IMFMediaTypeHandler.VTable));
    try std.testing.expectEqual(43 * usize8, @sizeOf(IMFTopology.VTable));
    try std.testing.expectEqual(49 * usize8, @sizeOf(IMFTopologyNode.VTable));
    try std.testing.expectEqual(17 * usize8, @sizeOf(IMFMediaSession.VTable));
    try std.testing.expectEqual(8 * usize8, @sizeOf(IMFClock.VTable));
    // mfidl.h：IMFClock 5 方法（3-7）+ 自身 8（SetTimeSource/GetTimeSource/
    // GetTime/AddClockStateSink/RemoveClockStateSink/Start/Stop/Pause）
    try std.testing.expectEqual(16 * usize8, @sizeOf(IMFPresentationClock.VTable));
    try std.testing.expectEqual(7 * usize8, @sizeOf(IMFSimpleAudioVolume.VTable));
    try std.testing.expectEqual(36 * usize8, @sizeOf(IMFMediaEvent.VTable));
}

test "PROPVARIANT 与 C ABI 布局一致" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PROPVARIANT));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(PROPVARIANT, "val"));
    const pv = PROPVARIANT{ .vt = VT_I8, .val = .{ .i64 = 12_345_678 } };
    try std.testing.expectEqual(@as(u16, 20), pv.vt);
    try std.testing.expectEqual(@as(i64, 12_345_678), pv.val.i64);
}

test "事件状态机纯决策" {
    try std.testing.expect(eventAction(ME_SESSION_TOPOLOGY_STATUS, MF_TOPOSTATUS_READY, false) == .ready);
    // 非 READY 的拓扑状态（源已启动/输出已切换/已结束/已冲刷）不得触发 Start
    try std.testing.expect(eventAction(ME_SESSION_TOPOLOGY_STATUS, 200, true) == .none);
    try std.testing.expect(eventAction(ME_SESSION_TOPOLOGY_STATUS, 300, true) == .none);
    try std.testing.expect(eventAction(ME_SESSION_TOPOLOGY_STATUS, 400, true) == .none);
    try std.testing.expect(eventAction(ME_SESSION_STARTED, 0, true) == .pause_if_wanted);
    // 换拓扑时旧拓扑的迟到 Ended 不算 eof（loadFile 已把 ready_seen 翻假）
    try std.testing.expect(eventAction(ME_SESSION_ENDED, 0, false) == .none);
    try std.testing.expect(eventAction(ME_SESSION_ENDED, 0, true) == .mark_eof);
    try std.testing.expect(eventAction(ME_ERROR, 0, true) == .none);
    try std.testing.expect(eventAction(ME_SESSION_TOPOLOGY_SET, 0, true) == .none);
}
