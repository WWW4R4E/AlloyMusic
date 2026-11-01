# Media Foundation 播放后端规划（Windows COM）

> 分支 `feat/media-foundation`。目标：Windows 上没有 mpv 时，用系统自带的 Media Foundation（纯 COM，零外部二进制）兜底真播放，替代现在的"假进度"降级。
> 本文所有 GUID / 枚举 / vtable 顺序均已对照**本机 Windows SDK 10.0.22621** 的 `um/*.idl|*.h` 逐条核实，搓码时照抄即可，不要再凭记忆写。
> Zig 0.17.0（Writergate 时代 std）——std 相关事实见 §3.7。

> **✅ 状态：已实现并真机验证通过（2026-10-28）。** 内置 WAV 冒烟全链路（打开/时长/推进/暂停/seek/resume/EOF/换曲）通过，真机 TUI 播放本地 MP3 与网络 URL 正常。实现与规划的一致与偏差见下方「实施记录」。

## 实施记录（真机踩坑，按发现顺序）

规划时静态核实了 GUID/vtable/枚举，但有几处**运行时语义**只有真机才能暴露，记录如下（后续搓 COM 都值得引以为戒）：

1. **拓扑源节点必须挂 presentation descriptor**。只设 `SOURCE` + `STREAM_DESCRIPTOR` 时 `SetTopology` 返回 `0xC00D5217 MF_E_TOPO_MISSING_PRESENTATION_DESCRIPTOR`。三个 Unknown 属性（`MF_TOPONODE_SOURCE=58ec` / `MF_TOPONODE_PRESENTATION_DESCRIPTOR=58ed` / `MF_TOPONODE_STREAM_DESCRIPTOR=58ee`）是 SDK GUID 表里的三连号，缺一不可。诊断靠 `buildAndSetTopology` 的阶段码（1~17）+ `topo_hr` 原始 HRESULT，`amtui-mfsmoke` 打印。
2. **`MESessionTopologyStatus` 在拓扑生命周期内连发多条**（READY=100 → STARTED_SOURCE=200 → SINK_SWITCHED=300 → …），事件类型全部相同，必须用 `IMFMediaEvent::GetUINT32(&MF_EVENT_TOPOLOGY_STATUS)` 解出属性值，**仅 READY(100) 触发 Start**。把每条都当 READY 会导致播放开始后 200/300 事件再次 Start、进度反复重置回 0（现象：完全无声）。状态机抽成纯函数 `eventAction(事件类型) → 动作` 加单测（覆盖 200/300/400 忽略用例）。
3. **`Start(NULL, NULL)` ≠ 从头播**。NULL 时间语义是"从当前位置"；规范写法是 `Start(NULL, &VT_EMPTY)`。
4. **编译期错误**：Zig 0.17 中 `if (fn返回u32) {...}` 不再隐式转 bool（`buildAndSetTopology` 返回阶段码，需 `== 0` 判断）——编译器直接报，无运行时风险，列此备忘。
5. **诊断方法论**：`mf_smoke.zig` 的失败消息必须带阶段码与 HRESULT 原始值（`@bitCast` i32→u32 打印十六进制）， MF 的 HRESULT 只能靠值查 `mferror.h`。

## 0. TL;DR

- 新增 `src/core/mf.zig`：Media Foundation 后端（`MFCreateMediaSession` + 手搓 COM vtable + 轮询事件队列，无回调）。
- 新增 `src/core/player.zig`：后端派发层，暴露与 `mpv.Player` 同形的 API。启动链：**mpv spawn 成功 → mpv；失败（仅 Windows）→ MF；都失败 → 假进度**。
- `app.zig` 约 25 处 `self.mpv.*` 机械改名 `self.player.*`；新增一处 MF 专属的 eof 自动前进；预取 append 在 MF 下跳过。
- `build.zig`：修一个现存 bug（Windows 原生目标 early-return 导致 `zig build test` 步骤根本没注册），新增 `mfsmoke` 冒烟（本地 WAV 真播放，无网络）。
- 平台门：mf.zig 全部 COM 代码只在 windows 目标进入语义分析（comptime 惰性分支），linux/mac 交叉编译零 COM 符号。

## 1. 背景与目标

- 现状：`core/mpv.zig` 以裸名 spawn `mpv`（CreateProcess 搜 PATH），JSON IPC 控制播放；mpv 缺失/连不上 → 假进度（无声）。Windows 无"系统 mpv"，没装的用户无法真播放。
- 目标：Windows 上走系统自带解码栈 Media Foundation，不要求用户下载任何东西。
- 排除项：`libmpv-2.dll` 路线不算系统依赖（Windows 不自带，仍要下载）。
- 决策：MF 是**兜底**不是替代——有 mpv 的用户继续享受 mpv 的播放列表 append 无感衔接；MF 没有播放列表概念，曲间前进由 app 驱动（有 1~2s 取链接空隙，见 §9）。

## 2. 架构设计

### 2.1 分层

