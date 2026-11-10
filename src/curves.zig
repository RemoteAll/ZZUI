//! 曲线与渐变族（对位 CUI `cui_curves.c` 的编辑器部分）：
//! 贝塞尔曲线编辑器 + 求值、渐变编辑器 + 取色。
//!
//! 求值函数是**纯函数**（不读 `Context`），因此同一份数据在编辑器里画出来的曲线
//! 与运行时采样到的值完全一致 —— 这是 CUI `cui_curve_eval` 的语义约定。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const num = @import("num.zig");
const t = @import("types.zig");

pub const CurveMode = enum(u8) {
    /// 线性：忽略手柄。
    linear = 0,
    /// 三次贝塞尔（手柄生效）。
    free = 1,
};

pub const CurveKey = struct {
    x: f32,
    y: f32,
    /// 指向前一个关键帧的手柄（相对本帧）。
    in_dx: f32 = 0,
    in_dy: f32 = 0,
    /// 指向后一个关键帧的手柄（相对本帧）。
    out_dx: f32 = 0,
    out_dy: f32 = 0,
    mode: CurveMode = .linear,
};

/// 单位化插值（0..1），返回 `p0` 到 `p3` 的三次贝塞尔在参数 `s` 处的位置。
fn cubic(p0: f32, p1: f32, p2: f32, p3: f32, s: f32) f32 {
    const u = 1 - s;
    return u * u * u * p0 + 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s * p3;
}

/// 曲线在 `x` 处的值（与编辑器画出来的一致）。`keys` 需按 x 升序。
pub fn curveEval(keys: []const CurveKey, x: f32) f32 {
    if (keys.len == 0) return 0;
    if (keys.len == 1 or x <= keys[0].x) return keys[0].y;
    if (x >= keys[keys.len - 1].x) return keys[keys.len - 1].y;
    var i: usize = 0;
    while (i + 1 < keys.len) : (i += 1) {
        const a = keys[i];
        const b = keys[i + 1];
        if (x < a.x or x > b.x) continue;
        const dx = b.x - a.x;
        if (dx <= 0) return b.y;
        if (a.mode == .linear) {
            return a.y + (b.y - a.y) * ((x - a.x) / dx);
        }
        // 三次贝塞尔：控制点由手柄给出；先按 x 二分求出参数 s，再取 y
        const p1x = a.x + a.out_dx;
        const p1y = a.y + a.out_dy;
        const p2x = b.x + b.in_dx;
        const p2y = b.y + b.in_dy;
        var lo: f32 = 0;
        var hi: f32 = 1;
        var s: f32 = 0.5;
        var iter: usize = 0;
        while (iter < 18) : (iter += 1) {
            s = (lo + hi) / 2;
            const px = cubic(a.x, p1x, p2x, b.x, s);
            if (px < x) lo = s else hi = s;
        }
        return cubic(a.y, p1y, p2y, b.y, s);
    }
    return keys[keys.len - 1].y;
}

pub const CurveOpts = struct {
    x_min: f32 = 0,
    x_max: f32 = 0,
    y_min: f32 = 0,
    y_max: f32 = 0,
    width: f32 = 0,
    height: f32 = 220,
    x_label: []const u8 = "X",
    y_label: []const u8 = "Y",
    /// 拖动是否吸附到网格。
    snap: bool = false,
    decimals: u8 = 2,
};

pub const CurveResult = struct {
    /// 关键帧被移动/新增/删除，或模式改变。
    changed: bool = false,
    added: i32 = -1,
    removed: i32 = -1,
    selected: i32 = -1,
    hovered: bool = false,
    hover_x: f32 = 0,
    hover_y: f32 = 0,
};

pub const CurveState = struct {
    selected: i32 = -1,
    drag_index: i32 = -1,
    drag_x: f32 = 0,
    drag_y: f32 = 0,
    dragging: bool = false,
};

