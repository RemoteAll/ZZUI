//! 图表族（对位 CUI 的 `cui_charts.c` 公开件）：迷你折线 / 折线图 / 柱状图 / 环形图 / 仪表盘。
//!
//! 全部用「线段 + 矩形 + 文本」绘制，不引入曲线渲染器与位图：
//! 圆弧用线段近似（段数按角度自适应），因此体积增量只有几 KB。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const num = @import("num.zig");
const t = @import("types.zig");

/// 圆弧线段上限（`MAX_OVERLAYS` = 192，一帧里还有别的线段，这里保守取 20 段/整圈）。
fn arcSegs(span: f32) usize {
    const n: f32 = @max(3.0, 16.0 * span);
    return @as(usize, @intFromFloat(n));
}

fn arc(ui: *core.Context, cx: f32, cy: f32, r: f32, start: f32, span: f32, color: t.Color, width: f32) void {
    if (span <= 0) return;
    const segs = arcSegs(span);
    const pi: f32 = std.math.pi;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const f0 = start + span * (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)));
        const f1 = start + span * (@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs)));
        ui.addOverlayLine(
            .{ .x = cx + @cos(f0 * 2 * pi - pi / 2) * r, .y = cy + @sin(f0 * 2 * pi - pi / 2) * r },
            .{ .x = cx + @cos(f1 * 2 * pi - pi / 2) * r, .y = cy + @sin(f1 * 2 * pi - pi / 2) * r },
            width,
            color,
        );
    }
}

pub const Series = struct {
    values: []const f32,
    /// 透明（alpha = 0）= 跟随主题强调色。
    color: t.Color = t.Color.transparent,
    label: []const u8 = "",
};

/// 序列颜色：未显式指定时跟随当前主题。
fn seriesColor(s: Series) t.Color {
    return if (s.color.a == 0) theme.accent else s.color;
}

/// 选项里的颜色：未显式指定时跟随当前主题。
fn optColor(c: t.Color) t.Color {
    return if (c.a == 0) theme.accent else c;
}

pub const ChartOpts = struct {
    /// 0 表示撑满内容宽。
    width: f32 = 0,
    height: f32 = 160,
    /// 水平网格线条数（0 = 不画网格）。
    grid: u8 = 4,
    /// null = 由数据自动取范围。
    min: ?f32 = null,
    max: ?f32 = null,
    /// 折线是否画数据点。
    points: bool = true,
    /// 折线是否填充面积（仅单序列有效）。
    fill: bool = false,
    /// 柱间距。
    bar_gap: f32 = 3,
    /// 是否画左侧数值标签（min/max）。
    labels: bool = true,
};

const Range = struct { lo: f32, hi: f32 };

