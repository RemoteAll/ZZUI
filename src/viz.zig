//! 数据可视化族（对位 CUI `cui_viz.c`）：热力图 / 日历热力 / 树图 / 雷达 / 漏斗 /
//! 桑基 / 华夫 / 堆叠条 / 排行榜条 / 活动环 / 散点 / 径向仪表 / K 线。
//!
//! 全部只用 **矩形 + 线段 + 文本** 绘制（与 `charts.zig` 同口径，不引入位图或曲线渲染器）。
//! 线段预算（`MAX_OVERLAYS`）是硬约束：圆环类按 16 段/圈、连线类按 1 段/边控制。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const extras = @import("extras.zig");
const num = @import("num.zig");
const month = @import("month.zig");
const t = @import("types.zig");

pub const VizItem = struct {
    label: []const u8,
    value: f32,
    color: ?t.Color = null,
};

pub const Series = struct {
    name: []const u8,
    values: []const f32,
    color: ?t.Color = null,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

const palette = [_]t.Color{
    t.Color.hex(0x2563EB, 255),
    t.Color.hex(0x0891B2, 255),
    t.Color.hex(0x15803D, 255),
    t.Color.hex(0xB45309, 255),
    t.Color.hex(0xB91C1C, 255),
    t.Color.hex(0x7C3AED, 255),
};

fn colorAt(i: usize) t.Color {
    return palette[i % palette.len];
}

fn mix(a: t.Color, b: t.Color, r0: f32) t.Color {
    const r = if (r0 < 0) 0 else if (r0 > 1) 1 else r0;
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * r),
        .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * r),
        .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * r),
        .a = 255,
    };
}

fn arc(ui: *core.Context, cx: f32, cy: f32, rad: f32, a0: f32, a1: f32, color: t.Color, width: f32) void {
    if (a1 <= a0) return;
    const span = a1 - a0;
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

fn fmtCell(buf: []u8, v: f32, decimals: u8) []const u8 {
    return num.fixed(buf, v, decimals);
}

// ------------------------------------------------------------------ 热力图
pub const HeatmapOpts = struct {
    row_labels: ?[]const []const u8 = null,
    col_labels: ?[]const []const u8 = null,
    /// 0 = 按可用宽度均分。
    cell: f32 = 0,
    /// 都为 0 时自动取数据范围。
    min: f32 = 0,
    max: f32 = 0,
    decimals: u8 = 0,
    width: f32 = 0,
};

/// 网格热力图：值 → 颜色深浅（track → accent）。返回本帧点中的格子线性下标。
pub fn heatmap(
    ui: *core.Context,
    id: []const u8,
    values: []const f32,
    rows: usize,
    cols: usize,
    opts: HeatmapOpts,
) ?usize {
    if (rows == 0 or cols == 0) return null;
    var vmin = opts.min;
    var vmax = opts.max;
    if (vmax <= vmin) {
        vmin = values[0];
        vmax = values[0];
        for (values) |v| {
            if (v < vmin) vmin = v;
            if (v > vmax) vmax = v;
        }
        if (vmax <= vmin) vmax = vmin + 1;
    }

    const label_w: f32 = if (opts.row_labels != null) 64 else 0;
    const label_h: f32 = if (opts.col_labels != null) 16 else 0;
    const avail: f32 = if (opts.width > 0) opts.width else ui.width - label_w;
    const gap: f32 = 1;
    const cell: f32 = if (opts.cell > 2) opts.cell else @max(6, (avail - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols)));
    const total_h = label_h + @as(f32, @floatFromInt(rows)) * (cell + gap);
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, total_h, opts.width <= 0);

    // 命中只登记一次（整块）：逐格登记会吃光 `MAX_HITS`（128），waffle/热力图同页必爆
    const grid = t.Rect{
        .x = rect.x + label_w,
        .y = rect.y + label_h,
        .w = @as(f32, @floatFromInt(cols)) * (cell + gap),
        .h = @as(f32, @floatFromInt(rows)) * (cell + gap),
    };
    const grid_hit = ui.interactEx(core.Context.idOf(id) ^ 0x4EA700, grid, true);
    var hover_idx: ?usize = null;
    if (grid_hit.hover) {
        const cc: f32 = @floor((ui.input.mouse.x - grid.x) / (cell + gap));
        const rr: f32 = @floor((ui.input.mouse.y - grid.y) / (cell + gap));
        if (cc >= 0 and rr >= 0) {
            const ci: usize = @intFromFloat(cc);
            const ri: usize = @intFromFloat(rr);
            if (ci < cols and ri < rows) hover_idx = ri * cols + ci;
        }
    }
    var picked: ?usize = null;
    if (grid_hit.clicked) {
        if (hover_idx) |h0| picked = h0;
    }

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        if (opts.row_labels) |labels| {
            if (r < labels.len) {
                const m = ui.measureText(labels[r], theme.font_small);
                ui.addText(
                    .{ .x = rect.x, .y = rect.y + label_h + @as(f32, @floatFromInt(r)) * (cell + gap) + (cell - m.h) / 2, .w = label_w - 6, .h = m.h },
                    labels[r],
                    theme.font_small,
                    theme.secondary,
                );
            }
        }
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            const idx = r * cols + c;
            const v = if (idx < values.len) values[idx] else 0;
            const ratio = (v - vmin) / (vmax - vmin);
            const cell_rect = t.Rect{
                .x = grid.x + @as(f32, @floatFromInt(c)) * (cell + gap),
                .y = grid.y + @as(f32, @floatFromInt(r)) * (cell + gap),
                .w = cell,
                .h = cell,
            };
            const hot = hover_idx != null and hover_idx.? == idx;
            ui.addBox(cell_rect, .{
                .fill = mix(theme.surface, if (hot) theme.accent_active else theme.accent, ratio * 0.9 + 0.1),
                .radius = 2,
            });
        }
    }
    // 列标签（放在顶部）
    if (opts.col_labels) |labels| {
        var c: usize = 0;
        while (c < cols and c < labels.len) : (c += 1) {
            ui.addText(
                .{
                    .x = rect.x + label_w + @as(f32, @floatFromInt(c)) * (cell + gap),
                    .y = rect.y,
                    .w = cell,
                    .h = label_h,
                },
                labels[c],
                theme.font_small,
                theme.secondary,
            );
        }
    }
    _ = fmtCell;
    return picked;
}

