//! 颜色与主题选择（对位 CUI 的 `cui_color_picker` / `cui_theme_switcher` / `cui_theme_toggle`）。
//!
//! `colorPicker`：HSV 取色 —— 左上「饱和度 × 明度」方块 + 下方色相条 + 预览色块 + `#RRGGBB` 读数 + 预设色。
//! `themeSwitcher`：浅色 / 深色（可选「跟随系统」）三段切换，选中即调用 `theme.setMode`。
//!
//! 差异（有意为之，写在这里免得下次当成 bug）：
//! - **不画 2D SV 方块的真实渐变**：软件光栅没有渐变指令，用 8×8 个实色小方块近似（每格 `w/8 × h/8`），
//!   所以取色是**按格对齐**的（8 档饱和度 × 8 档明度）；要更细就把 `SV_N` 调大（节点预算按平方涨）；
//! - **十六进制只显示不可编辑**：单行输入要外部持有缓冲，取色器保持「调用方只给 `*Color`」的签名；
//! - 整块只登记**一个命中**（网格类红线：逐格命中会吃光 `MAX_HITS`），点击/拖拽后按鼠标坐标反算区域；
//! - 色相存在 `knownSize(id ^ 0xC010)` 里：灰阶（S=0）时颜色本身算不出色相，不记住就会「一选灰就跳红」；
//! - `themeSwitcher` 的「跟随系统」**不替调用方决定主题**（框架不读系统设置），只是把选择记进 `*Sel`。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

/// SV 方块的格数（每边）。8×8 = 64 个矩形，单屏放一个取色器足够。
const SV_N: usize = 8;
/// 色相条分几段（24 段 ≈ 每段 15°）。
const HUE_SEG: usize = 24;

pub const Opts = struct {
    width: f32 = 240,
    /// 预设色；空 = 不显示预设行。
    presets: []const t.Color = &.{},
    /// 显示 `#RRGGBB` 读数。
    show_hex: bool = true,
};

/// 主题选择（`system` 只记录，不替调用方解析）。
pub const Sel = enum { light, dark, system };

fn pairId(id: []const u8, salt: u64) u64 {
    return core.Context.idOf(id) ^ salt;
}

// ------------------------------------------------------------------ HSV 换算

pub const Hsv = struct { h: f32 = 0, s: f32 = 0, v: f32 = 0 };

pub fn rgbToHsv(c: t.Color) Hsv {
    const r = @as(f32, @floatFromInt(c.r)) / 255.0;
    const g = @as(f32, @floatFromInt(c.g)) / 255.0;
    const b = @as(f32, @floatFromInt(c.b)) / 255.0;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    var h: f32 = 0;
    if (d > 0.0001) {
        if (mx == r) {
            h = @mod((g - b) / d, 6.0);
        } else if (mx == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h /= 6.0;
        if (h < 0) h += 1.0;
    }
    return .{ .h = h, .s = if (mx > 0) d / mx else 0, .v = mx };
}

pub fn hsvToRgb(hsv: Hsv) t.Color {
    const h = @mod(hsv.h, 1.0) * 6.0;
    const s = @min(@max(hsv.s, 0), 1);
    const v = @min(@max(hsv.v, 0), 1);
    const i = @floor(h);
    const f = h - i;
    const p = v * (1 - s);
    const q = v * (1 - s * f);
    const u = v * (1 - s * (1 - f));
    const seg: u8 = @intFromFloat(@mod(i, 6.0));
    const rgb = switch (seg) {
        0 => .{ v, u, p },
        1 => .{ q, v, p },
        2 => .{ p, v, u },
        3 => .{ p, q, v },
        4 => .{ u, p, v },
        else => .{ v, p, q },
    };
    return .{
        .r = @intFromFloat(@round(rgb[0] * 255)),
        .g = @intFromFloat(@round(rgb[1] * 255)),
        .b = @intFromFloat(@round(rgb[2] * 255)),
        .a = 255,
    };
}

/// `#RRGGBB` 文本（大写）。
pub fn hexOf(c: t.Color, out: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    if (out.len < 7) return "";
    out[0] = '#';
    const ch = [_]u8{ c.r, c.g, c.b };
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        out[1 + i * 2] = hex[ch[i] >> 4];
        out[2 + i * 2] = hex[ch[i] & 0xF];
    }
    return out[0..7];
}