fn computeRange(series: []const Series, opts: ChartOpts) Range {
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    for (series) |s| {
        for (s.values) |v| {
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
    }
    if (opts.min) |m| lo = m;
    if (opts.max) |m| hi = m;
    if (!(hi > lo)) {
        hi = lo + 1;
    }
    return .{ .lo = lo, .hi = hi };
}

/// 大数组按步长采样：一帧的线段预算有限（`MAX_OVERLAYS`），不能按点数硬画。
fn strideFor(len: usize) usize {
    return if (len > 110) (len + 109) / 110 else 1;
}

fn fmtValue(buf: []u8, v: f32) []const u8 {
    if (@abs(v) >= 100) return num.fixed(buf, v, 0);
    if (@abs(v - @round(v)) < 0.05) return num.fixed(buf, v, 0);
    return num.fixed(buf, v, 1);
}

const Plot = struct {
    rect: t.Rect,
    lo: f32,
    hi: f32,

    fn y(self: Plot, v: f32) f32 {
        const span = self.hi - self.lo;
        const r = if (span > 0) (v - self.lo) / span else 0;
        const c = if (r < 0) 0 else if (r > 1) 1 else r;
        return self.rect.y + self.rect.h * (1 - c);
    }
};

fn beginPlot(ui: *core.Context, series: []const Series, opts: ChartOpts) Plot {
    const rect = ui.reserve(opts.width, opts.height, opts.width <= 0);
    const rng = computeRange(series, opts);
    // 面板底
    ui.addBox(rect, .{ .fill = theme.bg, .radius = 10 });
    ui.addBox(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, .{ .fill = theme.border });
    ui.addBox(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, .{ .fill = theme.border });
    ui.addBox(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, .{ .fill = theme.border });
    ui.addBox(.{ .x = rect.x + rect.w - 1, .y = rect.y, .w = 1, .h = rect.h }, .{ .fill = theme.border });

    const label_w: f32 = if (opts.labels) 34 else 8;
    const plot = t.Rect{
        .x = rect.x + label_w,
        .y = rect.y + 10,
        .w = @max(@as(f32, 10), rect.w - label_w - 10),
        .h = @max(@as(f32, 10), rect.h - 20 - (if (opts.labels) @as(f32, 14) else @as(f32, 0))),
    };

    // 网格 + 数值标签
    if (opts.grid > 0) {
        var i: u8 = 0;
        while (i <= opts.grid) : (i += 1) {
            const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(opts.grid));
            const gy = plot.y + plot.h * f;
            ui.addOverlayLine(.{ .x = plot.x, .y = gy }, .{ .x = plot.x + plot.w, .y = gy }, 1, theme.border);
            if (opts.labels and (i == 0 or i == opts.grid)) {
                var buf: [24]u8 = @splat(0);
                const v = rng.hi - (rng.hi - rng.lo) * f;
                const s = fmtValue(&buf, v);
                const m = ui.measureText(s, theme.font_small);
                ui.addText(.{ .x = rect.x + label_w - m.w - 6, .y = gy - m.h / 2, .w = m.w, .h = m.h }, ui.frameStr(s), theme.font_small, theme.secondary);
            }
        }
    }
    return .{ .rect = plot, .lo = rng.lo, .hi = rng.hi };
}

/// 面积填充：用**宽矩形条**（每 20px 一条）。
/// 用矩形而不是粗线段，是因为线段预算（`MAX_OVERLAYS`）比节点预算更紧张：
/// 一页放多个图表时线段会先被打满（实测 192 条）。
fn fillArea(ui: *core.Context, plot: Plot, values: []const f32, color: t.Color) void {
    if (values.len < 2) return;
    const stride: f32 = 20;
    const step = plot.rect.w / @as(f32, @floatFromInt(values.len - 1));
    const bottom = plot.rect.y + plot.rect.h;
    var x = plot.rect.x;
    while (x < plot.rect.x + plot.rect.w) : (x += stride) {
        const idx_f = (x - plot.rect.x) / @max(0.001, step);
        const k0: usize = @min(values.len - 1, @as(usize, @intFromFloat(idx_f)));
        const k1 = @min(values.len - 1, k0 + 1);
        const frac = idx_f - @as(f32, @floatFromInt(k0));
        const v = values[k0] + (values[k1] - values[k0]) * frac;
        const y = plot.y(v);
        if (bottom > y) {
            ui.addBox(.{ .x = x, .y = y, .w = stride + 0.5, .h = bottom - y }, .{ .fill = color });
        }
    }
}

/// 迷你折线（无坐标轴、无网格），用于趋势列。
pub const SparkOpts = struct {
    width: f32 = 0,
    height: f32 = 32,
    /// 透明（alpha = 0）= 跟随主题强调色。
    color: t.Color = t.Color.transparent,
    fill: bool = false,
};

pub fn sparkline(ui: *core.Context, values: []const f32, opts: SparkOpts) void {
    const rect = ui.reserve(opts.width, opts.height, opts.width <= 0);
    if (values.len < 2) return;
    const rng = computeRange(&.{.{ .values = values }}, .{});
    const plot = Plot{ .rect = rect, .lo = rng.lo, .hi = rng.hi };
    const step = plot.rect.w / @as(f32, @floatFromInt(values.len - 1));

    if (opts.fill) fillArea(ui, plot, values, theme.withAlpha(if (opts.color.a == 0) theme.accent else opts.color, 48));
    const st = strideFor(values.len);
    var i: usize = st;
    while (i < values.len) : (i += st) {
        ui.addOverlayLine(
            .{ .x = plot.rect.x + step * @as(f32, @floatFromInt(i - st)), .y = plot.y(values[i - st]) },
            .{ .x = plot.rect.x + step * @as(f32, @floatFromInt(i)), .y = plot.y(values[i]) },
            1.6,
            optColor(opts.color),
        );
    }
}

