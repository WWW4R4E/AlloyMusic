// src/ui/model.zig — UI 层的纯值类型。
//
// 这是 UI 与数据源之间的唯一契约：页面只认这些类型，provider.zig 负责把
// sidecar 统一响应翻译成它们，mock.zig 负责把 testdata/mock/*.json（模拟
// 波点原始响应）翻译成它们（离线测试/演示用）。所有切片/字符串都分配在
// 各自请求的 arena 上，随 Model 一起释放。

/// 音乐平台。歌曲/歌单随身携带，播放时回到正确的后端取播放链接。
/// .mock 是演示模式（testdata 离线数据），不参与音源切换轮换。
pub const Backend = enum {
    bodian,
    netease,
    qq,
    mock,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .bodian => "波点",
            .netease => "网易云",
            .qq => "QQ音乐",
            .mock => "演示",
        };
    }

    pub fn short(self: Backend) []const u8 {
        return switch (self) {
            .bodian => "波点",
            .netease => "网易",
            .qq => "QQ",
            .mock => "演示",
        };
    }
};

pub const Song = struct {
    id: []const u8,
    title: []const u8,
    artist: []const u8,
    album: []const u8,
    duration_s: u32,
    vip: bool = false,
    backend: Backend = .bodian,
    /// QQ 取播放链接用 songMid（id 是数字 songid）
    song_mid: []const u8 = "",
    media_mid: []const u8 = "",
    /// 专辑封面（https 直链，经 sidecar /cover 解码缩放后渲染）
    cover_url: []const u8 = "",
};

pub const Playlist = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    track_count: u32 = 0,
    kind: Kind = .playlist,
    backend: Backend = .bodian,

    pub const Kind = enum { playlist, album };

    pub fn typeName(self: Playlist) []const u8 {
        return switch (self.kind) {
            .playlist => "歌单",
            .album => "专辑",
        };
    }
};
