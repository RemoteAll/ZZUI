//! 显示与反馈控件族（对位 CUI 的 `cui_widgets.c` / `cui_extras.c` 公开基础件）。
//! 与 `widgets.zig` 的分工：`widgets` 是可交互的基础件（按钮/表单/浮层），
//! 这里是只读呈现件（徽标/进度/骨架/空状态/时间线/卡片容器）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const t = @import("types.zig");

pub const Tone = enum { neutral, accent, success, warn, danger };

pub const ToneColors = struct { fg: t.Color, bg: t.Color };

pub fn toneColors(tone: Tone) ToneColors {
    return switch (tone) {
        .neutral => .{ .fg = theme.secondary, .bg = theme.surface },
        .accent => .{ .fg = theme.accent, .bg = t.Color.hex(0xE8EFFD, 255) },
        .success => .{ .fg = theme.success, .bg = theme.success_bg },
        .warn => .{ .fg = theme.warn, .bg = theme.warn_bg },
        .danger => .{ .fg = theme.danger, .bg = theme.danger_bg },
    };
}

fn clamp01(v: f32) f32 {
    return if (v < 0) 0 else if (v > 1) 1 else v;
}

/// 小号弱化文本（CUI `cui_muted`）。
pub fn muted(ui: *core.Context, s: []const u8) void {
    _ = ui.textRun(s, theme.font_small, theme.secondary);
}

/// 胶囊徽标。
pub fn badge(ui: *core.Context, label: []const u8, tone: Tone) void {
    const c = toneColors(tone);
    const m = ui.measureText(label, theme.font_small);
    const h: f32 = 20;
    const r = ui.reserve(m.w + 16, h, false);
    ui.addBox(r, .{ .fill = c.bg, .radius = theme.radius_pill });
    ui.addText(.{ .x = r.x + 8, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, c.fg);
}

/// 可点击文本链接（带下划线，hover 变深）。
pub fn link(ui: *core.Context, label: []const u8) bool {
    const m = ui.measureText(label, theme.font_body);
    const h: f32 = 22;
    const r = ui.reserve(m.w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x11AC0009, r, true);
    const color = if (it.hover) theme.accent_active else theme.accent;
    if (it.focused) ui.addBox(r.inset(-3), .{ .border = theme.accent, .radius = 6 });
    ui.addText(.{ .x = r.x, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, color);
    const uy = r.y + h - 4;
    ui.addOverlayLine(.{ .x = r.x, .y = uy }, .{ .x = r.x + m.w, .y = uy }, 1, color);
    return it.clicked or it.activated;
}

/// 内联代码片段（浅底 + 左侧细条）。
pub fn code(ui: *core.Context, s: []const u8) void {
    const m = ui.measureText(s, theme.font_small);
    const h: f32 = m.h + 8;
    const r = ui.reserve(m.w + 14, h, false);
    ui.addBox(r, .{ .fill = theme.surface, .radius = 6 });
    ui.addBox(.{ .x = r.x, .y = r.y, .w = 2, .h = r.h }, .{ .fill = theme.border });
    ui.addText(.{ .x = r.x + 8, .y = r.y + 4, .w = m.w, .h = m.h }, s, theme.font_small, theme.text);
}

/// 键帽序列：空格分隔，每个键一个键帽（CUI `cui_kbd`）。
pub fn kbd(ui: *core.Context, keys: []const u8) void {
    var row = ui.row(.{ .gap = 4 });
    defer row.end();
    var start: usize = 0;
    var i: usize = 0;
    while (i <= keys.len) : (i += 1) {
        if (i == keys.len or keys[i] == ' ') {
            if (i > start) keycap(ui, keys[start..i]);
            start = i + 1;
        }
    }
}

fn keycap(ui: *core.Context, key: []const u8) void {
    const m = ui.measureText(key, theme.font_small);
    const h: f32 = 20;
    const w = @max(m.w + 10, 20);
    const r = ui.reserve(w, h, false);
    widgets.ringBox(ui, r, 5, theme.bg, theme.border);
    ui.addBox(.{ .x = r.x + 1, .y = r.y + r.h - 3, .w = r.w - 2, .h = 1 }, .{ .fill = theme.track });
    ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + (h - m.h) / 2 - 1, .w = m.w, .h = m.h }, key, theme.font_small, theme.secondary);
}

