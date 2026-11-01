const std = @import("std");
const builtin = @import("builtin");

// src/core/smtc.zig — Windows System Media Transport Controls（系统媒体集成）。
//
// 职能：
//   1. 「正在播放」系统展示：标题/歌手 + 播放状态 + 进度（任务栏悬浮、
//      Win+A 快速设置、音量面板、锁屏、蓝牙设备都吃这份元数据）
//   2. 系统媒体键（播放/暂停、上一首、下一首）：键盘媒体键、耳机线控、
//      蓝牙按钮、Win+A/音量面板系统播放按钮，全部收口到 SMTC
//      ButtonPressed（经 relay 进程，见下）→ 原子位标志 → takeButton
//
// ── 架构：relay 模式（默认）＋ 进程内 STA 回退 ──
//
// relay 模式（AM_SMTC_NORELAY=1 关闭）：spawn 同目录的
// AlloyMusic-SMTC.exe（C#/.NET Framework，源码 relay/AlloyMusic-SMTC.cs，
// build.zig 用系统自带 csc 编译，零外部依赖），它独占 SMTC 会话本体
// （DisplayUpdater 元数据 + PlaybackStatus + Timeline + ButtonPressed 事件），
// 本进程经 127.0.0.1:47821 行协议交互：T(曲目)/P(状态)/L(时间线) 出，
// B(按键枚举值) 入。按键映射：0/1→play_pause、6→next、7→prev（.NET
// 投影枚举序，已按实机核实）。子进程生命周期：连接断开后 15s 无新连接
// 自杀；收到 Q 立即退；amtui 崩溃 → TCP 断 → 15s 后 relay 自清。
//
// 为什么 SMTC 要放在另一个进程（2026-10 真机取证定论，Win 内测版
// 10.0.28120，勿回退）：
//   MC.dll（Windows.Media.MediaControl.dll）的 ButtonPressed fire 路径
//   存在 use-after-free：EventInvocationContext<0>::AsyncEventWorkCallback
//   经 Windows::Internal::GitInvokeHelper（GIT）调用已注册委托的内部包装
//   lambda 时，jmp 进已释放堆块（0xABAB… freed fill），进程崩溃。用
//   smtcsmoke + 自制调试 harness（dbghelp + MS 符号服务器 PDB）拿符号化
//   栈确认崩点全在 MC.dll 内部，Invoke 从未进入。本进程内穷尽以下变量
//   均复现：handler 形态（agile/FTM、非 agile、+IWeakReferenceSource、
//   getIids 实值）、初始化顺序（含 MusicPlayer2 配方）、获取路径
//   （interop GetForWindow / MediaPlayer 托管）、套间（STA/MTA/纯
//   CoInitializeEx）、进程形态（带 MF+MTA / 无 MF 单 STA 最小）、稀疏
//   MSIX 包身份（2026-11-01 资产已删：relay 模式下无作用场景，机制见
//   docs/smtc.md §2.6）。
//   MusicPlayer2（WRL/MFC）同机同注入实测可用；.NET 探针（csc 编译的
//   MediaPlayer + ButtonPressed）也全收不崩——MSVC/CLR 运行时进程不触发
//   此 UAF，Zig 静态二进制触发，残余差异无法定位。故把 SMTC 挪进 .NET
//   中转进程：媒体键、Win+A 按钮全链路实测可用（smtcsmoke 三键断言
//   PASS）。代价：多一个 ~8KB 子进程 + 系统面板里应用名显示为中转 exe。
//
// 回退路径（relay exe 缺失或 AM_SMTC_NORELAY=1）：进程内 STA 线程走
// MediaPlayer 托管 SMTC（仅展示职能）+ RegisterHotKey 热键媒体键
// （VK_MEDIA_*，MOD_NOREPEAT，WM_HOTKEY → 原子位标志）。此时 Win+A
// 按钮无效（不注册 ButtonPressed——注册会触发上述 UAF 杀进程），
// AM_SMTC_BTNEVENTS=1 可强制注册（仅实验/系统修复后验证用）。
//
// 回归工具 `zig build smtcsmoke`：默认模式跑 relay 全链路三键断言
// （SendInput 注入；锁屏下也有效——锁屏媒体层照常路由）；注意锁屏下
// WM_HOTKEY 不投递，故 NORELAY 回退路径的三键断言须解锁后验证。
//
// 接口事实来源（照抄，勿凭记忆改；取自 microsoft/windows-rs 生成代码）：
//   IMediaPlayer2                       3c841218-2123-4fc5-9082-2f883f77bdf5（get_SystemMediaTransportControls 第 6 槽）
//   IMediaPlayer3                       ee0660da-031b-4feb-bd9b-92e0a0a8d299（get_CommandManager 第 17 槽）
//   IMediaPlaybackCommandManager        5acee5a6-5cb6-4a5a-8521-cc86b1c1ed37（put_IsEnabled 第 7 槽）
//   ISystemMediaTransportControls       99fa3ff4-1742-42a6-902e-087d41f965ec
//   ISystemMediaTransportControls2      ea98d2f6-7f3c-4af2-a586-72889808efb1
//   ISystemMediaTransportControlsDisplayUpdater 8abbc53e-fa55-4ecf-ad8e-c984e5dd1550
//   IMusicDisplayProperties             6bbf0c59-d0a0-4d26-92a0-f978e1d18e7b
//   ISystemMediaTransportControlsTimelineProperties 5125316a-c3a2-475b-8507-93534dc88f15
//   ITypedEventHandler`2<SMTC,ButtonPressedEventArgs> 0557e996-7b23-5bae-aa81-ea0d671143a4（.NET 投影核实）
//   ISystemMediaTransportControlsButtonPressedEventArgs b7f47116-a56f-4dc8-9e11-92031f4a87c2
//
// 线程模型：
//   relay 模式：主线程只填请求槽 + SetEvent；writer 线程消费请求槽发
//   T/P/L 行，reader 线程收 B 行写 g_btn_flags（与热键路径共用的原子
//   位标志，takeButton 无感知差异）。
//   回退模式：专用 STA 线程（MediaPlayer 激活、控件获取、元数据/状态/
//   时间线更新、热键注册、消息泵）；主线程经请求槽 + PostMessage 投递。
//   两模式进程内单实例（请求槽与标志都是文件级全局）。

pub const supported = builtin.os.tag == .windows;

/// 媒体键语义（player.zig 原样转出；app.zig 映射到动作）。
pub const MediaButton = enum(u8) {
    play_pause,
    next,
    prev,
};

// ── WinRT 枚举值（投影核实）──
const MediaPlaybackStatus_Closed: i32 = 0;
const MediaPlaybackStatus_Stopped: i32 = 2;
const MediaPlaybackStatus_Playing: i32 = 3;
const MediaPlaybackStatus_Paused: i32 = 4;
const MediaPlaybackType_Music: i32 = 1;

const GUID = std.os.windows.GUID;
const HRESULT = i32;
const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const HSTRING = ?*anyopaque;

/// GUID 是 extern struct，0.17 不允许 == 运算；16 字节无填充，按内存比较
fn guidEql(a: GUID, b: GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
const IID_IInspectable = GUID.parse("{AF86E2E0-B12D-4c6a-9C5A-D7AA65101E90}");

// ────────────────────────── COM 接口声明 ──────────────────────────
// 扁平 vtable：槽 0-5 = IUnknown + IInspectable（QI/AddRef/Release/
// GetIids/GetRuntimeClassName/GetTrustLevel），槽 6 起为自身方法。
// 不调用的方法用 Pad 占位（尺寸正确即可）。

const Pad = *const anyopaque;

/// 裸 IUnknown 视角（QI 其他接口 / Release 用）
const UnknownLike = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*UnknownLike, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*UnknownLike) callconv(.winapi) u32,
        Release: *const fn (*UnknownLike) callconv(.winapi) u32,
    };
};

inline fn unkRelease(p: anytype) void {
    _ = p.vtbl.Release(p);
}

/// IMediaPlayer2（get_SystemMediaTransportControls 第 6 槽）
const MediaPlayer2 = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*MediaPlayer2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*MediaPlayer2) callconv(.winapi) u32,
        Release: *const fn (*MediaPlayer2) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_SystemMediaTransportControls: *const fn (*MediaPlayer2, *?*Smtc) callconv(.winapi) HRESULT, // 6
    };
};

/// IMediaPlayer3（get_CommandManager 第 17 槽；前 11 个方法 Pad 占位）
const MediaPlayer3 = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*MediaPlayer3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*MediaPlayer3) callconv(.winapi) u32,
        Release: *const fn (*MediaPlayer3) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        add_IsMutedChanged: Pad, // 6
        remove_IsMutedChanged: Pad, // 7
        add_SourceChanged: Pad, // 8
        remove_SourceChanged: Pad, // 9
        get_AudioBalance: Pad, // 10
        put_AudioBalance: Pad, // 11
        get_RealTimePlayback: Pad, // 12
        put_RealTimePlayback: Pad, // 13
        get_StereoscopicVideoRenderMode: Pad, // 14
        put_StereoscopicVideoRenderMode: Pad, // 15
        get_BreakManager: Pad, // 16
        get_CommandManager: *const fn (*MediaPlayer3, *?*CommandManager) callconv(.winapi) HRESULT, // 17
    };
};

/// IMediaPlaybackCommandManager（put_IsEnabled 第 7 槽）
const CommandManager = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*CommandManager, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*CommandManager) callconv(.winapi) u32,
        Release: *const fn (*CommandManager) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_IsEnabled: Pad, // 6
        put_IsEnabled: *const fn (*CommandManager, bool) callconv(.winapi) HRESULT, // 7
    };
};

