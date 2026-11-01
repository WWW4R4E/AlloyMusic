# AlloyMusic（bodian-tui）项目交接分析

> 写给接手的 agent：读完这一篇即可掌握项目全貌，不必逐个读源码。需要细节时按文中给出的文件/函数坐标定点去查。
> 基准：`feat/media-foundation` 工作树（2026-11-01）：Windows 适配 + MF 播放后端 + 渲染防御 + SMTC relay（单文件分发）+ auth.json 用户目录化。

## 1. 一句话概括

纯 Zig 单进程的终端多源音乐播放器：三源（网易/QQ/波点-酷我）API 直调（Node sidecar 已全量移除），UI 基于 Elm 架构框架 zigzag，播放经 `core/player.zig` 派发——优先 mpv 子进程 JSON IPC，Windows 上 mpv 不可用时降级系统自带 Media Foundation（`core/mf.zig` 纯 COM），另开放一个 loopback HTTP 只读接口给外部消费播放状态。

## 2. 构建与运行

- `build.zig.zon`：包名 `bodian_tui`，唯一依赖 **zigzag**（vendored 在 `zig-pkg/`，**严禁修改 zig-pkg/ 下依赖源码**）。构建离线模式：`zig build --system zig-pkg`。
- 产物 `amtui`（root `src/main.zig`，Zig 0.17 新式 `pub fn main(init: std.process.Init)`）。
- 其他 step：默认 `zig build` 产物只有发布所需可执行（Windows 上 relay 以字节字面量内嵌 amtui，见 §4.10）；smoke 系全部走独立 step、按需安装运行——`run`、`smoke`（`src/core/smoke.zig` 真网络冒烟）、`qqsmoke`/`bodsmoke`/`netsmoke`（直调真网络，POSIX）、`mfsmoke`（仅 Windows，`src/core/mf_smoke.zig`，无参=内置 WAV 全链路）、`smtcsmoke`（仅 Windows，`src/core/smtc_smoke.zig`，SendInput 注入三键断言 relay 全链路；`AM_SMTC_NORELAY=1` 回退路径、`AM_SMTC_NO_HOTKEY=1` 关热键、`AM_SMTC_MIN=1` 最小复现）、`test`（exe module 内所有 test 块，UI 冒烟走 mock）。
- 环境变量：`AM_BACKEND`（netease|qq|bodian|mock，默认 netease）、`AM_API_PORT`（8790，0=关）、`AM_CELL_RATIO`（封面格像素比例）、`AM_MOCK_DIR`（默认 `testdata/mock`）。
- **snap 模式**：`amtui snap --size=WxH --keys=... --out=frame.ansi` —— zigzag `testing.Harness` 假 Io 驱动按键出 ANSI 帧，是 UI 验收/回归的主要手段（mock backend）。注意 Harness 假 Io 不支持真源网络。
- **跨平台**：`zig build -Dtarget=x86_64-windows` 出 `amtui.exe`（Windows 适配见 §4.8）；smoke 系开发工具在 Windows 目标不安装。

## 3. 目录地图