/// 多序列折线图（网格 + 数值范围标签 + 数据点 + 可选面积）。
pub fn lineChart(ui: *core.Context, series: []const Series, opts: ChartOpts) void {
    if (series.len == 0) return;
    const plot = beginPlot(ui, series, opts);

    var max_len: usize = 0;
    for (series) |s| max_len = @max(max_len, s.values.len);
    if (max_len < 2) return;
    const step = plot.rect.w / @as(f32, @floatFromInt(max_len - 1));

    // 面积填充（只对第一个序列）
    if (opts.fill) fillArea(ui, plot, series[0].values, theme.withAlpha(seriesColor(series[0]), 48));

    for (series) |s| {
        if (s.values.len < 2) continue;
        const st = strideFor(s.values.len);
        var i: usize = st;
        while (i < s.values.len) : (i += st) {
            ui.addOverlayLine(
                .{ .x = plot.rect.x + step * @as(f32, @floatFromInt(i - st)), .y = plot.y(s.values[i - st]) },
                .{ .x = plot.rect.x + step * @as(f32, @floatFromInt(i)), .y = plot.y(s.values[i]) },
                1.8,
                seriesColor(s),
            );
        }
        if (opts.points) {
            i = 0;
            while (i < s.values.len) : (i += st) {
                const px = plot.rect.x + step * @as(f32, @floatFromInt(i));
                const py = plot.y(s.values[i]);
                ui.addBox(.{ .x = px - 2.5, .y = py - 2.5, .w = 5, .h = 5 }, .{ .fill = theme.bg, .radius = 2.5, .border = seriesColor(s) });
            }
        }
    }
}

/// 柱状图：多序列并排，柱顶圆角。
pub fn barChart(ui: *core.Context, series: []const Series, opts: ChartOpts) void {
    if (series.len == 0) return;
    const plot = beginPlot(ui, series, opts);

    var max_len: usize = 0;
    for (series) |s| max_len = @max(max_len, s.values.len);
    if (max_len == 0) return;

    const slot = plot.rect.w / @as(f32, @floatFromInt(max_len));
    const bar_w = @max(2, (slot - opts.bar_gap * 2) / @as(f32, @floatFromInt(series.len)));
    const base_y = plot.y(if (plot.lo < 0) 0 else plot.lo);
    const zero_y = if (plot.lo < 0) plot.y(0) else plot.rect.y + plot.rect.h;

    var si: usize = 0;
    while (si < series.len) : (si += 1) {
        const s = series[si];
        var i: usize = 0;
        while (i < s.values.len) : (i += 1) {
            const x = plot.rect.x + slot * @as(f32, @floatFromInt(i)) + opts.bar_gap + bar_w * @as(f32, @floatFromInt(si));
            const y = plot.y(s.values[i]);
            const top = @min(y, zero_y);
            const h = @max(1, @abs(zero_y - y));
            ui.addBox(.{ .x = x, .y = top, .w = bar_w, .h = h }, .{ .fill = seriesColor(s), .radius = @min(3, bar_w / 2) });
        }
    }
    _ = base_y;
}

/// 环形图：`values` 各占一段圆弧，中心显示总量；右侧图例。
pub const DonutOpts = struct {
    size: f32 = 120,
    thickness: f32 = 16,
    /// 中心文本（空则不画）。
    center_label: []const u8 = "",
    legend: bool = true,
};