```
ui/app.zig (编排)
   │  只认 player.zig 的接口（同形于原 mpv.Player）
   ▼
core/player.zig (派发: kind = none|mpv|mf)
   ├── core/mpv.zig   原 mpv 子进程 + JSON IPC（全平台，不动）
   └── core/mf.zig    Media Foundation COM（仅 windows 编译门内生效）
         └── ole32/mfplat/mf 三个 DLL，std.os.windows raw 调用（风格同 ipc.zig）
```

### 2.2 后端决策链

- `player.startAsync()`（首次播放时调，保持现有懒启动语义）：
  1. `kind == .none` → 尝试 mpv spawn（`std.process.spawn`，失败极快，无阻塞）；成功 → `kind = .mpv`。
  2. mpv spawn 失败 且 `builtin.os.tag == .windows`（comptime 判断）→ `mf.startAsync()`（CoInitializeEx + MFStartup + MFCreateMediaSession，全本地快速调用，无网络）；成功 → `kind = .mf`。
  3. 都失败 → 返回 false，app 维持假进度（文案改为"未找到播放后端"）。
- `player.tickConnect()`：
  - `.mpv`：沿用现逻辑（socket/管道逐 tick 重试，20 次放弃）。
  - `.mpv` 放弃（`child == null`）且 windows → **自动切 `.mf`**（`used_fallback = true`，app 可据此提示"mpv 不可用，已改用 Media Foundation"）。
  - `.mf`：startAsync 成功即 available（session 已建），直接 true。
- `player.gaveUp()`：全后端放弃 → app 走假进度（非 windows 的 mpv 放弃、或 windows 的 COM 初始化失败）。

### 2.3 平台编译门（关键机制）

- `mf.zig` 结构：

  ```zig
  pub const supported = builtin.os.tag == .windows;
  pub const Player = if (supported) MfPlayer else UnsupportedPlayer; // 同形 stub，全方法返回 false/void
  ```

- `MfPlayer` 每个方法体首行 `if (comptime !supported) return <默认值>;`——`builtin.os.tag` 是 comptime 已知，**false 分支整体不被语义分析**，extern 声明与 COM 调用在 linux/mac 上零分析、零链接引用（与 ipc.zig 的 comptime 分支同思路）。
- `player.zig` 的派发臂同样 comptime 门控（`.mf` 分支在非 windows 目标下不可达），双保险。
- 验收：`zig build -Dtarget=x86_64-linux-gnu test` 与 `-Dtarget=aarch64-macos test` 必须编译通过（§8）。

## 3. COM 事实清单（本机 SDK 已核实）

### 3.1 接口 IID

| 接口 | IID |
|---|---|
| IMFMediaSession | 90377834-21D0-4dee-8214-BA2E3E6C1127 |
| IMFMediaSource | 279a808d-aec7-40c8-9c6b-a6b492c78a66 |
| IMFTopology | 83CF873A-F6DA-4bc8-823F-BACFD55DC433 |
| IMFTopologyNode | 83CF873A-F6DA-4bc8-823F-BACFD55DC430 |
| IMFGetService | fa993888-4383-415a-a930-dd472a8cf6f7 |
| IMFPresentationClock | 868CE85C-8EA9-4f55-AB82-B009A910A805 |
| IMFPresentationDescriptor | 03cb2711-24d7-4db6-a17f-f3a7a479a536 |
| IMFStreamDescriptor | 56c03d9c-9dbb-45f5-ab4b-d80f47c05938 |
| IMFMediaTypeHandler | e93dcf6c-4b07-4e1e-8123-aa16ed6eadf5 |
| IMFAttributes | 2cd2d921-c447-44a7-a13c-4adabfc247e3 |
| IMFMediaEvent | DF598932-F10C-4E39-BBA2-C308F101DAA3 |
| IMFMediaEventGenerator | 2CD0BD52-BCD5-4B89-B62C-EADC0C031E7D |
| IMFSimpleAudioVolume | 089EDF13-CF71-4338-8D13-9E569DBDC319 |
| IMFActivate | 7FEE9E9A-4A89-47a6-899C-B6A53A70FB67 |

GUID 解析直接用 `std.os.windows.GUID.parse("{XXXXXXXX-...}")`（**必须带花括号**，源码 assert `s[0]=='{'`、`s[37]=='}'`）。

### 3.2 属性 / 服务 / 事件 GUID

| 名称 | GUID | 用途 |
|---|---|---|
| MF_TOPONODE_SOURCE | 835c58ec-e075-4bc7-bcba-4de000df9ae6 | 源节点挂 IMFMediaSource（SetUnknown） |
| MF_TOPONODE_STREAM_DESCRIPTOR | 835c58ee-e075-4bc7-bcba-4de000df9ae6 | 源节点挂流描述符（SetUnknown） |
| MF_TOPONODE_STREAMID | 14932f9b-9087-4bb4-8412-5167145cbe04 | 源节点流 id = 0（SetUINT32） |
| MF_TOPONODE_NOSHUTDOWN_ON_REMOVE | 14932f9c-9087-4bb4-8412-5167145cbe04 | 置 0：拓扑被移除时 MF 自动 Shutdown 源（换曲不泄漏） |
| MF_PD_DURATION | 6c990d33-bb8e-477a-8598-0d5d96fcd88a | PD 上取时长（GetUINT64，100ns） |
| MF_EVENT_TOPOLOGY_STATUS | 30C5018D-9A53-454b-AD9E-6D5F8FA7C43B | MESessionTopologyStatus 事件上读状态（GetUINT32） |
| MR_POLICY_VOLUME_SERVICE | 1abaa2ac-9d3b-47c6-ab48-c5950606de784d | 从 session 取 IMFSimpleAudioVolume（MFGetService） |
| MFMediaType_Audio | 73647561-0000-0010-8000-00AA00389B71 | 选音频流时比对 GetMajorType |