fn normOf(v: f32, lo: f32, hi: f32) f32 {
    if (hi <= lo) return 0;
    const r = (v - lo) / (hi - lo);
    return if (r < 0) 0 else if (r > 1) 1 else r;
}

/// 曲线编辑器：拖关键帧移动、双击添加、Delete 删除、右键切换线性/贝塞尔。
pub fn curveEditor(
    ui: *core.Context,
    id: []const u8,
    keys: []CurveKey,
    count: *usize,
    state: *CurveState,
    opts: CurveOpts,
) CurveResult {
    var res = CurveResult{ .selected = state.selected };
    const h = if (opts.height > 80) opts.height else 220;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, h + 20, opts.width <= 0);
    const pad: f32 = 26;
    const plot = t.Rect{ .x = rect.x + pad, .y = rect.y + 6, .w = rect.w - pad - 8, .h = h - 12 };
    const x0 = if (opts.x_max > opts.x_min) opts.x_min else 0;
    const x1 = if (opts.x_max > opts.x_min) opts.x_max else 1;
    const y0 = if (opts.y_max > opts.y_min) opts.y_min else 0;
    const y1 = if (opts.y_max > opts.y_min) opts.y_max else 1;
    const n = @min(count.*, keys.len);

    ui.addBox(plot, .{ .fill = theme.bg, .radius = 6, .border = theme.border });
    // 网格
    var g: usize = 0;
    while (g <= 4) : (g += 1) {
        const f = @as(f32, @floatFromInt(g)) / 4;
        const gx = plot.x + plot.w * f;
        const gy = plot.y + plot.h * f;
        ui.addOverlayLine(.{ .x = gx, .y = plot.y }, .{ .x = gx, .y = plot.y + plot.h }, 1, theme.surface);
        ui.addOverlayLine(.{ .x = plot.x, .y = gy }, .{ .x = plot.x + plot.w, .y = gy }, 1, theme.surface);
    }

    // 曲线本体：按采样列画折线（与运行时 `curveEval` 同一函数）。
    // **不能按像素列采样**：500px 宽就是 500 条线段，`MAX_OVERLAYS` 只有 192，
    // 会当场溢出并让后面的控件「莫名不画」。固定 96 段（≈5px/段）视觉足够。
    var px: usize = 0;
    var prev: ?t.Point = null;
    const cols: usize = 96;
    while (px <= cols) : (px += 1) {
        const f = @as(f32, @floatFromInt(px)) / @as(f32, @floatFromInt(cols));
        const xv = x0 + (x1 - x0) * f;
        const yv = curveEval(keys[0..n], xv);
        const p = t.Point{
            .x = plot.x + plot.w * f,
            .y = plot.y + plot.h * (1 - normOf(yv, y0, y1)),
        };
        if (prev) |pv| ui.addOverlayLine(pv, p, 1.6, theme.accent);
        prev = p;
    }

    // 关键帧 + 手柄
    const hit_plot = ui.interactEx(core.Context.idOf(id) ^ 0xC0DE, plot, true);
    if (hit_plot.hover) {
        res.hovered = true;
        res.hover_x = x0 + (x1 - x0) * normOf(ui.input.mouse.x, plot.x, plot.x + plot.w);
        res.hover_y = curveEval(keys[0..n], res.hover_x);
    }
    // 双击添加（立即模式没有双击事件：用 Shift+点击 代替，文档写明）
    if (hit_plot.clicked and ui.input.mods.shift and count.* < keys.len) {
        const nx = x0 + (x1 - x0) * normOf(ui.input.mouse.x, plot.x, plot.x + plot.w);
        var ny = y0 + (y1 - y0) * (1 - normOf(ui.input.mouse.y, plot.y, plot.y + plot.h));
        if (opts.snap) {
            ny = @round(ny * 20) / 20;
        }
        // 插入到保持 x 升序的位置
        var at: usize = 0;
        while (at < count.* and keys[at].x < nx) at += 1;
        var k = count.*;
        while (k > at) : (k -= 1) keys[k] = keys[k - 1];
        keys[at] = .{ .x = nx, .y = ny };
        count.* += 1;
        state.selected = @intCast(at);
        res.changed = true;
        res.added = @intCast(at);
        res.selected = state.selected;
    }

    var i: usize = 0;
    while (i < @min(count.*, keys.len)) : (i += 1) {
        const k = &keys[i];
        const kx = plot.x + plot.w * normOf(k.x, x0, x1);
        const ky = plot.y + plot.h * (1 - normOf(k.y, y0, y1));
        const hz = t.Rect{ .x = kx - 7, .y = ky - 7, .w = 14, .h = 14 };
        const hit = ui.interactEx(core.Context.idOf(id) ^ (0xCE00 + i), hz, true);
        const selected = state.selected == @as(i32, @intCast(i));
        ui.addBox(.{ .x = kx - 4, .y = ky - 4, .w = 8, .h = 8 }, .{
            .fill = if (selected) theme.accent else theme.bg,
            .radius = 4,
            .border = theme.accent,
        });
        if (k.mode == .free) {
            // 手柄：从关键帧指向控制点
            ui.addOverlayLine(.{ .x = kx, .y = ky }, .{ .x = kx + plot.w * normOf(k.out_dx, 0, x1 - x0), .y = ky - plot.h * normOf(k.out_dy, 0, y1 - y0) }, 1, theme.secondary);
            ui.addOverlayLine(.{ .x = kx, .y = ky }, .{ .x = kx + plot.w * normOf(k.in_dx, 0, x1 - x0), .y = ky - plot.h * normOf(k.in_dy, 0, y1 - y0) }, 1, theme.secondary);
        }
        if (hit.clicked) {
            state.selected = @intCast(i);
            res.selected = state.selected;
            if (ui.input.mods.alt) {
                // Alt+点击：切换线性/贝塞尔
                k.mode = if (k.mode == .linear) .free else .linear;
                res.changed = true;
            } else {
                state.drag_index = @intCast(i);
                state.drag_x = ui.input.mouse.x;
                state.drag_y = ui.input.mouse.y;
                state.dragging = true;
            }
        }
    }

    // 拖动
    if (state.dragging and state.drag_index >= 0 and @as(usize, @intCast(state.drag_index)) < count.*) {
        if (ui.input.down) {
            const idx: usize = @intCast(state.drag_index);
            const guess: sf32 = .{
                .x = keys[idx].x + (ui.input.mouse.x - state.drag_x) / plot.w * (x1 - x0),
                .y = keys[idx].y - (ui.input.mouse.y - state.drag_y) / plot.h * (y1 - y0),
            };
            var nx = if (guess.x < x0) x0 else if (guess.x > x1) x1 else guess.x;
            var ny = if (guess.y < y0) y0 else if (guess.y > y1) y1 else guess.y;
            if (opts.snap) {
                nx = @round(nx * 20) / 20;
                ny = @round(ny * 20) / 20;
            }
            // 首尾帧的 x 也要保持单调，避免越界交叉
            if (idx > 0 and nx <= keys[idx - 1].x) nx = keys[idx - 1].x + 0.001;
            if (idx + 1 < count.* and nx >= keys[idx + 1].x) nx = keys[idx + 1].x - 0.001;
            if (nx != keys[idx].x or ny != keys[idx].y) {
                keys[idx].x = nx;
                keys[idx].y = ny;
                res.changed = true;
            }
            state.drag_x = ui.input.mouse.x;
            state.drag_y = ui.input.mouse.y;
        } else {
            state.dragging = false;
            state.drag_index = -1;
        }
    }

    // 删除选中帧（至少留一帧）
    if (ui.input.keyPressed(.delete) and count.* > 1) {
        const at: usize = @intCast(@max(state.selected, 0));
        if (at < count.*) {
            var k = at;
            while (k + 1 < count.*) : (k += 1) keys[k] = keys[k + 1];
            count.* -= 1;
            state.selected = @intCast(@min(at, count.* - 1));
            res.changed = true;
            res.removed = @intCast(at);
            res.selected = state.selected;
        }
    }

    // 轴标签
    var b1: [20]u8 = undefined;
    var b2: [20]u8 = undefined;
    const lx0 = ui.frameStr(num.fixed(&b1, x0, opts.decimals));
    const lx1 = ui.frameStr(num.fixed(&b2, x1, opts.decimals));
    ui.addText(.{ .x = plot.x, .y = rect.y + h, .w = 40, .h = 12 }, lx0, theme.font_small, theme.secondary);
    ui.addText(.{ .x = plot.x + plot.w - 30, .y = rect.y + h, .w = 40, .h = 12 }, lx1, theme.font_small, theme.secondary);
    if (res.hovered) {
        var bx: [20]u8 = undefined;
        var by: [20]u8 = undefined;
        const sx = ui.frameStr(num.fixed(&bx, res.hover_x, opts.decimals));
        const sy = ui.frameStr(num.fixed(&by, res.hover_y, opts.decimals));
        ui.addText(.{ .x = rect.x, .y = plot.y, .w = 24, .h = 12 }, opts.y_label, theme.font_small, theme.secondary);
        ui.addText(.{ .x = plot.x + plot.w - 60, .y = plot.y - 2, .w = 30, .h = 12 }, sx, theme.font_small, theme.secondary);
        ui.addText(.{ .x = plot.x + plot.w - 28, .y = plot.y - 2, .w = 30, .h = 12 }, sy, theme.font_small, theme.secondary);
    }
    return res;
}