pub fn donutChart(
    ui: *core.Context,
    values: []const f32,
    labels: []const []const u8,
    colors: []const t.Color,
    opts: DonutOpts,
) void {
    var total: f32 = 0;
    for (values) |v| total += @max(0, v);
    if (total <= 0) total = 1;

    // 宽度必须是「圆 + 图例」，不能撑满：否则在 row 里与相邻控件重叠
    const total_w = opts.size + (if (opts.legend) @as(f32, 200) else @as(f32, 0));
    const rect = ui.reserve(total_w, opts.size + 8, false);
    const cx = rect.x + opts.size / 2;
    const cy = rect.y + rect.h / 2;
    const r = opts.size / 2 - opts.thickness / 2 - 2;

    // 底环
    arc(ui, cx, cy, r, 0, 1, theme.track, opts.thickness);
    var acc: f32 = 0;
    for (values, 0..) |v, i| {
        const frac = @max(0, v) / total;
        if (frac <= 0) continue;
        const color = if (i < colors.len) colors[i] else theme.accent;
        arc(ui, cx, cy, r, acc, frac, color, opts.thickness);
        acc += frac;
    }

    if (opts.center_label.len > 0) {
        const m = ui.measureText(opts.center_label, theme.font_body);
        ui.addText(.{ .x = cx - m.w / 2, .y = cy - m.h / 2, .w = m.w, .h = m.h }, opts.center_label, theme.font_body, theme.text);
    }

    if (opts.legend) {
        var ly = rect.y + 12;
        const lx = rect.x + opts.size + 20;
        for (labels, 0..) |label, i| {
            const color = if (i < colors.len) colors[i] else theme.accent;
            ui.addBox(.{ .x = lx, .y = ly + 3, .w = 10, .h = 10 }, .{ .fill = color, .radius = 3 });
            const m = ui.measureText(label, theme.font_small);
            ui.addText(.{ .x = lx + 16, .y = ly, .w = m.w, .h = m.h }, label, theme.font_small, theme.text);
            ly += 20;
        }
    }
}

fn halfArc(ui: *core.Context, cx: f32, cy: f32, r: f32, from: f32, to: f32, color: t.Color, width: f32) void {
    const segn: usize = 12;
    var i: usize = 0;
    while (i < segn) : (i += 1) {
        const a0 = from + (to - from) * (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segn)));
        const a1 = from + (to - from) * (@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segn)));
        ui.addOverlayLine(
            .{ .x = cx - @cos(a0) * r, .y = cy - @sin(a0) * r },
            .{ .x = cx - @cos(a1) * r, .y = cy - @sin(a1) * r },
            width,
            color,
        );
    }
}

/// 仪表盘：半圆刻度 + 指针值弧 + 中心数值。
pub const GaugeOpts = struct {
    size: f32 = 140,
    label: []const u8 = "",
    thickness: f32 = 12,
};

pub fn gauge(ui: *core.Context, value: f32, opts: GaugeOpts) void {
    const w = opts.size;
    const h = opts.size * 0.62;
    const rect = ui.reserve(w, h + 8, false);
    const cx = rect.x + w / 2;
    const cy = rect.y + h - 4;
    const r = w / 2 - opts.thickness / 2 - 2;

    // 半圆（左 0% → 右 100%）
    halfArc(ui, cx, cy, r, 0, std.math.pi, theme.track, opts.thickness);
    const v: f32 = if (value < 0) 0 else if (value > 1) 1 else value;
    if (v > 0) halfArc(ui, cx, cy, r, std.math.pi * (1 - v), std.math.pi, theme.accent, opts.thickness);

    var buf: [24]u8 = @splat(0);
    const s = num.percent(&buf, v);
    const m = ui.measureText(s, theme.font_heading);
    ui.addText(.{ .x = cx - m.w / 2, .y = cy - m.h - 2, .w = m.w, .h = m.h }, ui.frameStr(s), theme.font_heading, theme.text);
    if (opts.label.len > 0) {
        const lm = ui.measureText(opts.label, theme.font_small);
        ui.addText(.{ .x = cx - lm.w / 2, .y = cy + 2, .w = lm.w, .h = lm.h }, opts.label, theme.font_small, theme.secondary);
    }
}