> 音量选 `IMFSimpleAudioVolume`（MR_POLICY_VOLUME_SERVICE，官方 MFPlayer 样例同款），不用逐声道的 IMFAudioStreamVolume（IID 76B1BBDB-…，备用）。
> 服务必须在 TOPOLOGY READY 之后取（MSDN：READY 前 GetService 语义未定）。

### 3.3 枚举与常量

| 名称 | 值 |
|---|---|
| MEError | 1 |
| MESessionTopologySet / TopologiesCleared / Started / Paused / Stopped / Closed / Ended | 101 / 102 / 103 / 104 / 105 / 106 / 107 |
| MESessionTopologyStatus | 111 |
| MEEndOfPresentation / MEEndOfStream | 211 / 212 |
| MF_TOPOSTATUS_READY | **100**（STARTED_SOURCE=200, DYNAMIC_CHANGED=210, SINK_SWITCHED=300, ENDED=400） |
| MF_TOPOLOGY_TYPE：OUTPUT_NODE / SOURCESTREAM_NODE | 0 / 1 |
| MFCLOCK_STATE：INVALID / RUNNING / STOPPED / PAUSED | 0 / 1 / 2 / 3 |
| MF_EVENT_FLAG_NO_WAIT | 0x1（GetEvent 非阻塞轮询） |
| MF_RESOLUTION_MEDIASOURCE | 0x1 |
| MFSESSION_SETTOPOLOGY_IMMEDIATE（备用） | 0x1 |
| MF_VERSION | 0x00020070（MF_SDK_VERSION 0x0002 << 16 \| MF_API_VERSION 0x0070） |
| MFSTARTUP_NOSOCKET | 0x1（**不用**：要网络源，flags 传 0） |
| MF_E_NO_EVENTS_AVAILABLE | 0xC00D3E80 |
| VT_EMPTY / VT_I8 | 0 / 20 |
| COINIT_MULTITHREADED | 0x0 |
| MF_OBJECT_TYPE：MEDIASOURCE / BYTESTREAM | 0 / 1 |

### 3.4 接口 vtable 顺序（槽位 = 下标；`Remote*`/`[call_as]` 是 MIDL 编组辅助，**不进 vtable**）

继承链槽位 = 父接口全部槽位 + 自身方法。`IMFAttributes` 是绝大多数 MF 接口的前缀（30 个方法，槽 0–32；QI=0 AddRef=1 Release=2）。

**IMFAttributes（30 方法，槽 3–32）**：GetItem(3), GetItemType(4), CompareItem(5), Compare(6), **GetUINT32(7)**, **GetUINT64(8)**, GetDouble(9), GetGUID(10), GetStringLength(11), GetString(12), GetAllocatedString(13), GetBlobSize(14), GetBlob(15), GetAllocatedBlob(16), GetUnknown(17), SetItem(18), DeleteItem(19), DeleteAllItems(20), **SetUINT32(21)**, SetUINT64(22), SetDouble(23), SetGUID(24), SetString(25), SetBlob(26), **SetUnknown(27)**, LockStore(28), UnlockStore(29), GetCount(30), GetItemByIndex(31), CopyAllItems(32)。
（注意：本 SDK 的 IMFAttributes **没有** SetStringLength，别手滑补进去。）

**IMFMediaEventGenerator（槽 0–6）**：QI, AddRef, Release, **GetEvent(3)**, BeginGetEvent(4), EndGetEvent(5), QueueEvent(6)。

**IMFMediaSession**：eventgen 7 槽 + SetTopology(7), ClearTopologies(8), **Start(9)**, **Pause(10)**, Stop(11), Close(12), Shutdown(13), **GetClock(14)**, GetSessionCapabilities(15), GetFullTopology(16)。

**IMFMediaSource**：eventgen 7 槽 + GetCharacteristics(7), **CreatePresentationDescriptor(8)**, Start(9), Stop(10), Pause(11), Shutdown(12)。（GetSourceAttributes 起属于 IMFMediaSourceEx，别算进来。）

**IMFSourceResolver（槽 0–9）**：QI, AddRef, Release, **CreateObjectFromURL(3)**, CreateObjectFromByteStream(4), BeginCreateObjectFromURL(5), EndCreateObjectFromURL(6), BeginCreateObjectFromByteStream(7), EndCreateObjectFromByteStream(8), CancelObjectCreation(9)。