/// ISystemMediaTransportControls（投影方法序：get/put PlaybackStatus、
/// DisplayUpdater、SoundLevel、IsEnabled、IsPlay…IsChannelDown 共 30 方法）
const Smtc = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*Smtc, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Smtc) callconv(.winapi) u32,
        Release: *const fn (*Smtc) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_PlaybackStatus: Pad, // 6
        put_PlaybackStatus: *const fn (*Smtc, i32) callconv(.winapi) HRESULT, // 7
        get_DisplayUpdater: *const fn (*Smtc, *?*DisplayUpdater) callconv(.winapi) HRESULT, // 8
        get_SoundLevel: Pad, // 9
        get_IsEnabled: Pad, // 10
        put_IsEnabled: *const fn (*Smtc, bool) callconv(.winapi) HRESULT, // 11
        get_IsPlayEnabled: Pad, // 12
        put_IsPlayEnabled: *const fn (*Smtc, bool) callconv(.winapi) HRESULT, // 13
        get_IsStopEnabled: Pad, // 14
        put_IsStopEnabled: *const fn (*Smtc, bool) callconv(.winapi) HRESULT, // 15
        get_IsPauseEnabled: Pad, // 16
        put_IsPauseEnabled: *const fn (*Smtc, bool) callconv(.winapi) HRESULT, // 17
        get_IsRecordEnabled: Pad, // 18
        put_IsRecordEnabled: Pad, // 19
        get_IsFastForwardEnabled: Pad, // 20
        put_IsFastForwardEnabled: Pad, // 21
        get_IsRewindEnabled: Pad, // 22
        put_IsRewindEnabled: Pad, // 23
        get_IsPreviousEnabled: Pad, // 24
        put_IsPreviousEnabled: *const fn (*Smtc, bool) callconv(.winapi) HRESULT, // 25
        get_IsNextEnabled: Pad, // 26
        put_IsNextEnabled: *const fn (*Smtc, bool) callconv(.winapi) HRESULT, // 27
        get_IsChannelUpEnabled: Pad, // 28
        put_IsChannelUpEnabled: Pad, // 29
        get_IsChannelDownEnabled: Pad, // 30
        put_IsChannelDownEnabled: Pad, // 31
        add_ButtonPressed: *const fn (*Smtc, *ButtonHandler, *i64) callconv(.winapi) HRESULT, // 32
        remove_ButtonPressed: *const fn (*Smtc, i64) callconv(.winapi) HRESULT, // 33
        add_PropertyChanged: Pad, // 34
        remove_PropertyChanged: Pad, // 35
    };
};

/// ISystemMediaTransportControls2（时间线：UpdateTimelineProperties 第 13 槽）
const Smtc2 = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*Smtc2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Smtc2) callconv(.winapi) u32,
        Release: *const fn (*Smtc2) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_AutoRepeatMode: Pad, // 6
        put_AutoRepeatMode: Pad, // 7
        get_ShuffleEnabled: Pad, // 8
        put_ShuffleEnabled: Pad, // 9
        get_PlaybackRate: Pad, // 10
        put_PlaybackRate: Pad, // 11
        UpdateTimelineProperties: *const fn (*Smtc2, *TimelineProps) callconv(.winapi) HRESULT, // 12
    };
};

/// ISystemMediaTransportControlsDisplayUpdater（12 方法，Update 末槽）
const DisplayUpdater = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*DisplayUpdater, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*DisplayUpdater) callconv(.winapi) u32,
        Release: *const fn (*DisplayUpdater) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_Type: Pad, // 6
        put_Type: *const fn (*DisplayUpdater, i32) callconv(.winapi) HRESULT, // 7
        get_AppMediaId: Pad, // 8
        put_AppMediaId: Pad, // 9
        get_Thumbnail: Pad, // 10
        put_Thumbnail: Pad, // 11
        get_MusicProperties: *const fn (*DisplayUpdater, *?*MusicProps) callconv(.winapi) HRESULT, // 12
        get_VideoProperties: Pad, // 13
        get_ImageProperties: Pad, // 14
        CopyFromFileAsync: Pad, // 15
        ClearAll: Pad, // 16
        Update: *const fn (*DisplayUpdater) callconv(.winapi) HRESULT, // 17
    };
};

/// IMusicDisplayProperties（投影只含 Title/AlbumArtist/Artist 三对）
const MusicProps = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*MusicProps, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*MusicProps) callconv(.winapi) u32,
        Release: *const fn (*MusicProps) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_Title: Pad, // 6
        put_Title: *const fn (*MusicProps, HSTRING) callconv(.winapi) HRESULT, // 7
        get_AlbumArtist: Pad, // 8
        put_AlbumArtist: *const fn (*MusicProps, HSTRING) callconv(.winapi) HRESULT, // 9
        get_Artist: Pad, // 10
        put_Artist: *const fn (*MusicProps, HSTRING) callconv(.winapi) HRESULT, // 11
        get_Album: Pad, // 12
        put_Album: *const fn (*MusicProps, HSTRING) callconv(.winapi) HRESULT, // 13
    };
};

/// WinRT TimeSpan：{ i64 Duration }，100ns 单位（与 MF 时间一致），
/// 8 字节标量结构体按值传参。
const TimeSpan = extern struct { duration: i64 };

/// ISystemMediaTransportControlsTimelineProperties（StartTime…Position 五对）
const TimelineProps = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*TimelineProps, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*TimelineProps) callconv(.winapi) u32,
        Release: *const fn (*TimelineProps) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_StartTime: Pad, // 6
        put_StartTime: *const fn (*TimelineProps, TimeSpan) callconv(.winapi) HRESULT, // 7
        get_EndTime: Pad, // 8
        put_EndTime: *const fn (*TimelineProps, TimeSpan) callconv(.winapi) HRESULT, // 9
        get_MinSeekTime: Pad, // 10
        put_MinSeekTime: *const fn (*TimelineProps, TimeSpan) callconv(.winapi) HRESULT, // 11
        get_MaxSeekTime: Pad, // 12
        put_MaxSeekTime: *const fn (*TimelineProps, TimeSpan) callconv(.winapi) HRESULT, // 13
        get_Position: Pad, // 14
        put_Position: *const fn (*TimelineProps, TimeSpan) callconv(.winapi) HRESULT, // 15
    };
};

const IID_Smtc = GUID.parse("{99fa3ff4-1742-42a6-902e-087d41f965ec}");
const IID_Smtc2 = GUID.parse("{ea98d2f6-7f3c-4af2-a586-72889808efb1}");
const IID_Timeline = GUID.parse("{5125316a-c3a2-475b-8507-93534dc88f15}");
const IID_ButtonArgs = GUID.parse("{b7f47116-a56f-4dc8-9e11-92031f4a87c2}");
const IID_TypedHandler = GUID.parse("{0557e996-7b23-5bae-aa81-ea0d671143a4}");
const IID_IAgileObject = GUID.parse("{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}");
const IID_IMarshal = GUID.parse("{00000003-0000-0000-C000-000000000046}");
const IID_MediaPlayer2 = GUID.parse("{3c841218-2123-4fc5-9082-2f883f77bdf5}");
const IID_MediaPlayer3 = GUID.parse("{ee0660da-031b-4feb-bd9b-92e0a0a8d299}");
const IID_CommandManager = GUID.parse("{5acee5a6-5cb6-4a5a-8521-cc86b1c1ed37}");
// IWeakReferenceSource/IWeakReference（WRL RuntimeClass 默认实现；MC.dll 的
// GitEventSourceSupportsAgile 在注册 handler 时会 QI 弱引用源）
const IID_IWeakReferenceSource = GUID.parse("{00000038-0000-0000-C000-000000000046}");
const IID_IWeakReference = GUID.parse("{00000037-0000-0000-C000-000000000046}");

// ────────────────────────── WinRT/Win32 导入 ──────────────────────────

const RO_INIT_MULTITHREADED: u32 = 1;
const RO_INIT_SINGLETHREADED: u32 = 0;
const WM_HOTKEY: u32 = 0x0312;
const MOD_NOREPEAT: u32 = 0x4000;

