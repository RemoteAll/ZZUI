//! 动效核心（对位 CUI 的 `cui__tween` / `cui__spring` 的**指数趋近**版本）。
//!
//! 口径（都是踩过坑定下来的）：
//! - **不用弹簧**：一律 `approach(cur, target, dt, rate)`，单调逼近、不超调；
//! - 状态按 **id** 存在 `Context.tracks` 里（跨帧、有界、按最久未用淘汰）；
//! - `dt` 来自 `ui.time`，所以**需要调用方持续出帧**；后端空闲不出帧时动画会停在中途
//!   （下一帧会因 dt 被夹到 0.1s 而直接收敛，不会跳变）；
//! - **只做颜色/不透明度的插值，不做几何位移**：位移会改命中矩形，而本项目输入是
//!   「对上一帧矩形判定」，两者混用很容易出现「按钮跑掉了点不到」。
const std = @import("std");
const core = @import("core.zig");
const t = @import("types.zig");

/// 单帧最大步进（丢帧时不让动画瞬移）。
const max_dt: f32 = 0.1;

/// 悬停淡入淡出速率（≈ 每帧 22% → 4~5 帧到位）。
pub const rate_hover: f32 = 14;
/// 选中/激活状态的切换速率（比悬停略快）。
pub const rate_toggle: f32 = 18;

/// 标量插值。
pub fn lerp(a: f32, b: f32, x: f32) f32 {
    return a + (b - a) * x;
}

/// 颜色插值（各通道分别插值，含 alpha）。
pub fn mix(a: t.Color, b: t.Color, x: f32) t.Color {
    const f = clampF(x, 0, 1);
    return .{
        .r = @intFromFloat(@round(lerp(@floatFromInt(a.r), @floatFromInt(b.r), f))),
        .g = @intFromFloat(@round(lerp(@floatFromInt(a.g), @floatFromInt(b.g), f))),
        .b = @intFromFloat(@round(lerp(@floatFromInt(a.b), @floatFromInt(b.b), f))),
        .a = @intFromFloat(@round(lerp(@floatFromInt(a.a), @floatFromInt(b.a), f))),
    };
}

fn clampF(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn trackFor(ui: *core.Context, id: u64) *core.AnimTrack {
    var i: usize = 0;
    while (i < ui.track_n) : (i += 1) {
        if (ui.tracks[i].id == id) return &ui.tracks[i];
    }
    if (ui.track_n < ui.tracks.len) {
        ui.tracks[ui.track_n] = .{ .id = id };
        ui.track_n += 1;
        return &ui.tracks[ui.track_n - 1];
    }
    // 池满：淘汰最久未使用的那条（**有界**，不会随控件数量无限增长）
    var oldest: usize = 0;
    for (ui.tracks, 0..) |tr, k| {
        if (tr.used < ui.tracks[oldest].used) oldest = k;
    }
    ui.tracks[oldest] = .{ .id = id };
    return &ui.tracks[oldest];
}

/// 推进一条轨道并返回当前值。
/// **首次**建立轨道时直接对齐到 `target`：启动那一刻不搞「全体淡入」，
/// 只有**之后的变化**才走过渡（否则每次开窗所有控件都会从 0 爬上来）。
pub fn step(ui: *core.Context, id: u64, target: f32, rate: f32) f32 {
    const tr = trackFor(ui, id);
    if (tr.last == 0) {
        tr.value = target;
        tr.last = ui.time;
        tr.used = ui.time;
        return target;
    }
    var dt: f32 = 0;
    if (tr.last > 0 and ui.time > tr.last) dt = @floatCast(ui.time - tr.last);
    tr.last = ui.time;
    tr.used = ui.time;
    if (dt > max_dt) dt = max_dt;
    const k = @min(@as(f32, 1), dt * rate);
    tr.value += (target - tr.value) * k;
    // 收敛后吸附到位，避免永远差 0.0001 导致每帧都在重算
    if (@abs(tr.value - target) < 0.002) tr.value = target;
    // 没到位就要求下一帧（空闲节流靠这个标志；否则停在半路）
    if (tr.value != target) ui.requestFrame();
    return tr.value;
}

/// 悬停淡入淡出：`on` 为真趋近 1，否则趋近 0。
pub fn hover(ui: *core.Context, id: u64, on: bool) f32 {
    return step(ui, id, if (on) 1 else 0, rate_hover);
}

/// 开/关类状态（勾选、开关、选中页签）。
pub fn toggle(ui: *core.Context, id: u64, on: bool) f32 {
    return step(ui, id, if (on) 1 else 0, rate_toggle);
}

/// 该轨道是否还有未完成的过渡（供「需要持续出帧」的判断用）。
pub fn isAnimating(ui: *core.Context, id: u64) bool {
    var i: usize = 0;
    while (i < ui.track_n) : (i += 1) {
        if (ui.tracks[i].id == id) {
            const tr = ui.tracks[i];
            return tr.value != 0 and tr.value != 1;
        }
    }
    return false;
}