**IMFPresentationDescriptor**：attrs 33 槽 + **GetStreamDescriptorCount(33)**, **GetStreamDescriptorByIndex(34)**（签名带 `BOOL* pfSelected` 出参）, **SelectStream(35)**, DeselectStream(36), Clone(37)。
（方法名就是 `GetStreamDescriptorByIndex`，MSDN 同名；没有 `GetStreamDescriptor`。）

**IMFStreamDescriptor**：attrs 33 槽 + GetStreamIdentifier(33), **GetMediaTypeHandler(34)**。

**IMFMediaTypeHandler（槽 0–8）**：QI, AddRef, Release, IsMediaTypeSupported(3), GetMediaTypeCount(4), GetMediaTypeByIndex(5), SetCurrentMediaType(6), GetCurrentMediaType(7), **GetMajorType(8)**。

**IMFTopology**：attrs 33 槽 + GetTopologyID(33), **AddNode(34)**, RemoveNode(35), GetNodeCount(36), GetNode(37), Clear(38), CloneFrom(39), GetNodeByID(40), GetSourceNodeCollection(41), GetOutputNodeCollection(42)。

**IMFTopologyNode**：attrs 33 槽 + **SetObject(33)**, GetObject(34), GetNodeType(35), GetTopoNodeID(36), SetTopoNodeID(37), GetInputCount(38), GetOutputCount(39), **ConnectOutput(40)**, DisconnectOutput(41), GetInput(42), GetOutput(43), SetOutputPrefType(44), GetOutputPrefType(45), SetInputPrefType(46), GetInputPrefType(47), CloneFrom(48)。

**IMFClock（槽 0–7）**：QI, AddRef, Release, GetClockCharacteristics(3), GetCorrelatedTime(4), GetContinuityKey(5), **GetState(6)**, GetProperties(7)。

**IMFPresentationClock**：IMFClock 8 槽 + SetTimeSource(8), GetTimeSource(9), **GetTime(10)**（100ns，i64）。

**IMFGetService（槽 0–3）**：QI, AddRef, Release, **GetService(3)**。

**IMFSimpleAudioVolume（槽 0–6）**：QI, AddRef, Release, **SetMasterVolume(3)**, GetMasterVolume(4), SetMute(5), GetMute(6)。

**IMFActivate**：attrs 33 槽 + ActivateObject(33), ShutdownObject(34), DetachObject(35)——只当 IUnknown 传给 SetObject，不调方法，可不声明方法。

### 3.5 DLL 导出归属（对本机 System32 DLL 导出表核实）

| 函数 | DLL |
|---|---|
| MFStartup / MFShutdown | **mfplat** |
| MFCreateMediaSession | **mf** |
| MFCreateSourceResolver | **mf** |
| MFCreateTopology / MFCreateTopologyNode | **mf** |
| MFCreateAudioRendererActivate | **mf** |
| MFGetService | **mf** |
| CoInitializeEx / CoUninitialize | **ole32** |

Zig 对 `extern "dllname"` 自动生成导入库（ipc.zig 的 `extern "kernel32"` 同理），无需 SDK .lib。本机 SDK 只装了头文件没装 Libs，也无所谓。

### 3.6 关键签名

```c
// mfplat
HRESULT MFStartup(ULONG Version, DWORD dwFlags);      // MFStartup(0x00020070, 0)
HRESULT MFShutdown(void);
// mf
HRESULT MFCreateSourceResolver(IMFSourceResolver **ppResolver);
HRESULT MFCreateMediaSession(IMFAttributes *pConfig, IMFMediaSession **ppSession);
HRESULT MFCreateTopology(IMFTopology **ppTopology);
HRESULT MFCreateTopologyNode(MF_TOPOLOGY_TYPE NodeType, IMFTopologyNode **ppNode);
HRESULT MFCreateAudioRendererActivate(IMFActivate **ppActivate);
HRESULT MFGetService(IUnknown *punk, REFGUID guidService, REFGUID riid, LPVOID *ppv);
// ole32
HRESULT CoInitializeEx(LPVOID reserved, DWORD coinit);  // S_OK=0 / S_FALSE=1 都算成功
```

- `CreateObjectFromURL(LPCWSTR pwszURL, DWORD dwFlags, IPropertyStore *pProps, MF_OBJECT_TYPE *pType, IUnknown **ppObj)` —— flags = MF_RESOLUTION_MEDIASOURCE，pProps = null。**网络源打开是同步阻塞调用**（§4.2 worker 化的原因）。
- `Start(const GUID *pguidTimeFormat, const PROPVARIANT *pvarStartValue)`：从头播 = (null, null)；seek/续播 = (&GUID_NULL, VT_I8 位置 100ns)。
- `GetEvent(DWORD dwFlags, IMFMediaEvent **ppEvent)`：NO_WAIT 下队空返回 MF_E_NO_EVENTS_AVAILABLE。
- `GetState(DWORD dwFlags, MFCLOCK_STATE *pState)`：dwFlags 传 0。
- `GetStreamDescriptorByIndex(DWORD idx, BOOL *pfSelected, IMFStreamDescriptor **ppSD)`。
- `SelectStream(DWORD dwDescriptorIndex)`（单参数）。
- `ConnectOutput(DWORD dwOutputIndex, IMFTopologyNode *pDownstream, DWORD dwInputIndexOnDownstream)`。
- PROPVARIANT：std 无定义，自声明 `{ vt: u16, r1..r3: u16, val: extern union { i64, u32, ?*anyopaque } }`（24 字节 8 对齐）。
- HRESULT：std 无定义，自声明 `const HRESULT = i32;`。