// combase.dll 无 Zig 自带导入库（mingw bundle 缺 libcombase.a，静态导入
// 链接期报 DllImportLibraryNotFound）→ LoadLibraryW + GetProcAddress
// 运行时加载。combase.dll 在 Win8+ 恒存在；加载失败按 SMTC 不可用静默降级。
const Combase = struct {
    RoInitialize: *const fn (apartmentType: u32) callconv(.winapi) HRESULT,
    RoGetActivationFactory: *const fn (classId: HSTRING, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT,
    RoActivateInstance: *const fn (classId: HSTRING, instance: *?*anyopaque) callconv(.winapi) HRESULT,
    WindowsCreateString: *const fn (source: [*]const u16, length: u32, out: *HSTRING) callconv(.winapi) HRESULT,
    WindowsDeleteString: *const fn (h: HSTRING) callconv(.winapi) HRESULT,
};

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "ole32" fn CoCreateFreeThreadedMarshaler(outer: ?*anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemAlloc(size: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: ?[*]u8, size: u32) callconv(.winapi) u32;

var g_cb: ?Combase = null;

/// 保证当前线程已完成 WinRT(MTA) 初始化。进程内首个 COM 初始化必须走
/// 这里（mf.zig 主线程 startAsync 调用）：WinRT 线程上下文只在首次
/// RoInitialize 时建立，纯 CoInitializeEx 先行会让后续 RoInitialize
/// S_FALSE 短路跳过，参数化类型机器（泛型委托解析）处于半初始化状态。
pub fn ensureWinrtMta() bool {
    if (!combaseInit()) return false;
    const hr = g_cb.?.RoInitialize(RO_INIT_MULTITHREADED);
    return hr == S_OK or hr == S_FALSE;
}

fn combaseInit() bool {
    if (g_cb != null) return true;
    const mod = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll").ptr) orelse return false;
    g_cb = .{
        .RoInitialize = @ptrCast(@alignCast(GetProcAddress(mod, "RoInitialize") orelse return false)),
        .RoGetActivationFactory = @ptrCast(@alignCast(GetProcAddress(mod, "RoGetActivationFactory") orelse return false)),
        .RoActivateInstance = @ptrCast(@alignCast(GetProcAddress(mod, "RoActivateInstance") orelse return false)),
        .WindowsCreateString = @ptrCast(@alignCast(GetProcAddress(mod, "WindowsCreateString") orelse return false)),
        .WindowsDeleteString = @ptrCast(@alignCast(GetProcAddress(mod, "WindowsDeleteString") orelse return false)),
    };
    return true;
}

const WNDPROC = *const fn (?*anyopaque, u32, usize, isize) callconv(.winapi) isize;

const WNDCLASSW = extern struct {
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
};

const MSG = extern struct {
    hwnd: ?*anyopaque,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt_x: i32,
    pt_y: i32,
    lPrivate: u32 = 0, // 新版 SDK 的 MSG 有此尾字段，尺寸必须 48 字节
};

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn RegisterClassW(cls: *const WNDCLASSW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, name: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, inst: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn DefWindowProcW(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize;
extern "user32" fn DestroyWindow(hwnd: *anyopaque) callconv(.winapi) i32;
extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?*anyopaque, min: u32, max: u32) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;
extern "user32" fn PostMessageW(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) i32;
extern "user32" fn RegisterHotKey(hwnd: ?*anyopaque, id: i32, mods: u32, vk: u32) callconv(.winapi) i32;
extern "user32" fn UnregisterHotKey(hwnd: ?*anyopaque, id: i32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

fn wndProc(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

const host_class_w = std.unicode.utf8ToUtf16LeStringLiteral("AmtuiSmtcHost");
const host_name_w = std.unicode.utf8ToUtf16LeStringLiteral("");

/// SMTC 宿主窗口：只需要窗口身份（GetForWindow + 热键投递），从不显示。
fn createHostWindow() ?*anyopaque {
    const cls = WNDCLASSW{ .lpfnWndProc = wndProc, .hInstance = GetModuleHandleW(null), .lpszClassName = host_class_w.ptr };
    if (RegisterClassW(&cls) == 0) return null;
    // 顶层隐藏窗口（parent=null、无 WS_VISIBLE、从不 ShowWindow）。
    // 不能用 HWND_MESSAGE 的 message-only 窗口：GetForWindow 会返回
    // E_INVALIDARG——SMTC 需要真实顶层窗口做应用身份关联。
    return CreateWindowExW(0, host_class_w.ptr, host_name_w.ptr, 0, 0, 0, 0, 0, null, null, GetModuleHandleW(null), null);
}

// ────────────────────────── 媒体键（RegisterHotKey）──────────────────────────

/// WM_HOTKEY id → 位标志（bit1=播放/暂停 bit2=下一首 bit4=上一首）。
/// 进程内单实例：标志是文件级全局，STA 泵线程写、主线程 swap 读。
var g_btn_flags = std.atomic.Value(u32).init(0);

const HotkeyDef = struct { id: i32, vk: u32, bit: u32, name: []const u8 };
const hotkeys = [_]HotkeyDef{
    .{ .id = 1, .vk = 0xB3, .bit = 1, .name = "play_pause" }, // VK_MEDIA_PLAY_PAUSE
    .{ .id = 2, .vk = 0xB0, .bit = 2, .name = "next" }, // VK_MEDIA_NEXT_TRACK
    .{ .id = 3, .vk = 0xB1, .bit = 4, .name = "prev" }, // VK_MEDIA_PREV_TRACK
};

// ────────────────────────── ButtonPressed 事件委托 ──────────────────────────
// Win+A 快速设置/音量面板的系统播放按钮只经 SMTC ButtonPressed 事件投递
// （键盘媒体键走上面的热键，两通道互补：热键先拦截按键，按键不进 SMTC
// 路由；UI 按钮只经 SMTC）。handler 为 agile/FTM 形态（Chromium 同款）。

const Btn_Play: u32 = 0;
const Btn_Pause: u32 = 1;
const Btn_Next: u32 = 6;
const Btn_Previous: u32 = 7;

/// ISystemMediaTransportControlsButtonPressedEventArgs（单方法 get_Button）
const ButtonArgs = extern struct {
    vtbl: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const fn (*ButtonArgs, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ButtonArgs) callconv(.winapi) u32,
        Release: *const fn (*ButtonArgs) callconv(.winapi) u32,
        GetIids: Pad,
        GetRuntimeClassName: Pad,
        GetTrustLevel: Pad,
        get_Button: *const fn (*ButtonArgs, *u32) callconv(.winapi) HRESULT, // 6
    };
};

/// 自由线程列集器（CoCreateFreeThreadedMarshaler；进程级，永不释放）。
/// handler 经它实现 IMarshal + IAgileObject → agile 对象：系统拿到的
/// objref 在同进程 resolve 回裸指针，fire 直接在 RPC 线程裸调 Invoke。
var g_ftm: ?*anyopaque = null;

// ── 临时调试：fire 路径文件日志（定位媒体键崩溃，调试完删除）──
const dbg_on = true;
const dbg_path_w = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\123\\AppData\\Local\\Temp\\amtui_smtc_dbg.log");
var dbg_mutex: std.atomic.Mutex = .unlocked;
var dbg_file: ?*anyopaque = null;
var dbg_tried = false;

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(f: *anyopaque, buf: [*]const u8, len: u32, written: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn FlushFileBuffers(f: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn SetFilePointer(f: *anyopaque, dist: i32, dist_hi: ?*i32, method: u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

/// 追加一行到临时日志（持久句柄 + 移到文件尾 + flush；任意线程可调）
fn dbgLog(comptime fmt: []const u8, args: anytype) void {
    if (!dbg_on) return;
    var buf: [384]u8 = undefined;
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "[{d}.{d:0>3}] ", .{ GetTickCount64() / 1000, GetTickCount64() % 1000 }) catch "";
    const line = std.fmt.bufPrint(&buf, "{s}" ++ fmt ++ "\r\n", .{ ts } ++ args) catch return;
    while (!dbg_mutex.tryLock()) std.atomic.spinLoopHint();
    defer dbg_mutex.unlock();
    if (dbg_file == null) {
        if (dbg_tried) return;
        dbg_tried = true;
        const f = CreateFileW(dbg_path_w.ptr, 0x4004, 0x1, null, 4, 0x80, null);
        if (f == null or @intFromPtr(f.?) == std.math.maxInt(usize)) return;
        dbg_file = f;
    }
    var written: u32 = 0;
    _ = SetFilePointer(dbg_file.?, 0, null, 2); // FILE_END
    _ = WriteFile(dbg_file.?, line.ptr, @intCast(line.len), &written, null);
    _ = FlushFileBuffers(dbg_file.?);
}

/// 弱引用对（WRL RuntimeClass 形态的一部分）：IWeakReferenceSource 由
/// ButtonHandler.qi 转出；Resolve 回强引用 handler（静态生命周期，恒活）。
const WeakRef = struct {
    vtbl: *const VTable,
    ref: std.atomic.Value(u32),

    pub const VTable = extern struct {
        QueryInterface: *const fn (*WeakRef, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*WeakRef) callconv(.winapi) u32,
        Release: *const fn (*WeakRef) callconv(.winapi) u32,
        Resolve: *const fn (*WeakRef, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT, // 3
    };

    fn qi(self: *WeakRef, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (guidEql(iid.*, IID_IWeakReference) or guidEql(iid.*, IID_IUnknown)) {
            _ = self.vtbl.AddRef(self);
            out.* = @ptrCast(self);
            return S_OK;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002));
    }
    fn addRef(self: *WeakRef) callconv(.winapi) u32 {
        return self.ref.fetchAdd(1, .release) + 1;
    }
    fn release(self: *WeakRef) callconv(.winapi) u32 {
        return self.ref.fetchSub(1, .acq_rel); // 静态生命周期，不销毁
    }
    fn resolve(_: *WeakRef, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (guidEql(iid.*, IID_TypedHandler) or guidEql(iid.*, IID_IUnknown) or
            guidEql(iid.*, IID_IInspectable))
        {
            const h: *ButtonHandler = &g_handler;
            _ = h.vtbl.AddRef(h);
            out.* = @ptrCast(h);
            return S_OK;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002));
    }

    const vtable = VTable{
        .QueryInterface = qi,
        .AddRef = addRef,
        .Release = release,
        .Resolve = resolve,
    };
};
var g_weak_ref = WeakRef{ .vtbl = &WeakRef.vtable, .ref = .init(1) };

const WeakRefSource = struct {
    vtbl: *const VTable,
    ref: std.atomic.Value(u32),

    pub const VTable = extern struct {
        QueryInterface: *const fn (*WeakRefSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*WeakRefSource) callconv(.winapi) u32,
        Release: *const fn (*WeakRefSource) callconv(.winapi) u32,
        GetWeakReference: *const fn (*WeakRefSource, *?*anyopaque) callconv(.winapi) HRESULT, // 3
    };

    fn qi(self: *WeakRefSource, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (guidEql(iid.*, IID_IWeakReferenceSource) or guidEql(iid.*, IID_IUnknown)) {
            _ = self.vtbl.AddRef(self);
            out.* = @ptrCast(self);
            return S_OK;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002));
    }
    fn addRef(self: *WeakRefSource) callconv(.winapi) u32 {
        return self.ref.fetchAdd(1, .release) + 1;
    }
    fn release(self: *WeakRefSource) callconv(.winapi) u32 {
        return self.ref.fetchSub(1, .acq_rel); // 静态生命周期，不销毁
    }
    fn getWeakReference(self: *WeakRefSource, out: *?*anyopaque) callconv(.winapi) HRESULT {
        _ = self;
        const w: *WeakRef = &g_weak_ref;
        _ = w.vtbl.AddRef(w);
        out.* = @ptrCast(w);
        return S_OK;
    }

    const vtable = VTable{
        .QueryInterface = qi,
        .AddRef = addRef,
        .Release = release,
        .GetWeakReference = getWeakReference,
    };
};
var g_weak_src = WeakRefSource{ .vtbl = &WeakRefSource.vtable, .ref = .init(1) };

const ButtonHandler = struct {
    vtbl: *const VTable,
    ref: std.atomic.Value(u32),
    pub const VTable = extern struct {
        QueryInterface: *const fn (*ButtonHandler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*ButtonHandler) callconv(.winapi) u32,
        Release: *const fn (*ButtonHandler) callconv(.winapi) u32,
        GetIids: *const fn (*ButtonHandler, *u32, *?*GUID) callconv(.winapi) HRESULT,
        GetRuntimeClassName: *const fn (*ButtonHandler, *HSTRING) callconv(.winapi) HRESULT,
        GetTrustLevel: *const fn (*ButtonHandler, *i32) callconv(.winapi) HRESULT,
        Invoke: *const fn (*ButtonHandler, ?*anyopaque, ?*ButtonArgs) callconv(.winapi) HRESULT,
    };

    fn qi(self: *ButtonHandler, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (guidEql(iid.*, IID_TypedHandler) or guidEql(iid.*, IID_IUnknown) or
            guidEql(iid.*, IID_IInspectable))
        {
            _ = self.vtbl.AddRef(self);
            out.* = @ptrCast(self);
            return S_OK;
        }
        // agile 形态：IAgileObject 自指 + IMarshal 转发进程级 FTM（fire 可
        // 在任意线程裸调 Invoke，不依赖 STA 泵）
        if (guidEql(iid.*, IID_IAgileObject)) {
            _ = self.vtbl.AddRef(self);
            out.* = @ptrCast(self);
            return S_OK;
        }
        if (guidEql(iid.*, IID_IMarshal)) {
            const ftm = g_ftm orelse {
                out.* = null;
                return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
            };
            const u: *UnknownLike = @ptrCast(@alignCast(ftm));
            return u.vtbl.QueryInterface(u, iid, out);
        }
        // 弱引用源（WRL RuntimeClass 默认提供；GitEventSourceSupportsAgile
        // 注册路径会 QI）
        if (guidEql(iid.*, IID_IWeakReferenceSource)) {
            out.* = @ptrCast(&g_weak_src);
            _ = g_weak_src.ref.fetchAdd(1, .release);
            return S_OK;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }
    fn addRef(self: *ButtonHandler) callconv(.winapi) u32 {
        const r = self.ref.fetchAdd(1, .release) + 1;
        return r;
    }
    fn release(self: *ButtonHandler) callconv(.winapi) u32 {
        // 静态生命周期：只减计数，永不销毁（引用可能归零，无妨）
        const r = self.ref.fetchSub(1, .acq_rel);
        return r;
    }
    /// IInspectable 契约：返回本对象实现的接口 IID 列表（调用方
    /// CoTaskMemFree）。必须报实情——fire 路径会读本列表（count=0 的
    /// 空报告是 MC.dll 崩溃的嫌疑变量之一，见文件头）。
    fn getIids(self: *ButtonHandler, count: *u32, iids: *?*GUID) callconv(.winapi) HRESULT {
        _ = self;
        const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
        const mem = CoTaskMemAlloc(@sizeOf(GUID)) orelse {
            count.* = 0;
            iids.* = null;
            return E_OUTOFMEMORY;
        };
        const arr: [*]GUID = @ptrCast(@alignCast(mem));
        arr[0] = IID_TypedHandler;
        count.* = 1;
        iids.* = @ptrCast(arr);
        return S_OK;
    }
    fn getRuntimeClassName(self: *ButtonHandler, out: *HSTRING) callconv(.winapi) HRESULT {
        _ = self;
        out.* = g_handler_rn;
        if (g_handler_rn == null) return @bitCast(@as(u32, 0x8007000E)); // E_OUTOFMEMORY
        return S_OK;
    }
    fn getTrustLevel(self: *ButtonHandler, out: *i32) callconv(.winapi) HRESULT {
        _ = self;
        out.* = 0; // Base
        return S_OK;
    }
    fn invoke(self: *ButtonHandler, sender: ?*anyopaque, args: ?*ButtonArgs) callconv(.winapi) HRESULT {
        _ = self;
        _ = sender;
        // fire 在任意 RPC 线程：只触碰原子量
        const a = args orelse {
            return S_OK;
        };
        var btn: u32 = 0;
        const hr = a.vtbl.get_Button(a, &btn);
        if (hr != S_OK) return S_OK;
        const bit: u32 = switch (btn) {
            Btn_Play, Btn_Pause => 1,
            Btn_Next => 2,
            Btn_Previous => 4,
            else => 0,
        };
        if (bit != 0) _ = g_btn_flags.fetchOr(bit, .release);
        return S_OK;
    }

    const vtable = VTable{
        .QueryInterface = qi,
        .AddRef = addRef,
        .Release = release,
        .GetIids = getIids,
        .GetRuntimeClassName = getRuntimeClassName,
        .GetTrustLevel = getTrustLevel,
        .Invoke = invoke,
    };
};

/// 静态单实例委托（免分配；QI 计数不影响生命周期）
var g_handler = ButtonHandler{ .vtbl = &ButtonHandler.vtable, .ref = .init(1) };


/// 委托的运行时类名（IInspectable 契约要求非 null；attach 时创建，进程级复用）
var g_handler_rn: HSTRING = null;
const handler_rn_w = blk: {
    @setEvalBranchQuota(10000);
    break :blk std.unicode.utf8ToUtf16LeStringLiteral("Windows.Foundation.ITypedEventHandler`2<Windows.Media.SystemMediaTransportControls,Windows.Media.SystemMediaTransportControlsButtonPressedEventArgs>");
};

// ────────────────────────── Session ──────────────────────────

const class_mediaplayer_w = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Media.Playback.MediaPlayer");
const class_timeline_w = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Media.SystemMediaTransportControlsTimelineProperties");

/// 时间线刷新节流（SMTC 官方建议 <5s，500ms 足够顺滑且开销可忽略）
const TIMELINE_MIN_MS: u64 = 500;

// ── 主线程 → STA 线程请求（互斥保护；按类分槽，互不覆盖）────────
// SMTC 对象是 apartment 敏感的：窗口/控件/元数据只能在创建它们的
// STA 线程上使用。主线程只投递请求，STA 线程在消息泵循环里消费。
// set_track / set_paused 是事件语义（不丢），timeline 是状态刷新
// 语义（后写覆盖前写，且可被事件类请求压制——下一 tick 会再投）。
const TrackReq = struct {
    pending: bool = false,
    title_len: u16 = 0,
    artist_len: u16 = 0,
    // 先写字符串再置 pending，读取只到 len 为止，undefined 不会被读到
    title: [160]u16 = undefined,
    artist: [160]u16 = undefined,
    album_len: u16 = 0,
    album: [160]u16 = undefined,
    // 封面 URL（UTF-8）：仅 relay 模式消费（STA 回退路径不做封面——
    // RandomAccessStreamReference 需要新的 COM 面，回退本来就只有展示）
    cover_len: u16 = 0,
    cover: [768]u8 = undefined,
};
const PauseReq = struct { pending: bool = false, paused: bool = false };
const TimelineReq = struct { pending: bool = false, pos_s: f64 = 0, dur_s: f64 = 0 };

var g_track: TrackReq = .{};
var g_pause: PauseReq = .{};
var g_timeline: TimelineReq = .{};
var g_req_mutex: std.atomic.Mutex = .unlocked;
var g_quit = std.atomic.Value(bool).init(false);
/// STA attach 状态：0=启动中 1=attached 2=失败（失败按 SMTC 不可用静默降级）
var g_sta_state = std.atomic.Value(u8).init(0);
const WM_APP_REQ: u32 = 0x8001; // WM_APP+1：唤醒 STA 泵

/// UTF-8 → UTF-16 定长缓冲（非法序列跳过，超长截断），返回写入的 u16 数
fn utf8ToUtf16Fixed(dst: []u16, src: []const u8) u16 {
    var di: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(src[i]) catch {
            i += 1;
            continue;
        };
        if (i + seq_len > src.len) break;
        const cp = std.unicode.utf8Decode(src[i .. i + seq_len]) catch {
            i += seq_len;
            continue;
        };
        i += seq_len;
        var out: [2]u16 = undefined;
        const n: usize = if (cp < 0x10000) blk: {
            if (cp >= 0xD800 and cp < 0xE000) break :blk 0; // 孤立代理项跳过
            out[0] = @intCast(cp);
            break :blk 1;
        } else blk: {
            const v = cp - 0x10000;
            out[0] = @intCast(0xD800 + (v >> 10));
            out[1] = @intCast(0xDC00 + (v & 0x3FF));
            break :blk 2;
        };
        if (n == 0) continue;
        if (di + n > dst.len) break; // 超长截断
        @memcpy(dst[di .. di + n], out[0..n]);
        di += n;
    }
    return @intCast(di);
}

/// UTF-16 切片 → HSTRING（调用方 WindowsDeleteString）
fn hstrFromUtf16(slice: []const u16) ?HSTRING {
    if (g_cb == null) return null;
    var h: HSTRING = null;
    if (g_cb.?.WindowsCreateString(slice.ptr, @intCast(slice.len), &h) != S_OK) return null;
    return h;
}

// ────────────────────────── relay 模式 ──────────────────────────
// 子进程 AlloyMusic-SMTC.exe（C#/.NET Framework，csc 编译，源码
// relay/AlloyMusic-SMTC.cs）持有 SMTC 会话本体；本进程连 127.0.0.1:47821
// 行协议交互（协议见该文件头注释）。按键事件经 reader 线程写进与热键共用
// 的 g_btn_flags，下游 takeButton 无感知。裸 ws2_32 实现（与全文件风格
// 一致；std.net 需 Io 能力，而 attach 链路不持有 io）。匿名管道版本曾出现
// 「子进程写成功、父端 ReadFile 永远收不到」的诡异现象，TCP 无此问题。
// 端口被占 = 已有 relay 实例（attach 直接连它）；relay 自身单实例语义。

const RelayState = struct {
    h_proc: ?*anyopaque,
    sock: usize, // SOCKET（INVALID_SOCKET = ~0）
    wake: ?*anyopaque, // CreateEventW（writer 唤醒）
    alive: std.atomic.Value(u8), // 1=子进程与连接可用
};

var g_relay: ?RelayState = null;
var g_relay_writer: ?std.Thread = null;
var g_relay_reader: ?std.Thread = null;

extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) u32;
extern "kernel32" fn GetTempPathW(size: u32, buf: [*]u16) u32;
extern "kernel32" fn GetFileSize(f: *anyopaque, high: ?*u32) u32;
extern "kernel32" fn ReadFile(f: *anyopaque, buf: [*]u8, len: u32, got: *u32, ov: ?*anyopaque) i32;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) u32;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: i32, init: i32, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(h: *anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]const u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: i32, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *StartupInfoW, pi: *ProcessInfoW) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(h: *anyopaque, code: u32) callconv(.winapi) i32;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetHandleInformation(h: *anyopaque, mask: u32, flags: u32) callconv(.winapi) i32;

const StartupInfoW = extern struct {
    cb: u32,
    reserved: ?*anyopaque,
    desktop: ?*anyopaque,
    title: ?*anyopaque,
    x: u32, y: u32, xsize: u32, ysize: u32,
    xchars: u32, ychars: u32, fill: u32, flags: u32,
    show_window: u16, reserved2: u16,
    reserved3: ?*anyopaque,
    std_input: ?*anyopaque,
    std_output: ?*anyopaque,
    std_error: ?*anyopaque,
};
const ProcessInfoW = extern struct {
    h_process: ?*anyopaque,
    h_thread: ?*anyopaque,
    pid: u32,
    tid: u32,
};

extern "ws2_32" fn WSAStartup(ver: u16, data: *WSAData) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, tp: i32, proto: i32) callconv(.winapi) i32;
extern "ws2_32" fn connect(s: i32, addr: *const SockAddrIn, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: i32, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: i32, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: i32) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const WSAData = extern struct {
    wVersion: u16, wHighVersion: u16, iMaxSockets: u16, iMaxUdpDg: u16,
    lpVendorInfo: ?*anyopaque, szDescription: [257]u8, szSystemStatus: [129]u8,
};
const SockAddrIn = extern struct {
    family: u16 = 2, // AF_INET
    port: u16 = 0, // 大端
    addr: u32 = 0x0100_007f, // 127.0.0.1（网络序）
    zero: [8]u8 = @splat(0),
};