```
src/
  main.zig            入口（150 行）：env 解析 + zz.Program 启动 / snap 模式
  ui/
    app.zig     (3000 行)  Model + 全部交互/播放编排/登录/封面 —— 项目核心
    provider.zig (700)     异步取数层：FetchQueue/Mailbox/epoch + JSON→model 翻译
    pages.zig   (600)      各页渲染（行模型 buildRows/detailRows/renderXxx/lyricView）
    widgets.zig (500)      Page 枚举、侧栏/顶栏/进度条/列表项/封面占位
    playmode.zig(260)      播放模式三态状态机 PlayControl（sequence/one/shuffle+洗牌袋）
    lyrics.zig / mock.zig / model.zig / theme.zig
  core/
    providers/  mod.zig    Backend 抽象 + 统一 envelope {ok:true,...}/{ok:false,code,message}
                netease.zig(1400) weapi/eapi 加密、匿名 token、QR 登录
                qq.zig     (1400) musicu.fcg 直调、风控退避、五步扫码链
                bodian.zig (940)  kuwotest MD5 签名直调、试听/like/QR
    mpv.zig     (390)      mpv JSON IPC（经 ipc.zig 传输抽象，刻意不走 std.Io 派发）
    ipc.zig     (200)      mpv IPC 传输抽象：unix socket / Windows 命名管道（comptime 选型）
    player.zig  (300)      播放后端派发层：mpv → MF（Windows）→ 假进度，公共 Player 接口
    mf.zig      (1200)     Media Foundation COM 后端（仅 Windows，手搓 vtable，见 docs/media-foundation-plan.md）
    mf_smoke.zig(200)      MF 全链路冒烟（内置 WAV / 命令行传入 URL 或本地文件）
    api_server.zig(450)    127.0.0.1:8790 只读 HTTP（/now /lyrics /health）
    http.zig    (350)      bodian 专用 HTTP 客户端 + 统一 ErrorCode/Param/Result 类型
    paths.zig   (100)      auth.json 用户数据目录定位（%APPDATA%\AlloyMusic / XDG，安装模式）
    cover.zig / jpeg.zig / qr.zig / pngqr.zig / lyrics.zig / catalog.zig / smoke*.zig
relay/                AlloyMusic-SMTC.cs（SMTC relay 源码，构建期 csc 编译后嵌入 amtui）
docs/                 agent-handoff.md（本篇）/ smtc.md / media-foundation-plan.md
testdata/mock/        离线 JSON 夹具（配 ui/mock.zig），gen_lyrics.mjs 生成
scratch/              gitignore 实验区（小程序、参考实现 qq-tui-ref、zigzag-docs）
%APPDATA%/AlloyMusic  登录态 auth.json（0600，勿提交/勿外泄；unix 为 ~/.config/alloy-music）
```

## 4. 核心架构要点

### 4.1 Elm 循环（zigzag）
Model 声明 `Msg` union（收 key/mouse/window_size/tick 四种），框架调 `init → update → view`，tick 周期 500ms。一切状态变化都收敛在 `app.zig` 的 `update`。

### 4.2 异步取数（provider.zig —— 理解本项目的关键）
- 13 种 `Kind`（search/explore/detail/lyrics/play_url/health/library/login_qr/login_check/cover/liked/radio/like），`Outcome{arena, epoch, flag, result}` 产物全部在请求专属 arena 上。
- **FetchQueue 单 worker 串行**：并发 `std.http.Client` 实测死锁，故刻意串行；`kick` 入队 + 惰性 spawn 线程。
- **Mailbox**：自旋锁多槽链表，worker push，主线程每帧 `drainFetches()` 收。
- **epoch 门控**：切源/新搜索时 `epoch+1`，search/explore/detail/health/library/liked 的过期结果直接丢弃；lyrics/cover/play_url/radio 不走 epoch，用各自 pending key（如 `backend:id|mid`、`url_pending_q`）门控晚到结果。
- 每个 Kind 的结果 arena 存 `Model.slots[i]`，新到释放旧；常驻字符串已 dupe 进模型 arena，无悬垂。

### 4.3 播放链（经 `core/player.zig` 派发）
app 只面向 `player.Player` 接口（`load/append/setPause/seek/volume/drain/status…`），`player.init` 时探测后端：mpv 可 spawn → `mpv.zig`；否则 Windows → `mf.zig`；都不可用 → 假进度（fake）。选歌 → `requestPlayback`（kick play_url job，取新链接期间先 `setPause(true)`）→ provider `opSongUrl` → Outcome 回主线程 → `player.loadFile`（replace）或 `player.appendFile`（预取下一首，`syncNext` 按 `pc.nextIndex` 计算）。连接失败时 `pending_url` 缓存，connect 后补 loadFile；mpv 懒启动（`--idle=yes --input-ipc-server=<ipc 服务名>`），断线重连。预览试听用 `preview_start_ms/end_ms`。IPC 传输经 `core/ipc.zig` 抽象（unix socket / Windows 命名管道，comptime 选型，raw 系统调用刻意不走 std.Io 派发——与并发 HTTP fetch 组合会死锁）。MF 后端细节（状态机/拓扑/事件泵）见 §4.9 与 docs/media-foundation-plan.md。

