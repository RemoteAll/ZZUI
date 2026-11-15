//! 矢量图标（对位 CUI 的 `cui_draw_icon` + `cui_icons.h`）。
//!
//! **不嵌字体、不背字形数据**：CUI 用 Lucide 图标字体（168 个 PUA 码位），ZZUI 改成「24×24 网格上的
//! 线段/圆弧/圆/矩形」描述，绘制时按目标尺寸缩放 —— 零数据段，图标再用也只是一个 switch 分支。
//!
//! 差异（有意为之）：
//! - 图标集是**常用子集**（`Icon` 枚举里的那些），不是 Lucide 全量 168 个；要加图标就往下写几条 `Seg`；
//! - 走**浮层线通道**（`addOverlayLine` / `addArc`），因此受 `MAX_OVERLAYS`(192) 约束：
//!   一个图标 2~9 段，**一屏别超过 ~25 个图标**（工具栏、列表行、按钮图标都在这个量级内）；
//!   超出会 `overflowed` 报警而不是静默画错；
//! - 线宽按 Lucide 口径（24 网格上 2px → 实际 `size/12`），缩到 12px 以下会取 1px 下限。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const anim = @import("anim.zig");

pub const Icon = enum {
    check,
    x,
    plus,
    minus,
    chevron_down,
    chevron_up,
    chevron_left,
    chevron_right,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    search,
    settings,
    user,
    home,
    bell,
    mail,
    calendar,
    clock,
    trash,
    pencil,
    copy,
    lock,
    star,
    heart,
    info,
    alert,
    check_circle,
    x_circle,
    more,
    more_vertical,
    menu,
    sun,
    moon,
    download,
    upload,
    file,
    folder,
    link,
    external,
    refresh,
    filter,
    chart_bar,
    chart_line,
    send,
    bookmark,
    tag,
    play,
    pause,
    terminal,
    code,
    save,
    cloud,
    database,
    cpu,
    wifi,
    battery,
    mic,
    palette,
    type,
    bold,
    italic,
    underline,
    list,
    grid,
    maximize,
    minimize,
    move,
    zoom_in,
    zoom_out,
};

const Seg = union(enum) {
    /// x1, y1, x2, y2
    line: [4]f32,
    /// cx, cy, r
    circle: [3]f32,
    /// cx, cy, r, start（弧度）, span（弧度，正 = 顺时针增）
    arc: [5]f32,
    /// x, y, w, h（描边，不填充）
    rect: [4]f32,
};