/// 解析 `#RGB` / `#RRGGBB`（大小写均认）。返回 null = 格式不对。
pub fn parseHex(s: []const u8) ?t.Color {
    var body = s;
    if (body.len > 0 and body[0] == '#') body = body[1..];
    if (body.len == 3) {
        const r = hexNibble(body[0]) orelse return null;
        const g = hexNibble(body[1]) orelse return null;
        const b = hexNibble(body[2]) orelse return null;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 255 };
    }
    if (body.len != 6) return null;
    const r = (hexNibble(body[0]) orelse return null) * 16 + (hexNibble(body[1]) orelse return null);
    const g = (hexNibble(body[2]) orelse return null) * 16 + (hexNibble(body[3]) orelse return null);
    const b = (hexNibble(body[4]) orelse return null) * 16 + (hexNibble(body[5]) orelse return null);
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ------------------------------------------------------------------ 取色器

/// 取色器。`value` 是调用方持有的颜色（读改写）；返回是否变了。
pub fn colorPicker(ui: *core.Context, id: []const u8, value: *t.Color, opts: Opts) bool {
    const width = if (opts.width > 0) opts.width else 240;
    const pid = core.Context.idOf(id);
    const sv_h = @round(width * 0.55);
    const hue_h: f32 = 14;
    const foot_h: f32 = 24;
    const total_h = sv_h + 8 + hue_h + 8 + foot_h + (if (opts.presets.len > 0) foot_h + 6 else 0);

    const rect = ui.reserve(width, total_h, false);
    const it = ui.interactEx(pid, rect, true);

    // 色相：从记住的值起步（灰阶算不出色相）
    const hue_key = pid ^ 0xC010;
    var hsv = rgbToHsv(value.*);
    if (ui.knownSize(hue_key)) |k| {
        if (hsv.s < 0.02) hsv.h = k.w;
    }
    ui.rememberSize(hue_key, hsv.h, 0);

    const sv = t.Rect{ .x = rect.x, .y = rect.y, .w = width, .h = sv_h };
    const hue = t.Rect{ .x = rect.x, .y = sv.y + sv_h + 8, .w = width, .h = hue_h };
    const foot = t.Rect{ .x = rect.x, .y = hue.y + hue_h + 8, .w = width, .h = foot_h };
    const presets_y = foot.y + foot_h + 6;

    var changed = false;
    if (it.pressed or it.dragging) {
        const mx = ui.input.mouse.x;
        const my = ui.input.mouse.y;
        if (my >= sv.y and my < sv.y + sv.h and mx >= sv.x and mx < sv.x + sv.w) {
            hsv.s = @min(@max((mx - sv.x) / sv.w, 0), 1);
            hsv.v = 1.0 - @min(@max((my - sv.y) / sv.h, 0), 1);
            value.* = hsvToRgb(hsv);
            changed = true;
        } else if (my >= hue.y and my < hue.y + hue.h and mx >= hue.x and mx < hue.x + hue.w) {
            hsv.h = @min(@max((mx - hue.x) / hue.w, 0), 0.9999);
            value.* = hsvToRgb(hsv);
            changed = true;
        } else if (opts.presets.len > 0 and my >= presets_y and my < presets_y + 20) {
            const idx_f = @floor((mx - rect.x) / 24);
            const idx: usize = @intFromFloat(@max(0, idx_f));
            if (idx < opts.presets.len) {
                value.* = opts.presets[idx];
                changed = true;
            }
        }
    }

    // ---- 画：SV 方块（8×8 实色格）
    const cell_w = sv.w / @as(f32, @floatFromInt(SV_N));
    const cell_h = sv.h / @as(f32, @floatFromInt(SV_N));
    var row: usize = 0;
    while (row < SV_N) : (row += 1) {
        var col: usize = 0;
        while (col < SV_N) : (col += 1) {
            const s = (@as(f32, @floatFromInt(col)) + 0.5) / @as(f32, @floatFromInt(SV_N));
            const v = 1.0 - (@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(SV_N));
            ui.addBox(.{
                .x = sv.x + cell_w * @as(f32, @floatFromInt(col)),
                .y = sv.y + cell_h * @as(f32, @floatFromInt(row)),
                .w = cell_w + 0.5,
                .h = cell_h + 0.5,
            }, .{ .fill = hsvToRgb(.{ .h = hsv.h, .s = s, .v = v }) });
        }
    }
    ui.addBox(sv, .{ .border = theme.border, .radius = 6 });

    // 当前色在方块里的位置（十字）
    const px = sv.x + hsv.s * sv.w;
    const py = sv.y + (1.0 - hsv.v) * sv.h;
    ui.addBox(.{ .x = px - 5, .y = py - 5, .w = 10, .h = 10 }, .{ .border = theme.bg, .radius = 5, .border_width = 2 });
    ui.addBox(.{ .x = px - 5, .y = py - 5, .w = 10, .h = 10 }, .{ .border = theme.text, .radius = 5 });

    // ---- 画：色相条
    var i: usize = 0;
    while (i < HUE_SEG) : (i += 1) {
        const h0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(HUE_SEG));
        ui.addBox(.{
            .x = hue.x + hue.w * h0,
            .y = hue.y,
            .w = hue.w / @as(f32, @floatFromInt(HUE_SEG)) + 0.5,
            .h = hue.h,
        }, .{ .fill = hsvToRgb(.{ .h = h0, .s = 1, .v = 1 }), .radius = if (i == 0 or i + 1 == HUE_SEG) 4 else 0 });
    }
    const hx = hue.x + hsv.h * hue.w;
    ui.addBox(.{ .x = hx - 2.5, .y = hue.y - 2, .w = 5, .h = hue.h + 4 }, .{ .border = theme.text, .radius = 3 });

    // ---- 画：预览 + 读数
    ui.addBox(.{ .x = foot.x, .y = foot.y, .w = foot_h, .h = foot_h }, .{ .fill = value.*, .radius = 6, .border = theme.border });
    if (opts.show_hex) {
        var buf: [8]u8 = undefined;
        const hex = hexOf(value.*, buf[0..]);
        const m = ui.measureText(hex, theme.font_small);
        ui.addMonoText(.{
            .x = foot.x + foot_h + 10,
            .y = foot.y + (foot_h - m.h) / 2,
            .w = m.w + 2,
            .h = m.h,
        }, ui.frameStr(hex), theme.font_small, theme.text);
        var rgb_buf: [32]u8 = undefined;
        const rgbt = std.fmt.bufPrint(rgb_buf[0..], "{d}, {d}, {d}", .{ value.r, value.g, value.b }) catch "";
        ui.addText(.{
            .x = foot.x + foot_h + 10 + m.w + 12,
            .y = foot.y + (foot_h - theme.font_small * 1.4) / 2,
            .w = width - foot_h - m.w - 24,
            .h = theme.font_small * 1.4,
        }, ui.frameStr(rgbt), theme.font_small, theme.secondary);
    }

    // ---- 画：预设色
    if (opts.presets.len > 0) {
        for (opts.presets, 0..) |c, k| {
            const r = t.Rect{ .x = rect.x + 24 * @as(f32, @floatFromInt(k)), .y = presets_y, .w = 20, .h = 20 };
            const same = c.r == value.r and c.g == value.g and c.b == value.b;
            ui.addBox(r, .{ .fill = c, .radius = 5, .border = if (same) theme.text else theme.border });
        }
    }

    return changed;
}