### 4.4 队列镜像与媒体键
`Model.pl_order: ArrayList(u32)` 是 mpv 内部 playlist 的 append-only 镜像（replace 时重置为 [当前歌]）——**mpv 列表顺序 = 播放顺序**，系统媒体键（MPRIS）直接驱动这份列表。TUI 侧：每 tick `mpv.drain()`；pause 事件直接翻转 `playing`（mpv 是事实源）；`playlist-pos` 事件经 `pl_order` 映射回队列下标，统一收口"mpv 自己切歌"（媒体键/自动前进），过滤自己 loadFile 的回声；列表尾转 idle 由 `nextSong(.eof)` 兜底（电台续批/绕回）。Windows MF 后端：系统媒体键经 `smtc.zig` 的 RegisterHotKey → 原子标志 → `player.takeMediaButton()`，app 侧映射 play_pause/next/prev 到与本地按键同一条动作路径（见 §4.10）。

### 4.5 三源直调（providers/）
- **netease**：`weapi()` 两层 AES-128-CBC + RSA-None（big.int modpow）、`eapi()` AES-ECB；匿名 token（缓存 /tmp/anonymous_token）；QR 登录 unikey 轮询，Set-Cookie 落盘。已知坑：songUrl `level` 缺省必须为 standard（空串会被上游按无权限处理，见 9b4476e）。
- **qq**：POST `musicu.fcg`；登录态 comm 需补 `tmeLoginType=2` + `authst`；顶层 `code=2001` 即风控 → 退避 + 轮换 HOSTS（最坏 ~18s）；迷你 cookie jar（`name@domain`，空值=过期标记）；扫码是五步链（ptqrlogin → 轮询 → ptsigx/uin → check_sig 收 p_skey → OAuth code → 换凭证）。
- **bodian**：`http.zig` 的 MD5 签名（"kuwotest"+查询串排序+body MD5）作 `sign` 参数；播放类接口必须 **GET+JSON body**（手写 content-length）；songUrl 走 checkRight + `validateAudioUrl`。
- envelope 与 sidecar 时代同构，`health()` 改为本地读 auth.json。

### 4.6 持久化
- 登录态：`core/paths.zig` 定位 auth.json（安装模式：Windows `%APPDATA%\AlloyMusic\auth.json`、unix `~/.config/alloy-music/auth.json`；解析失败兜底 cwd 旧行为）三源分节（bodian uid/token/user；netease cookie 串；qq cookie/uin/nickname），0600 读改写保留其他段。进程内解析一次缓存（page_allocator）。
- 切源：`~/.config/alloymusic/backend` 写 enum tag；`switchBackend` 只在已登录源间循环，`epoch+1` 作废在途结果；**队列跨源保留，封面跟歌走**（见 c9c051f）。

### 4.7 外部接口（api_server.zig）
127.0.0.1:8790：`GET /now`（state/seq/position_ms/song/lyrics JSON）、`GET /lyrics`（纯 LRC，无歌词=空体 200）、`GET /health`。快照法并发：UI 线程每 tick 整包 publish（自旋锁），HTTP 线程锁内拼 JSON 永不碰 Model；key=backend:id 变化则 `seq+1`。端口占用静默降级。

### 4.8 跨平台（Windows 适配，2026-10-28）

原则：单一代码库，`builtin.os.tag` **comptime 分支**选平台实现（comptime 已知分支才不参与语义分析，runtime if 门控挡不住编译期检查）。

- **`core/ipc.zig`**：`Conn = switch(builtin.os.tag)` 选 unix socket（原 raw posix）或 Windows 命名管道（kernel32 extern：CreateFileW/ReadFile/WriteFile/PeekNamedPipe/CloseHandle，`\\.\pipe\<name>`）。serverName/ArgPath/cleanupServer/currentPid 全平台化。
- **mpv.zig**：所有 posix 引用经 ipc.Conn；`getpid` → `ipc.currentPid()`。
- **backend 持久化**：`std.Io.Dir.cwd()`（createDirPath/writeFile/readFile，绝对路径当子路径两端成立）；unix `~/.config/alloymusic`，Windows `%HOME%/AlloyMusic`（`backendDir`）。
- **字格比**：`widgets.probeCellRatio()`（TIOCGWINSZ）与 `app.terminalCellPx` Windows 下编译期短路——控制台无像素尺寸，封面铺满回退估算比（AM_CELL_RATIO 可救）。
- **api_server**：Windows `start()` 返回 false（loopback HTTP 可选附属，未换 winsock）；deinit 的 posix 分支同门控。
- **providers**：auth.json 的 `.fromMode(0o600)` Windows 无此枚举 → `.default_file`。
- **main.zig**：`Args.Iterator` 必须 `initAllocator(init.minimal.args, init.gpa)`（Windows 上旧 init 是编译错误）。
- **build.zig**：smoke 工具 Windows 目标跳过。
- **渲染防御**：Windows 输出过 conhost（ConPTY）有状态中间层，两个结构性差异——写满最后一格**立即换行**（pty 是延迟换行，diff 渲染碰右下角会整屏错位）、对 DEC 2026 同步输出**转发不完整**（切页大帧被分段上屏闪帧）。对策：`main.zig` Windows 下 `render_mode = .full` 全量重绘（绝对寻址 + 每帧自洽）；posix 保留 diff。代码页自愈（ensureUtf8Console）曾实现后移除——代码页污染属罕见外部干扰，新开终端即恢复，不值得每帧查询。WSL 下渲染无此问题。
- **未真机验证 → 已真机验证（2026-10-28）**：Windows 实机 `zig build run` 正常（zigzag windows 终端后端、UI/扫码/封面均工作）；播放走 MF 后端（见 §4.9）。唯一遗留：Windows 下 `api_server` 未启用（winsock 未换）。