const sf32 = struct { x: f32, y: f32 };

// ------------------------------------------------------------------ 渐变
pub const GradientStop = struct {
    t: f32,
    color: t.Color,
};

/// 取渐变在 `t`（0..1）处的颜色（线性插值）。
pub fn gradientEval(stops: []const GradientStop, x: f32) t.Color {
    if (stops.len == 0) return t.Color.transparent;
    if (stops.len == 1) return stops[0].color;
    const at = if (x < 0) 0 else if (x > 1) 1 else x;
    if (at <= stops[0].t) return stops[0].color;
    var i: usize = 0;
    while (i + 1 < stops.len) : (i += 1) {
        const a = stops[i];
        const b = stops[i + 1];
        if (at < a.t or at > b.t) continue;
        const span = b.t - a.t;
        const f: f32 = if (span <= 0) 0 else (at - a.t) / span;
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(a.color.r)) + (@as(f32, @floatFromInt(b.color.r)) - @as(f32, @floatFromInt(a.color.r))) * f),
            .g = @intFromFloat(@as(f32, @floatFromInt(a.color.g)) + (@as(f32, @floatFromInt(b.color.g)) - @as(f32, @floatFromInt(a.color.g))) * f),
            .b = @intFromFloat(@as(f32, @floatFromInt(a.color.b)) + (@as(f32, @floatFromInt(b.color.b)) - @as(f32, @floatFromInt(a.color.b))) * f),
            .a = 255,
        };
    }
    return stops[stops.len - 1].color;
}

