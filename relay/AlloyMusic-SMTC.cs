using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Media;
using Windows.Media.Playback;

// AlloyMusic-SMTC 中转进程（.NET Framework 4.x，csc 编译，零外部依赖）。
//
// 为什么存在：amtui.exe（Zig 静态二进制）进程内注册 SMTC ButtonPressed
// handler 会触发 MC.dll fire 路径的 use-after-free（Win 内测版 28120，
// 详见 src/core/smtc.zig 头注释与 docs/media-foundation-plan.md §10）；
// MSVC/.NET 运行时进程不触发（MusicPlayer2 同理）。故 SMTC 会话整体
// （展示 + 按钮）由本进程持有，amtui 经 127.0.0.1:47821 行协议连接喂
// 元数据、收按键事件。
//
// 协议（TCP，行式 UTF-8，LF 结尾）：
//   amtui → relay：
//     T\t<title>\t<artist>   曲目元数据（Update DisplayUpdater）
//     P\t<0|1>               暂停/播放状态
//     L\t<pos_ms>\t<dur_ms>  时间线
//     Q                      退出
//   relay → amtui：
//     B\t<n>                 n = SystemMediaTransportControlsButton 枚举值
//                            (Play=0 Pause=1 Stop=2 Record=3 FastForward=4
//                             Rewind=5 Next=6 Previous=7 ChannelUp=8 …，
//                             .NET 投影核实)
//
// 端口被占 = 已有 relay 在跑 → 本实例直接退出（单实例语义，amtui 连旧实例）。
// 退出条件：收到 Q、启动后 120s 无客户端、客户端断开后 15s 无新连接。
class AlloySmtcRelay {
    const int Port = 47821;

    static SystemMediaTransportControls g_smtc;
    static object g_write_lock = new object();
    static StreamWriter g_out;
    static volatile bool g_quit = false;

