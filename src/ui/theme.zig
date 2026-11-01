const zz = @import("zigzag");

// src/ui/theme.zig — 256 色调色板与常用样式。
// 主色取自参考设计的绿 42；强调粉 212、次要文字暗 241、正文 252、警告 203、
// 选中行底 237、侧栏/头部底 236、分隔线 238。换品牌色只改这一处。

pub const green = zz.Color.color256(42);
pub const pink = zz.Color.color256(212);
pub const dim = zz.Color.color256(241);
pub const text = zz.Color.color256(252);
pub const warn = zz.Color.color256(203);
pub const row_on_bg = zz.Color.color256(237);
pub const sidebar_bg = zz.Color.color256(236);
pub const rule = zz.Color.color256(238);
pub const panel_border = zz.Color.color256(240);

/// 行内样式：嵌进单行文本里的着色段（不加边框/占位行为）
pub fn inlineStyle(fg: zz.Color) zz.Style {
    return (zz.Style{}).fg(fg).inline_style(true);
}

pub fn inlineBold(fg: zz.Color) zz.Style {
    return (zz.Style{}).fg(fg).bold(true).inline_style(true);
}

/// 行内样式 + 自带底色。zigzag 里行内片段结尾的 reset 会把外层 Style 的
/// bg 一并清掉（其后的补位空格变透明），所以需要底色的区域（侧栏、选中行）
/// 必须让每个片段自己带 bg，行尾再用 widgets.bgSpan 补齐。
pub fn inlineOn(fg: zz.Color, bg: ?zz.Color) zz.Style {
    var s = (zz.Style{}).fg(fg).inline_style(true);
    if (bg) |b| s = s.bg(b);
    return s;
}

pub fn boldOn(fg: zz.Color, bg: ?zz.Color) zz.Style {
    var s = (zz.Style{}).fg(fg).bold(true).inline_style(true);
    if (bg) |b| s = s.bg(b);
    return s;
}

/// 侧栏顶部的应用名
pub fn headerBadge() zz.Style {
    return (zz.Style{}).fg(green).bold(true).inline_style(true);
}

/// 选中列表行：浅底 + 正文色
pub fn rowOn() zz.Style {
    return (zz.Style{}).fg(text).bg(row_on_bg);
}

pub fn note() zz.Style {
    return inlineStyle(dim);
}

pub fn warnInline() zz.Style {
    return inlineStyle(warn);
}

/// 浮层卡片：圆角绿边框
pub fn card() zz.Style {
    return (zz.Style{}).borderAll(zz.Border.rounded).borderForeground(green);
}

/// 内容面板：圆角暗边框（封面卡、歌词面板、搜索框外圈）
pub fn panel() zz.Style {
    return (zz.Style{}).borderAll(zz.Border.rounded).borderForeground(panel_border);
}

/// 搜索输入框外框：聚焦时绿色
pub fn inputBox(focused: bool) zz.Style {
    var s = (zz.Style{}).borderAll(zz.Border.rounded);
    s = s.borderForeground(if (focused) green else panel_border);
    return s;
}