const RELAY_PORT: u16 = 47821;
var g_wsa_done = false;

fn wsaInit() bool {
    if (g_wsa_done) return true;
    var data: WSAData = undefined;
    if (WSAStartup(0x0202, &data) != 0) return false;
    g_wsa_done = true;
    return true;
}

/// relay exe 与本 exe 同目录（zig-out/bin 下由 build 的 csc step 产出）
fn relayExePath(buf: *[512]u16) ?[*:0]const u16 {
    const n = GetModuleFileNameW(null, buf, buf.len);
    if (n == 0 or n >= buf.len - 24) return null;
    var dir_len: usize = n;
    while (dir_len > 0 and buf[dir_len - 1] != '\\') dir_len -= 1;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("AlloyMusic-SMTC.exe");
    if (dir_len + suffix.len >= buf.len) return null;
    @memcpy(buf[dir_len .. dir_len + suffix.len], suffix);
    buf[dir_len + suffix.len] = 0;
    return @ptrCast(buf[0 .. dir_len + suffix.len :0].ptr);
}

const relay_embed = @import("relay_embed.zig");

/// 单文件分发：同目录没有 relay exe 时把构建期嵌入的字节解包到 %TEMP%。
/// 已存在且大小一致则复用（不重写——运行中的 relay exe 不可覆盖写）。
fn ensureEmbeddedRelayExe(buf: *[512]u16) ?[*:0]const u16 {
    if (relay_embed.exe_bytes.len == 0) return null;
    var tmp_len = GetTempPathW(buf.len - 24, buf);
    if (tmp_len == 0 or tmp_len >= buf.len - 24) return null;
    if (tmp_len > 1 and buf[tmp_len - 1] != '\\') {
        buf[tmp_len] = '\\';
        tmp_len += 1;
    }
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("AlloyMusic-SMTC.exe");
    if (tmp_len + suffix.len >= buf.len) return null;
    @memcpy(buf[tmp_len .. tmp_len + suffix.len], suffix);
    buf[tmp_len + suffix.len] = 0;
    const path: [*:0]const u16 = @ptrCast(buf[0 .. tmp_len + suffix.len :0].ptr);
    // 已存在且内容一致 → 复用。不能只比大小：新旧 csc 产物可能恰好同长
    // （实测 11264==11264 导致旧 relay 永不更新），用 FNV-1a 64 校验内容
    if (CreateFileW(path, 0x80000000, 0x1, null, 3, 0x80, null)) |ex| { // GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING
        var size_hi: u32 = 0;
        const size_lo = GetFileSize(ex, &size_hi);
        if (size_hi == 0 and size_lo == relay_embed.exe_bytes.len) {
            var file_buf: [16384]u8 = undefined;
            var read_total: usize = 0;
            var h: u64 = 0xcbf29ce484222325;
            while (true) {
                var got: u32 = 0;
                _ = ReadFile(ex, file_buf[0..], file_buf.len, &got, null);
                if (got == 0) break;
                read_total += got;
                for (file_buf[0..got]) |c| {
                    h = (h ^ c) *% 0x100000001b3;
                }
            }
            _ = CloseHandle(ex);
            // 校验和一致才复用；长度/内容不符都重写
            var emb_h: u64 = 0xcbf29ce484222325;
            for (relay_embed.exe_bytes) |c| emb_h = (emb_h ^ c) *% 0x100000001b3;
            if (read_total == relay_embed.exe_bytes.len and h == emb_h) return path;
        } else {
            _ = CloseHandle(ex);
        }
    }
    // CREATE_ALWAYS 覆盖写（旧版字节差异；被运行中进程锁住时写失败 → 本轮
    // 连不上，走回退路径，下一轮启动再换）
    const f = CreateFileW(path, 0x40000000, 0, null, 2, 0x80, null) orelse return null; // GENERIC_WRITE, CREATE_ALWAYS
    var written: u32 = 0;
    _ = WriteFile(f, relay_embed.exe_bytes.ptr, @intCast(relay_embed.exe_bytes.len), &written, null);
    _ = CloseHandle(f);
    if (written != relay_embed.exe_bytes.len) return null;
    dbgLog("relayEmbed extracted {d} bytes", .{written});
    return path;
}

