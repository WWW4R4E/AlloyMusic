const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

// src/ui/mock.zig — 演示数据提供方，UI 与数据之间的唯一翻译点。
//
// 运行时从 AM_MOCK_DIR（默认 testdata/mock，相对 cwd）读取模拟波点
// 原始响应的 JSON：顶层 {code, data}，歌曲字段按已知 Bodian 形态
// （musicId/name/artist/album/duration/payInfo），歌单字段
// id/name/musicCount/sourceType（6=专辑）。core 就绪后这一层换成真实
// Catalog 调用，UI 其他文件不动。
//
// 读取/解析的一切都分配在 Model 的 arena 上；任何文件缺失或字段畸形
// 都不致命：对应列表留空，错误信息进 errors 显示在探索页和状态行。

pub const Data = struct {
    search: []model.Song = &.{},
    fm: []model.Song = &.{},
    recommend: []model.Playlist = &.{},
    discover: []model.Playlist = &.{},
    liked: []model.Song = &.{},
    owned: []model.Playlist = &.{},
    collected_playlists: []model.Playlist = &.{},
    collected_albums: []model.Playlist = &.{},
    detail_playlist: model.Playlist = .{},
    detail_songs: []model.Song = &.{},
    /// 歌词接口 data.content 的 base64 文本（对应 lyric_song_id 这首歌）
    lyrics_b64: ?[]const u8 = null,
    lyric_song_id: []const u8 = "",
    errors: std.ArrayList([]const u8) = .empty,
};

const max_json_bytes = 8 << 20;

/// 永不抛错的加载入口：单个文件失败只影响对应列表。
pub fn load(a: Allocator, io: std.Io, dir_path: []const u8) Data {
    var d: Data = .{};
    loadSearch(a, io, dir_path, &d);
    loadSimple(a, io, dir_path, &d);
    return d;
}

fn loadSearch(a: Allocator, io: std.Io, dir_path: []const u8, d: *Data) void {
    const root = parseFile(a, io, dir_path, "search.json", d) orelse return;
    const list = objField(root, "data", "resultList") orelse {
        addError(a, d, "search.json", "缺少 data.resultList");
        return;
    };
    d.search = parseSongs(a, list) catch &.{};
}

fn loadSimple(a: Allocator, io: std.Io, dir_path: []const u8, d: *Data) void {
    // 探索页三个分节
    if (parseFile(a, io, dir_path, "recommendations.json", d)) |root| {
        if (objField(root, "data", "playLists")) |v| {
            d.recommend = parsePlaylists(a, v) catch &.{};
        } else addError(a, d, "recommendations.json", "缺少 data.playLists");
    }
    if (parseFile(a, io, dir_path, "personal_fm.json", d)) |root| {
        if (objField(root, "data", "resultList")) |v| {
            d.fm = parseSongs(a, v) catch &.{};
        } else addError(a, d, "personal_fm.json", "缺少 data.resultList");
    }
    if (parseFile(a, io, dir_path, "home_module.json", d)) |root| {
        if (objField(root, "data", "list")) |v| {
            d.discover = parsePlaylists(a, v) catch &.{};
        } else addError(a, d, "home_module.json", "缺少 data.list");
    }

    // 我的喜欢
    if (parseFile(a, io, dir_path, "liked.json", d)) |root| {
        if (objField(root, "data", "list")) |v| {
            d.liked = parseSongs(a, v) catch &.{};
        } else addError(a, d, "liked.json", "缺少 data.list");
    }

    // 音乐库：自建 + 收藏（收藏混返，按 sourceType 分流专辑）
    if (parseFile(a, io, dir_path, "library.json", d)) |root| {
        const data = get(root, "data") orelse {
            addError(a, d, "library.json", "缺少 data");
            return;
        };
        if (getObj(get(data, "owned"), "playLists")) |v| {
            d.owned = parsePlaylists(a, v) catch &.{};
        }
        var mixed_playlists: std.ArrayList(model.Playlist) = .empty;
        var mixed_albums: std.ArrayList(model.Playlist) = .empty;
        if (getObj(get(data, "collected"), "playLists")) |v| {
            if (v == .array) for (v.array.items) |item| {
                const pl = parsePlaylist(item) orelse continue;
                const target = if (pl.kind == .album) &mixed_albums else &mixed_playlists;
                target.append(a, pl) catch {};
            };
        }
        d.collected_playlists = mixed_playlists.toOwnedSlice(a) catch &.{};
        d.collected_albums = mixed_albums.toOwnedSlice(a) catch &.{};
    }

    // 歌单详情浮层（任意歌单/专辑都打开这份演示详情）
    if (parseFile(a, io, dir_path, "playlist_detail.json", d)) |root| {
        if (get(root, "data")) |data| {
            if (data == .object) {
                var pl: model.Playlist = .{};
                if (get(data, "name")) |n| pl.name = str(a, n) orelse "";
                if (get(data, "id")) |i| pl.id = str(a, i) orelse "";
                pl.kind = if (eqInt(get(data, "sourceType"), 6)) .album else .playlist;
                if (get(data, "musicCount")) |m| pl.track_count = uint(m) orelse 0;
                d.detail_playlist = pl;
            }
            if (getObj(data, "musicList")) |v| {
                d.detail_songs = parseSongs(a, v) catch &.{};
            } else addError(a, d, "playlist_detail.json", "缺少 data.musicList");
        } else addError(a, d, "playlist_detail.json", "缺少 data");
    }

    // 歌词（base64 原样保留，展示层再走 core 解码链路）
    if (parseFile(a, io, dir_path, "lyrics.json", d)) |root| {
        const data = get(root, "data") orelse return;
        if (getStr(data, "content")) |c| d.lyrics_b64 = c;
        if (getStr(data, "musicId")) |id| d.lyric_song_id = id;
        if (d.lyrics_b64 == null) addError(a, d, "lyrics.json", "缺少 data.content");
    }
}