// ------------------------------------------------------------------ 日历热力
pub const CalendarHeatmapOpts = struct {
    cell: f32 = 12,
    color: ?t.Color = null,
    /// 星期行的起始日（0 = 周一）。
    first_weekday: u8 = 0,
};

/// 日历热力图（GitHub 贡献图样式）：按周分列、按星期分行。
pub fn calendarHeatmap(
    ui: *core.Context,
    id: []const u8,
    start: month.Date,
    values: []const f32,
    opts: CalendarHeatmapOpts,
) ?usize {
    if (values.len == 0) return null;
    var vmax: f32 = 0;
    for (values) |v| {
        if (v > vmax) vmax = v;
    }
    if (vmax <= 0) vmax = 1;

    const cell = if (opts.cell > 4) opts.cell else 12;
    const gap: f32 = 2;
    const weeks = (values.len + 6) / 7 + 1;
    const total_w = @as(f32, @floatFromInt(weeks)) * (cell + gap);
    const total_h = 7 * (cell + gap);
    const rect = ui.reserve(total_w, total_h, false);
    const base = opts.color orelse theme.accent;

    const lead = month.weekdayOf(start);
    const grid_hit = ui.interactEx(core.Context.idOf(id) ^ 0xCA1E, rect, true);
    var hover_idx: ?usize = null;
    if (grid_hit.hover) {
        const cc: f32 = @floor((ui.input.mouse.x - rect.x) / (cell + gap));
        const rr: f32 = @floor((ui.input.mouse.y - rect.y) / (cell + gap));
        if (cc >= 0 and rr >= 0) {
            const ci: usize = @intFromFloat(cc);
            const ri: usize = @intFromFloat(rr);
            const slot = ci * 7 + (ri + @as(usize, opts.first_weekday)) % 7;
            if (slot >= lead) {
                const day = slot - lead;
                if (day < values.len) hover_idx = day;
            }
        }
    }
    var picked: ?usize = null;
    if (grid_hit.clicked) {
        if (hover_idx) |h0| picked = h0;
    }

    var i: usize = 0;
    while (i < values.len) : (i += 1) {
        const slot = lead + i;
        const col = slot / 7;
        const row = (slot % 7 + 7 - @as(usize, opts.first_weekday)) % 7;
        const r = t.Rect{
            .x = rect.x + @as(f32, @floatFromInt(col)) * (cell + gap),
            .y = rect.y + @as(f32, @floatFromInt(row)) * (cell + gap),
            .w = cell,
            .h = cell,
        };
        const ratio = values[i] / vmax;
        const hot = hover_idx != null and hover_idx.? == i;
        ui.addBox(r, .{ .fill = mix(theme.surface, if (hot) theme.accent_active else base, ratio * 0.9 + 0.05), .radius = 2 });
    }
    return picked;
}

// ------------------------------------------------------------------ 树图
pub const TreemapOpts = struct {
    width: f32 = 0,
    height: f32 = 160,
    decimals: u8 = 0,
};

/// 树图（squarified 的简化版：先按列切、再按行切），面积与数值成正比。
pub fn treemap(ui: *core.Context, id: []const u8, items: []const VizItem, opts: TreemapOpts) ?usize {
    if (items.len == 0) return null;
    var total: f32 = 0;
    for (items) |it| total += if (it.value > 0) it.value else 0;
    if (total <= 0) return null;

    const h = if (opts.height > 40) opts.height else 160;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, h, opts.width <= 0);
    var picked: ?usize = null;

    // 交替切分：横向两列，每列内纵向堆叠
    const cols: usize = if (items.len > 3) 2 else 1;
    var acc: f32 = 0;
    var col_start: usize = 0;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        // 本列分到的比例
        const remain = total - acc;
        const share = if (col + 1 == cols) remain else remain / @as(f32, @floatFromInt(cols - col));
        var col_sum: f32 = 0;
        var j = col_start;
        while (j < items.len and col_sum < share * 0.98) : (j += 1) {
            col_sum += if (items[j].value > 0) items[j].value else 0;
        }
        const col_w = rect.w * (col_sum / total);
        const x0 = rect.x + rect.w * (acc / total);
        acc += col_sum;

        var y0 = rect.y;
        var k = col_start;
        while (k < j) : (k += 1) {
            const v = if (items[k].value > 0) items[k].value else 0;
            const ih = h * (v / col_sum);
            const r = t.Rect{ .x = x0 + 1, .y = y0 + 1, .w = @max(col_w - 2, 4), .h = @max(ih - 2, 4) };
            const hit = ui.interactEx(core.Context.idOf(id) ^ (0x7EE000 + k), r, true);
            const c = items[k].color orelse colorAt(k);
            ui.addBox(r, .{ .fill = if (hit.hover) mix(c, theme.text, 0.15) else c, .radius = 4 });
            if (r.w > 42 and r.h > 22) {
                ui.addText(
                    .{ .x = r.x + 6, .y = r.y + 4, .w = r.w - 10, .h = 14 },
                    items[k].label,
                    theme.font_small,
                    theme.accent_text,
                );
                var vb: [20]u8 = undefined;
                const vs = ui.frameStr(num.fixed(&vb, items[k].value, opts.decimals));
                ui.addText(
                    .{ .x = r.x + 6, .y = r.y + 18, .w = r.w - 10, .h = 14 },
                    vs,
                    theme.font_small,
                    theme.accent_text,
                );
            }
            if (hit.clicked) picked = k;
            y0 += ih;
        }
        col_start = j;
    }
    return picked;
}