/// attach 的 relay 分支：spawn（尽力）→ 连 127.0.0.1:RELAY_PORT →
/// reader/writer 线程。成功返回 true（g_sta_state 由调用方置 1）。
fn relayAttach(self: *Session) bool {
    if (!wsaInit()) return false;
    var path_buf: [512]u16 = undefined;
    // 兄弟 exe 优先（开发：zig-out/bin 里的手放产物可覆盖嵌入版），
    // 没有 → 解包构建期嵌入的字节到 %TEMP%（单文件分发主路径）
    var exe = relayExePath(&path_buf);
    if (exe != null and GetFileAttributesW(exe.?) == 0xFFFFFFFF) exe = null;
    var emb_buf: [512]u16 = undefined;
    if (exe == null) exe = ensureEmbeddedRelayExe(&emb_buf);
    var h_proc: ?*anyopaque = null;
    if (exe != null) {
        var si = std.mem.zeroes(StartupInfoW);
        si.cb = @sizeOf(StartupInfoW);
        var pi = std.mem.zeroes(ProcessInfoW);
        // DETACHED_PROCESS：不继承 TUI 的控制台/stdio——.NET 运行时偶发往
        // 控制台写（异常文本等 UTF-16 流）会直接打花 TUI 终端（用户观测的
        // 二进制乱码）；relay 的诊断走自己的文件日志，无需任何 stdio。
        if (CreateProcessW(exe.?, exe.?, null, null, 0, 0x00000008, null, null, &si, &pi) != 0) {
            h_proc = pi.h_process;
            _ = CloseHandle(pi.h_thread.?);
            dbgLog("relaySpawn ok", .{});
        } else {
            dbgLog("relaySpawn FAILED err={d}", .{GetLastError()});
        }
    }
    // 连接重试（relay 启动 + MediaPlayer 初始化 ~1s）
    var sock: i32 = -1;
    var waited: u32 = 0;
    while (waited < 4000) {
        sock = socket(2, 1, 6); // AF_INET, SOCK_STREAM, IPPROTO_TCP
        if (sock >= 0) {
            var addr = SockAddrIn{ .port = std.mem.nativeToBig(u16, RELAY_PORT) };
            if (connect(sock, &addr, @sizeOf(SockAddrIn)) == 0) break;
            _ = closesocket(sock);
            sock = -1;
        }
        Sleep(150);
        waited += 150;
    }
    if (sock < 0) {
        dbgLog("relayAttach connect failed wsa={d}", .{WSAGetLastError()});
        if (h_proc) |hp| {
            _ = TerminateProcess(hp, 1);
            _ = CloseHandle(hp);
        }
        return false;
    }
    const wake = CreateEventW(null, 0, 0, null) orelse {
        _ = closesocket(sock);
        if (h_proc) |hp| {
            _ = TerminateProcess(hp, 1);
            _ = CloseHandle(hp);
        }
        return false;
    };
    g_relay = .{ .h_proc = h_proc, .sock = @intCast(sock), .wake = wake, .alive = .init(1) };
    g_quit.store(false, .release);
    g_relay_reader = std.Thread.spawn(.{}, relayReaderMain, .{}) catch {
        _ = SetEvent(wake);
        _ = CloseHandle(wake);
        _ = closesocket(sock);
        if (h_proc) |hp| {
            _ = TerminateProcess(hp, 1);
            _ = CloseHandle(hp);
        }
        g_relay = null;
        return false;
    };
    g_relay_writer = std.Thread.spawn(.{}, relayWriterMain, .{self}) catch {
        g_quit.store(true, .release);
        _ = SetEvent(wake);
        if (g_relay_reader) |t| t.join();
        g_relay_reader = null;
        _ = CloseHandle(wake);
        _ = closesocket(sock);
        if (h_proc) |hp| {
            _ = TerminateProcess(hp, 1);
            _ = CloseHandle(hp);
        }
        g_relay = null;
        return false;
    };
    dbgLog("relayAttach ok sock={d}", .{sock});
    return true;
}

/// 读线程：recv 按键行（B\t<n>），映射进与热键共用的位标志。
/// n 来自 .NET 投影枚举：Play=0 Pause=1 Stop=2 Record=3 FF=4 Rewind=5
/// Next=6 Previous=7（已按实机投影核实，勿凭旧记忆改）。
fn relayReaderMain() void {
    const relay = &(g_relay orelse return);
    var buf: [256]u8 = undefined;
    var line: [64]u8 = undefined;
    var li: usize = 0;
    const sock: i32 = @intCast(relay.sock);
    while (relay.alive.load(.acquire) == 1) {
        const n = recv(sock, &buf, buf.len, 0);
        if (n <= 0) {
            dbgLog("relayReader end n={d} wsa={d}", .{ n, WSAGetLastError() });
            break;
        }
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n') {
                parseRelayEvent(line[0..li]);
                li = 0;
            } else if (li < line.len) {
                line[li] = ch;
                li += 1;
            }
        }
    }
    relay.alive.store(0, .release);
}