// ── JSON 基础助手（容错：形状不对一律返回 null）──

fn parseFile(a: Allocator, io: std.Io, dir_path: []const u8, name: []const u8, d: *Data) ?std.json.Value {
    const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_json_bytes)) catch |e| {
        addError(a, d, name, @errorName(e));
        return null;
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| {
        addError(a, d, name, @errorName(e));
        return null;
    };
    if (parsed != .object) {
        addError(a, d, name, "顶层不是 object");
        return null;
    }
    return parsed;
}

fn addError(a: Allocator, d: *Data, name: []const u8, detail: []const u8) void {
    const msg = std.fmt.allocPrint(a, "{s}: {s}", .{ name, detail }) catch return;
    d.errors.append(a, msg) catch {};
}

fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn getObj(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const value = v orelse return null;
    const field = get(value, key) orelse return null;
    return if (field == .array) field else null;
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const field = get(v, key) orelse return null;
    if (field == .string) return field.string;
    return null;
}

/// 两个 key 的链式取数组（data.resultList 之类）
fn objField(root: std.json.Value, outer: []const u8, inner: []const u8) ?std.json.Value {
    return getObj(get(root, outer), inner);
}

fn uint(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        .float => |f| if (f >= 0 and f == @trunc(f) and f <= std.math.maxInt(u32)) @intFromFloat(f) else null,
        .string, .number_string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}

/// musicId 这类字段可能是数字也可能是字符串，统一成 arena 上的字符串
fn str(a: Allocator, v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch null,
        else => null,
    };
}

fn eqInt(v: ?std.json.Value, want: u32) bool {
    const value = v orelse return false;
    return uint(value) == want;
}

// ── 列表翻译 ──

fn parseSongs(a: Allocator, v: std.json.Value) ![]model.Song {
    var out: std.ArrayList(model.Song) = .empty;
    for (v.array.items) |item| {
        const song = parseSong(a, item) orelse continue;
        try out.append(a, song);
    }
    return out.toOwnedSlice(a);
}

fn parseSong(a: Allocator, v: std.json.Value) ?model.Song {
    if (v != .object) return null;
    // 没有歌名或 id 的条目没有展示价值，跳过（服务端可能吞字段）
    const title = getStr(v, "name") orelse getStr(v, "songName") orelse return null;
    const id = str(a, get(v, "musicId") orelse return null) orelse return null;
    const pay = getStr(v, "payInfo");
    return .{
        .id = id,
        .title = title,
        .artist = getStr(v, "artist") orelse getStr(v, "artistName") orelse "未知歌手",
        .album = getStr(v, "album") orelse getStr(v, "albumName") orelse "未知专辑",
        .duration_s = uint(get(v, "duration") orelse std.json.Value{ .integer = 0 }) orelse 0,
        .vip = pay != null and pay.?.len > 0,
    };
}

fn parsePlaylists(a: Allocator, v: std.json.Value) ![]model.Playlist {
    var out: std.ArrayList(model.Playlist) = .empty;
    for (v.array.items) |item| {
        const pl = parsePlaylist(item) orelse continue;
        try out.append(a, pl);
    }
    return out.toOwnedSlice(a);
}

fn parsePlaylist(v: std.json.Value) ?model.Playlist {
    if (v != .object) return null;
    const name = getStr(v, "name") orelse getStr(v, "title") orelse return null;
    return .{
        .id = "", // 由调用方按需补；展示不需要
        .name = name,
        .track_count = uint(get(v, "musicCount") orelse std.json.Value{ .integer = 0 }) orelse 0,
        .kind = if (eqInt(get(v, "sourceType"), 6)) .album else .playlist,
    };
}