### 3.7 Zig 0.17.0 std 事实（本机实测）

- **没有** `std.os.windows.HRESULT`（自声明 i32）。有 `std.os.windows.GUID`（含 `parse`）。
- **没有** `std.Thread.Mutex` / `std.Thread.Condition`（`std.atomic.Mutex` 只是 tryLock/unlock 自旋锁；`std.Io.Condition` 需要 io 实例，worker 原生线程用不了）。
- `std.Thread.spawn(SpawnConfig, comptime fn, args) !Thread`、`join()`、`yield()` 可用；**没有** `std.Thread.sleep`。
- ⇒ worker 节流/等待用 `extern "kernel32" fn Sleep(u32)`（与 ipc.zig 的 raw extern 风格一致），互斥用 `std.atomic.Mutex`（临界区纳秒级，自旋无所谓）+ `std.atomic.Value` 做标志位。
- COM vtable 函数指针调用约定：`callconv(.winapi)`（std 同款）。

## 4. mf.zig 详细设计

### 4.1 状态机（全部在主线程 tick 内推进，无回调）

```
idle ──loadFile(url)──▶ opening(worker 打开中)
opening ──worker 发布 ok──▶ ready           （主线程：建拓扑 + SetTopology(0)）
opening ──worker 发布 err──▶ ended(带错误)   （status().eof=true，app 自动前进跳过坏链）
ready ──(want_paused? 不 Start : Start)──▶ playing ⇄ paused
playing/paused ──MESessionEnded──▶ ended
loadFile 任何时候可打断回 opening（换曲）
```

- 事件轮询：每 tick `GetEvent(NO_WAIT)` 最多捞 16 条：
  - `MESessionTopologyStatus`(111) + `GetUINT32(MF_EVENT_TOPOLOGY_STATUS)==100` → READY：取 clock（session→GetClock→QI IMFPresentationClock）、取音量服务并套用当前音量、`want_paused` 为假才 `Start(null,null)`。
  - `MESessionStarted`(103)：若 `want_paused`（链接到达前用户按了暂停）→ 补 `Pause()`。
  - `MESessionEnded`(107)：`eof_seen = true`。
  - `MEError`(1)：`GetStatus` 记错误码（打日志/状态栏用），不改变状态机。
- position：clock `GetTime()/1e7`；duration：PD 的 MF_PD_DURATION 预读（open 线程里取，100ns→s）。clock 取不到（READY 前）按 0 处理——`status()` 对 MF **永不返回 null**（mpv 用 null 表示传输层死亡，MF 无此概念）。
- seek：`Start(&GUID_NULL, VT_I8 t*1e7)`；若处于暂停态，Start 后立即补 Pause（位置保持，声音瞬断可接受）。
- pause：`want_paused=true`；session 在播放中才调 `Pause()`（loading 期只记意图，READY 后不 Start）。
- resume：`want_paused=false`；clock 处于 PAUSED/STOPPED 且已加载 → `Start(&GUID_NULL, VT_I8 当前 GetTime)`；从未 Start 过 → 交给 READY 路径。
- volume：`MFGetService(session, MR_POLICY_VOLUME_SERVICE, IID_IMFSimpleAudioVolume)` → `SetMasterVolume(volume/100)`。READY 前调用会失败，失败只缓存意图，READY 后补。换拓扑（新 READY）重新取一次服务。

### 4.2 线程模型（worker 化打开，TUI 不冻结）

- `CreateObjectFromURL` 对 http 源是**同步网络调用**（百 ms~数秒），绝不能在主线程 tick 里做。开一条常驻 worker（player 生命周期=线程生命周期，deinit join，杜绝 UAF）：

```
主线程                          worker
──────                          ──────
loadFile(url):
  gpa dupe url
  cmd_gen += 1                  循环（每 16ms Sleep 醒一次）:
  原子发布 {url_ptr, gen}          若 cmd_gen > my_done_gen:
                                    取 url → CreateObjectFromURL
tick: 拉取 result 槽(gen 匹配才收)     → QI IMFMediaSource
  建 topology、SetTopology、         → CreatePresentationDescriptor
  Start 由 READY 事件驱动            → 读 MF_PD_DURATION
  （全部快速调用，不阻塞）            原子发布 result{src, pd, dur, gen, err}
                                    Release 自己多余的引用
deinit:
  置 quit → join（worker 不卡网络）
  MFShutdown + CoUninitialize
```

- 同步原语：`std.atomic.Value(u32)`（gen/quit）+ `std.atomic.Mutex`（保护指针槽的发布/读取）+ `Sleep(16)`。
- 快速连点：worker 串行处理，旧结果 gen 过期被主线程丢弃；v1 不做打开取消（`CancelObjectCreation` 留 TODO，§9）。
- COM 套间：主线程与 worker 都 `CoInitializeEx(MTA)`；MF 对象自由线程，跨线程传引用安全；MTA 不需要消息泵（TUI 主线程无窗口）。
- worker 只碰 resolver/source/pd；session 的所有方法只从主线程调（IMFMediaSession 非线程安全的保守处理）。