fn parseRelayEvent(l: []const u8) void {
    // relay 的 WriteLine 是 CRLF：解析前去掉首尾空白与 CR
    const t = std.mem.trim(u8, l, " \r\t\n");
    if (t.len < 3 or t[0] != 'B' or t[1] != '\t') return;
    const n = std.fmt.parseInt(u32, t[2..], 10) catch return;
    const bit: u32 = switch (n) {
        0, 1 => 1, // Play/Pause → play_pause
        6 => 2, // Next
        7 => 4, // Previous
        else => return, // Stop/Record/FF/Rewind/Channel 不映射
    };
    _ = g_btn_flags.fetchOr(bit, .release);
}

/// 写线程：等 wake 或 200ms 轮询，消费请求槽 → 协议行 → relay。
fn relayWriterMain(self: *Session) void {
    const relay = &(g_relay orelse return);
    var line_buf: [4096]u8 = undefined; // T(title+artist+album) + C(封面URL) 同批可超 2KB
    const sock: i32 = @intCast(relay.sock);
    while (g_quit.load(.acquire) == false) {
        _ = WaitForSingleObject(relay.wake.?, 200);
        if (g_quit.load(.acquire)) break;
        while (!g_req_mutex.tryLock()) std.atomic.spinLoopHint();
        const track = g_track;
        const pause = g_pause;
        const tl = g_timeline;
        g_track.pending = false;
        g_pause.pending = false;
        g_timeline.pending = false;
        g_req_mutex.unlock();
        if (!track.pending and !pause.pending and !tl.pending) continue;
        var w: usize = 0;
        var wrote_any = false;
        if (track.pending) {
            var title_u8: [512]u8 = undefined;
            var artist_u8: [512]u8 = undefined;
            var album_u8: [512]u8 = undefined;
            const tl8 = utf16LeToUtf8Fixed(&title_u8, track.title[0..track.title_len]);
            const ar8 = utf16LeToUtf8Fixed(&artist_u8, track.artist[0..track.artist_len]);
            const al8 = utf16LeToUtf8Fixed(&album_u8, track.album[0..track.album_len]);
            // T 行第 4 段 album（relay 对缺段向后兼容）；C 行封面 URL 紧随
            // 其后——relay 收 T 先清旧封面，C 才能落到本曲（无封面不发 C）。
            if (w + 2 + tl8 + 1 + ar8 + 1 + al8 + 1 < line_buf.len) {
                line_buf[w] = 'T';
                line_buf[w + 1] = '\t';
                w += 2;
                @memcpy(line_buf[w .. w + tl8], title_u8[0..tl8]);
                w += tl8;
                line_buf[w] = '\t';
                w += 1;
                @memcpy(line_buf[w .. w + ar8], artist_u8[0..ar8]);
                w += ar8;
                line_buf[w] = '\t';
                w += 1;
                @memcpy(line_buf[w .. w + al8], album_u8[0..al8]);
                w += al8;
                line_buf[w] = '\n';
                w += 1;
                wrote_any = true;
            }
            if (track.cover_len > 0 and w + 2 + track.cover_len + 1 < line_buf.len) {
                line_buf[w] = 'C';
                line_buf[w + 1] = '\t';
                w += 2;
                @memcpy(line_buf[w .. w + track.cover_len], track.cover[0..track.cover_len]);
                w += track.cover_len;
                line_buf[w] = '\n';
                w += 1;
                wrote_any = true;
            }
        }
        if (pause.pending and w + 4 < line_buf.len) {
            line_buf[w] = 'P';
            line_buf[w + 1] = '\t';
            line_buf[w + 2] = if (pause.paused) '1' else '0';
            line_buf[w + 3] = '\n';
            w += 4;
            wrote_any = true;
        }
        if (tl.pending) {
            const now = GetTickCount64();
            if (self.last_tl_ms != 0 and now - self.last_tl_ms < TIMELINE_MIN_MS) {
                // 节流：丢弃本次时间线（与 STA 路径同一策略）
            } else {
                self.last_tl_ms = now;
                var pos_buf: [24]u8 = undefined;
                var dur_buf: [24]u8 = undefined;
                const pos_s = std.fmt.bufPrint(&pos_buf, "{d}", .{@as(u64, @intFromFloat(@max(tl.pos_s, 0) * 1000))}) catch "";
                const dur_s = std.fmt.bufPrint(&dur_buf, "{d}", .{@as(u64, @intFromFloat(@max(tl.dur_s, 0) * 1000))}) catch "";
                if (w + 2 + pos_s.len + 1 + dur_s.len + 1 < line_buf.len) {
                    line_buf[w] = 'L';
                    line_buf[w + 1] = '\t';
                    w += 2;
                    @memcpy(line_buf[w .. w + pos_s.len], pos_s);
                    w += pos_s.len;
                    line_buf[w] = '\t';
                    w += 1;
                    @memcpy(line_buf[w .. w + dur_s.len], dur_s);
                    w += dur_s.len;
                    line_buf[w] = '\n';
                    w += 1;
                    wrote_any = true;
                }
            }
        }
        if (wrote_any) {
            if (send(sock, line_buf[0..w].ptr, @intCast(w), 0) != @as(i32, @intCast(w))) {
                relay.alive.store(0, .release);
                dbgLog("relayWriter send failed", .{});
                return;
            }
        }
    }
}

/// UTF-16 → UTF-8（定长缓冲；出错返回 0 长度即空串，标题缺失可接受）
fn utf16LeToUtf8Fixed(dst: []u8, src: []const u16) usize {
    var di: usize = 0;
    for (src) |u| {
        if (u == 0) break;
        const cp: u21 = u;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch continue;
        if (di + n > dst.len) break;
        @memcpy(dst[di .. di + n], enc[0..n]);
        di += n;
    }
    return di;
}

/// detach 的 relay 分支：发 Q、关连接、收线程、兜底杀进程。
fn relayDetach() void {
    const relay_ptr = &(g_relay orelse return);
    g_quit.store(true, .release);
    if (relay_ptr.wake) |w| _ = SetEvent(w);
    if (g_relay_writer) |t| t.join();
    g_relay_writer = null;
    _ = send(@intCast(relay_ptr.sock), "Q\n", 2, 0); // relay 收 Q 优雅退出
    _ = closesocket(@intCast(relay_ptr.sock));
    if (g_relay_reader) |t| t.join();
    g_relay_reader = null;
    if (relay_ptr.h_proc) |hp| {
        _ = WaitForSingleObject(hp, 2000); // 正常情况 relay 已自行退出
        _ = TerminateProcess(hp, 0); // 幂等兜底
        _ = CloseHandle(hp);
    }
    if (relay_ptr.wake) |w| _ = CloseHandle(w);
    g_relay = null;
}




