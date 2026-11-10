//! 控件：立即模式函数。状态全部由调用方变量保存（与 CUI 一致）。
//! 交互一律对上一帧矩形判定（`Context.interactEx`），所以点击落在用户看到的位置。
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

/// 1px 圆角边框：外圈画边框色、内圈画填充色（比 4 条矩形拼边框更圆顺）。
fn ringBox(ui: *core.Context, rect: t.Rect, radius: f32, fill: t.Color, border: t.Color) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    ui.addBox(rect, .{ .fill = border, .radius = radius });
    const r2 = if (radius > 1) radius - 1 else 0;
    ui.addBox(rect.inset(1), .{ .fill = fill, .radius = r2 });
}

pub fn heading(ui: *core.Context, s: []const u8, level: u8) void {
    const size: f32 = switch (level) {
        1 => 32,
        2 => theme.font_heading,
        else => 20,
    };
    _ = ui.textRun(s, size, theme.text);
}

pub fn text(ui: *core.Context, s: []const u8) void {
    _ = ui.textRun(s, theme.font_body, theme.text);
}

pub fn secondary(ui: *core.Context, s: []const u8) void {
    _ = ui.textRun(s, theme.font_body, theme.secondary);
}

pub fn textInt(ui: *core.Context, prefix: []const u8, value: u64, suffix: []const u8) void {
    ui.textIntRun(prefix, value, suffix, theme.font_body, theme.text);
}

/// 水平分隔线（1px，撑满内容宽）。
pub fn separator(ui: *core.Context) void {
    const rect = ui.reserve(0, 1, true);
    ui.addBox(rect, .{ .fill = theme.border });
}

pub const ButtonOpts = struct {
    variant: t.Variant = .secondary,
    width: f32 = 0,
};

pub fn button(ui: *core.Context, label: []const u8, opts: ButtonOpts) bool {
    const m = ui.measureText(label, theme.font_body);
    const h: f32 = 36;
    const w = if (opts.width > 0) opts.width else m.w + 28;
    const rect = ui.reserve(w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x9E3779B97F4A7C15, rect, true);

    switch (opts.variant) {
        .primary => {
            var fill = theme.accent;
            if (it.pressed and it.hover) fill = theme.accent_active;
            ui.addBox(rect, .{ .fill = fill, .radius = theme.radius_control });
        },
        .secondary => {
            var fill = theme.surface;
            if (it.hover) fill = theme.track;
            if (it.pressed and it.hover) fill = theme.border;
            ringBox(ui, rect, theme.radius_control, fill, theme.border);
        },
        .ghost => {
            if (it.hover) ui.addBox(rect, .{ .fill = theme.surface, .radius = theme.radius_control });
        },
    }

    if (it.focused) {
        ui.addBox(rect.inset(-2), .{ .border = theme.accent, .border_width = 1, .radius = theme.radius_control + 2 });
    }
    const label_color: t.Color = if (opts.variant == .primary) theme.accent_text else theme.text;
    const tx = rect.x + (rect.w - m.w) / 2;
    const ty = rect.y + (rect.h - m.h) / 2;
    ui.addText(.{ .x = tx, .y = ty, .w = m.w, .h = m.h }, label, theme.font_body, label_color);
    return it.clicked or it.activated;
}

pub fn controlSwitch(ui: *core.Context, label: []const u8, value: *bool) void {
    const label_size = theme.font_body;
    const m = ui.measureText(label, label_size);
    const track_w: f32 = 44;
    const track_h: f32 = 24;

    var row = ui.row(.{ .gap = 10 });
    defer row.end();

    const lr = ui.reserve(m.w, track_h, false);
    ui.addText(.{ .x = lr.x, .y = lr.y + (lr.h - m.h) / 2, .w = m.w, .h = m.h }, label, label_size, theme.text);

    const tr = ui.reserve(track_w, track_h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x51ED270B, tr, true);
    if (it.clicked or it.activated) value.* = !value.*;

    const on = value.*;
    ui.addBox(tr, .{ .fill = if (on) theme.accent else theme.track, .radius = theme.radius_pill });
    const knob_d: f32 = 18;
    const kx = if (on) tr.x + tr.w - knob_d - 3 else tr.x + 3;
    ui.addBox(.{ .x = kx, .y = tr.y + 3, .w = knob_d, .h = knob_d }, .{
        .fill = t.Color.hex(0xFFFFFF, 255),
        .radius = knob_d / 2,
    });
    if (it.focused) {
        ui.addBox(tr.inset(-2), .{ .border = theme.accent, .border_width = 1, .radius = theme.radius_pill });
    }
}