// ------------------------------------------------------------------ 雷达图
pub const RadarOpts = struct {
    size: f32 = 220,
    max: f32 = 0,
    no_legend: bool = false,
};

/// 雷达图：多个系列在共享轴上的多边形（每系列 axes 条边）。
pub fn radarChart(
    ui: *core.Context,
    id: []const u8,
    series: []const Series,
    axes: []const []const u8,
    opts: RadarOpts,
) void {
    _ = id;
    const n = axes.len;
    if (n < 3 or series.len == 0) return;
    const size = if (opts.size > 80) opts.size else 220;
    const legend_h: f32 = if (opts.no_legend) 0 else 18 * @as(f32, @floatFromInt(series.len));
    const rect = ui.reserve(size, size + legend_h, false);
    const cx = rect.x + size / 2;
    const cy = rect.y + size / 2;
    const rad = size / 2 - 24;

    var vmax = opts.max;
    if (vmax <= 0) {
        for (series) |s| {
            for (s.values) |v| {
                if (v > vmax) vmax = v;
            }
        }
        if (vmax <= 0) vmax = 1;
    }

    // 网格：三圈
    var ring: usize = 1;
    while (ring <= 3) : (ring += 1) {
        const rr = rad * @as(f32, @floatFromInt(ring)) / 3.0;
        var a: usize = 0;
        while (a < n) : (a += 1) {
            const ang0 = angleOf(a, n);
            const ang1 = angleOf(a + 1, n);
            ui.addOverlayLine(
                .{ .x = cx + @cos(ang0) * rr, .y = cy + @sin(ang0) * rr },
                .{ .x = cx + @cos(ang1) * rr, .y = cy + @sin(ang1) * rr },
                1,
                theme.border,
            );
        }
    }
    // 轴 + 标签
    var a2: usize = 0;
    while (a2 < n) : (a2 += 1) {
        const ang = angleOf(a2, n);
        ui.addOverlayLine(.{ .x = cx, .y = cy }, .{ .x = cx + @cos(ang) * rad, .y = cy + @sin(ang) * rad }, 1, theme.border);
        const m = ui.measureText(axes[a2], theme.font_small);
        ui.addText(
            .{ .x = cx + @cos(ang) * (rad + 12) - m.w / 2, .y = cy + @sin(ang) * (rad + 12) - m.h / 2, .w = m.w, .h = m.h },
            axes[a2],
            theme.font_small,
            theme.secondary,
        );
    }
    // 系列
    for (series, 0..) |s, si| {
        const c = s.color orelse colorAt(si);
        var prev: ?t.Point = null;
        var first: ?t.Point = null;
        var k: usize = 0;
        while (k < n and k < s.values.len) : (k += 1) {
            const ang = angleOf(k, n);
            const r = rad * @min(s.values[k] / vmax, 1);
            const p = t.Point{ .x = cx + @cos(ang) * r, .y = cy + @sin(ang) * r };
            if (prev) |pv| ui.addOverlayLine(pv, p, 1.6, c);
            if (first == null) first = p;
            prev = p;
            ui.addBox(.{ .x = p.x - 2, .y = p.y - 2, .w = 4, .h = 4 }, .{ .fill = c, .radius = 2 });
        }
        if (prev != null and first != null and n > 2) ui.addOverlayLine(prev.?, first.?, 1.6, c);
    }
    // 图例
    if (!opts.no_legend) {
        var y = rect.y + size + 2;
        for (series, 0..) |s, si| {
            const c = s.color orelse colorAt(si);
            ui.addBox(.{ .x = rect.x, .y = y + 3, .w = 8, .h = 8 }, .{ .fill = c, .radius = 2 });
            ui.addText(.{ .x = rect.x + 14, .y = y, .w = 160, .h = 14 }, s.name, theme.font_small, theme.secondary);
            y += 18;
        }
    }
}

fn angleOf(i: usize, n: usize) f32 {
    const pi: f32 = std.math.pi;
    return -pi / 2 + 2 * pi * @as(f32, @floatFromInt(i % n)) / @as(f32, @floatFromInt(n));
}

// ------------------------------------------------------------------ 漏斗
pub const FunnelOpts = struct {
    width: f32 = 0,
    height: f32 = 160,
    decimals: u8 = 0,
    color: ?t.Color = null,
};

/// 漏斗图：每级宽度与数值成正比，右侧标注转化率。
pub fn funnel(ui: *core.Context, id: []const u8, stages: []const VizItem, opts: FunnelOpts) ?usize {
    if (stages.len == 0) return null;
    var vmax: f32 = 0;
    for (stages) |s| {
        if (s.value > vmax) vmax = s.value;
    }
    if (vmax <= 0) return null;
    const h = if (opts.height > 40) opts.height else 160;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, h, opts.width <= 0);
    const row_h = h / @as(f32, @floatFromInt(stages.len));
    const base = opts.color orelse theme.accent;

    var picked: ?usize = null;
    for (stages, 0..) |s, i| {
        const ratio = s.value / vmax;
        const w = rect.w * 0.62 * ratio;
        const x = rect.x;
        const y = rect.y + row_h * @as(f32, @floatFromInt(i));
        const bar = t.Rect{ .x = x, .y = y + 2, .w = @max(w, 6), .h = row_h - 4 };
        const hit = ui.interactEx(core.Context.idOf(id) ^ (0xF0E000 + i), bar, true);
        ui.addBox(bar, .{ .fill = if (hit.hover) mix(base, theme.text, 0.15) else base, .radius = 4 });
        const m = ui.measureText(s.label, theme.font_small);
        ui.addText(.{ .x = x + 8, .y = y + row_h / 2 - m.h / 2, .w = m.w, .h = m.h }, s.label, theme.font_small, theme.accent_text);
        var vb: [24]u8 = undefined;
        const vs = ui.frameStr(num.fixed(&vb, s.value, opts.decimals));
        var conv_b: [24]u8 = undefined;
        var conv: []const u8 = "";
        if (i > 0 and stages[i - 1].value > 0) {
            const pct = s.value / stages[i - 1].value * 100;
            conv = ui.frameStr(num.fixed(&conv_b, pct, 0));
        }
        ui.addText(
            .{ .x = rect.x + rect.w * 0.64, .y = y + row_h / 2 - m.h / 2, .w = 60, .h = m.h },
            vs,
            theme.font_small,
            theme.text,
        );
        if (conv.len > 0) {
            ui.addText(
                .{ .x = rect.x + rect.w * 0.64 + 46, .y = y + row_h / 2 - m.h / 2, .w = 60, .h = m.h },
                conv,
                theme.font_small,
                theme.secondary,
            );
        }
        if (hit.clicked) picked = i;
    }
    return picked;
}