pub const ProgressOpts = struct {
    height: f32 = 8,
    tone: Tone = .accent,
    label: []const u8 = "",
};

/// 进度条（`value` 取 0..1，越界自动夹取）。
/// 带 `label` 时上方先画一行「标签 + 百分比」，条本身体撑满。
pub fn progress(ui: *core.Context, value: f32, opts: ProgressOpts) void {
    const v = clamp01(value);
    if (opts.label.len > 0) {
        var col = ui.column(.{ .gap = 6 });
        defer col.end();
        var row = ui.row(.{ .gap = 8 });
        defer row.end();
        const lm = ui.measureText(opts.label, theme.font_small);
        const lr = ui.reserve(lm.w, 18, false);
        ui.addText(.{ .x = lr.x, .y = lr.y, .w = lm.w, .h = lm.h }, opts.label, theme.font_small, theme.secondary);
        ui.textIntRun("", @intFromFloat(v * 100), "%", theme.font_small, theme.secondary);
    }
    const r = ui.reserve(0, opts.height, true);
    ui.addBox(r, .{ .fill = theme.track, .radius = opts.height / 2 });
    if (v > 0) {
        ui.addBox(.{ .x = r.x, .y = r.y, .w = r.w * v, .h = r.h }, .{
            .fill = toneColors(opts.tone).fg,
            .radius = opts.height / 2,
        });
    }
}

/// 细条指标（CUI `cui_meter`）：标签 + 百分比一行，细细的条在下方。
pub fn meter(ui: *core.Context, label: []const u8, value: f32) void {
    const v = clamp01(value);
    var col = ui.column(.{ .gap = 5 });
    defer col.end();
    var row = ui.row(.{ .gap = 8 });
    defer row.end();
    const lm = ui.measureText(label, theme.font_small);
    const lr = ui.reserve(lm.w, 18, false);
    ui.addText(.{ .x = lr.x, .y = lr.y, .w = lm.w, .h = lm.h }, label, theme.font_small, theme.secondary);
    ui.textIntRun("", @intFromFloat(v * 100), "%", theme.font_small, theme.secondary);
    const bar = ui.reserve(0, 8, true);
    ui.addBox(bar, .{ .fill = theme.track, .radius = 4 });
    if (v > 0) ui.addBox(.{ .x = bar.x, .y = bar.y, .w = bar.w * v, .h = bar.h }, .{ .fill = theme.accent, .radius = 4 });
}

/// 环形进度（用线段近似圆弧，避免引入曲线渲染器）。
pub fn progressRing(ui: *core.Context, value: f32, size: f32) void {
    const r = ui.reserve(size, size, false);
    const cx = r.x + size / 2;
    const cy = r.y + size / 2;
    const rad = size / 2 - 3;
    const width: f32 = @max(3, size * 0.1);
    arc(ui, cx, cy, rad, 0, 1, theme.track, width);
    const v = clamp01(value);
    if (v > 0) arc(ui, cx, cy, rad, 0, v, theme.accent, width);
}

/// 加载指示器：随时间旋转的四分之一圆（无动画时是一段固定弧）。
pub fn spinner(ui: *core.Context, size: f32) void {
    const r = ui.reserve(size, size, false);
    const cx = r.x + size / 2;
    const cy = r.y + size / 2;
    const rad = size / 2 - 2;
    const phase: f32 = @floatCast(ui.time - @floor(ui.time));
    arc(ui, cx, cy, rad, phase, phase + 0.25, theme.accent, @max(2, size * 0.14));
}

fn arc(ui: *core.Context, cx: f32, cy: f32, rad: f32, a0: f32, a1: f32, color: t.Color, width: f32) void {
    if (a1 <= a0) return;
    const span = a1 - a0;
    const segs: usize = @max(4, @as(usize, @intFromFloat(24.0 * span)));
    const pi: f32 = std.math.pi;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const f0 = a0 + span * (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)));
        const f1 = a0 + span * (@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs)));
        const ang0 = f0 * 2 * pi - pi / 2;
        const ang1 = f1 * 2 * pi - pi / 2;
        ui.addOverlayLine(
            .{ .x = cx + @cos(ang0) * rad, .y = cy + @sin(ang0) * rad },
            .{ .x = cx + @cos(ang1) * rad, .y = cy + @sin(ang1) * rad },
            width,
            color,
        );
    }
}