### 4.3 拓扑构建（主线程，open 成功后）

```
MFCreateTopology()
srcNode = MFCreateTopologyNode(SOURCESTREAM_NODE=1)
  SetUINT32(MF_TOPONODE_STREAMID, 0)
  SetUINT32(MF_TOPONODE_NOSHUTDOWN_ON_REMOVE, 0)   // 换曲时 MF 自动 Shutdown 旧源
  SetUnknown(MF_TOPONODE_SOURCE, source)
  SetUnknown(MF_TOPONODE_STREAM_DESCRIPTOR, audio_sd)
outNode = MFCreateTopologyNode(OUTPUT_NODE=0); outNode.SetObject(MFCreateAudioRendererActivate())
topology.AddNode(srcNode); topology.AddNode(outNode)
srcNode.ConnectOutput(0, outNode, 0)
session.SetTopology(0, topology)
```

- 选流：遍历 `GetStreamDescriptorCount` → 每个流 `GetMediaTypeHandler → GetMajorType == MFMediaType_Audio` → `SelectStream(i)`、其余 `DeselectStream(j)`；找不到音频流 → 视为 open 失败。
- 引用管理：SetUnknown/SetObject/AddRef 持有的引用靠 Release 配对；topology/nodes/activate/sd/pd/source 在 SetTopology 返回后全部 Release（session 侧持有，NOSHUTDOWN=0 保证移除时 Shutdown）；错误路径各自 Release，不泄漏。

### 4.4 API 映射（player 派发到 MF 的语义）

| player 方法 | MF 行为 |
|---|---|
| startAsync | CoInitializeEx + MFStartup + MFCreateMediaSession（快速，成功即 available） |
| tickConnect | available 直接 true |
| loadFile(url, title) | dup url 发 worker；清 eof/duration；title 无处显示，忽略（无 SMTC） |
| appendFile | **恒 false**（MF 无播放列表；app 侧因此不 append 预取，见 §6.8） |
| setPause(true/false) | 见 §4.1 |
| setVolume(u8) | IMFSimpleAudioVolume.SetMasterVolume(v/100)；服务未就绪只缓存 |
| setLoopFile | no-op（app 的 eof 前进路径天然支持单曲循环，代价是循环时重取链接，§9） |
| seekTo(f64) | Start(GUID_NULL, VT_I8)（±暂停补 Pause） |
| status() | 永不 null：{clock 位置, PD 时长, eof_seen} |
| playlistPos/Next/Prev | null / false / false（触发 app 走 pc 状态机换曲路径） |
| dropConnection | no-op |
| autoAdvances() | **false**（mpv 恒 true）：app 在 status eof 时自己调 nextSong(.eof) |
| drain(&pos,&pause) | 无外部控制器，输出恒 null（mpv 的媒体键事件通道对 MF 不存在） |

## 5. player.zig 派发层

```zig
pub const Kind = enum(u8) { none, mpv, mf };
pub const Status = mpv_mod.Status;
pub const Player = struct {
    mpv: mpv_mod.Player,
    mf: mf_mod.Player,          // 非 windows = UnsupportedPlayer stub
    kind_: Kind = .none,
    used_fallback: bool = false,
    // 方法集与 mpv.Player 同形 + 4 个新增:
    //   started() kind_ != .none；available()；gaveUp()；autoAdvances()；usedFallback()
};
```

- 派发臂用 `switch (self.kind_)`，`.mf` 臂整体 `if (comptime mf_mod.supported)` 包裹（非 windows 不可达、不分析）。
- `startAsync` 决策链与 `tickConnect` 内的 mpv→mf 自动切换见 §2.2；切换置 `used_fallback`，app 提示一次。
- `.mf` 下 `status()` 永不 null ⇒ app 的"mpv 掉线重连"分支自然不会被 MF 触发。

## 6. app.zig 接入点清单（行号基于 master b5892c3）

机械改名 `self.mpv` → `self.player`、`self.mpv.available` → `self.player.available()`、`self.mpv_started` → `self.player.started()`：