### 4.9 Media Foundation 后端（mf.zig，2026-10-28 真机验证通过）

**派发条件**：`player.init` 探测 mpv spawn 失败且 `builtin.os.tag == .windows` 时启用。

- **线程模型**：worker 线程同步 `MFCreateSourceResolver` 打开 URL（TUI 不冻结），结果经原子槽交主线程；主线程每 tick `drain()` 收 worker 结果 + 泵事件队列。
- **状态机**：`eventAction(事件类型) → 动作` 纯函数（单测覆盖）；`MESessionTopologyStatus` 事件**必须解 `MF_EVENT_TOPOLOGY_STATUS` 属性，仅 `READY(100)` 触发 Start**——拓扑生命周期会连发多条状态（200/300/400），全当 READY 会反复 Start 重置进度（真机踩坑）。
- **拓扑构建**：源节点必须同时挂 `SOURCE` + **`PRESENTATION_DESCRIPTOR`** + `STREAM_DESCRIPTOR` 三个 Unknown 属性，漏 PD 则 `SetTopology` 返回 `0xC00D5217 MF_E_TOPO_MISSING_PRESENTATION_DESCRIPTOR`（真机踩坑）；从头播放规范写法 `Start(NULL, VT_EMPTY)`，`Start(NULL, NULL)` 语义是"从当前位置"。
- **诊断**：拓扑构建阶段码 1-17 + `topo_hr` 原始 HRESULT，`amtui-mfsmoke`（无参=内置 WAV 全链路：打开/时长/推进/暂停/seek/resume/EOF/换曲；带参=真 URL 或本地文件）。
- **细节/踩坑全记录**：`docs/media-foundation-plan.md`。

### 4.10 SMTC（smtc.zig + relay/AlloyMusic-SMTC.cs，2026-10-30 定稿）

Windows「正在播放」系统展示 + 系统媒体键。**relay 中转架构（默认）**：amtui 运行时把构建期嵌入的 relay 字节解包到 `%TEMP%\AlloyMusic-SMTC.exe`（内容 FNV-1a 哈希校验——同长不同内容必重写，曾因只比大小导致旧 relay 永不更新；同目录有手放 relay 则优先用，开发可覆盖），它独占 SMTC 会话（展示 + ButtonPressed），经 127.0.0.1:47821 行协议交互（T<title/artist/album>/P/L + C<封面URL> 出、B 入；reader 线程把按键写进与热键共用的原子位标志，`takeButton()` 下游无感知）。**媒体键 + Win+A 系统面板按钮 + 元数据/封面全链路可用**（smtcsmoke 三键断言 PASS，锁屏下也有效）。封面走 `CreateFromFile(StorageFile)`（`CreateFromUri`/`CreateFromStream` 面板静默不显示，见 docs/smtc.md 坑表）；relay 的 `CommandManager.IsEnabled=false`（自动集成会用空 updater 抹掉元数据）。