/// 骨架屏占位块。
pub fn skeleton(ui: *core.Context, w: f32, h: f32) void {
    const r = ui.reserve(w, h, w <= 0);
    ui.addBox(r, .{ .fill = theme.surface, .radius = @min(6, h / 2) });
}

fn centered(ui: *core.Context, s: []const u8, size: f32, color: t.Color) void {
    const m = ui.measureText(s, size);
    const r = ui.reserve(0, m.h + 2, true);
    ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + 1, .w = m.w, .h = m.h }, s, size, color);
}

/// 空状态卡片（标题 + 提示，居中）。
pub fn emptyState(ui: *core.Context, title: []const u8, hint: []const u8) void {
    var col = ui.column(.{ .pad = 24, .gap = 6, .fill = theme.bg, .radius = 12, .border = theme.border });
    defer col.end();
    centered(ui, title, theme.font_body, theme.text);
    if (hint.len > 0) centered(ui, hint, theme.font_small, theme.secondary);
}

pub const CardOpts = struct {
    pad: f32 = 16,
    gap: f32 = 10,
    radius: f32 = 12,
    fill: t.Color = theme.bg,
    border: ?t.Color = theme.border,
};

/// 卡片容器（流式，宽度撑满父级）。
pub fn card(ui: *core.Context, opts: CardOpts) core.Scope {
    return ui.column(.{
        .pad = opts.pad,
        .gap = opts.gap,
        .fill = opts.fill,
        .radius = opts.radius,
        .border = opts.border,
    });
}

/// 指标卡：小标签 + 大数值 + 可选涨跌徽标。
pub fn metric(ui: *core.Context, label: []const u8, value: []const u8, delta: []const u8) void {
    var c = card(ui, .{});
    defer c.end();
    muted(ui, label);
    const m = ui.measureText(value, theme.font_heading);
    const r = ui.reserve(0, m.h, true);
    ui.addText(.{ .x = r.x, .y = r.y, .w = m.w, .h = m.h }, value, theme.font_heading, theme.text);
    if (delta.len > 0) {
        const tone: Tone = if (delta[0] == '-') .danger else .success;
        badge(ui, delta, tone);
    }
}

/// 时间线条目：时间 / 标题 / 正文（左对齐竖排）。
pub fn timelineItem(ui: *core.Context, when: []const u8, title: []const u8, body: []const u8) void {
    var col = ui.column(.{ .pad = 0, .gap = 2 });
    defer col.end();
    if (when.len > 0) _ = ui.textRun(when, theme.font_small, theme.secondary);
    _ = ui.textRun(title, theme.font_body, theme.text);
    if (body.len > 0) _ = ui.textRun(body, theme.font_small, theme.secondary);
}

/// 复制按钮：`copied` 由调用方在真正写入剪贴板后置位（本控件只负责外观与点击）。
pub fn copyButton(ui: *core.Context, id: []const u8, copied: *bool) bool {
    const label = if (copied.*) "Copied" else "Copy";
    const m = ui.measureText(label, theme.font_small);
    const h: f32 = 24;
    const r = ui.reserve(m.w + 20, h, false);
    const it = ui.interactEx(core.Context.idOf(id) ^ 0x0C0F1ED, r, true);
    widgets.ringBox(ui, r, 6, if (it.hover) theme.surface else theme.bg, theme.border);
    const color = if (copied.*) theme.success else theme.text;
    ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, color);
    return it.clicked or it.activated;
}

/// 口令强度条（0..4 档，弱/中/强标注）。
pub fn passwordStrength(ui: *core.Context, score: u8, max: u8) void {
    var row = ui.row(.{ .gap = 4 });
    defer row.end();
    var i: u8 = 0;
    while (i < max) : (i += 1) {
        const r = ui.reserve(36, 6, false);
        const on = i < score;
        const tone: Tone = if (score <= 1) .danger else if (score <= 2) .warn else .success;
        ui.addBox(r, .{ .fill = if (on) toneColors(tone).fg else theme.track, .radius = 3 });
    }
}