/// 每个图标的线段表（24×24 坐标系，0,0 在左上）。
fn segs(icon: Icon) []const Seg {
    return switch (icon) {
        .check => &.{ .{ .line = .{ 4, 12, 10, 18 } }, .{ .line = .{ 10, 18, 20, 6 } } },
        .x => &.{ .{ .line = .{ 6, 6, 18, 18 } }, .{ .line = .{ 18, 6, 6, 18 } } },
        .plus => &.{ .{ .line = .{ 12, 5, 12, 19 } }, .{ .line = .{ 5, 12, 19, 12 } } },
        .minus => &.{.{ .line = .{ 5, 12, 19, 12 } }},
        .chevron_down => &.{ .{ .line = .{ 6, 9, 12, 15 } }, .{ .line = .{ 12, 15, 18, 9 } } },
        .chevron_up => &.{ .{ .line = .{ 6, 15, 12, 9 } }, .{ .line = .{ 12, 9, 18, 15 } } },
        .chevron_left => &.{ .{ .line = .{ 15, 6, 9, 12 } }, .{ .line = .{ 9, 12, 15, 18 } } },
        .chevron_right => &.{ .{ .line = .{ 9, 6, 15, 12 } }, .{ .line = .{ 15, 12, 9, 18 } } },
        .arrow_left => &.{ .{ .line = .{ 19, 12, 5, 12 } }, .{ .line = .{ 5, 12, 11, 6 } }, .{ .line = .{ 5, 12, 11, 18 } } },
        .arrow_right => &.{ .{ .line = .{ 5, 12, 19, 12 } }, .{ .line = .{ 19, 12, 13, 6 } }, .{ .line = .{ 19, 12, 13, 18 } } },
        .arrow_up => &.{ .{ .line = .{ 12, 19, 12, 5 } }, .{ .line = .{ 12, 5, 6, 11 } }, .{ .line = .{ 12, 5, 18, 11 } } },
        .arrow_down => &.{ .{ .line = .{ 12, 5, 12, 19 } }, .{ .line = .{ 12, 19, 6, 13 } }, .{ .line = .{ 12, 19, 18, 13 } } },
        .search => &.{ .{ .circle = .{ 10.5, 10.5, 6.5 } }, .{ .line = .{ 15.5, 15.5, 20, 20 } } },
        .settings => &.{
            .{ .circle = .{ 12, 12, 3 } },
            .{ .line = .{ 12, 2, 12, 5 } },
            .{ .line = .{ 12, 19, 12, 22 } },
            .{ .line = .{ 2, 12, 5, 12 } },
            .{ .line = .{ 19, 12, 22, 12 } },
        },
        .user => &.{ .{ .circle = .{ 12, 8, 4 } }, .{ .arc = .{ 12, 20, 7, 3.14159, 3.14159 } } },
        .home => &.{
            .{ .line = .{ 4, 11, 12, 4 } },
            .{ .line = .{ 12, 4, 20, 11 } },
            .{ .line = .{ 6, 10, 6, 20 } },
            .{ .line = .{ 18, 10, 18, 20 } },
            .{ .line = .{ 6, 20, 18, 20 } },
        },
        .bell => &.{
            .{ .arc = .{ 12, 14, 6, 3.14159, 3.14159 } },
            .{ .line = .{ 6, 14, 6, 18 } },
            .{ .line = .{ 18, 14, 18, 18 } },
            .{ .line = .{ 6, 18, 18, 18 } },
            .{ .line = .{ 12, 18, 12, 21 } },
        },
        .mail => &.{
            .{ .rect = .{ 4, 6, 16, 12 } },
            .{ .line = .{ 4, 7, 12, 13 } },
            .{ .line = .{ 12, 13, 20, 7 } },
        },
        .calendar => &.{
            .{ .rect = .{ 4, 5, 16, 15 } },
            .{ .line = .{ 8, 3, 8, 7 } },
            .{ .line = .{ 16, 3, 16, 7 } },
            .{ .line = .{ 4, 10, 20, 10 } },
        },
        .clock => &.{ .{ .circle = .{ 12, 12, 8 } }, .{ .line = .{ 12, 7, 12, 12 } }, .{ .line = .{ 12, 12, 16, 14 } } },
        .trash => &.{
            .{ .line = .{ 4, 7, 20, 7 } },
            .{ .rect = .{ 6, 7, 12, 13 } },
            .{ .line = .{ 10, 4, 14, 4 } },
            .{ .line = .{ 10, 11, 10, 17 } },
            .{ .line = .{ 14, 11, 14, 17 } },
        },
        .pencil => &.{
            .{ .line = .{ 4, 20, 5, 16 } },
            .{ .line = .{ 5, 16, 16, 5 } },
            .{ .line = .{ 16, 5, 19, 8 } },
            .{ .line = .{ 19, 8, 8, 19 } },
            .{ .line = .{ 8, 19, 4, 20 } },
        },
        .copy => &.{
            .{ .rect = .{ 4, 4, 11, 11 } },
            .{ .rect = .{ 9, 9, 11, 11 } },
        },
        .lock => &.{ .{ .rect = .{ 5, 11, 14, 10 } }, .{ .arc = .{ 12, 11, 5, 3.14159, 3.14159 } } },
        .star => &.{
            .{ .line = .{ 12, 3, 14.6, 9.4 } },
            .{ .line = .{ 14.6, 9.4, 21, 10 } },
            .{ .line = .{ 21, 10, 16, 14.4 } },
            .{ .line = .{ 16, 14.4, 17.6, 21 } },
            .{ .line = .{ 17.6, 21, 12, 17.6 } },
            .{ .line = .{ 12, 17.6, 6.4, 21 } },
            .{ .line = .{ 6.4, 21, 8, 14.4 } },
            .{ .line = .{ 8, 14.4, 3, 10 } },
            .{ .line = .{ 3, 10, 9.4, 9.4 } },
            .{ .line = .{ 9.4, 9.4, 12, 3 } },
        },
        .heart => &.{ .{ .arc = .{ 8.5, 9, 4.5, 3.6, 2.6 } }, .{ .arc = .{ 15.5, 9, 4.5, 3.9, 2.6 } }, .{ .line = .{ 4, 11, 12, 20 } }, .{ .line = .{ 20, 11, 12, 20 } } },
        .info => &.{ .{ .circle = .{ 12, 12, 8 } }, .{ .line = .{ 12, 11, 12, 16 } }, .{ .line = .{ 12, 8, 12, 8.5 } } },
        .alert => &.{ .{ .line = .{ 12, 3, 21, 20 } }, .{ .line = .{ 21, 20, 3, 20 } }, .{ .line = .{ 3, 20, 12, 3 } }, .{ .line = .{ 12, 9, 12, 14 } }, .{ .line = .{ 12, 17, 12, 17.5 } } },
        .check_circle => &.{ .{ .circle = .{ 12, 12, 8 } }, .{ .line = .{ 8, 12, 11, 15 } }, .{ .line = .{ 11, 15, 16, 9 } } },
        .x_circle => &.{ .{ .circle = .{ 12, 12, 8 } }, .{ .line = .{ 9, 9, 15, 15 } }, .{ .line = .{ 15, 9, 9, 15 } } },
        .more => &.{ .{ .circle = .{ 5, 12, 1.4 } }, .{ .circle = .{ 12, 12, 1.4 } }, .{ .circle = .{ 19, 12, 1.4 } } },
        .more_vertical => &.{ .{ .circle = .{ 12, 5, 1.4 } }, .{ .circle = .{ 12, 12, 1.4 } }, .{ .circle = .{ 12, 19, 1.4 } } },
        .menu => &.{ .{ .line = .{ 4, 7, 20, 7 } }, .{ .line = .{ 4, 12, 20, 12 } }, .{ .line = .{ 4, 17, 20, 17 } } },
        .sun => &.{
            .{ .circle = .{ 12, 12, 4.5 } },
            .{ .line = .{ 12, 2, 12, 4 } },
            .{ .line = .{ 12, 20, 12, 22 } },
            .{ .line = .{ 2, 12, 4, 12 } },
            .{ .line = .{ 20, 12, 22, 12 } },
            .{ .line = .{ 5, 5, 6.5, 6.5 } },
            .{ .line = .{ 17.5, 17.5, 19, 19 } },
            .{ .line = .{ 19, 5, 17.5, 6.5 } },
            .{ .line = .{ 6.5, 17.5, 5, 19 } },
        },
        .moon => &.{ .{ .arc = .{ 15, 12, 8, 1.5708, 3.14159 } }, .{ .arc = .{ 9, 12, 8, -1.5708, 3.14159 } } },
        .download => &.{ .{ .line = .{ 12, 4, 12, 15 } }, .{ .line = .{ 12, 15, 7, 10 } }, .{ .line = .{ 12, 15, 17, 10 } }, .{ .line = .{ 4, 20, 20, 20 } } },
        .upload => &.{ .{ .line = .{ 12, 16, 12, 5 } }, .{ .line = .{ 12, 5, 7, 10 } }, .{ .line = .{ 12, 5, 17, 10 } }, .{ .line = .{ 4, 20, 20, 20 } } },
        .file => &.{ .{ .line = .{ 6, 3, 14, 3 } }, .{ .line = .{ 14, 3, 19, 8 } }, .{ .line = .{ 19, 8, 19, 21 } }, .{ .line = .{ 19, 21, 6, 21 } }, .{ .line = .{ 6, 21, 6, 3 } }, .{ .line = .{ 14, 3, 14, 8 } }, .{ .line = .{ 14, 8, 19, 8 } } },
        .folder => &.{ .{ .line = .{ 3, 7, 10, 7 } }, .{ .line = .{ 10, 7, 12, 10 } }, .{ .line = .{ 12, 10, 21, 10 } }, .{ .line = .{ 21, 10, 21, 19 } }, .{ .line = .{ 21, 19, 3, 19 } }, .{ .line = .{ 3, 19, 3, 7 } } },
        .link => &.{ .{ .arc = .{ 9, 12, 4, 1.5708, 3.14159 } }, .{ .arc = .{ 15, 12, 4, -1.5708, 3.14159 } }, .{ .line = .{ 9, 12, 15, 12 } } },
        .external => &.{ .{ .line = .{ 5, 5, 5, 19 } }, .{ .line = .{ 5, 19, 19, 19 } }, .{ .line = .{ 19, 19, 19, 9 } }, .{ .line = .{ 11, 13, 20, 4 } }, .{ .line = .{ 14, 4, 20, 4 } }, .{ .line = .{ 20, 4, 20, 10 } } },
        .refresh => &.{ .{ .arc = .{ 12, 12, 8, 0.6, 4.4 } }, .{ .line = .{ 18, 4, 19, 9 } }, .{ .line = .{ 19, 9, 14, 9 } } },
        .filter => &.{ .{ .line = .{ 3, 5, 21, 5 } }, .{ .line = .{ 6, 11, 18, 11 } }, .{ .line = .{ 10, 17, 14, 17 } }, .{ .line = .{ 12, 17, 12, 21 } } },
        .chart_bar => &.{ .{ .line = .{ 3, 20, 21, 20 } }, .{ .rect = .{ 6, 12, 3, 6 } }, .{ .rect = .{ 11, 8, 3, 10 } }, .{ .rect = .{ 16, 15, 3, 3 } } },
        .chart_line => &.{ .{ .line = .{ 3, 20, 21, 20 } }, .{ .line = .{ 4, 16, 9, 11 } }, .{ .line = .{ 9, 11, 14, 14 } }, .{ .line = .{ 14, 14, 20, 6 } } },
        .send => &.{ .{ .line = .{ 3, 12, 21, 12 } }, .{ .line = .{ 21, 12, 14, 5 } }, .{ .line = .{ 21, 12, 14, 19 } } },
        .bookmark => &.{ .{ .line = .{ 6, 3, 18, 3 } }, .{ .line = .{ 18, 3, 18, 21 } }, .{ .line = .{ 18, 21, 12, 16 } }, .{ .line = .{ 12, 16, 6, 21 } }, .{ .line = .{ 6, 21, 6, 3 } } },
        .tag => &.{ .{ .line = .{ 3, 11, 11, 3 } }, .{ .line = .{ 11, 3, 21, 3 } }, .{ .line = .{ 21, 3, 21, 13 } }, .{ .line = .{ 21, 13, 13, 21 } }, .{ .line = .{ 13, 21, 3, 11 } }, .{ .circle = .{ 17, 7, 1.2 } } },
        .play => &.{ .{ .line = .{ 7, 4, 19, 12 } }, .{ .line = .{ 19, 12, 7, 20 } }, .{ .line = .{ 7, 20, 7, 4 } } },
        .pause => &.{ .{ .line = .{ 9, 4, 9, 20 } }, .{ .line = .{ 15, 4, 15, 20 } } },
        .terminal => &.{ .{ .rect = .{ 3, 4, 18, 16 } }, .{ .line = .{ 7, 9, 10, 12 } }, .{ .line = .{ 10, 12, 7, 15 } }, .{ .line = .{ 12, 15, 17, 15 } } },
        .code => &.{ .{ .line = .{ 9, 6, 3, 12 } }, .{ .line = .{ 3, 12, 9, 18 } }, .{ .line = .{ 15, 6, 21, 12 } }, .{ .line = .{ 21, 12, 15, 18 } } },
        .save => &.{ .{ .rect = .{ 4, 4, 16, 16 } }, .{ .line = .{ 8, 4, 8, 10 } }, .{ .line = .{ 8, 10, 16, 10 } }, .{ .rect = .{ 8, 14, 8, 6 } } },
        .cloud => &.{ .{ .arc = .{ 9, 13, 5, 3.3, 2.6 } }, .{ .arc = .{ 15, 13, 5, 3.5, 2.4 } }, .{ .line = .{ 8, 18, 17, 18 } } },
        .database => &.{ .{ .arc = .{ 12, 6, 7, 3.14159, 3.14159 } }, .{ .line = .{ 5, 6, 5, 18 } }, .{ .line = .{ 19, 6, 19, 18 } }, .{ .arc = .{ 12, 18, 7, 0, 3.14159 } }, .{ .arc = .{ 12, 12, 7, 0, 3.14159 } } },
        .cpu => &.{ .{ .rect = .{ 6, 6, 12, 12 } }, .{ .rect = .{ 10, 10, 4, 4 } }, .{ .line = .{ 12, 2, 12, 6 } }, .{ .line = .{ 12, 18, 12, 22 } }, .{ .line = .{ 2, 12, 6, 12 } }, .{ .line = .{ 18, 12, 22, 12 } } },
        .wifi => &.{ .{ .arc = .{ 12, 18, 9, 3.9, 1.6 } }, .{ .arc = .{ 12, 18, 5.5, 3.9, 1.6 } }, .{ .circle = .{ 12, 18, 1.3 } } },
        .battery => &.{ .{ .rect = .{ 3, 7, 16, 10 } }, .{ .line = .{ 19, 10, 22, 10 } }, .{ .line = .{ 22, 10, 22, 14 } }, .{ .line = .{ 19, 14, 22, 14 } }, .{ .rect = .{ 5, 9, 10, 6 } } },
        .mic => &.{ .{ .rect = .{ 9, 3, 6, 11 } }, .{ .arc = .{ 12, 12, 7, 0, 3.14159 } }, .{ .line = .{ 12, 19, 12, 22 } }, .{ .line = .{ 8, 22, 16, 22 } } },
        .palette => &.{ .{ .circle = .{ 12, 12, 9 } }, .{ .circle = .{ 8, 9, 1.3 } }, .{ .circle = .{ 14, 7.5, 1.3 } }, .{ .circle = .{ 16.5, 13, 1.3 } }, .{ .circle = .{ 11, 15.5, 1.3 } } },
        .type => &.{ .{ .line = .{ 5, 6, 19, 6 } }, .{ .line = .{ 12, 6, 12, 20 } }, .{ .line = .{ 8, 20, 16, 20 } } },
        .bold => &.{ .{ .line = .{ 7, 4, 7, 20 } }, .{ .arc = .{ 12, 8, 4, 4.712, 3.1416 } }, .{ .arc = .{ 12, 16, 4, 4.712, 3.1416 } }, .{ .line = .{ 7, 12, 12, 12 } } },
        .italic => &.{ .{ .line = .{ 9, 4, 17, 4 } }, .{ .line = .{ 7, 20, 15, 20 } }, .{ .line = .{ 14, 4, 10, 20 } } },
        .underline => &.{ .{ .line = .{ 7, 4, 7, 12 } }, .{ .line = .{ 17, 4, 17, 12 } }, .{ .arc = .{ 12, 12, 5, 0, 3.14159 } }, .{ .line = .{ 5, 21, 19, 21 } } },
        .list => &.{ .{ .line = .{ 8, 6, 20, 6 } }, .{ .line = .{ 8, 12, 20, 12 } }, .{ .line = .{ 8, 18, 20, 18 } }, .{ .circle = .{ 4, 6, 1.2 } }, .{ .circle = .{ 4, 12, 1.2 } }, .{ .circle = .{ 4, 18, 1.2 } } },
        .grid => &.{ .{ .rect = .{ 3, 3, 8, 8 } }, .{ .rect = .{ 13, 3, 8, 8 } }, .{ .rect = .{ 3, 13, 8, 8 } }, .{ .rect = .{ 13, 13, 8, 8 } } },
        .maximize => &.{ .{ .line = .{ 4, 10, 4, 4 } }, .{ .line = .{ 4, 4, 10, 4 } }, .{ .line = .{ 20, 10, 20, 4 } }, .{ .line = .{ 20, 4, 14, 4 } }, .{ .line = .{ 4, 14, 4, 20 } }, .{ .line = .{ 4, 20, 10, 20 } }, .{ .line = .{ 20, 14, 20, 20 } }, .{ .line = .{ 20, 20, 14, 20 } } },
        .minimize => &.{ .{ .line = .{ 4, 4, 10, 10 } }, .{ .line = .{ 10, 10, 10, 4 } }, .{ .line = .{ 20, 4, 14, 10 } }, .{ .line = .{ 14, 10, 20, 10 } }, .{ .line = .{ 4, 20, 10, 14 } }, .{ .line = .{ 10, 14, 10, 20 } }, .{ .line = .{ 20, 20, 14, 14 } }, .{ .line = .{ 14, 14, 20, 14 } } },
        .move => &.{ .{ .line = .{ 12, 3, 12, 21 } }, .{ .line = .{ 3, 12, 21, 12 } }, .{ .line = .{ 12, 3, 9, 6 } }, .{ .line = .{ 12, 3, 15, 6 } }, .{ .line = .{ 12, 21, 9, 18 } }, .{ .line = .{ 12, 21, 15, 18 } }, .{ .line = .{ 3, 12, 6, 9 } }, .{ .line = .{ 3, 12, 6, 15 } }, .{ .line = .{ 21, 12, 18, 9 } }, .{ .line = .{ 21, 12, 18, 15 } } },
        .zoom_in => &.{ .{ .circle = .{ 10.5, 10.5, 6.5 } }, .{ .line = .{ 15.5, 15.5, 20, 20 } }, .{ .line = .{ 7.5, 10.5, 13.5, 10.5 } }, .{ .line = .{ 10.5, 7.5, 10.5, 13.5 } } },
        .zoom_out => &.{ .{ .circle = .{ 10.5, 10.5, 6.5 } }, .{ .line = .{ 15.5, 15.5, 20, 20 } }, .{ .line = .{ 7.5, 10.5, 13.5, 10.5 } } },
    };
}