    // 文件日志（排障用，正式版可删）：写 exe 同目录，避免硬编码绝对路径
    static void Log(string m) {
        try {
            File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "relay_log.txt"),
                DateTime.Now.ToString("HH:mm:ss.fff") + " " + m + Environment.NewLine);
        } catch (Exception) {}
    }

    static void Main() {
        AppDomain.CurrentDomain.UnhandledException += (s, e) => Log("UNHANDLED: " + e.ExceptionObject);
        Log("main enter");
        var mp = new MediaPlayer();
        // 关自动媒体集成：relay 的 MediaPlayer 从不开媒体，其 CommandManager
        // 集成会在状态变化时用【空】DisplayUpdater 打 Update()，抹掉我们
        // 挂的 Title/Thumbnail——展示必须完全收口到行协议这一侧
        mp.CommandManager.IsEnabled = false;
        g_smtc = mp.SystemMediaTransportControls;
        g_smtc.IsEnabled = true;
        g_smtc.IsPlayEnabled = true;
        g_smtc.IsPauseEnabled = true;
        g_smtc.IsNextEnabled = true;
        g_smtc.IsPreviousEnabled = true;
        g_smtc.PlaybackStatus = MediaPlaybackStatus.Stopped;
        var du = g_smtc.DisplayUpdater;
        du.Type = MediaPlaybackType.Music;
        du.MusicProperties.Title = "AlloyMusic";
        du.Update();
        g_smtc.ButtonPressed += OnButton;
        Log("sub ok");

        TcpListener listener;
        try {
            listener = new TcpListener(IPAddress.Loopback, Port);
            listener.Start();
        } catch (Exception ex) {
            Log("bind busy -> exit: " + ex.Message); // 已有实例在跑
            return;
        }
        Log("listening");
        var started = DateTime.UtcNow;
        while (!g_quit) {
            TcpClient client = null;
            while (client == null && !g_quit) {
                var have = listener.Pending();
                if (!have) {
                    if (g_out == null && DateTime.UtcNow - started > TimeSpan.FromSeconds(120)) {
                        Log("no client ever, exit");
                        return;
                    }
                    if (g_out != null && DateTime.UtcNow - started > TimeSpan.FromSeconds(15)) {
                        Log("client gone too long, exit");
                        return;
                    }
                    Thread.Sleep(100);
                    continue;
                }
                client = listener.AcceptTcpClient();
            }
            if (client == null) break;
            Log("client connected");
            started = DateTime.UtcNow;
            try {
                Serve(client);
            } catch (Exception ex) {
                Log("serve err: " + ex.Message);
            }
            lock (g_write_lock) { g_out = null; }
            try { client.Dispose(); } catch (Exception) {}
            Log("client disconnected");
        }
    }

    static void Serve(TcpClient client) {
        var stream = client.GetStream();
        var reader = new StreamReader(stream, new UTF8Encoding(false));
        lock (g_write_lock) { g_out = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true }; }
        string line;
        while (!g_quit && (line = reader.ReadLine()) != null) {
            if (line.Length == 0) continue;
            if (line[0] == 'Q') { Log("quit line"); g_quit = true; return; }
            Handle(line);
        }
    }

    static void Handle(string line) {
        try {
            var parts = line.Split('\t');
            if (parts[0] == "T" && parts.Length >= 3) {
                var du = g_smtc.DisplayUpdater;
                du.Type = MediaPlaybackType.Music;
                du.MusicProperties.Title = parts[1];
                du.MusicProperties.Artist = parts[2];
                if (parts.Length >= 4) du.MusicProperties.AlbumTitle = parts[3];
                // 每张 T 先清旧封面（切到无封面歌不会残留上一首的），
                // 紧随的 C 行再挂本曲封面
                du.Thumbnail = null;
                du.Update();
            } else if (parts[0] == "C" && parts.Length >= 2) {
                Log("C recv len=" + parts[1].Length);
                SetCover(parts[1]);
            } else if (parts[0] == "P" && parts.Length >= 2) {
                g_smtc.PlaybackStatus = parts[1] == "1" ? MediaPlaybackStatus.Paused : MediaPlaybackStatus.Playing;
            } else if (parts[0] == "L" && parts.Length >= 3) {
                long pos = long.Parse(parts[1]);
                long dur = long.Parse(parts[2]);
                var tp = new SystemMediaTransportControlsTimelineProperties();
                tp.StartTime = TimeSpan.Zero;
                tp.MinSeekTime = TimeSpan.Zero;
                tp.Position = TimeSpan.FromMilliseconds(pos);
                tp.EndTime = TimeSpan.FromMilliseconds(dur);
                tp.MaxSeekTime = TimeSpan.FromMilliseconds(dur);
                g_smtc.UpdateTimelineProperties(tp);
            }
        } catch (Exception ex) {
            Log("req err: " + ex.Message);
        }
    }

    // 封面：下载 URL 到 %TEMP% 缓存（文件名 = URL 的 MD5），挂 Thumbnail。
    // 走本地文件而非 CreateFromUri——http URI 缩略图在 SMTC 侧不可靠。
    static void SetCover(string url) {
        try {
            // 本地缓存可复用（跨次启动），挂 Thumbnail 前重设 Type——
            // DisplayUpdater 可能返回新实例，Type 回到 Unknown 会被面板忽略
            string path = CoverCachePath(url);
            if (!File.Exists(path)) {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = "GET";
                req.Timeout = 10000;
                req.UserAgent = "Mozilla/5.0";
                using (var resp = req.GetResponse())
                using (var rs = resp.GetResponseStream())
                using (var fs = File.Create(path + ".tmp")) rs.CopyTo(fs);
                File.Move(path + ".tmp", path);
                DownscaleIfHuge(path);
            }
            // 正统路径：StorageFile → CreateFromFile。实测 CreateFromUri 和
            // CreateFromStream（内存流）面板都不加载，只有文件路径这条 shell
            // 肯消费。StorageFile 需要 async——GetAwaiter().GetResult() 阻塞
            // 等待（console 主线程 MTA，无线程池死锁风险）。
            var f = Windows.Storage.StorageFile.GetFileFromPathAsync(System.IO.Path.GetFullPath(path))
                .AsTask().GetAwaiter().GetResult();
            var du = g_smtc.DisplayUpdater;
            du.Type = MediaPlaybackType.Music;
            du.Thumbnail = Windows.Storage.Streams.RandomAccessStreamReference.CreateFromFile(f);
            du.Update();
            Log("cover ok file bytes=" + new FileInfo(path).Length);
        } catch (Exception ex) {
            Log("cover err: " + ex.Message);
        }
    }

    // >2MB 的原图降采样到宽 600（SMTC 缩略图用不着 6MB 原图，解码慢）。
    // 注意 GDI+ 的 Image.FromFile 会锁住文件、Save 同路径必炸（"GDI+ 一般性
    // 错误"）——必须经内存流解码、先写 .tmp 再换名。
    static void DownscaleIfHuge(string path) {
        try {
            if (new FileInfo(path).Length <= 2 * 1024 * 1024) return;
            byte[] raw = File.ReadAllBytes(path);
            using (var ms = new MemoryStream(raw))
            using (var src = System.Drawing.Image.FromStream(ms))
            using (var dst = new System.Drawing.Bitmap(600, 600 * src.Height / src.Width))
            using (var g = System.Drawing.Graphics.FromImage(dst)) {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(src, 0, 0, dst.Width, dst.Height);
                dst.Save(path + ".tmp", System.Drawing.Imaging.ImageFormat.Jpeg);
            }
            File.Delete(path);
            File.Move(path + ".tmp", path);
        } catch (Exception ex) { Log("downscale err: " + ex.Message); }
    }

    static string CoverCachePath(string url) {
        using (var md5 = System.Security.Cryptography.MD5.Create()) {
            var hash = md5.ComputeHash(Encoding.UTF8.GetBytes(url));
            var sb = new System.Text.StringBuilder(hash.Length * 2);
            foreach (var b in hash) sb.Append(b.ToString("x2"));
            string ext = ".jpg";
            try {
                string p = new Uri(url).AbsolutePath;
                int dot = p.LastIndexOf('.');
                if (dot >= 0 && p.Length - dot <= 5) ext = p.Substring(dot).ToLowerInvariant();
            } catch (Exception) {}
            return Path.Combine(Path.GetTempPath(), "AlloyMusic-SMTC-" + sb + ext);
        }
    }

    static void OnButton(SystemMediaTransportControls s, SystemMediaTransportControlsButtonPressedEventArgs e) {        Log("BTN " + e.Button);
        try {
            lock (g_write_lock) {
                if (g_out != null) g_out.WriteLine("B\t" + (int)e.Button);
            }
        } catch (Exception ex) {
            Log("btn write err: " + ex.Message);
        }
    }
}
