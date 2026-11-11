//! 表单与导航控件族（对位 CUI 的 `cui_controls.c`），沿用 `widgets.zig` 的交互口径：
//! 输入对上一帧矩形判定、状态由调用方保存、控件函数直接返回结果。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const widgets = @import("widgets.zig");
const num = @import("num.zig");
const t = @import("types.zig");

fn pairId(id: []const u8, salt: u64) u64 {
    return core.Context.idOf(id) ^ salt;
}

/// 可切换标签（chip）。
pub fn chip(ui: *core.Context, label: []const u8, selected: *bool) bool {
    const m = ui.measureText(label, theme.font_body);
    const h: f32 = 28;
    const r = ui.reserve(m.w + 22, h, false);
    const it = ui.interactEx(pairId(label, 0xC41F), r, true);
    const toggled = it.clicked or it.activated;
    if (toggled) selected.* = !selected.*;
    const on = selected.*;
    if (on) {
        ui.addBox(r, .{ .fill = theme.accent, .radius = theme.radius_pill });
    } else {
        widgets.ringBox(ui, r, theme.radius_pill, if (it.hover) theme.surface else theme.bg, theme.border);
    }
    const color = if (on) theme.accent_text else theme.text;
    ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, color);
    return toggled;
}

pub const TabsOpts = struct {
    gap: f32 = 4,
    /// 超出可用宽度时换行（11 个页签这类场景必须开，否则会被裁掉）。
    wrap: bool = true,
};

/// 标签页：底部 2px 强调线标识当前页。
pub fn tabs(ui: *core.Context, id: []const u8, labels: []const []const u8, active: *usize) void {
    tabsEx(ui, id, labels, active, .{});
}

/// 与 `tabs` 相同，可配置换行。换行时按「行」整体占位，不会把后续内容挤出去。
pub fn tabsEx(ui: *core.Context, id: []const u8, labels: []const []const u8, active: *usize, opts: TabsOpts) void {
    const h: f32 = 34;
    const avail = ui.width - 48;
    var total: f32 = 0;
    for (labels) |label| total += ui.measureText(label, theme.font_body).w + 24 + opts.gap;
    const wrap = opts.wrap and total > avail and labels.len > 1;

    var rows: usize = 1;
    if (wrap) {
        var x: f32 = 0;
        for (labels) |label| {
            const w = ui.measureText(label, theme.font_body).w + 24 + opts.gap;
            if (x + w > avail and x > 0) {
                rows += 1;
                x = 0;
            }
            x += w;
        }
    }
    const block = ui.reserve(0, h * @as(f32, @floatFromInt(rows)), true);

    var x = block.x;
    var y = block.y;
    for (labels, 0..) |label, i| {
        const m = ui.measureText(label, theme.font_body);
        const w = m.w + 24;
        if (wrap and x + w > block.x + avail and x > block.x) {
            x = block.x;
            y += h;
        }
        const r = t.Rect{ .x = x, .y = y, .w = w, .h = h };
        const it = ui.interactEx(pairId(id, 0x7AB5 +% i), r, true);
        if (it.clicked or it.activated) active.* = i;
        const on = active.* == i;
        const hid = pairId(id, 0x7AB5 +% i);
        // 悬停底淡入、选中下划线淡入（fixture 里第一帧就到位 -> 截图像素不受影响）
        const hv = anim.hover(ui, hid ^ 0x7001, it.hover);
        if (!on and hv > 0.01) ui.addBox(r, .{ .fill = theme.withAlpha(theme.surface, @intFromFloat(255.0 * hv)), .radius = 6 });
        ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + (h - m.h) / 2 - 1, .w = m.w, .h = m.h }, label, theme.font_body, if (on) theme.text else theme.secondary);
        const on_k = anim.toggle(ui, hid ^ 0x7002, on);
        if (on_k > 0.01) ui.addBox(.{ .x = r.x, .y = r.y + h - 2, .w = r.w, .h = 2 }, .{ .fill = theme.withAlpha(theme.accent, @intFromFloat(255.0 * on_k)) });
        x += w + opts.gap;
    }
}

/// 分段控件（iOS 风格）：浅底容器 + 选中块。
pub fn segmented(ui: *core.Context, id: []const u8, labels: []const []const u8, active: *usize) void {
    const pad: f32 = 3;
    var row = ui.row(.{ .gap = 2, .pad = pad, .fill = theme.surface, .radius = 9 });
    defer row.end();
    for (labels, 0..) |label, i| {
        const m = ui.measureText(label, theme.font_small);
        const h: f32 = 26;
        const r = ui.reserve(m.w + 20, h, false);
        const it = ui.interactEx(pairId(id, 0x5E9 + i), r, true);
        if (it.clicked or it.activated) active.* = i;
        const on = active.* == i;
        const hv = anim.hover(ui, pairId(id, 0x5E9 + i) ^ 0x7003, it.hover);
        if (on) {
            ui.addBox(r, .{ .fill = theme.bg, .radius = 7, .border = theme.border });
        } else if (hv > 0.01) {
            ui.addBox(r, .{ .fill = theme.withAlpha(theme.track, @intFromFloat(255.0 * hv)), .radius = 7 });
        }
        ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, if (on) theme.text else theme.secondary);
    }
}