/// 单个图标最多有几段（画之前可以用它做预算判断）。
pub fn segCount(icon: Icon) usize {
    return segs(icon).len;
}

/// 在 `rect` 内居中画一个图标（不占布局、不登记命中，纯绘制）。
pub fn draw(ui: *core.Context, icon: Icon, rect: t.Rect, color: t.Color) void {
    const size = @min(rect.w, rect.h);
    if (size <= 1) return;
    const k = size / 24.0;
    const ox = rect.x + (rect.w - size) / 2;
    const oy = rect.y + (rect.h - size) / 2;
    const w = @max(1, size / 12.0);
    for (segs(icon)) |s| {
        switch (s) {
            .line => |p| ui.addOverlayLine(
                .{ .x = ox + p[0] * k, .y = oy + p[1] * k },
                .{ .x = ox + p[2] * k, .y = oy + p[3] * k },
                w,
                color,
            ),
            .circle => |c| ui.addArc(.{ .x = ox + c[0] * k, .y = oy + c[1] * k }, c[2] * k, 0, 6.2831855, color, 10),
            .arc => |a| ui.addArc(.{ .x = ox + a[0] * k, .y = oy + a[1] * k }, a[2] * k, a[3], a[3] + a[4], color, 8),
            .rect => |r| {
                const x0 = ox + r[0] * k;
                const y0 = oy + r[1] * k;
                const x1 = ox + (r[0] + r[2]) * k;
                const y1 = oy + (r[1] + r[3]) * k;
                ui.addOverlayLine(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, w, color);
                ui.addOverlayLine(.{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, w, color);
                ui.addOverlayLine(.{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 }, w, color);
                ui.addOverlayLine(.{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 }, w, color);
            },
        }
    }
}

pub const ButtonOpts = struct {
    /// 边长（正方形）。
    size: f32 = 28,
    /// 实心：强调色底 + 反色图标；否则悬停出浅底。
    solid: bool = false,
    /// 图标颜色（null = 跟着主题/变体走）。
    color: ?t.Color = null,
    /// 禁用（只用颜色区分，不登记命中）。
    disabled: bool = false,
};

/// 图标按钮（对位 `cui_icon_button_ex`）。返回是否被点击。
pub fn iconButton(ui: *core.Context, id: []const u8, icon: Icon, opts: ButtonOpts) bool {
    const side = if (opts.size > 0) opts.size else 28;
    const r = ui.reserve(side, side, false);
    if (opts.disabled) {
        ui.addBox(r, .{ .fill = theme.surface, .radius = 7 });
        draw(ui, icon, .{ .x = r.x + side * 0.2, .y = r.y + side * 0.2, .w = side * 0.6, .h = side * 0.6 }, theme.withAlpha(theme.secondary, 120));
        return false;
    }
    const it = ui.interactEx(core.Context.idOf(id), r, true);
    const hv = anim.hover(ui, core.Context.idOf(id) ^ 0x1C0B, it.hover or it.focused);
    if (opts.solid) {
        const bg = theme.mix(theme.accent, theme.accent_active, hv * 0.6 + (if (it.pressed) @as(f32, 0.3) else 0));
        ui.addBox(r, .{ .fill = bg, .radius = 7 });
    } else if (hv > 0.01 or it.pressed) {
        ui.addBox(r, .{ .fill = theme.withAlpha(theme.track, @intFromFloat(255.0 * @max(hv, 0.35))), .radius = 7 });
    }
    if (it.focused) ui.addBox(r, .{ .border = theme.accent, .radius = 7 });
    const base = opts.color orelse (if (opts.solid) theme.accent_text else theme.text);
    draw(ui, icon, .{ .x = r.x + side * 0.2, .y = r.y + side * 0.2, .w = side * 0.6, .h = side * 0.6 }, base);
    return it.clicked or it.activated;
}

/// 图标 + 文本的一行（列表项、菜单项的常用组合），返回是否被点击。
pub fn iconLabel(ui: *core.Context, id: []const u8, icon: Icon, label: []const u8) bool {
    const m = ui.measureText(label, theme.font_small);
    const h: f32 = 26;
    const rw = ui.reserve(24 + 8 + m.w + 12, h, false);
    const it = ui.interactEx(core.Context.idOf(id), rw, true);
    if (it.hover) ui.addBox(rw, .{ .fill = theme.withAlpha(theme.track, 90), .radius = 6 });
    draw(ui, icon, .{ .x = rw.x + 4, .y = rw.y + (h - 18) / 2, .w = 18, .h = 18 }, theme.secondary);
    ui.addText(.{
        .x = rw.x + 32,
        .y = rw.y + (h - m.h) / 2,
        .w = m.w,
        .h = m.h,
    }, label, theme.font_small, theme.text);
    return it.clicked or it.activated;
}