// ------------------------------------------------------------------ 桑基图
pub const SankeyLink = struct {
    from: usize,
    to: usize,
    value: f32,
};

pub const SankeyOpts = struct {
    width: f32 = 0,
    height: f32 = 180,
    node_width: f32 = 12,
};

/// 桑基图：节点按「从源点出发的层数」分列，连线宽度与流量成正比。
pub fn sankey(
    ui: *core.Context,
    id: []const u8,
    nodes: []const []const u8,
    links: []const SankeyLink,
    opts: SankeyOpts,
) void {
    _ = id;
    if (nodes.len == 0 or links.len == 0) return;
    const h = if (opts.height > 40) opts.height else 180;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, h, opts.width <= 0);
    const nw = if (opts.node_width > 3) opts.node_width else 12;

    // 分列：from → to 的层级（简单两遍松弛，节点数很少）
    var col: [16]usize = @splat(0);
    const ncount = @min(nodes.len, 16);
    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        for (links) |l| {
            if (l.from < ncount and l.to < ncount and col[l.to] <= col[l.from]) col[l.to] = col[l.from] + 1;
        }
    }
    var cols: usize = 1;
    for (col[0..ncount]) |c| {
        if (c + 1 > cols) cols = c + 1;
    }
    const col_gap = (rect.w - nw * @as(f32, @floatFromInt(cols))) / @as(f32, @floatFromInt(if (cols > 1) cols - 1 else 1));

    // 每个节点的流量 → 高度
    var flow: [16]f32 = @splat(0);
    for (links) |l| {
        if (l.from < ncount) flow[l.from] += l.value;
        if (l.to < ncount) flow[l.to] += l.value;
    }
    var total: f32 = 0;
    for (flow[0..ncount]) |f| total += f;
    if (total <= 0) return;

    // 节点矩形
    var node_y: [16]f32 = @splat(0);
    var node_h: [16]f32 = @splat(0);
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        var y = rect.y;
        var i: usize = 0;
        while (i < ncount) : (i += 1) {
            if (col[i] != c) continue;
            const nh = h * (flow[i] / total) * 0.85;
            node_y[i] = y;
            node_h[i] = @max(nh, 6);
            y += nh + 6;
        }
    }

    // 连线（直线 + 端点色块，控制线段用量）
    for (links) |l| {
        if (l.from >= ncount or l.to >= ncount) continue;
        const x0 = rect.x + @as(f32, @floatFromInt(col[l.from])) * (nw + col_gap) + nw;
        const x1 = rect.x + @as(f32, @floatFromInt(col[l.to])) * (nw + col_gap);
        const y0 = node_y[l.from] + node_h[l.from] / 2;
        const y1 = node_y[l.to] + node_h[l.to] / 2;
        ui.addOverlayLine(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, @max(1, 6 * (l.value / total)), mix(theme.accent, theme.bg, 0.35));
    }
    // 节点与标签
    var ni: usize = 0;
    while (ni < ncount) : (ni += 1) {
        const x = rect.x + @as(f32, @floatFromInt(col[ni])) * (nw + col_gap);
        ui.addBox(.{ .x = x, .y = node_y[ni], .w = nw, .h = node_h[ni] }, .{ .fill = colorAt(ni), .radius = 3 });
        const m = ui.measureText(nodes[ni], theme.font_small);
        const right_side = col[ni] + 1 == cols;
        ui.addText(
            .{
                .x = if (right_side) x - m.w - 6 else x + nw + 6,
                .y = node_y[ni] + node_h[ni] / 2 - m.h / 2,
                .w = m.w,
                .h = m.h,
            },
            nodes[ni],
            theme.font_small,
            theme.secondary,
        );
    }
}

// ------------------------------------------------------------------ 华夫图
pub const WaffleOpts = struct {
    cell: f32 = 14,
    columns: usize = 10,
    rows: usize = 10,
    decimals: u8 = 0,
};