| # | 位置 | 改法 |
|---|---|---|
| 1 | L9 / L91-92 / L203 / L250 | import 换 player_mod；字段 `mpv`→`player`，删 `mpv_started`；init/deinit 对应 |
| 2 | L404 syncNext | 守卫加 `self.player.kind != .mpv 则 return`——MF 下不再发无意义的预取链接请求 |
| 3 | L450-459 requestPlayback | startAsync 块换成 `player.startAsync()`；失败文案"未找到播放后端（安装 mpv 后重启）"；`setPause` 守卫换 available() |
| 4 | L566-606 consume .play_url | append 分支维持（appendFile 对 MF 恒 false，pl_order 不动）；loadFile/setVolume/setPause/setLoopFile/syncNext 全换 player |
| 5 | L1028-1034 drain | 换 player.drain（MF 输出恒 null，无行为差异） |
| 6 | L1057-1084 tickConnect 块 | `player.tickConnect()` 成功路径原样（pending_url 补课，天然适用于切到 mf 的场景）；`else if (player.gaveUp())` 替代 `mpv.child == null` 判断；新增 `usedFallback()` 提示一次"mpv 不可用，已改用 Media Foundation" |
| 7 | L1091-1103 status 轮询 | **新增**：`if (st.eof and !player.autoAdvances()) { self.nextSong(.eof); return; }`——MF 的前进收口在这（mpv 分支不变：它 autoAdvances=true 且靠 playlist-pos 事件回环） |
| 8 | L1707 / L1899 / L1927-1945 / L1961 / L2149 / L2156-2168 | seekTo/togglePlay/next/prev/setLoopFile/音量 全换 player；MF 下 playlistPos 返回 null 自动走 pc 换曲路径，无需分支 |

- `pl_order` / `onMpvPosChange` / `syncNext` 语义不变（仅 mpv kind 生效）。
- mock 后端不触碰 player（现逻辑已如此）。

## 7. build.zig 改动

1. **修 bug**：`test` step 注册目前在 `if (windows) return;`（L34-37）之后——Windows 原生 `zig build test` 实际不存在该步骤。把 `test` step 注册移到所有平台 early-return 之前。
2. **新增 mfsmoke**（windows 分支内）：`src/core/mf_smoke.zig` → 可执行 `amtui-mfsmoke` + `zig build mfsmoke` 运行步。
3. 非 windows 的 smoke 系（unix allocator 语义）维持原样。

## 8. 测试与验收矩阵

| 项 | 命令 | 通过标准 |
|---|---|---|
| 单测（windows） | `zig build test` | 全部 test 块过（新增：GUID parse comptime 测试、状态机纯逻辑测试） |
| 交叉编译门（linux/mac） | `zig build -Dtarget=x86_64-linux-gnu test` / `-Dtarget=aarch64-macos test` | 编译通过（COM 代码零分析），证平台门有效 |
| MF 冒烟 | `zig build mfsmoke` | 生成 3s 44.1k 正弦 WAV → MF 打开 → READY → 时长≈3.0s、位置前进 >0.5s、seek 到 1.0s 生效、pause/resume 往返正常 → exit 0 |
| MF 冒烟（真链接，手动） | `zig-out/bin/amtui-mfsmoke <url 或文件>` | http 直链可播 |
| UI 回归 | `amtui snap` 系 | 帧不变（UI 不受影响） |
| 端到端手测 | 无 mpv 的 Windows 环境（或临时把 spawn 名改成 `mpv-不存在`）跑 amtui | 播放真出声，状态栏出现 MF 兜底提示；有 mpv 时行为与 master 一致 |

## 9. 已知妥协与后续路线（v1 明确不做）

1. **曲间空隙**：MF 无播放列表，eof → nextSong → 取链接（1~2s）。后续可做"app 侧预取缓存"（syncNext 的预取结果按队列下标缓存给 MF 直接用）。
2. **单曲循环重取链接**：loop-file=inf 的替代是 eof→重新 loadFile 同曲（每次循环一次取链接）。缓存方案顺带解决。
3. **无打开取消**：快速连点时 worker 串行排队打开（每次 ~1s 级）。后续 `CancelObjectCreation` + 丢弃旧 resolver。
4. **格式覆盖**：MF 原生 MP3/AAC/FLAC/ALAC/WAV（三源直链主要格式够用）；Vorbis/Opus 不保证。
5. **错误提示粒度**：open 失败仅记 HRESULT 并 eof 前进跳歌，状态栏文案从简。
6. **SMTC 元数据不含封面**：DisplayUpdater 的 Thumbnail 需要 RandomAccessStream（IRandomAccessStreamReference），手搓成本高，v1 只推标题/歌手/进度。

## 10. SMTC 接入（relay 中转架构，2026-10-30 定稿并全链路验证）

> **完整技术文档见 `docs/smtc.md`**：术语词典（handler 形态/套间/包身份/FTM/GIT…逐个
> 解释）、取证复盘、协议与坑清单、MusicPlayer2（C++/WRL，非 C#）实现对照、WSL 场景结论。

`src/core/smtc.zig` + `relay/AlloyMusic-SMTC.cs`（build.zig 用系统自带 csc 编译为 `AlloyMusic-SMTC.exe`，零外部依赖）。职能分工是本实现的核心决策：

- **SMTC 会话整体由 .NET 中转进程持有**（relay 模式，默认）：amtui spawn 同目录 `AlloyMusic-SMTC.exe`，经 `127.0.0.1:47821` 行协议交互——`T	<title>	<artist>`（曲目）、`P	0|1`（状态）、`L	<pos_ms>	<dur_ms>`（时间线）出；`B	<n>`（按键枚举值：Play=0 Pause=1 … Next=6 Previous=7，.NET 投影序）入。amtui 侧 reader 线程把按键写进与热键共用的原子位标志，`takeButton()` 下游无感知。
- **媒体键/Win+A 按钮全链路可用**：`zig build smtcsmoke` 三键断言 PASS（play_pause/next/prev 全到达，锁屏下也有效——锁屏媒体层照常路由 SMTC fire）。
- **回退路径**（relay exe 缺失或 `AM_SMTC_NORELAY=1`）：进程内 STA 线程走 MediaPlayer 托管 SMTC（仅展示）+ `RegisterHotKey` 热键媒体键（VK_MEDIA_*，WM_HOTKEY → 原子位标志）。此时 Win+A 按钮无效（不注册 ButtonPressed，见下）。