pub const GradientOpts = struct {
    width: f32 = 220,
    height: f32 = 24,
    /// 采样条的分段数（越高越平滑，但耗节点）。
    steps: usize = 32,
};

pub const GradientResult = struct {
    changed: bool = false,
    selected: i32 = -1,
    added: i32 = -1,
    removed: i32 = -1,
};

pub const GradientState = struct {
    selected: i32 = -1,
    dragging: bool = false,
};

/// 渐变编辑器：采样条 + 停靠点（拖动改位置，Shift+点击添加，Delete 删除）。
pub fn gradientEditor(
    ui: *core.Context,
    id: []const u8,
    stops: []GradientStop,
    count: *usize,
    state: *GradientState,
    opts: GradientOpts,
) GradientResult {
    var res = GradientResult{ .selected = state.selected };
    const w = if (opts.width > 60) opts.width else 220;
    const bar_h = if (opts.height > 8) opts.height else 24;
    const rect = ui.reserve(w, bar_h + 18, false);
    const bar = t.Rect{ .x = rect.x, .y = rect.y, .w = w, .h = bar_h };
    const n = @min(count.*, stops.len);
    if (n == 0) return res;

    // 采样条：steps 段色块
    const steps = if (opts.steps >= 4) opts.steps else 32;
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const f0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const seg = bar.w / @as(f32, @floatFromInt(steps));
        ui.addBox(.{
            .x = bar.x + seg * @as(f32, @floatFromInt(i)),
            .y = bar.y,
            .w = seg + 1,
            .h = bar_h,
        }, .{ .fill = gradientEval(stops[0..n], f0 + 0.5 / @as(f32, @floatFromInt(steps))) });
    }
    ui.addBox(bar, .{ .border = theme.border, .radius = 4 });

    const bar_hit = ui.interactEx(core.Context.idOf(id) ^ 0x6AD0, bar, false);
    if (bar_hit.clicked and ui.input.mods.shift and count.* < stops.len) {
        const nt = normOf(ui.input.mouse.x, bar.x, bar.x + bar.w);
        var at: usize = 0;
        while (at < n and stops[at].t < nt) at += 1;
        var k = count.*;
        while (k > at) : (k -= 1) stops[k] = stops[k - 1];
        stops[at] = .{ .t = nt, .color = gradientEval(stops[0..n], nt) };
        count.* += 1;
        state.selected = @intCast(at);
        res.changed = true;
        res.added = @intCast(at);
        res.selected = state.selected;
    }

    // 停靠点
    var si: usize = 0;
    while (si < n) : (si += 1) {
        const sx = bar.x + bar.w * normOf(stops[si].t, 0, 1);
        const hz = t.Rect{ .x = sx - 6, .y = bar.y + bar_h - 6, .w = 12, .h = 16 };
        const hit = ui.interactEx(core.Context.idOf(id) ^ (0x6500 + si), hz, true);
        const selected = state.selected == @as(i32, @intCast(si));
        ui.addBox(.{ .x = sx - 5, .y = bar.y + bar_h - 4, .w = 10, .h = 10 }, .{
            .fill = stops[si].color,
            .radius = 2,
            .border = if (selected) theme.accent else theme.border,
            .border_width = 2,
        });
        if (hit.clicked) {
            state.selected = @intCast(si);
            res.selected = state.selected;
            state.dragging = true;
        }
    }

    if (state.dragging and ui.input.down and state.selected >= 0 and @as(usize, @intCast(state.selected)) < n) {
        const idx: usize = @intCast(state.selected);
        var nt = normOf(ui.input.mouse.x, bar.x, bar.x + bar.w);
        if (idx > 0 and nt < stops[idx - 1].t) nt = stops[idx - 1].t;
        if (idx + 1 < n and nt > stops[idx + 1].t) nt = stops[idx + 1].t;
        if (nt != stops[idx].t) {
            stops[idx].t = nt;
            res.changed = true;
        }
    } else if (!ui.input.down) {
        state.dragging = false;
    }

    if (ui.input.keyPressed(.delete) and count.* > 2 and state.selected >= 0) {
        const at: usize = @intCast(state.selected);
        if (at < count.*) {
            var k = at;
            while (k + 1 < count.*) : (k += 1) stops[k] = stops[k + 1];
            count.* -= 1;
            state.selected = @intCast(@min(at, count.* - 1));
            res.changed = true;
            res.removed = @intCast(at);
            res.selected = state.selected;
        }
    }
    return res;
}