/// 华夫图：`columns × rows` 的方格按占比染色（按行合并同色段，控制节点数）。
pub fn waffle(ui: *core.Context, id: []const u8, items: []const VizItem, opts: WaffleOpts) ?usize {
    if (items.len == 0) return null;
    var total: f32 = 0;
    for (items) |it| total += if (it.value > 0) it.value else 0;
    if (total <= 0) return null;
    const cols = if (opts.columns > 0) opts.columns else 10;
    const rows = if (opts.rows > 0) opts.rows else 10;
    const cell = if (opts.cell > 4) opts.cell else 14;
    const gap: f32 = 2;
    const w = @as(f32, @floatFromInt(cols)) * (cell + gap);
    const h = @as(f32, @floatFromInt(rows)) * (cell + gap) + 20;
    const rect = ui.reserve(w, h, false);

    const total_cells = cols * rows;
    // 一格一个命中会让 100 格吃掉 `MAX_HITS` 的绝大部分 → 整块一次命中后反算
    const grid_hit = ui.interactEx(core.Context.idOf(id) ^ 0xBAF00000, .{
        .x = rect.x,
        .y = rect.y,
        .w = @as(f32, @floatFromInt(cols)) * (cell + gap),
        .h = @as(f32, @floatFromInt(rows)) * (cell + gap),
    }, true);
    var picked: ?usize = null;
    var acc_share: f32 = 0;
    var cell_of: [8]usize = @splat(0);
    var start_of: [8]usize = @splat(0);
    const n_items = @min(items.len, 8);
    for (items[0..n_items], 0..) |it, i| {
        const share = (if (it.value > 0) it.value else 0) / total;
        cell_of[i] = @intFromFloat(@round(@as(f32, @floatFromInt(total_cells)) * share));
        start_of[i] = @intFromFloat(@round(@as(f32, @floatFromInt(total_cells)) * acc_share));
        acc_share += share;
    }
    if (grid_hit.clicked) {
        const cc: f32 = @floor((ui.input.mouse.x - rect.x) / (cell + gap));
        const rr: f32 = @floor((ui.input.mouse.y - rect.y) / (cell + gap));
        if (cc >= 0 and rr >= 0) {
            const ci: usize = @intFromFloat(cc);
            const ri: usize = @intFromFloat(rr);
            if (ci < cols and ri < rows) {
                const idx = ri * cols + ci;
                for (0..n_items) |i| {
                    if (idx >= start_of[i] and idx < start_of[i] + cell_of[i]) picked = i;
                }
            }
        }
    }
    for (items[0..n_items], 0..) |it, i| {
        const c = it.color orelse colorAt(i);
        var k: usize = 0;
        while (k < cell_of[i]) : (k += 1) {
            const idx = start_of[i] + k;
            if (idx >= total_cells) break;
            const cx = idx % cols;
            const cy = idx / cols;
            ui.addBox(.{
                .x = rect.x + @as(f32, @floatFromInt(cx)) * (cell + gap),
                .y = rect.y + @as(f32, @floatFromInt(cy)) * (cell + gap),
                .w = cell,
                .h = cell,
            }, .{ .fill = c, .radius = 2 });
        }
    }
    // 图例一行：色块 + 标签
    var x = rect.x;
    for (items, 0..) |it, i| {
        const c = it.color orelse colorAt(i);
        ui.addBox(.{ .x = x, .y = rect.y + h - 14, .w = 8, .h = 8 }, .{ .fill = c, .radius = 2 });
        const m = ui.measureText(it.label, theme.font_small);
        ui.addText(.{ .x = x + 12, .y = rect.y + h - 16, .w = m.w, .h = 14 }, it.label, theme.font_small, theme.secondary);
        x += 20 + m.w + 10;
    }
    return picked;
}

// ------------------------------------------------------------------ 堆叠条
pub const SplitBarOpts = struct {
    width: f32 = 0,
    height: f32 = 20,
    decimals: u8 = 0,
    no_legend: bool = false,
};

/// 堆叠条：一条按占比分段，下方带数值与占比图例。
pub fn splitBar(ui: *core.Context, id: []const u8, items: []const VizItem, opts: SplitBarOpts) ?usize {
    if (items.len == 0) return null;
    var total: f32 = 0;
    for (items) |it| total += if (it.value > 0) it.value else 0;
    if (total <= 0) return null;
    const bar_h = if (opts.height > 6) opts.height else 20;
    const legend_h: f32 = if (opts.no_legend) 0 else 18;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, bar_h + legend_h, opts.width <= 0);

    var picked: ?usize = null;
    var x = rect.x;
    var lx = rect.x;
    for (items, 0..) |it, i| {
        const seg_w = rect.w * ((if (it.value > 0) it.value else 0) / total);
        const r = t.Rect{ .x = x, .y = rect.y, .w = @max(seg_w - 1, 1), .h = bar_h };
        const hit = ui.interactEx(core.Context.idOf(id) ^ (0x5B0000 + i), r, true);
        const c = it.color orelse colorAt(i);
        ui.addBox(r, .{ .fill = if (hit.hover) mix(c, theme.text, 0.15) else c, .radius = if (i == 0) 4 else 0 });
        if (hit.clicked) picked = i;
        x += seg_w;
        if (!opts.no_legend) {
            ui.addBox(.{ .x = lx, .y = rect.y + bar_h + 4, .w = 8, .h = 8 }, .{ .fill = c, .radius = 2 });
            const m = ui.measureText(it.label, theme.font_small);
            ui.addText(.{ .x = lx + 12, .y = rect.y + bar_h + 2, .w = m.w, .h = 14 }, it.label, theme.font_small, theme.secondary);
            var pb: [12]u8 = undefined;
            const ps = ui.frameStr(num.fixed(&pb, (if (it.value > 0) it.value else 0) / total * 100, 0));
            ui.addText(.{ .x = lx + 12 + m.w + 6, .y = rect.y + bar_h + 2, .w = 40, .h = 14 }, ps, theme.font_small, theme.secondary);
            lx += 12 + m.w + 6 + 30 + 14;
        }
    }
    return picked;
}

// ------------------------------------------------------------------ 排行榜条
pub const BarListOpts = struct {
    width: f32 = 0,
    decimals: u8 = 0,
    max_rows: usize = 6,
    color: ?t.Color = null,
    row_h: f32 = 24,
};