**为什么 SMTC 必须放另一个进程（2026-10-30 真机取证定论，Win 内测版 10.0.28120，勿回退）**：
MC.dll（Windows.Media.MediaControl.dll）的 ButtonPressed fire 路径存在 **use-after-free**：`EventInvocationContext<0>::AsyncEventWorkCallback → GitInvokeHelper（GIT）` 调用已注册委托的内部包装 lambda 时 `jmp` 进已释放堆块（0xABAB… freed fill），进程崩溃。用 smtcsmoke + 自制调试 harness（ctypes 调试循环 + dbghelp + MS 符号服务器 PDB）拿符号化栈确认：崩点全在 MC.dll 内部，Invoke 从未进入。**在 amtui（Zig 静态二进制）进程内穷尽以下变量均复现**：

- handler 形态：agile/FTM（IAgileObject + CoCreateFreeThreadedMarshaler）、非 agile、补 IWeakReferenceSource/IWeakReference、getIids 实值 + CoTaskMemAlloc；
- 初始化顺序：先启用后注册 / MusicPlayer2 配方（先注册后启用 + IsStopEnabled + Closed 起始）；
- 获取路径：interop GetForWindow（真窗口）/ MediaPlayer 托管；
- 套间：STA 专用线程 / MTA / 纯 CoInitializeEx（无 RoInitialize）；
- 进程形态：带 MF+MTA 的完整播放 / 无 MF 的单 STA 最小进程；
- 稀疏 MSIX 包身份（完整打通：exe 内嵌 `<msix>` 元素 + `-ExternalLocation` 注册，GetPackageFullName S_OK——对崩溃无影响）。

**旁证**：MusicPlayer2（WRL/MFC 无包）同机同 SendInput 实测可用（GSMTC 观测其会话状态随键切换）；**.NET 探针**（csc 编译的 MediaPlayer + ButtonPressed 订阅）五连发全收不崩——**MSVC/CLR 运行时进程不触发此 UAF，Zig 静态二进制触发**，残余差异无法定位（GIT 单独探针在本进程 S_OK；`RoActivateInstance(ButtonPressedEventArgs)` 恒 REGDB_E_CLASSNOTREG，疑为 args 类本就不支持按名激活）。GSMTC 客户端 API 无 ButtonPressed 事件，无法旁路。注册 handler 的后果是点一下 Win+A 播放按钮就杀掉整个播放器——relay 是唯一能同时保住展示、媒体键、Win+A 按钮的方案。

**实现细节与坑**：
- 中转以 TCP loopback 通信（匿名管道版本出现「子进程写成功、父端 ReadFile 永远收不到」的未解现象，TCP 无此问题）；端口被占 = 已有 relay 实例（单实例语义，直接连旧实例）；relay 断连 15s 无新连接自杀，收到 `Q` 立即退。
- relay 的 `WriteLine` 是 CRLF：amtui 解析前必须 trim CR。
- 按键枚举值以 .NET 投影为准（Next=6/Previous=7，与旧记忆 3/4 不同）。
- `AM_SMTC_NO_HOTKEY=1`：关热键（冒烟用）；`AM_SMTC_BTNEVENTS=1`：回退路径强制注册 ButtonPressed（实验/系统修复后验证，会触发 UAF 杀进程）；`AM_SMTC_MIN=1`：无 MF 单 STA 最小复现模式。
- **锁屏下 SendInput 注入的键不会触发 WM_HOTKEY**（F9 对照实验证实），但 SMTC fire 照常路由——冒烟须解锁后跑热键路径断言。

**包身份实验资产（2026-11-01 已删除）**：原 `AppxManifest.xml` + `assets/smtc_identity.manifest`（exe 内嵌 msix 元素）+ `assets/logo{44,150}.png`。对 UAF 无帮助（不是崩溃判别变量）；relay 落地后 SMTC 卡片归属 relay 进程，amtui 包身份无作用场景，故删。机制记录见 `docs/smtc.md` §2.6；将来要面板显示真实应用名，走 relay 侧身份/快捷方式（§5 的 .lnk 方案）。

## 11. 工作顺序 checklist

1. 建分支 `feat/media-foundation`。
2. build.zig：test step 前移 + mfsmoke 骨架（先让它编译失败/红的）。
3. mf.zig：GUID 常量 + COM 接口声明 + 平台门 + stub（先保 `zig build test` 三平台绿）。
4. mf.zig：完整实现 + mfsmoke 跑通本地 WAV（**冒烟绿灯是本分支的里程碑**）。
5. player.zig 派发层 + app.zig 接入（§6 表逐项过）。
6. 验收矩阵全跑（§8），提交。
