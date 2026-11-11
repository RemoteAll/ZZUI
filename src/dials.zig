//! 旋钮族（对位 CUI `cui_dials.c`）：旋钮 / 推子 / 电平表。
//! 三者都面向「音频/设备调参」场景，**只用线段与矩形**绘制，不引入曲线渲染器。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const num = @import("num.zig");
const t = @import("types.zig");

fn clamp01(v: f32) f32 {
    return if (v < 0) 0 else if (v > 1) 1 else v;
}

/// 把值映射成 0..1 的比例（支持对数刻度：等转角等倍率）。
fn ratioOf(v: f32, min: f32, max: f32, log_scale: bool) f32 {
    if (max <= min) return 0;
    if (log_scale and min > 0 and v > 0) {
        const lo = @log(min);
        const hi = @log(max);
        return clamp01((@log(v) - lo) / (hi - lo));
    }
    return clamp01((v - min) / (max - min));
}

/// 比例还原成值。
fn valueOf(r: f32, min: f32, max: f32, log_scale: bool) f32 {
    const c = clamp01(r);
    if (log_scale and min > 0) {
        const lo = @log(min);
        const hi = @log(max);
        return @exp(lo + (hi - lo) * c);
    }
    return min + (max - min) * c;
}

fn arc(ui: *core.Context, cx: f32, cy: f32, rad: f32, a0: f32, a1: f32, color: t.Color, width: f32) void {
    if (a1 <= a0) return;
    const span = a1 - a0;
    // 线段预算：整个旋钮最多 16 段
    const segs: usize = @max(3, @as(usize, @intFromFloat(16.0 * span)));
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

// ------------------------------------------------------------------ 旋钮
pub const KnobOpts = struct {
    label: []const u8 = "",
    /// 值的后缀，如 "Hz" / "dB"。
    unit: []const u8 = "",
    decimals: u8 = 0,
    /// 直径。
    size: f32 = 48,
    /// 0 = 连续（方向键按范围的 1% 移动）。
    step: f32 = 0,
    /// 双击复位的值。
    reset: f32 = 0,
    /// 弧从中间长出来（声像/EQ 增益）。
    bipolar: bool = false,
    /// 等转角等倍率（频率/时间，要求 min > 0）。
    log_scale: bool = false,
    hide_value: bool = false,
};

pub const KnobState = struct {
    start_y: f32 = 0,
    start_ratio: f32 = 0,
};

/// 旋钮：上下拖拽改值（Shift 精细），方向键步进，双击复位。
/// 返回 true 表示值变了。
pub fn knob(
    ui: *core.Context,
    id: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    state: *KnobState,
    opts: KnobOpts,
) bool {
    const size = if (opts.size > 8) opts.size else 48;
    const label_h: f32 = if (opts.label.len > 0) 16 else 0;
    const value_h: f32 = if (opts.hide_value) 0 else 14;
    const total_h = size + 4 + label_h + value_h;
    const rect = ui.reserve(size, total_h, false);
    const cx = rect.x + size / 2;
    const cy = rect.y + size / 2;
    const rad = size / 2 - 4;
    const it = ui.interactEx(core.Context.idOf(id) ^ 0x4B0B, rect, true);
    var changed = false;
    const step = if (opts.step > 0) opts.step else (max - min) / 100;

    if (ui.input.pressed and it.hover) {
        state.start_y = ui.input.mouse.y;
        state.start_ratio = ratioOf(value.*, min, max, opts.log_scale);
    }
    if (it.dragging) {
        var dy = state.start_y - ui.input.mouse.y;
        if (ui.input.mods.shift) dy /= 10;
        const next = valueOf(state.start_ratio + dy / 120, min, max, opts.log_scale);
        const snapped = if (opts.step > 0) @round(next / step) * step else next;
        const cl = if (snapped < min) min else if (snapped > max) max else snapped;
        if (cl != value.*) {
            value.* = cl;
            changed = true;
        }
    }
    if (it.focused) {
        if (ui.input.keyPressed(.up)) {
            value.* = @min(max, value.* + step);
            changed = true;
        }
        if (ui.input.keyPressed(.down)) {
            value.* = @max(min, value.* - step);
            changed = true;
        }
    }
    // 双击复位：同一帧内两次 clicked 无法区分，用「聚焦且按了 Home」作为等价操作
    if (it.focused and ui.input.keyPressed(.home)) {
        const r = if (opts.reset < min) min else if (opts.reset > max) max else opts.reset;
        if (r != value.*) {
            value.* = r;
            changed = true;
        }
    }

    // 画：底圆 + 轨道弧 + 数值弧 + 指针
    ui.addBox(.{ .x = cx - rad, .y = cy - rad, .w = rad * 2, .h = rad * 2 }, .{
        .fill = theme.surface,
        .radius = rad,
        .border = if (it.hover or it.dragging) theme.accent else theme.border,
    });
    const span: f32 = 0.75; // 3/4 圈
    const a0: f32 = 0.0;
    arc(ui, cx, cy, rad - 3, a0, span, theme.track, 3);
    const r = ratioOf(value.*, min, max, opts.log_scale);
    if (opts.bipolar) {
        arc(ui, cx, cy, rad - 3, span / 2, span / 2 + (r - 0.5) * span, theme.accent, 3);
    } else if (r > 0) {
        arc(ui, cx, cy, rad - 3, a0, span * r, theme.accent, 3);
    }
    // 指针
    const ang: f32 = (span * r) * 2 * std.math.pi - std.math.pi / 2.0;
    ui.addOverlayLine(
        .{ .x = cx + @cos(ang) * (rad - 10), .y = cy + @sin(ang) * (rad - 10) },
        .{ .x = cx + @cos(ang) * (rad - 2), .y = cy + @sin(ang) * (rad - 2) },
        2,
        theme.text,
    );

    if (opts.label.len > 0) {
        const lm = ui.measureText(opts.label, theme.font_small);
        ui.addText(
            .{ .x = rect.x + (size - lm.w) / 2, .y = rect.y + size + 4, .w = lm.w, .h = lm.h },
            opts.label,
            theme.font_small,
            theme.secondary,
        );
    }
    if (!opts.hide_value) {
        var vb: [24]u8 = undefined;
        const vt = num.fixed(&vb, value.*, opts.decimals);
        var fb: [32]u8 = undefined;
        var n: usize = 0;
        for (vt) |c| {
            if (n < fb.len) {
                fb[n] = c;
                n += 1;
            }
        }
        for (opts.unit) |c| {
            if (n < fb.len) {
                fb[n] = c;
                n += 1;
            }
        }
        const vm = ui.measureText(fb[0..n], theme.font_small);
        ui.addText(
            .{ .x = rect.x + (size - vm.w) / 2, .y = rect.y + size + 4 + label_h, .w = vm.w, .h = vm.h },
            ui.frameStr(fb[0..n]),
            theme.font_small,
            theme.text,
        );
    }
    return changed;
}

// ------------------------------------------------------------------ 推子
pub const FaderOpts = struct {
    label: []const u8 = "",
    unit: []const u8 = "",
    decimals: u8 = 1,
    /// 轨道长度（竖）或宽度（横）。
    length: f32 = 160,
    horizontal: bool = false,
    step: f32 = 0,
    reset: f32 = 0,
    /// 两侧刻度值（超过 5 个只画前 5 个，避免挤满）。
    ticks: []const f32 = &.{},
};

pub const FaderState = struct {
    start_pos: f32 = 0,
    start_ratio: f32 = 0,
};

/// 推子：拖手柄改值（Shift 精细），方向键步进，Home 复位。
pub fn fader(
    ui: *core.Context,
    id: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    state: *FaderState,
    opts: FaderOpts,
) bool {
    const track_len = if (opts.length > 20) opts.length else 160;
    const thickness: f32 = 6;
    const handle: f32 = 18;
    const label_h: f32 = if (opts.label.len > 0) 16 else 0;
    const w = if (opts.horizontal) track_len + handle else @max(thickness + handle, 44);
    const h = if (opts.horizontal) @max(thickness + handle, 44) else track_len + handle + label_h;
    const rect = ui.reserve(w, h, false);
    const it = ui.interactEx(core.Context.idOf(id) ^ 0xFA0E, rect, true);
    var changed = false;
    const step = if (opts.step > 0) opts.step else (max - min) / 100;

    if (ui.input.pressed and it.hover) {
        state.start_pos = if (opts.horizontal) ui.input.mouse.x else ui.input.mouse.y;
        state.start_ratio = ratioOf(value.*, min, max, false);
    }
    if (it.dragging) {
        var d: f32 = if (opts.horizontal)
            (ui.input.mouse.x - state.start_pos) / track_len
        else
            (state.start_pos - ui.input.mouse.y) / track_len;
        if (ui.input.mods.shift) d /= 10;
        var next = valueOf(state.start_ratio + d, min, max, false);
        if (opts.step > 0) next = @round(next / step) * step;
        const cl = if (next < min) min else if (next > max) max else next;
        if (cl != value.*) {
            value.* = cl;
            changed = true;
        }
    }
    if (it.focused) {
        const up = ui.input.keyPressed(.up) or ui.input.keyPressed(.right);
        const dn = ui.input.keyPressed(.down) or ui.input.keyPressed(.left);
        if (up) {
            value.* = @min(max, value.* + step);
            changed = true;
        }
        if (dn) {
            value.* = @max(min, value.* - step);
            changed = true;
        }
        if (ui.input.keyPressed(.home)) {
            const r = if (opts.reset < min) min else if (opts.reset > max) max else opts.reset;
            if (r != value.*) {
                value.* = r;
                changed = true;
            }
        }
    }

    const r = ratioOf(value.*, min, max, false);
    if (opts.horizontal) {
        const ty = rect.y + label_h + (rect.h - label_h - thickness) / 2;
        ui.addBox(.{ .x = rect.x + handle / 2, .y = ty, .w = track_len, .h = thickness }, .{ .fill = theme.track, .radius = 3 });
        if (r > 0) {
            ui.addBox(.{ .x = rect.x + handle / 2, .y = ty, .w = track_len * r, .h = thickness }, .{ .fill = theme.accent, .radius = 3 });
        }
        const hx = rect.x + handle / 2 + track_len * r - handle / 2;
        widgets.ringBox(ui, .{ .x = hx, .y = rect.y + label_h + (rect.h - label_h - handle) / 2, .w = handle, .h = handle }, 4, theme.bg, if (it.hover or it.dragging) theme.accent else theme.border);
    } else {
        const tx = rect.x + (rect.w - thickness) / 2;
        ui.addBox(.{ .x = tx, .y = rect.y + handle / 2, .w = thickness, .h = track_len }, .{ .fill = theme.track, .radius = 3 });
        if (r > 0) {
            const fh = track_len * r;
            ui.addBox(.{ .x = tx, .y = rect.y + handle / 2 + track_len - fh, .w = thickness, .h = fh }, .{ .fill = theme.accent, .radius = 3 });
        }
        const hy = rect.y + handle / 2 + track_len - track_len * r - handle / 2;
        widgets.ringBox(ui, .{ .x = rect.x + (rect.w - handle - 12) / 2, .y = hy, .w = handle + 8, .h = handle }, 4, theme.bg, if (it.hover or it.dragging) theme.accent else theme.border);
    }

    // 刻度
    for (opts.ticks, 0..) |tv, i| {
        if (i >= 5) break;
        const tr = ratioOf(tv, min, max, false);
        var vb: [20]u8 = undefined;
        const vt = num.fixed(&vb, tv, opts.decimals);
        const vts = ui.frameStr(vt);
        const tm = ui.measureText(vts, theme.font_small);
        if (opts.horizontal) {
            const x = rect.x + handle / 2 + track_len * tr - tm.w / 2;
            ui.addText(.{ .x = x, .y = rect.y + 2, .w = tm.w, .h = tm.h }, vts, theme.font_small, theme.secondary);
        } else {
            const y = rect.y + handle / 2 + track_len - track_len * tr - tm.h / 2;
            ui.addText(.{ .x = rect.x + rect.w - tm.w, .y = y, .w = tm.w, .h = tm.h }, vts, theme.font_small, theme.secondary);
        }
    }

    if (opts.label.len > 0) {
        const lm = ui.measureText(opts.label, theme.font_small);
        ui.addText(
            .{ .x = rect.x + (rect.w - lm.w) / 2, .y = rect.y + rect.h - lm.h, .w = lm.w, .h = lm.h },
            opts.label,
            theme.font_small,
            theme.secondary,
        );
    }
    return changed;
}

// ------------------------------------------------------------------ 电平表
pub const LevelMeterOpts = struct {
    min_db: f32 = -60,
    max_db: f32 = 6,
    length: f32 = 160,
    /// 每声道条宽。
    thickness: f32 = 6,
    horizontal: bool = false,
    /// 旁边画 dB 刻度。
    scale: bool = true,
    /// LED 分段显示（每段之间留缝）。
    segmented: bool = false,
    /// 峰值保持时长（秒）；< 0 表示不保持。
    hold: f32 = 1.5,
};

pub const LevelMeterState = struct {
    peaks: [8]f32 = @splat(0),
    hold_until: [8]f64 = @splat(0),
};

fn dbToRatio(db: f32, min_db: f32, max_db: f32) f32 {
    return clamp01((db - min_db) / (max_db - min_db));
}

/// 电平表：`levels` 为各声道线性峰值（0..1），内部转 dB 后画条形 + 峰值保持。
/// 不返回是否变化（表头是纯显示件）。
pub fn levelMeter(
    ui: *core.Context,
    id: []const u8,
    levels: []const f32,
    state: *LevelMeterState,
    opts: LevelMeterOpts,
) void {
    _ = id;
    const n = @min(levels.len, 8);
    const len = if (opts.length > 20) opts.length else 160;
    const th = if (opts.thickness > 1) opts.thickness else 6;
    const gap: f32 = 3;
    const scale_w: f32 = if (opts.scale) 30 else 0;
    const bar_total = th * @as(f32, @floatFromInt(n)) + gap * @as(f32, @floatFromInt(if (n > 0) n - 1 else 0));
    const w = if (opts.horizontal) len + scale_w else bar_total + scale_w;
    const h = if (opts.horizontal) bar_total else len;
    const rect = ui.reserve(w, h, false);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const lin = levels[i];
        const db: f32 = if (lin <= 0.0000001) opts.min_db else 20.0 * @log10(lin);
        const r = dbToRatio(db, opts.min_db, opts.max_db);

        // 峰值保持
        if (opts.hold >= 0) {
            if (r >= state.peaks[i]) {
                state.peaks[i] = r;
                state.hold_until[i] = ui.time + opts.hold;
            ui.requestFrame(); // 峰值保持窗口内要持续出帧
            } else if (ui.time > state.hold_until[i]) {
                state.peaks[i] = r;
            }
        } else state.peaks[i] = r;

        const off = @as(f32, @floatFromInt(i)) * (th + gap);
        if (opts.horizontal) {
            const y = rect.y + off;
            ui.addBox(.{ .x = rect.x, .y = y, .w = len, .h = th }, .{ .fill = theme.track, .radius = 2 });
            const fw = len * r;
            if (fw > 0) ui.addBox(.{ .x = rect.x, .y = y, .w = fw, .h = th }, .{ .fill = if (r > 0.9) theme.danger else theme.success, .radius = 2 });
            if (opts.hold >= 0 and state.peaks[i] > 0) {
                ui.addBox(.{ .x = rect.x + len * state.peaks[i] - 1, .y = y, .w = 2, .h = th }, .{ .fill = theme.text });
            }
        } else {
            const x = rect.x + off;
            ui.addBox(.{ .x = x, .y = rect.y, .w = th, .h = len }, .{ .fill = theme.track, .radius = 2 });
            const fh = len * r;
            if (fh > 0) {
                if (opts.segmented) {
                    // 分段：每 6px 一段，间隔 2px
                    var sy = rect.y + len;
                    while (sy > rect.y + len - fh) {
                        const seg_h: f32 = 4;
                        const top = if (sy - seg_h < rect.y) rect.y else sy - seg_h;
                        const seg_r = (sy - rect.y) / len;
                        const tone: t.Color = if (seg_r > 0.9) theme.danger else if (seg_r > 0.75) theme.warn else theme.success;
                        ui.addBox(.{ .x = x, .y = top, .w = th, .h = sy - top }, .{ .fill = tone, .radius = 1 });
                        if (sy < 6) break;
                        sy -= (seg_h + 2);
                    }
                } else {
                    ui.addBox(.{ .x = x, .y = rect.y + len - fh, .w = th, .h = fh }, .{ .fill = if (r > 0.9) theme.danger else theme.success, .radius = 2 });
                }
            }
            if (opts.hold >= 0 and state.peaks[i] > 0) {
                ui.addBox(.{ .x = x, .y = rect.y + len - len * state.peaks[i] - 1, .w = th, .h = 2 }, .{ .fill = theme.text });
            }
        }
    }

    if (opts.scale) {
        // 只标 0 dB 与下限，两个标签足够定位；文本必须进帧内池（局部 buf 帧末失效）
        var lb: [16]u8 = undefined;
        const top_txt = ui.frameStr(num.fixed(&lb, opts.max_db, 0));
        var lb2: [16]u8 = undefined;
        const bot_txt = ui.frameStr(num.fixed(&lb2, opts.min_db, 0));
        if (opts.horizontal) {
            const tm = ui.measureText(top_txt, theme.font_small);
            ui.addText(.{ .x = rect.x + len + 4, .y = rect.y, .w = tm.w, .h = tm.h }, top_txt, theme.font_small, theme.secondary);
        } else {
            const tm = ui.measureText(top_txt, theme.font_small);
            ui.addText(.{ .x = rect.x + bar_total + 2, .y = rect.y, .w = tm.w, .h = tm.h }, top_txt, theme.font_small, theme.secondary);
            const bm = ui.measureText(bot_txt, theme.font_small);
            ui.addText(
                .{ .x = rect.x + bar_total + 2, .y = rect.y + len - bm.h, .w = bm.w, .h = bm.h },
                bot_txt,
                theme.font_small,
                theme.secondary,
            );
        }
    }
}