/// 排行榜横向条形图（条长按最大值归一）。
pub fn barList(ui: *core.Context, id: []const u8, items: []const VizItem, opts: BarListOpts) ?usize {
    if (items.len == 0) return null;
    var vmax: f32 = 0;
    for (items) |it| {
        if (it.value > vmax) vmax = it.value;
    }
    if (vmax <= 0) vmax = 1;
    const rows = @min(items.len, if (opts.max_rows > 0) opts.max_rows else 6);
    const row_h = if (opts.row_h > 12) opts.row_h else 24;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, row_h * @as(f32, @floatFromInt(rows)), opts.width <= 0);
    const base = opts.color orelse theme.accent;

    var picked: ?usize = null;
    var i: usize = 0;
    while (i < rows) : (i += 1) {
        const it = items[i];
        const y = rect.y + row_h * @as(f32, @floatFromInt(i));
        const r = t.Rect{ .x = rect.x, .y = y + 2, .w = rect.w, .h = row_h - 4 };
        const hit = ui.interactEx(core.Context.idOf(id) ^ (0xBA2000 + i), r, true);
        if (hit.hover) ui.addBox(r, .{ .fill = theme.surface, .radius = 4 });
        const m = ui.measureText(it.label, theme.font_small);
        ui.addText(.{ .x = r.x + 4, .y = y + row_h / 2 - m.h / 2, .w = 100, .h = m.h }, it.label, theme.font_small, theme.text);
        const bar_w = (rect.w - 130) * (it.value / vmax);
        ui.addBox(.{ .x = r.x + 110, .y = y + row_h / 2 - 4, .w = @max(bar_w, 2), .h = 8 }, .{ .fill = it.color orelse base, .radius = 4 });
        var vb: [20]u8 = undefined;
        const vs = ui.frameStr(num.fixed(&vb, it.value, opts.decimals));
        ui.addText(
            .{ .x = r.x + rect.w - 34, .y = y + row_h / 2 - m.h / 2, .w = 34, .h = m.h },
            vs,
            theme.font_small,
            theme.secondary,
        );
        if (hit.clicked) picked = i;
    }
    return picked;
}

// ------------------------------------------------------------------ 活动环
pub const RingsOpts = struct {
    size: f32 = 160,
    thickness: f32 = 12,
    center: []const u8 = "",
    caption: []const u8 = "",
    legend: bool = false,
};

/// 活动环：同心进度环（>1 的值继续缠绕一圈）。
pub fn activityRings(ui: *core.Context, id: []const u8, rings: []const VizItem, opts: RingsOpts) void {
    _ = id;
    if (rings.len == 0) return;
    const size = if (opts.size > 40) opts.size else 160;
    const th = if (opts.thickness > 3) opts.thickness else 12;
    const legend_w: f32 = if (opts.legend) 120 else 0;
    const rect = ui.reserve(size + legend_w, size, false);
    const cx = rect.x + size / 2;
    const cy = rect.y + size / 2;
    const n = @min(rings.len, 3);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rad = size / 2 - th / 2 - @as(f32, @floatFromInt(i)) * (th + 4);
        const c = rings[i].color orelse colorAt(i);
        arc(ui, cx, cy, rad, 0, 1, theme.track, th);
        const v = rings[i].value;
        const whole: u32 = if (v <= 0) 0 else @intFromFloat(@floor(v));
        var k: u32 = 0;
        while (k < whole and k < 3) : (k += 1) arc(ui, cx, cy, rad, 0, 1, c, th);
        const frac = v - @floor(v);
        if (frac > 0.001) arc(ui, cx, cy, rad, 0, frac, c, th);
    }
    if (opts.center.len > 0) {
        const m = ui.measureText(opts.center, theme.font_body);
        ui.addText(.{ .x = cx - m.w / 2, .y = cy - m.h - 2, .w = m.w, .h = m.h }, opts.center, theme.font_body, theme.text);
    }
    if (opts.caption.len > 0) {
        const m = ui.measureText(opts.caption, theme.font_small);
        ui.addText(.{ .x = cx - m.w / 2, .y = cy + 2, .w = m.w, .h = m.h }, opts.caption, theme.font_small, theme.secondary);
    }
    if (opts.legend) {
        var y = rect.y + size / 2 - @as(f32, @floatFromInt(n)) * 9;
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const c = rings[j].color orelse colorAt(j);
            ui.addBox(.{ .x = rect.x + size + 8, .y = y + 4, .w = 8, .h = 8 }, .{ .fill = c, .radius = 4 });
            const m = ui.measureText(rings[j].label, theme.font_small);
            ui.addText(.{ .x = rect.x + size + 22, .y = y, .w = m.w, .h = m.h }, rings[j].label, theme.font_small, theme.secondary);
            y += 18;
        }
    }
}

// ------------------------------------------------------------------ 散点
pub const ScatterSeries = struct {
    name: []const u8,
    points: []const Vec2,
    sizes: ?[]const f32 = null,
    color: ?t.Color = null,
};

pub const ScatterOpts = struct {
    width: f32 = 0,
    height: f32 = 180,
    x_label: []const u8 = "",
    y_label: []const u8 = "",
    no_legend: bool = false,
    decimals: u8 = 0,
};