/// 面包屑：末项为当前页（不可点），返回被点击的上级下标。
pub fn breadcrumb(ui: *core.Context, items: []const []const u8, active: usize) ?usize {
    var row = ui.row(.{ .gap = 6 });
    defer row.end();
    var clicked: ?usize = null;
    for (items, 0..) |label, i| {
        if (i > 0) {
            const sep = ui.reserve(8, 20, false);
            const sm = ui.measureText("/", theme.font_small);
            ui.addText(.{ .x = sep.x, .y = sep.y + (20 - sm.h) / 2, .w = sm.w, .h = sm.h }, "/", theme.font_small, theme.border);
        }
        const m = ui.measureText(label, theme.font_small);
        const r = ui.reserve(m.w, 20, false);
        const current = i == active or i + 1 == items.len;
        if (current) {
            ui.addText(.{ .x = r.x, .y = r.y + (20 - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, theme.text);
        } else {
            const it = ui.interactEx(pairId(label, 0xB4EA +% i), r, true);
            if (it.clicked or it.activated) clicked = i;
            const color = if (it.hover) theme.accent_active else theme.accent;
            ui.addText(.{ .x = r.x, .y = r.y + (20 - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, color);
        }
    }
    return clicked;
}

/// 分页：[‹] 第 n / m 页 [›]。
pub fn pagination(ui: *core.Context, id: []const u8, page: *usize, pages: usize) void {
    var row = ui.row(.{ .gap = 8 });
    defer row.end();
    const bw: f32 = 28;
    const bh: f32 = 28;
    const prev = ui.reserve(bw, bh, false);
    if (widgets.buttonRect(ui, prev, "<", .{ .width = bw, .id_salt = pairId(id, 0xE01) }) and page.* > 1) page.* -= 1;
    ui.textIntRun("Page ", page.*, "", theme.font_small, theme.text);
    ui.textIntRun(" / ", pages, "", theme.font_small, theme.secondary);
    const nx = ui.reserve(bw, bh, false);
    if (widgets.buttonRect(ui, nx, ">", .{ .width = bw, .id_salt = pairId(id, 0xE02) }) and page.* < pages) page.* += 1;
}

/// 星级评分（★/☆，点击第 n 颗设为 n）。
pub fn rating(ui: *core.Context, id: []const u8, value: *u8, max: u8) void {
    var row = ui.row(.{ .gap = 2 });
    defer row.end();
    var i: u8 = 0;
    while (i < max) : (i += 1) {
        const r = ui.reserve(22, 24, false);
        const it = ui.interactEx(pairId(id, 0x5A7 + @as(u64, i)), r, true);
        if (it.clicked or it.activated) value.* = if (value.* == i + 1) 0 else i + 1;
        const star = if (i < value.*) "★" else "☆";
        const m = ui.measureText(star, 18);
        const color = if (i < value.*) theme.warn else theme.border;
        ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + (24 - m.h) / 2, .w = m.w, .h = m.h }, star, 18, color);
    }
}

/// 数字步进器：[-] 值 [+]。
pub fn stepper(ui: *core.Context, id: []const u8, value: *i32, min: i32, max: i32) void {
    var row = ui.row(.{ .gap = 6 });
    defer row.end();
    const h: f32 = 28;
    const bw: f32 = 28;
    const dec = ui.reserve(bw, h, false);
    if (widgets.buttonRect(ui, dec, "-", .{ .width = bw, .id_salt = pairId(id, 0xE11) }) and value.* > min) value.* -= 1;
    const vr = ui.reserve(52, h, false);
    var buf: [16]u8 = @splat(0);
    const s = num.int(&buf, @intCast(value.*));
    const m = ui.measureText(s, theme.font_body);
    ui.addText(.{ .x = vr.x + (vr.w - m.w) / 2, .y = vr.y + (h - m.h) / 2, .w = m.w, .h = m.h }, ui.frameStr(s), theme.font_body, theme.text);
    const inc = ui.reserve(bw, h, false);
    if (widgets.buttonRect(ui, inc, "+", .{ .width = bw, .id_salt = pairId(id, 0xE12) }) and value.* < max) value.* += 1;
}

/// 单选组（竖排），返回值变化。
pub fn radioGroup(ui: *core.Context, id: []const u8, labels: []const []const u8, value: *usize) void {
    var col = ui.column(.{ .gap = 6 });
    defer col.end();
    const d: f32 = 18;
    for (labels, 0..) |label, i| {
        const m = ui.measureText(label, theme.font_body);
        const h: f32 = 22;
        const r = ui.reserve(d + 8 + m.w, h, false);
        const it = ui.interactEx(pairId(id, 0x4A11 +% i), r, true);
        if (it.clicked or it.activated) value.* = i;
        const cx = r.x;
        const cy = r.y + (h - d) / 2;
        if (value.* == i) {
            ui.addBox(.{ .x = cx, .y = cy, .w = d, .h = d }, .{ .fill = theme.accent, .radius = d / 2 });
            const dot: f32 = 8;
            ui.addBox(.{ .x = cx + (d - dot) / 2, .y = cy + (d - dot) / 2, .w = dot, .h = dot }, .{ .fill = theme.bg, .radius = dot / 2 });
        } else {
            widgets.ringBox(ui, .{ .x = cx, .y = cy, .w = d, .h = d }, d / 2, theme.bg, if (it.hover) theme.secondary else theme.border);
        }
        if (it.focused) ui.addBox(.{ .x = cx - 3, .y = cy - 3, .w = d + 6, .h = d + 6 }, .{ .border = theme.accent, .radius = (d + 6) / 2 });
        ui.addText(.{ .x = cx + d + 8, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, theme.text);
    }
}

/// 双端滑块（区间选择）：两个圆钮各自可拖拽。
pub fn rangeSlider(ui: *core.Context, id: []const u8, lo: *f32, hi: *f32, min: f32, max: f32) void {
    const h: f32 = 26;
    const r = ui.reserve(0, h, true);
    const track_h: f32 = 6;
    const track = t.Rect{ .x = r.x, .y = r.y + (h - track_h) / 2, .w = r.w, .h = track_h };
    const thumb: f32 = 16;

    if (lo.* < min) lo.* = min;
    if (hi.* > max) hi.* = max;
    if (lo.* > hi.*) lo.* = hi.*;

    const lo_ratio: f32 = if (max > min) (lo.* - min) / (max - min) else 0;
    const hi_ratio: f32 = if (max > min) (hi.* - min) / (max - min) else 1;
    const lo_x = track.x + track.w * lo_ratio;
    const hi_x = track.x + track.w * hi_ratio;

    if (track.w > 0) {
        const lo_hit = t.Rect{ .x = lo_x - thumb / 2 - 2, .y = r.y, .w = thumb + 4, .h = h };
        const hi_hit = t.Rect{ .x = hi_x - thumb / 2 - 2, .y = r.y, .w = thumb + 4, .h = h };
        const it_lo = ui.interactEx(pairId(id, 0x1001), lo_hit, true);
        const it_hi = ui.interactEx(pairId(id, 0x1002), hi_hit, true);
        if (it_lo.dragging) {
            var v = min + (max - min) * ((ui.input.mouse.x - track.x) / track.w);
            if (v < min) v = min;
            if (v > hi.*) v = hi.*;
            lo.* = v;
        }
        if (it_hi.dragging) {
            var v = min + (max - min) * ((ui.input.mouse.x - track.x) / track.w);
            if (v > max) v = max;
            if (v < lo.*) v = lo.*;
            hi.* = v;
        }
    }

    ui.addBox(track, .{ .fill = theme.track, .radius = track_h / 2 });
    const from = track.x + track.w * (if (max > min) (lo.* - min) / (max - min) else 0);
    const to = track.x + track.w * (if (max > min) (hi.* - min) / (max - min) else 1);
    if (to > from) ui.addBox(.{ .x = from, .y = track.y, .w = to - from, .h = track_h }, .{ .fill = theme.accent, .radius = track_h / 2 });
    const ty = r.y + (h - thumb) / 2;
    ui.addBox(.{ .x = from - thumb / 2, .y = ty, .w = thumb, .h = thumb }, .{ .fill = theme.bg, .radius = thumb / 2, .border = theme.accent });
    ui.addBox(.{ .x = to - thumb / 2, .y = ty, .w = thumb, .h = thumb }, .{ .fill = theme.bg, .radius = thumb / 2, .border = theme.accent });
}

/// 侧栏导航项（选中态为强调底色 + 左侧竖条）。
pub fn navItem(ui: *core.Context, label: []const u8, active: bool) bool {
    const m = ui.measureText(label, theme.font_body);
    const h: f32 = 34;
    const r = ui.reserve(0, h, true);
    const it = ui.interactEx(pairId(label, 0x9A11), r, true);
    if (active) {
        ui.addBox(r, .{ .fill = theme.accent_bg, .radius = 8 });
        ui.addBox(.{ .x = r.x, .y = r.y + 6, .w = 3, .h = h - 12 }, .{ .fill = theme.accent, .radius = 2 });
    } else if (it.hover) {
        ui.addBox(r, .{ .fill = theme.surface, .radius = 8 });
    }
    const color = if (active) theme.accent else theme.text;
    ui.addText(.{ .x = r.x + 14, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, color);
    return it.clicked or it.activated;
}