// ------------------------------------------------------------------ 主题切换

const sel_labels3 = [_][]const u8{ "Light", "Dark", "System" };
const sel_labels2 = [_][]const u8{ "Light", "Dark" };

/// 主题切换（对位 `cui_theme_switcher` / `cui_theme_toggle`）。
/// 选中「浅色 / 深色」时**立即** `theme.setMode`；选「跟随系统」只记录到 `sel`（框架不读系统设置）。
/// 返回是否发生了切换。
pub fn themeSwitcher(ui: *core.Context, id: []const u8, sel: *Sel, with_system: bool) bool {
    const labels: []const []const u8 = if (with_system) sel_labels3[0..] else sel_labels2[0..];
    var idx: usize = switch (sel.*) {
        .light => 0,
        .dark => 1,
        .system => 2,
    };
    const before = sel.*;
    controls_segmented(ui, id, labels, &idx);
    const now: Sel = switch (idx) {
        0 => .light,
        1 => .dark,
        else => .system,
    };
    if (now == before) return false;
    sel.* = now;
    switch (now) {
        .light => theme.setMode(.light),
        .dark => theme.setMode(.dark),
        // 系统分支由调用方决定（例如读 OS 设置后自己调 setMode）
        .system => {},
    }
    return true;
}

/// 内联一份最小分段控件（不依赖 `controls.zig`，避免「颜色模块」反向依赖控件层）。
fn controls_segmented(ui: *core.Context, id: []const u8, labels: []const []const u8, active: *usize) void {
    const pad: f32 = 3;
    var rw = ui.row(.{ .gap = 2, .pad = pad, .fill = theme.surface, .radius = 9 });
    defer rw.end();
    for (labels, 0..) |label, i| {
        const m = ui.measureText(label, theme.font_small);
        const h: f32 = 26;
        const r = ui.reserve(m.w + 20, h, false);
        const it = ui.interactEx(pairId(id, 0x5E9 + i), r, true);
        if (it.clicked or it.activated) active.* = i;
        const on = active.* == i;
        if (on) {
            ui.addBox(r, .{ .fill = theme.bg, .radius = 7, .border = theme.border });
        }
        ui.addText(.{ .x = r.x + (r.w - m.w) / 2, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, if (on) theme.text else theme.secondary);
    }
}

/// 一键切换浅/深（对位 `cui_theme_toggle`）。返回切换后的模式。
pub fn themeToggle() theme.Mode {
    theme.toggle();
    return theme.mode;
}