pub const Session = struct {
    gpa: std.mem.Allocator = undefined,
    thread: ?std.Thread = null,
    hwnd: ?*anyopaque = null, // STA 线程拥有
    controls: ?*Smtc = null, // 以下 WinRT 对象全部 STA 线程拥有
    controls2: ?*Smtc2 = null,
    updater: ?*DisplayUpdater = null,
    music: ?*MusicProps = null,
    timeline: ?*TimelineProps = null,
    media_player: ?*UnknownLike = null, // SMTC 会话的宿主，最后释放
    btn_token: i64 = 0, // ButtonPressed 注册令牌（0=未注册）
    last_tl_ms: u64 = 0,

    /// attach：主线程调用（MF startAsync 成功后）。优先 relay 模式（子进程
    /// AlloyMusic-SMTC.exe 独占 SMTC，stdin/stdout 行协议——躲开 MC.dll fire
    /// UAF，媒体键与 Win+A 按钮全链路可用）；失败回退进程内 STA（仅展示 +
    /// RegisterHotKey 热键）。SMTC 是增强功能，失败静默降级。
    pub fn attach(self: *Session, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        if (g_sta_state.load(.acquire) == 1 or self.thread != null) return;
        var no_relay_buf: [8]u8 = undefined;
        const no_relay = GetEnvironmentVariableA("AM_SMTC_NORELAY", &no_relay_buf, no_relay_buf.len) > 0;
        if (!no_relay and relayAttach(self)) {
            g_sta_state.store(1, .release);
            return;
        }
        // FTM（handler 的 IMarshal 载体）：进程级一次即可，QI 前必须就位
        if (g_ftm == null) {
            var ftm: ?*anyopaque = null;
            if (CoCreateFreeThreadedMarshaler(null, &ftm) == S_OK and ftm != null) g_ftm = ftm;
        }
        g_quit.store(false, .release);
        g_sta_state.store(0, .release);
        const t = std.Thread.spawn(.{}, staMain, .{self}) catch return;
        self.thread = t;
        var waited: u32 = 0;
        while (g_sta_state.load(.acquire) == 0 and waited < 3000) {
            Sleep(2);
            waited += 2;
        }
    }

    /// STA 线程主体：RoInitialize(STA) → 窗口 → MediaPlayer 激活取 SMTC
    /// → 元数据基线 →（可选）ButtonPressed 注册 → 热键注册 → 泵循环 → 拆除。
    fn staMain(self: *Session) void {
        // RoInitialize(SINGLETHREADED) 内部即 CoInitializeEx(STA) + WinRT 上下文。
        // 实验开关 AM_SMTC_MTA=1：SMTC 线程改跑 MTA——fire 由线程池直接裸调
        // agile handler，绕开 STA 编组回泵的路径（handler 本就 agile+FTM）。
        if (!combaseInit()) {
            g_sta_state.store(2, .release);
            return;
        }
        {
            var mta_buf: [4]u8 = undefined;
            const use_mta = GetEnvironmentVariableA("AM_SMTC_MTA", &mta_buf, mta_buf.len) > 0;
            const ro_hr = g_cb.?.RoInitialize(if (use_mta) RO_INIT_MULTITHREADED else RO_INIT_SINGLETHREADED);
            if (ro_hr != S_OK and ro_hr != S_FALSE) {
                g_sta_state.store(2, .release);
                return;
            }
        }
        // 委托运行时类名（getRuntimeClassName 返回用，IInspectable 契约）
        if (g_handler_rn == null)
            _ = g_cb.?.WindowsCreateString(handler_rn_w.ptr, handler_rn_w.len, &g_handler_rn);
        // 窗口必须与消息泵同线程创建（热键 WM_HOTKEY 也投递到这里）
        self.hwnd = createHostWindow() orelse {
            g_sta_state.store(2, .release);
            return;
        };
        // 激活 MediaPlayer（SMTC 会话由媒体引擎托管）
        var cm: ?*CommandManager = null;
        var player: ?*UnknownLike = null;
        var c: ?*Smtc = null;
        var ok = true;
        {
            var mpl_h: HSTRING = null;
            if (g_cb.?.WindowsCreateString(class_mediaplayer_w.ptr, class_mediaplayer_w.len, &mpl_h) != S_OK) {
                g_sta_state.store(2, .release);
                return;
            }
            defer _ = g_cb.?.WindowsDeleteString(mpl_h);
            var player_p: ?*anyopaque = null;
            const act_hr = g_cb.?.RoActivateInstance(mpl_h, &player_p);
            if (act_hr != S_OK or player_p == null) {
                g_sta_state.store(2, .release);
                return;
            }
            player = @ptrCast(@alignCast(player_p.?));
            // 先禁系统对 MediaPlayer 的自动媒体集成（展示收口全归我们），
            // 再取 SMTC 实例
            var mp3_p: ?*anyopaque = null;
            if (player.?.vtbl.QueryInterface(player.?, &IID_MediaPlayer3, &mp3_p) == S_OK and mp3_p != null) {
                const mp3: *MediaPlayer3 = @ptrCast(@alignCast(mp3_p.?));
                var cm_p: ?*CommandManager = null;
                if (mp3.vtbl.get_CommandManager(mp3, &cm_p) == S_OK and cm_p != null) {
                    cm = cm_p;
                    _ = cm.?.vtbl.put_IsEnabled(cm.?, false);
                }
            }
            var mp2_p: ?*anyopaque = null;
            if (player.?.vtbl.QueryInterface(player.?, &IID_MediaPlayer2, &mp2_p) == S_OK and mp2_p != null) {
                const mp2: *MediaPlayer2 = @ptrCast(@alignCast(mp2_p.?));
                var smtc_p: ?*Smtc = null;
                if (mp2.vtbl.get_SystemMediaTransportControls(mp2, &smtc_p) == S_OK and smtc_p != null) {
                    c = smtc_p;
                }
            }
        }
        if (c == null) ok = false;
        var du: ?*DisplayUpdater = null;
        var mp: ?*MusicProps = null;
        var controls2: ?*Smtc2 = null;
        var timeline: ?*TimelineProps = null;
        if (ok) {
            const cc = c.?;
            // 启用四键（Play/Pause/Next/Previous：系统 UI 按钮亮起）+ 初始状态
            _ = cc.vtbl.put_IsEnabled(cc, true);
            _ = cc.vtbl.put_IsPlayEnabled(cc, true);
            _ = cc.vtbl.put_IsPauseEnabled(cc, true);
            _ = cc.vtbl.put_IsNextEnabled(cc, true);
            _ = cc.vtbl.put_IsPreviousEnabled(cc, true);
            _ = cc.vtbl.put_PlaybackStatus(cc, MediaPlaybackStatus_Stopped);
            // 显示元数据：Type=Music + MusicProperties
            if (cc.vtbl.get_DisplayUpdater(cc, &du) == S_OK and du != null) {
                _ = du.?.vtbl.put_Type(du.?, MediaPlaybackType_Music);
                if (du.?.vtbl.get_MusicProperties(du.?, &mp) != S_OK or mp == null) ok = false;
            } else ok = false;
        }
        // STMTC2（时间线）+ TimelineProperties 实例（可选增强，失败不致命）
        if (ok) {
            var p2: ?*anyopaque = null;
            const u: *UnknownLike = @ptrCast(@alignCast(c.?));
            if (u.vtbl.QueryInterface(u, &IID_Smtc2, &p2) == S_OK and p2 != null) {
                controls2 = @ptrCast(@alignCast(p2.?));
                var tl_h: HSTRING = null;
                if (g_cb.?.WindowsCreateString(class_timeline_w.ptr, class_timeline_w.len, &tl_h) == S_OK) {
                    defer _ = g_cb.?.WindowsDeleteString(tl_h);
                    var inst: ?*anyopaque = null;
                    if (g_cb.?.RoActivateInstance(tl_h, &inst) == S_OK and inst != null) {
                        const ins: *UnknownLike = @ptrCast(@alignCast(inst.?));
                        var tl_p: ?*anyopaque = null;
                        if (ins.vtbl.QueryInterface(ins, &IID_Timeline, &tl_p) == S_OK and tl_p != null) {
                            timeline = @ptrCast(@alignCast(tl_p.?));
                        }
                        _ = ins.vtbl.Release(ins);
                    }
                }
            }
        }
        if (!ok) {
            if (timeline) |t| unkRelease(t);
            if (controls2) |c2| unkRelease(c2);
            if (mp) |m| unkRelease(m);
            if (du) |dup| unkRelease(dup);
            if (c) |cc| unkRelease(cc);
            if (cm) |m2| unkRelease(m2);
            if (player) |pp| unkRelease(pp); // SMTC 会话归 MediaPlayer 持有，最后放
            g_sta_state.store(2, .release);
            return;
        }
        self.controls = c;
        self.controls2 = controls2;
        self.updater = du;
        self.music = mp;
        self.timeline = timeline;
        self.media_player = player;
        // ButtonPressed 事件：默认【不注册】。取证结论（2026-10，Win 内测版
        // 28120）：MC.dll（Windows.Media.MediaControl.dll）的 fire 路径
        // （EventInvocationContext::AsyncEventWorkCallback → GitInvokeHelper）
        // 调用已注册委托的包装 lambda 时命中自身堆上的已释放对象（freed fill
        // 0xABAB…，jmp rax 崩溃），进程直接死亡。handler 形态（agile/FTM、
        // 非 agile、弱引用、getIids 实值）、初始化顺序、获取路径（interop/
        // MediaPlayer）、套间（STA/MTA/CoInit）、进程形态（有无 MF/MTA）、
        // 稀疏包身份——全部组合复现；MusicPlayer2（WRL/MFC）同机却可用，
        // 残余差异无法定位。注册它 = 用户点 Win+A 播放按钮就杀掉播放器，
        // 比按钮无效严重得多。AM_SMTC_BTNEVENTS=1 可强制启用（实验/系统
        // 修复后验证），冒烟 NO_HOTKEY 浸润也依赖它验证防崩。
        {
            var bt_buf: [8]u8 = undefined;
            const bt_n = GetEnvironmentVariableA("AM_SMTC_BTNEVENTS", &bt_buf, bt_buf.len);
            if (bt_n > 0 and bt_n < bt_buf.len) {
                var token: i64 = 0;
                const add_hr = c.?.vtbl.add_ButtonPressed(c.?, &g_handler, &token);
                if (add_hr == S_OK) self.btn_token = token;
            }
        }
        // 媒体键：win32k 全局热键（注册放最后——前面任何一步失败都不该留下
        // 无人泵消息的全局热键，否则媒体键会被全局吞掉且无响应）。
        // MOD_NOREPEAT 防长按连发；被其他进程占用时该键静默失效。
        // AM_SMTC_NO_HOTKEY=1 跳过（冒烟实验用：让按键进 SMTC 路由验证
        // ButtonPressed fire 链路）。
        var no_hotkey_buf: [4]u8 = undefined;
        const no_hotkey = GetEnvironmentVariableA("AM_SMTC_NO_HOTKEY", &no_hotkey_buf, no_hotkey_buf.len) > 0;
        if (!no_hotkey) {
            for (hotkeys) |hk| _ = RegisterHotKey(self.hwnd, hk.id, MOD_NOREPEAT, hk.vk);
        }
        g_sta_state.store(1, .release);
        // 消息泵：WM_HOTKEY → 位标志；WM_APP_REQ → 消费主线程请求
        var msg: MSG = undefined;
        while (GetMessageW(&msg, null, 0, 0) > 0) {
            _ = DispatchMessageW(&msg);
            if (msg.message == WM_HOTKEY) {
                for (hotkeys) |hk| {
                    if (msg.wParam == @as(usize, @intCast(hk.id))) {
                        _ = g_btn_flags.fetchOr(hk.bit, .release);
                    }
                }
            } else if (msg.message == WM_APP_REQ) {
                self.staProcessReq();
            }
            if (g_quit.load(.acquire)) break;
        }
        // 拆除（这些对象只在 STA 线程触碰）
        for (hotkeys) |hk| _ = UnregisterHotKey(self.hwnd, hk.id);
        if (self.controls) |cc| {
            if (self.btn_token != 0) _ = cc.vtbl.remove_ButtonPressed(cc, self.btn_token);
        }
        if (self.timeline) |t| unkRelease(t);
        if (self.controls2) |c2| unkRelease(c2);
        if (self.music) |m| unkRelease(m);
        if (self.updater) |dup| unkRelease(dup);
        if (self.controls) |cc| unkRelease(cc);
        if (self.hwnd) |hw| _ = DestroyWindow(hw);
        self.controls = null;
        self.controls2 = null;
        self.updater = null;
        self.music = null;
        self.timeline = null;
        // MediaPlayer 最后释放——SMTC 会话随之消亡
        if (self.media_player) |pl| unkRelease(pl);
        self.media_player = null;
        g_sta_state.store(0, .release);
    }

    /// 消费主线程请求（STA 线程；WM_APP_REQ 唤醒后清空各槽）
    fn staProcessReq(self: *Session) void {
        while (true) {
            while (!g_req_mutex.tryLock()) std.atomic.spinLoopHint();
            const track = g_track;
            const pause = g_pause;
            const tl = g_timeline;
            g_track.pending = false;
            g_pause.pending = false;
            g_timeline.pending = false;
            g_req_mutex.unlock();
            if (!track.pending and !pause.pending and !tl.pending) return;
            if (track.pending) {
                if (self.updater) |u| {
                    if (self.music) |mp| {
                        if (hstrFromUtf16(track.title[0..track.title_len])) |h| {
                            defer _ = g_cb.?.WindowsDeleteString(h);
                            _ = mp.vtbl.put_Title(mp, h);
                        }
                        if (hstrFromUtf16(track.artist[0..track.artist_len])) |h| {
                            defer _ = g_cb.?.WindowsDeleteString(h);
                            _ = mp.vtbl.put_Artist(mp, h);
                        }
                        if (hstrFromUtf16(track.album[0..track.album_len])) |h| {
                            defer _ = g_cb.?.WindowsDeleteString(h);
                            _ = mp.vtbl.put_Album(mp, h);
                        }
                        _ = u.vtbl.Update(u);
                    }
                }
            }
            if (pause.pending) {
                if (self.controls) |c| {
                    _ = c.vtbl.put_PlaybackStatus(c, if (pause.paused) MediaPlaybackStatus_Paused else MediaPlaybackStatus_Playing);
                }
            }
            if (tl.pending) {
                const now = GetTickCount64();
                if (self.last_tl_ms != 0 and now - self.last_tl_ms < TIMELINE_MIN_MS) continue;
                self.last_tl_ms = now;
                const c2 = self.controls2 orelse continue;
                const tl_props = self.timeline orelse continue;
                const pos: i64 = @intFromFloat(@max(tl.pos_s, 0) * 1e7);
                const end: i64 = @intFromFloat(@max(tl.dur_s, 0) * 1e7);
                _ = tl_props.vtbl.put_StartTime(tl_props, .{ .duration = 0 });
                _ = tl_props.vtbl.put_MinSeekTime(tl_props, .{ .duration = 0 });
                _ = tl_props.vtbl.put_EndTime(tl_props, .{ .duration = end });
                _ = tl_props.vtbl.put_MaxSeekTime(tl_props, .{ .duration = end });
                _ = tl_props.vtbl.put_Position(tl_props, .{ .duration = pos });
                _ = c2.vtbl.UpdateTimelineProperties(c2, tl_props);
            }
        }
    }

    /// detach：投递 quit 并等待 STA 线程完成拆除（热键反注册/释放/销毁
    /// 窗口全在 STA 线程做——对象 apartment 归属）。
    pub fn detach(self: *Session) void {
        if (g_relay != null) {
            relayDetach();
            return;
        }
        const t = self.thread orelse return;
        g_quit.store(true, .release);
        if (self.hwnd) |h| _ = PostMessageW(h, WM_APP_REQ, 0, 0); // 唤醒阻塞的泵
        t.join();
        self.thread = null;
        self.hwnd = null;
    }

    /// 切曲时更新元数据。title 格式沿用 mpv 后端惯例："歌名 - 歌手"
    /// （app 侧组装；无 " - " 分隔时整串进标题，歌手留空）。
    pub fn setTrack(self: *Session, title_artist: []const u8) void {
        const cut = splitTitleArtist(title_artist);
        self.setTrackMeta(cut.title, cut.artist, "", "");
    }

    /// 全量元数据（显式字段，不走 " - " 拆分启发式）。album/cover_url
    /// 可为空串；cover_url 为空 = 无封面（relay 收 T 即清旧封面）。
    pub fn setTrackMeta(self: *Session, title: []const u8, artist: []const u8, album: []const u8, cover_url: []const u8) void {
        if (g_sta_state.load(.acquire) != 1) return;
        while (!g_req_mutex.tryLock()) std.atomic.spinLoopHint();
        g_track = .{};
        g_track.title_len = utf8ToUtf16Fixed(&g_track.title, title);
        g_track.artist_len = utf8ToUtf16Fixed(&g_track.artist, artist);
        g_track.album_len = utf8ToUtf16Fixed(&g_track.album, album);
        const cov_n = @min(cover_url.len, g_track.cover.len);
        @memcpy(g_track.cover[0..cov_n], cover_url[0..cov_n]);
        g_track.cover_len = @intCast(cov_n);
        g_track.pending = true;
        g_req_mutex.unlock();
        notifyReq(self);
    }

    pub fn setPaused(self: *Session, paused: bool) void {
        if (g_sta_state.load(.acquire) != 1) return;
        while (!g_req_mutex.tryLock()) std.atomic.spinLoopHint();
        g_pause = .{ .pending = true, .paused = paused };
        g_req_mutex.unlock();
        notifyReq(self);
    }

    /// 每 tick（来自 mf.drain）：投递时间线刷新（STA 侧 500ms 节流）。
    pub fn pump(self: *Session, pos_s: f64, dur_s: f64) void {
        if (g_sta_state.load(.acquire) != 1) return;
        while (!g_req_mutex.tryLock()) std.atomic.spinLoopHint();
        // 事件类请求（切曲/暂停）未消费时不投时间线：既不覆盖它们，
        // 也避免一次唤醒里被节流逻辑跳过的时间线挤掉真正要紧的状态
        if (g_track.pending or g_pause.pending) {
            g_req_mutex.unlock();
            return;
        }
        g_timeline = .{ .pending = true, .pos_s = pos_s, .dur_s = dur_s };
        g_req_mutex.unlock();
        notifyReq(self);
    }

    /// 请求唤醒：relay 模式 SetEvent 唤醒 writer 线程；STA 模式
    /// PostMessage 唤醒泵。
    fn notifyReq(self: *Session) void {
        if (g_relay) |*r| {
            if (r.alive.load(.acquire) == 1) {
                if (r.wake) |w| _ = SetEvent(w);
                return;
            }
        }
        if (self.hwnd) |h| _ = PostMessageW(h, WM_APP_REQ, 0, 0);
    }

    /// 取走一次媒体键事件（主线程；play_pause 优先）。
    pub fn takeButton(self: *Session) ?MediaButton {
        _ = self; // 标志是文件级全局，无 per-session 状态
        const flags = g_btn_flags.swap(0, .acq_rel);
        if (flags & 1 != 0) return .play_pause;
        if (flags & 2 != 0) return .next;
        if (flags & 4 != 0) return .prev;
        return null;
    }
};