/// 散点 / 气泡图：点位置按数据范围归一，`sizes` 存在时按面积缩放。
pub fn scatterChart(ui: *core.Context, id: []const u8, series: []const ScatterSeries, opts: ScatterOpts) void {
    _ = id;
    if (series.len == 0) return;
    var xmin: f32 = std.math.floatMax(f32);
    var xmax: f32 = -std.math.floatMax(f32);
    var ymin = xmin;
    var ymax = xmax;
    for (series) |s| {
        for (s.points) |p| {
            if (p.x < xmin) xmin = p.x;
            if (p.x > xmax) xmax = p.x;
            if (p.y < ymin) ymin = p.y;
            if (p.y > ymax) ymax = p.y;
        }
    }
    if (xmax <= xmin) xmax = xmin + 1;
    if (ymax <= ymin) ymax = ymin + 1;
    var smax: f32 = 0;
    for (series) |s| {
        if (s.sizes) |sz| {
            for (sz) |v| {
                if (v > smax) smax = v;
            }
        }
    }
    const h = if (opts.height > 60) opts.height else 180;
    const legend_h: f32 = if (opts.no_legend) 0 else 18 * @as(f32, @floatFromInt(series.len));
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, h + legend_h + 14, opts.width <= 0);
    const plot = t.Rect{ .x = rect.x + 30, .y = rect.y + 4, .w = rect.w - 40, .h = h - 8 };

    // 轴
    ui.addOverlayLine(.{ .x = plot.x, .y = plot.y + plot.h }, .{ .x = plot.x + plot.w, .y = plot.y + plot.h }, 1, theme.border);
    ui.addOverlayLine(.{ .x = plot.x, .y = plot.y }, .{ .x = plot.x, .y = plot.y + plot.h }, 1, theme.border);

    for (series, 0..) |s, si| {
        const c = s.color orelse colorAt(si);
        for (s.points, 0..) |p, pi| {
            const nx = (p.x - xmin) / (xmax - xmin);
            const ny = (p.y - ymin) / (ymax - ymin);
            const px = plot.x + plot.w * nx;
            const py = plot.y + plot.h * (1 - ny);
            var r: f32 = 3;
            if (s.sizes) |sz| {
                if (pi < sz.len and smax > 0) r = 2 + 6 * @sqrt(sz[pi] / smax);
            }
            ui.addBox(.{ .x = px - r, .y = py - r, .w = r * 2, .h = r * 2 }, .{ .fill = c, .radius = r });
        }
        if (!opts.no_legend) {
            const ly = rect.y + h + 2 + @as(f32, @floatFromInt(si)) * 18;
            ui.addBox(.{ .x = rect.x, .y = ly + 4, .w = 8, .h = 8 }, .{ .fill = c, .radius = 4 });
            ui.addText(.{ .x = rect.x + 14, .y = ly, .w = 120, .h = 14 }, s.name, theme.font_small, theme.secondary);
        }
    }
    // 轴标签（最小/最大值）
    var b1: [20]u8 = undefined;
    var b2: [20]u8 = undefined;
    const t1 = ui.frameStr(num.fixed(&b1, xmin, opts.decimals));
    const t2 = ui.frameStr(num.fixed(&b2, xmax, opts.decimals));
    ui.addText(.{ .x = plot.x, .y = rect.y + h + 2, .w = 40, .h = 12 }, t1, theme.font_small, theme.secondary);
    ui.addText(.{ .x = plot.x + plot.w - 30, .y = rect.y + h + 2, .w = 40, .h = 12 }, t2, theme.font_small, theme.secondary);
    if (opts.x_label.len > 0) {
        const m = ui.measureText(opts.x_label, theme.font_small);
        ui.addText(.{ .x = plot.x + plot.w / 2 - m.w / 2, .y = rect.y + h + 2, .w = m.w, .h = 12 }, opts.x_label, theme.font_small, theme.secondary);
    }
    if (opts.y_label.len > 0) {
        ui.addText(.{ .x = rect.x, .y = plot.y + 2, .w = 26, .h = 12 }, opts.y_label, theme.font_small, theme.secondary);
    }
}

// ------------------------------------------------------------------ 径向仪表
pub const GaugeBand = struct {
    from: f32,
    to: f32,
    color: t.Color,
};

pub const RadialGaugeOpts = struct {
    label: []const u8 = "",
    unit: []const u8 = "",
    decimals: u8 = 0,
    size: f32 = 200,
    /// 弧的角度（度），默认 240。
    sweep: f32 = 240,
    bands: []const GaugeBand = &.{},
    /// 刻度分段数（-1 隐藏）。
    ticks: i32 = 5,
    /// 目标值标记。
    target: f32 = 0,
    show_target: bool = false,
};

/// 径向仪表：一段弧按值填充，可带分区色带、刻度与目标标记。
pub fn radialGauge(ui: *core.Context, id: []const u8, value: f32, min: f32, max: f32, opts: RadialGaugeOpts) void {
    _ = id;
    const size = if (opts.size > 60) opts.size else 200;
    const h = size * 0.78;
    const rect = ui.reserve(size, h + 18, false);
    const cx = rect.x + size / 2;
    const cy = rect.y + size / 2;
    const rad = size / 2 - 12;
    const sweep = if (opts.sweep > 30 and opts.sweep <= 360) opts.sweep else 240;
    const start = (1 - sweep / 360) / 2;
    const span = sweep / 360;
    const r: f32 = if (max > min) (value - min) / (max - min) else 0;
    const rc = if (r < 0) 0 else if (r > 1) 1 else r;

    arc(ui, cx, cy, rad, start, start + span, theme.track, 10);
    for (opts.bands) |band| {
        const b0 = if (max > min) (band.from - min) / (max - min) else 0;
        const b1 = if (max > min) (band.to - min) / (max - min) else 0;
        arc(ui, cx, cy, rad, start + span * @max(b0, 0), start + span * @min(b1, 1), band.color, 4);
    }
    if (rc > 0) arc(ui, cx, cy, rad, start, start + span * rc, theme.accent, 10);
    if (opts.show_target and max > min) {
        const tr = (opts.target - min) / (max - min);
        const ang: f32 = (start + span * tr) * 2 * std.math.pi - std.math.pi / 2.0;
        ui.addOverlayLine(
            .{ .x = cx + @cos(ang) * (rad - 9), .y = cy + @sin(ang) * (rad - 9) },
            .{ .x = cx + @cos(ang) * (rad + 9), .y = cy + @sin(ang) * (rad + 9) },
            2,
            theme.danger,
        );
    }
    if (opts.ticks >= 0) {
        const n: i32 = if (opts.ticks > 0) opts.ticks else 5;
        var i: i32 = 0;
        while (i <= n) : (i += 1) {
            const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const ang: f32 = (start + span * f) * 2 * std.math.pi - std.math.pi / 2.0;
            ui.addOverlayLine(
                .{ .x = cx + @cos(ang) * (rad - 8), .y = cy + @sin(ang) * (rad - 8) },
                .{ .x = cx + @cos(ang) * (rad - 14), .y = cy + @sin(ang) * (rad - 14) },
                1,
                theme.border,
            );
        }
    }
    var vb: [20]u8 = undefined;
    const vs = ui.frameStr(num.fixed(&vb, value, opts.decimals));
    const vm = ui.measureText(vs, theme.font_heading);
    ui.addText(.{ .x = cx - vm.w / 2, .y = cy - vm.h / 2 - 6, .w = vm.w, .h = vm.h }, vs, theme.font_heading, theme.text);
    if (opts.unit.len > 0) {
        const um = ui.measureText(opts.unit, theme.font_small);
        ui.addText(.{ .x = cx - um.w / 2, .y = cy + vm.h / 2 - 4, .w = um.w, .h = um.h }, opts.unit, theme.font_small, theme.secondary);
    }
    if (opts.label.len > 0) {
        const lm = ui.measureText(opts.label, theme.font_small);
        ui.addText(.{ .x = cx - lm.w / 2, .y = rect.y + h - 6, .w = lm.w, .h = lm.h }, opts.label, theme.font_small, theme.secondary);
    }
}

