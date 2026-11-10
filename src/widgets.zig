//! 控件：立即模式函数。状态全部由调用方变量保存（与 CUI 一致）。
//! 交互一律对上一帧矩形判定（`Context.interact`），所以点击落在用户看到的位置。
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

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

pub const ButtonOpts = struct {
    variant: t.Variant = .secondary,
    width: f32 = 0,
};

pub fn button(ui: *core.Context, label: []const u8, opts: ButtonOpts) bool {
    const m = ui.measureText(label, theme.font_body);
    const h: f32 = 36;
    const w = if (opts.width > 0) opts.width else m.w + 28;
    const rect = ui.reserve(w, h, false);
    const it = ui.interact(core.Context.idOf(label) ^ 0x9E3779B97F4A7C15, rect);

    var fill: t.Color = switch (opts.variant) {
        .primary => theme.accent,
        .secondary => theme.surface,
        .ghost => t.Color.transparent,
    };
    if (it.hover and opts.variant == .secondary) fill = theme.track;

    ui.addBox(rect, .{ .fill = fill, .radius = theme.radius_control });
    if (opts.variant != .primary) {
        ui.addBox(rect, .{ .border = theme.border, .border_width = 1, .radius = theme.radius_control });
    }
    const label_color: t.Color = if (opts.variant == .primary) theme.accent_text else theme.text;
    const tx = rect.x + (rect.w - m.w) / 2;
    const ty = rect.y + (rect.h - m.h) / 2;
    ui.addText(.{ .x = tx, .y = ty, .w = m.w, .h = m.h }, label, theme.font_body, label_color);
    return it.clicked;
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
    const it = ui.interact(core.Context.idOf(label) ^ 0x51ED270B, tr);
    if (it.clicked) value.* = !value.*;

    const on = value.*;
    ui.addBox(tr, .{ .fill = if (on) theme.accent else theme.track, .radius = theme.radius_pill });
    const knob_d: f32 = 18;
    const kx = if (on) tr.x + tr.w - knob_d - 3 else tr.x + 3;
    ui.addBox(.{ .x = kx, .y = tr.y + 3, .w = knob_d, .h = knob_d }, .{
        .fill = t.Color.hex(0xFFFFFF, 255),
        .radius = knob_d / 2,
    });
}