const IInspectableLike = UnknownLike;

/// "歌名 - 歌手" 拆分（最后一个 " - "；与 app 侧组装格式对应）
pub fn splitTitleArtist(s: []const u8) struct { title: []const u8, artist: []const u8 } {
    if (std.mem.lastIndexOf(u8, s, " - ")) |i| {
        return .{ .title = s[0..i], .artist = s[i + 3 ..] };
    }
    return .{ .title = s, .artist = "" };
}

// ────────────────────────── 非 windows 占位 ──────────────────────────

/// 非 windows 目标下同形 stub（player.zig 的 .mf 臂引用，零开销）。
pub const UnsupportedSession = struct {
    pub fn attach(self: *UnsupportedSession, gpa: std.mem.Allocator) void {
        _ = self;
        _ = gpa;
    }
    pub fn detach(self: *UnsupportedSession) void {
        _ = self;
    }
    pub fn setTrack(self: *UnsupportedSession, title_artist: []const u8) void {
        _ = self;
        _ = title_artist;
    }

    /// 非 Windows 桩：元数据增强仅 Windows 有接收方
    pub fn setTrackMeta(self: *UnsupportedSession, title: []const u8, artist: []const u8, album: []const u8, cover_url: []const u8) void {
        _ = self;
        _ = title;
        _ = artist;
        _ = album;
        _ = cover_url;
    }
    pub fn setPaused(self: *UnsupportedSession, paused: bool) void {
        _ = self;
        _ = paused;
    }
    pub fn pump(self: *UnsupportedSession, pos_s: f64, dur_s: f64) void {
        _ = self;
        _ = pos_s;
        _ = dur_s;
    }
    pub fn takeButton(self: *UnsupportedSession) ?MediaButton {
        _ = self;
        return null;
    }
};

pub const Impl = if (supported) Session else UnsupportedSession;

// ────────────────────────── 测试 ──────────────────────────

test "splitTitleArtist：最后一段 ' - ' 分隔" {
    const a = splitTitleArtist("ユキハナソウ - 水城新人");
    try std.testing.expectEqualStrings("ユキハナソウ", a.title);
    try std.testing.expectEqualStrings("水城新人", a.artist);
    // 多段 " - "：取最后一段分隔（歌名里含分隔符时归属标题）
    const b = splitTitleArtist("A - B - C");
    try std.testing.expectEqualStrings("A - B", b.title);
    try std.testing.expectEqualStrings("C", b.artist);
    // 无分隔：整串进标题
    const c = splitTitleArtist("只有标题");
    try std.testing.expectEqualStrings("只有标题", c.title);
    try std.testing.expectEqualStrings("", c.artist);
}

test "vtable 尺寸与投影方法数一致" {
    if (comptime !supported) return error.SkipZigTest;
    const u = @sizeOf(usize);
    try std.testing.expectEqual(7 * u, @sizeOf(MediaPlayer2.VTable));
    try std.testing.expectEqual(18 * u, @sizeOf(MediaPlayer3.VTable));
    try std.testing.expectEqual(8 * u, @sizeOf(CommandManager.VTable));
    try std.testing.expectEqual(36 * u, @sizeOf(Smtc.VTable));
    try std.testing.expectEqual(13 * u, @sizeOf(Smtc2.VTable));
    try std.testing.expectEqual(18 * u, @sizeOf(DisplayUpdater.VTable));
    try std.testing.expectEqual(12 * u, @sizeOf(MusicProps.VTable));
    try std.testing.expectEqual(16 * u, @sizeOf(TimelineProps.VTable));
    try std.testing.expectEqual(7 * u, @sizeOf(ButtonArgs.VTable));
    try std.testing.expectEqual(7 * u, @sizeOf(ButtonHandler.VTable));
    // MSG 必须与 SDK 布局同大小（PeekMessageW 按 SDK 尺寸整块写入）
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(MSG));
}

test "媒体键位图映射（WM_HOTKEY id → 位标志）" {
    for (hotkeys, 0..) |hk, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i + 1)), hk.id);
        try std.testing.expect(hk.bit == 1 or hk.bit == 2 or hk.bit == 4);
    }
}