// ------------------------------------------------------------------ K 线
pub const Candle = struct {
    open: f32,
    high: f32,
    low: f32,
    close: f32,
    volume: f32 = 0,
};

pub const CandlestickOpts = struct {
    width: f32 = 0,
    height: f32 = 200,
    decimals: u8 = 2,
    /// 叠加线（如均线），长度应与 candles 一致。
    overlays: []const Series = &.{},
    no_volume: bool = false,
    /// OHLC 竖线而不是实体蜡烛。
    ohlc: bool = false,
};

/// K 线图：实体 + 影线 + 可选成交量与叠加线。返回悬停/点中的那根下标。
pub fn candlestick(
    ui: *core.Context,
    id: []const u8,
    candles: []const Candle,
    opts: CandlestickOpts,
) ?usize {
    if (candles.len == 0) return null;
    const h = if (opts.height > 60) opts.height else 200;
    const show_vol = !opts.no_volume and blk: {
        for (candles) |c| {
            if (c.volume > 0) break :blk true;
        }
        break :blk false;
    };
    const vol_h: f32 = if (show_vol) h * 0.22 else 0;
    const price_h = h - vol_h - 4;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, h, opts.width <= 0);

    var hi: f32 = -std.math.floatMax(f32);
    var lo: f32 = std.math.floatMax(f32);
    var vmax: f32 = 0;
    for (candles) |c| {
        if (c.high > hi) hi = c.high;
        if (c.low < lo) lo = c.low;
        if (c.volume > vmax) vmax = c.volume;
    }
    if (hi <= lo) hi = lo + 1;
    const slot = rect.w / @as(f32, @floatFromInt(candles.len));
    const body_w = @max(slot * 0.6, 1.5);

    var hovered: ?usize = null;
    for (candles, 0..) |c, i| {
        const x = rect.x + slot * @as(f32, @floatFromInt(i)) + slot / 2;
        const py = struct {
            fn f(v: f32, lo0: f32, hi0: f32, top: f32, height: f32) f32 {
                return top + height * (1 - (v - lo0) / (hi0 - lo0));
            }
        }.f;
        const y_high = py(c.high, lo, hi, rect.y, price_h);
        const y_low = py(c.low, lo, hi, rect.y, price_h);
        const y_open = py(c.open, lo, hi, rect.y, price_h);
        const y_close = py(c.close, lo, hi, rect.y, price_h);
        const up = c.close >= c.open;
        const c_color = if (up) theme.success else theme.danger;

        const hit = ui.interactEx(core.Context.idOf(id) ^ (0xC0DE00 + i), .{
            .x = rect.x + slot * @as(f32, @floatFromInt(i)),
            .y = rect.y,
            .w = slot,
            .h = h,
        }, true);
        if (hit.hover) hovered = i;

        ui.addOverlayLine(.{ .x = x, .y = y_high }, .{ .x = x, .y = y_low }, 1, c_color);
        if (opts.ohlc) {
            ui.addOverlayLine(.{ .x = x - body_w / 2, .y = y_open }, .{ .x = x, .y = y_open }, 1, c_color);
            ui.addOverlayLine(.{ .x = x, .y = y_close }, .{ .x = x + body_w / 2, .y = y_close }, 1, c_color);
        } else {
            const top = @min(y_open, y_close);
            const bh = @max(@abs(y_close - y_open), 1.5);
            ui.addBox(.{ .x = x - body_w / 2, .y = top, .w = body_w, .h = bh }, .{ .fill = c_color });
        }
        if (show_vol) {
            const vh = vol_h * (c.volume / (if (vmax > 0) vmax else 1));
            ui.addBox(.{ .x = x - body_w / 2, .y = rect.y + h - vh, .w = body_w, .h = vh }, .{ .fill = mix(c_color, theme.bg, 0.5) });
        }
    }
    // 叠加线
    for (opts.overlays) |ov| {
        var prev: ?t.Point = null;
        for (candles, 0..) |_, i| {
            if (i >= ov.values.len) break;
            const x = rect.x + slot * @as(f32, @floatFromInt(i)) + slot / 2;
            const y = rect.y + price_h * (1 - (ov.values[i] - lo) / (hi - lo));
            const p = t.Point{ .x = x, .y = y };
            if (prev) |pv| ui.addOverlayLine(pv, p, 1.2, ov.color orelse theme.accent);
            prev = p;
        }
    }
    return hovered;
}