pub fn checkbox(ui: *core.Context, label: []const u8, value: *bool) void {
    const m = ui.measureText(label, theme.font_body);
    const box: f32 = 18;
    const gap: f32 = 8;
    const h: f32 = 22;
    const rect = ui.reserve(box + gap + m.w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x1B873593, rect, true);
    if (it.clicked or it.activated) value.* = !value.*;

    const bx = rect.x;
    const by = rect.y + (h - box) / 2;
    if (it.focused) {
        ui.addBox(.{ .x = bx - 3, .y = by - 3, .w = box + 6, .h = box + 6 }, .{ .fill = theme.accent, .radius = 7 });
        ui.addBox(.{ .x = bx - 2, .y = by - 2, .w = box + 4, .h = box + 4 }, .{ .fill = theme.bg, .radius = 6 });
    }
    if (value.*) {
        ui.addBox(.{ .x = bx, .y = by, .w = box, .h = box }, .{ .fill = theme.accent, .radius = 4 });
        ui.addOverlayLine(.{ .x = bx + 4.5, .y = by + 9.0 }, .{ .x = bx + 7.5, .y = by + 12.5 }, 2, theme.accent_text);
        ui.addOverlayLine(.{ .x = bx + 7.5, .y = by + 12.5 }, .{ .x = bx + 13.5, .y = by + 5.5 }, 2, theme.accent_text);
    } else {
        ringBox(ui, .{ .x = bx, .y = by, .w = box, .h = box }, 4, t.Color.hex(0xFFFFFF, 255), theme.border);
    }
    ui.addText(.{ .x = bx + box + gap, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, theme.text);
}

pub fn radio(ui: *core.Context, label: []const u8, value: *u32, this_value: u32) void {
    const m = ui.measureText(label, theme.font_body);
    const d: f32 = 18;
    const gap: f32 = 8;
    const h: f32 = 22;
    const rect = ui.reserve(d + gap + m.w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0xCC9E2D51, rect, true);
    if (it.clicked or it.activated) value.* = this_value;

    const cx = rect.x;
    const cy = rect.y + (h - d) / 2;
    if (it.focused) {
        ui.addBox(.{ .x = cx - 3, .y = cy - 3, .w = d + 6, .h = d + 6 }, .{ .fill = theme.accent, .radius = (d + 6) / 2 });
        ui.addBox(.{ .x = cx - 2, .y = cy - 2, .w = d + 4, .h = d + 4 }, .{ .fill = theme.bg, .radius = (d + 4) / 2 });
    }
    if (value.* == this_value) {
        ui.addBox(.{ .x = cx, .y = cy, .w = d, .h = d }, .{ .fill = theme.accent, .radius = d / 2 });
        const dot: f32 = 8;
        ui.addBox(.{ .x = cx + (d - dot) / 2, .y = cy + (d - dot) / 2, .w = dot, .h = dot }, .{
            .fill = t.Color.hex(0xFFFFFF, 255),
            .radius = dot / 2,
        });
    } else {
        ringBox(ui, .{ .x = cx, .y = cy, .w = d, .h = d }, d / 2, t.Color.hex(0xFFFFFF, 255), theme.border);
    }
    ui.addText(.{ .x = cx + d + gap, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, theme.text);
}

/// 滑杆：点击/拖拽轨道改值；获得焦点后左右方向键步进。
pub fn slider(ui: *core.Context, label: []const u8, value: *f32, min: f32, max: f32) void {
    const m = ui.measureText(label, theme.font_small);
    var col = ui.column(.{ .gap = 6 });
    defer col.end();

    const lr = ui.reserve(m.w, m.h, false);
    ui.addText(.{ .x = lr.x, .y = lr.y, .w = m.w, .h = m.h }, label, theme.font_small, theme.secondary);

    const track_h: f32 = 6;
    const row_h: f32 = 24;
    const rect = ui.reserve(0, row_h, true);
    const track = t.Rect{ .x = rect.x, .y = rect.y + (row_h - track_h) / 2, .w = rect.w, .h = track_h };
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x165667B1, rect, true);

    const step = (max - min) / 20;
    if (it.dragging and track.w > 0) {
        var ratio = (ui.input.mouse.x - track.x) / track.w;
        if (ratio < 0) ratio = 0;
        if (ratio > 1) ratio = 1;
        value.* = min + (max - min) * ratio;
    }
    if (it.focused) {
        if (ui.input.keyPressed(.left)) value.* -= step;
        if (ui.input.keyPressed(.right)) value.* += step;
    }
    if (value.* < min) value.* = min;
    if (value.* > max) value.* = max;

    const ratio: f32 = if (max > min) (value.* - min) / (max - min) else 0;
    ui.addBox(track, .{ .fill = theme.track, .radius = track_h / 2 });
    if (ratio > 0) {
        ui.addBox(.{ .x = track.x, .y = track.y, .w = track.w * ratio, .h = track_h }, .{
            .fill = theme.accent,
            .radius = track_h / 2,
        });
    }
    const d: f32 = 16;
    const thumb_x = track.x + track.w * ratio - d / 2;
    const thumb_y = rect.y + (row_h - d) / 2;
    if (it.focused) {
        ui.addBox(.{ .x = thumb_x - 3, .y = thumb_y - 3, .w = d + 6, .h = d + 6 }, .{ .fill = theme.accent, .radius = (d + 6) / 2 });
        ui.addBox(.{ .x = thumb_x - 2, .y = thumb_y - 2, .w = d + 4, .h = d + 4 }, .{ .fill = theme.bg, .radius = (d + 4) / 2 });
    }
    ui.addBox(.{ .x = thumb_x, .y = thumb_y, .w = d, .h = d }, .{ .fill = theme.accent, .radius = d / 2 });
    ui.addBox(.{ .x = thumb_x + 2, .y = thumb_y + 2, .w = d - 4, .h = d - 4 }, .{
        .fill = t.Color.hex(0xFFFFFF, 255),
        .radius = (d - 4) / 2,
    });
}