为什么必须中转：本机 Win 内测版 28120 的 MC.dll fire 路径有 use-after-free（符号化栈：AsyncEventWorkCallback→GitInvokeHelper 调用已注册委托时 jmp 进 NT 堆 freed 填充），Zig 静态二进制进程内 handler 形态/顺序/获取路径/套间/进程形态/稀疏包身份全变量穷尽均复现且 Invoke 从未进入；**MSVC/CLR 进程（MusicPlayer2、.NET 探针）不触发**——故 SMTC 挪进 .NET 子进程。回退路径（relay 缺失或 `AM_SMTC_NORELAY=1`）：进程内 STA 仅展示 + RegisterHotKey 热键（此时 Win+A 按钮无效；`AM_SMTC_BTNEVENTS=1` 强制注册会触发 UAF 杀进程，勿用）。

细节坑：relay 的 WriteLine 是 CRLF（解析须 trim CR）；按键枚举 Next=6/Previous=7（.NET 投影序）；锁屏下 SendInput 不触发 WM_HOTKEY（热键路径断言须解锁跑）；relay 断连 15s 自清、收 Q 即退。回归 `zig build smtcsmoke`（relay 三键）+ `zig build mfsmoke`（含 EOF 换曲位置归零断言，看门 2026-10-30 的进度残留 bug——根因是 MESessionEnded 后未 Stop，Start(VT_EMPTY) 从旧时钟位续播，已在 pumpEvents 修）。**完整技术文档 docs/smtc.md**（术语词典/取证/协议坑/MusicPlayer2 对照/WSL 结论）。简版见 docs/media-foundation-plan.md §10。

## 5. UI 交互（README 有完整键位表，这里列结构）

- 页面：侧栏四页签 探索/搜索/喜欢/队列（数字 1-4 直达）+ 全屏播放页（`v` 切换）。布局 = 顶栏/侧栏+主区/播放栏/迷你歌词/提示行。
- **Tab 逐项循环**（`tabNext`）：四页签 → "我的歌单"入口态 → 回绕；数字 5 进出我的歌单。
- **三级歌单交互**：侧栏页签 → 我的歌单入口态（Enter 展开、Tab 在歌单间循环）→ 歌单视图（Esc 逐级退）。
- 全局键：`q` 退出、`/` 搜索、`?` 帮助、空格 播放暂停、`n/p` 切歌、`←/→` seek、`r` 播放模式三态循环（列表→单曲→随机，随机即建洗牌袋并 `setLoopFile`）、`a` 追加队列、`m` 静音、`-/+` 音量、`s` 切源、`o` 电台模式（剩 ≤3 首自动以当前歌为种子续批）、`L` 登录浮层（选源 → 半块字符二维码，1.5s 轮询）。
- 播放页：`↑↓` 选歌词句、Enter 跳句、滚轮浏览（3s 无操作回归跟随）；迷你歌词以当前行为中心。
- 鼠标：单击选中/双击播放（450ms 判双击）、进度条按列 seek、滚轮 100ms 节流、**右键菜单**（喜欢 toggle/下一首播放/追加队列；`floatingAt` 渲染，刻意不走 zigzag LayerStack——SGR 合成会花）。
- 封面：仅 bitmap 终端且非 Windows 编译目标（`comptime` 门控整体移除组件），`requestCover` 按播放页矩形算像素（TIOCGWINSZ 实测，上限 640×1280），kitty/iterm2/sixel 惰性探测，`cover_key` 门控晚到；域白名单 + webp→jpg 改写 + 自写基线 JPEG 解码（`jpeg.zig`）。Windows 播放页布局：顶部歌名/歌手/专辑居中 + 歌词整块居中（`lyricGeom` 与渲染同源，点击命中的行=看到的行）。
- 歌词：`lyrics_mod.parse` + 逐字歌词 AWLRC 解码（`core/lyrics.zig`，`[kuwo:<八进制>]` 系数还原毫秒）；翻译按时间戳配对合并。

## 6. 测试与开发习惯

- `zig build test`：app/provider/providers 单元测试 + ui/mock 驱动的 UI 冒烟；真网络走独立 smoke 可执行。
- UI 验收优先 snap 截帧（mock backend）；scratch/ 下有实验程序和 `ansi2png.py` 可把 ANSI 帧转 PNG 看。
- 近期提交全部是直调链路 bug 修复（封面 off-by、netease level 缺省、切源封面丢失），说明当前活跃区在 core/providers 与 app.zig 播放编排的交界。
- 工作约定：实验代码放 `scratch/`（gitignore）；不修改 `zig-pkg/` 依赖。
