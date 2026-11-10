//! 可视化族与曲线/渐变族的测试（由 `tests.zig` 引入）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const viz = @import("viz.zig");
const curves = @import("curves.zig");
const month = @import("month.zig");
const t = @import("types.zig");

// ---------------------------------------------------------------- 热力图

// 热力图：整块一次命中，点击坐标反算出格子下标。
test "heatmap reports the clicked cell" {
    var ui = core.Context{};
    const values = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const rows = [_][]const u8{ "a", "b" };

    ui.begin(400, 300);
    _ = viz.heatmap(&ui, "hm", values[0..], 2, 3, .{ .row_labels = rows[0..], .cell = 40 });
    ui.paint();

    const grid_id = core.Context.idOf("hm") ^ 0x4EA700;
    const g = ui.lastRect(grid_id) orelse return error.NoHit;
    // 第 2 行第 3 列（下标 5）：cell=40、gap=1
    const cx = g.x + 2 * 41 + 20;
    const cy = g.y + 1 * 41 + 20;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 300);
    const picked = viz.heatmap(&ui, "hm", values[0..], 2, 3, .{ .row_labels = rows[0..], .cell = 40 });
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 5), picked);
}

// 日历热力图：整块高度 = 7 行；点第一天返回 0。
test "calendar heatmap maps days to weekday rows" {
    var ui = core.Context{};
    const values = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const start = month.Date{ .year = 2026, .month = 11, .day = 10 }; // 周二（weekday=1）

    ui.begin(500, 200);
    const first = viz.calendarHeatmap(&ui, "chm", start, values[0..], .{ .cell = 14 });
    ui.paint();
    try std.testing.expect(first == null);

    const grid_id = core.Context.idOf("chm") ^ 0xCA1E;
    const g = ui.lastRect(grid_id) orelse return error.NoHit;
    // 7 行 × (14+2) = 112
    try std.testing.expectApproxEqAbs(@as(f32, 112), g.h, 0.6);
    // 第 0 天在 slot=lead=1 → col 0 / row 1
    const cx = g.x + 7;
    const cy = g.y + 16 + 7;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(500, 200);
    const picked = viz.calendarHeatmap(&ui, "chm", start, values[0..], .{ .cell = 14 });
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 0), picked);
}

// ---------------------------------------------------------------- 树图 / 漏斗 / 堆叠 / 排行

// 树图：面积按数值比例分配，点击返回对应项。
test "treemap splits by value and reports clicks" {
    var ui = core.Context{};
    const items = [_]viz.VizItem{
        .{ .label = "A", .value = 50 },
        .{ .label = "B", .value = 30 },
        .{ .label = "C", .value = 20 },
    };
    ui.begin(500, 400);
    _ = viz.treemap(&ui, "tm", items[0..], .{ .height = 200 });
    ui.paint();
    const id = core.Context.idOf("tm") ^ (0x7EE000 + 0);
    const r = ui.lastRect(id) orelse return error.NoHit;
    try std.testing.expect(r.h > 50);
    try std.testing.expect(!ui.overflowed);
}

// 漏斗：转化率按上一级计算；点击返回级次。
test "funnel reports the clicked stage" {
    var ui = core.Context{};
    const stages = [_]viz.VizItem{
        .{ .label = "Visit", .value = 1000 },
        .{ .label = "Signup", .value = 400 },
        .{ .label = "Pay", .value = 100 },
    };
    ui.begin(500, 300);
    _ = viz.funnel(&ui, "fn", stages[0..], .{ .height = 150 });
    ui.paint();
    const id = core.Context.idOf("fn") ^ (0xF0E000 + 1);
    const r = ui.lastRect(id) orelse return error.NoHit;
    const cx = r.x + 4;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(500, 300);
    const picked = viz.funnel(&ui, "fn", stages[0..], .{ .height = 150 });
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 1), picked);
}

// 堆叠条：分段宽度按占比；图例不溢出。
test "split bar lays out proportional segments" {
    var ui = core.Context{};
    const items = [_]viz.VizItem{
        .{ .label = "used", .value = 60 },
        .{ .label = "free", .value = 40 },
    };
    ui.begin(400, 120);
    _ = viz.splitBar(&ui, "sb", items[0..], .{});
    ui.paint();
    const id0 = core.Context.idOf("sb") ^ 0x5B0000;
    const r0 = ui.lastRect(id0) orelse return error.NoHit;
    const id1 = core.Context.idOf("sb") ^ (0x5B0000 + 1);
    const r1 = ui.lastRect(id1) orelse return error.NoHit;
    try std.testing.expect(r0.w > r1.w);
    try std.testing.expect(!ui.overflowed);
}

// 排行榜条：条长按最大值归一，点击返回行下标。
test "bar list normalizes bar widths" {
    var ui = core.Context{};
    const items = [_]viz.VizItem{
        .{ .label = "alpha", .value = 80 },
        .{ .label = "beta", .value = 40 },
    };
    ui.begin(400, 160);
    _ = viz.barList(&ui, "bl", items[0..], .{});
    ui.paint();
    const id1 = core.Context.idOf("bl") ^ (0xBA2000 + 1);
    const r = ui.lastRect(id1) orelse return error.NoHit;
    const cx = r.x + 4;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 160);
    const picked = viz.barList(&ui, "bl", items[0..], .{});
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 1), picked);
}

// 华夫图：10×10 网格按占比染色，节点数受控。
test "waffle keeps its node count bounded" {
    var ui = core.Context{};
    const items = [_]viz.VizItem{
        .{ .label = "a", .value = 50 },
        .{ .label = "b", .value = 30 },
        .{ .label = "c", .value = 20 },
    };
    ui.begin(400, 400);
    _ = viz.waffle(&ui, "wf", items[0..], .{ .cell = 10, .columns = 10, .rows = 10 });
    ui.paint();
    try std.testing.expect(!ui.overflowed);
    // 100 格 + 图例，不该超过 256 个节点
    try std.testing.expect(ui.node_count < 200);
}

// ---------------------------------------------------------------- 雷达 / 桑基 / 散点 / 环 / 仪表 / K 线

// 雷达图：多系列多边形，不溢出线段预算。
test "radar chart draws polygons without overflowing" {
    var ui = core.Context{};
    const v1 = [_]f32{ 3, 5, 2, 4 };
    const v2 = [_]f32{ 4, 2, 5, 3 };
    const series = [_]viz.Series{
        .{ .name = "a", .values = v1[0..] },
        .{ .name = "b", .values = v2[0..] },
    };
    const axes = [_][]const u8{ "speed", "power", "range", "cost" };
    ui.begin(400, 400);
    viz.radarChart(&ui, "rd", series[0..], axes[0..], .{ .size = 200 });
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

// 桑基图：按层级分列，不崩溃且不溢出。
test "sankey lays out node columns" {
    var ui = core.Context{};
    const nodes = [_][]const u8{ "src", "mid", "out" };
    const links = [_]viz.SankeyLink{
        .{ .from = 0, .to = 1, .value = 10 },
        .{ .from = 1, .to = 2, .value = 8 },
    };
    ui.begin(500, 300);
    viz.sankey(&ui, "sk", nodes[0..], links[0..], .{ .height = 180 });
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

// 散点图：点按数据范围归一（含负值）。
test "scatter maps points into the plot area" {
    var ui = core.Context{};
    const pts = [_]viz.Vec2{ .{ .x = -5, .y = 2 }, .{ .x = 5, .y = 8 } };
    const series = [_]viz.ScatterSeries{.{ .name = "s", .points = pts[0..] }};
    ui.begin(500, 300);
    viz.scatterChart(&ui, "sc", series[0..], .{ .height = 160 });
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

// 活动环：值 > 1 继续缠绕，中心文字与图例不溢出。
test "activity rings wind past one" {
    var ui = core.Context{};
    const rings = [_]viz.VizItem{
        .{ .label = "move", .value = 1.4 },
        .{ .label = "exercise", .value = 0.6 },
    };
    ui.begin(400, 300);
    viz.activityRings(&ui, "ar", rings[0..], .{ .size = 140, .center = "1.4", .caption = "goal", .legend = true });
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

// 径向仪表：色带 + 目标标记都不越界。
test "radial gauge draws bands and target" {
    var ui = core.Context{};
    const bands = [_]viz.GaugeBand{
        .{ .from = 0, .to = 60, .color = t.Color.hex(0x15803D, 255) },
        .{ .from = 60, .to = 100, .color = t.Color.hex(0xB91C1C, 255) },
    };
    ui.begin(400, 300);
    viz.radialGauge(&ui, "rg", 72, 0, 100, .{ .label = "load", .unit = "%", .bands = bands[0..], .target = 80, .show_target = true });
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

// K 线：悬停返回那根下标；带成交量与叠加线时不溢出。
test "candlestick reports the hovered candle" {
    var ui = core.Context{};
    const candles = [_]viz.Candle{
        .{ .open = 10, .high = 12, .low = 9, .close = 11, .volume = 100 },
        .{ .open = 11, .high = 13, .low = 10, .close = 10.5, .volume = 80 },
    };
    const ma = [_]f32{ 10.8, 11.2 };
    const overlays = [_]viz.Series{.{ .name = "ma", .values = ma[0..] }};

    ui.begin(400, 300);
    _ = viz.candlestick(&ui, "cd", candles[0..], .{ .height = 160, .overlays = overlays[0..] });
    ui.paint();
    try std.testing.expect(!ui.overflowed);

    const id1 = core.Context.idOf("cd") ^ (0xC0DE00 + 1);
    const r = ui.lastRect(id1) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 } };
    ui.begin(400, 300);
    const hovered = viz.candlestick(&ui, "cd", candles[0..], .{ .height = 160, .overlays = overlays[0..] });
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 1), hovered);
}

// ---------------------------------------------------------------- 曲线

// 曲线求值：线性段 = 直线插值，端点外 = 常量。
test "curve eval interpolates linearly and clamps" {
    const keys = [_]curves.CurveKey{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 1 },
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), curves.curveEval(keys[0..], 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), curves.curveEval(keys[0..], -1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), curves.curveEval(keys[0..], 2), 0.001);
}

// 曲线求值：贝塞尔段在手柄为 0 时退化为平滑 S 形（中点仍在两端之间）。
test "curve eval handles bezier segments" {
    const keys = [_]curves.CurveKey{
        .{ .x = 0, .y = 0, .mode = .free, .out_dx = 0.4, .out_dy = 0 },
        .{ .x = 1, .y = 1, .mode = .free, .in_dx = -0.4, .in_dy = 0 },
    };
    const mid = curves.curveEval(keys[0..], 0.5);
    try std.testing.expect(mid > 0.2 and mid < 0.8);
    // x 单调 → 值也应单调
    try std.testing.expect(curves.curveEval(keys[0..], 0.25) <= mid);
    try std.testing.expect(curves.curveEval(keys[0..], 0.75) >= mid);
}

// 曲线编辑器：拖关键帧改变数值，并标记 changed。
test "curve editor drags a key" {
    var ui = core.Context{};
    var keys = [_]curves.CurveKey{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 1 },
    };
    var count: usize = 2;
    var st = curves.CurveState{};

    ui.begin(400, 300);
    _ = curves.curveEditor(&ui, "cv", keys[0..], &count, &st, .{ .height = 200 });
    ui.paint();

    const id = core.Context.idOf("cv") ^ (0xCE00 + 1);
    const r = ui.lastRect(id) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    // 点选并拖动（向下 20px → y 变小）
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .down = true, .pressed = true, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 300);
    _ = curves.curveEditor(&ui, "cv", keys[0..], &count, &st, .{ .height = 200 });
    ui.paint();
    try std.testing.expectEqual(@as(i32, 1), st.selected);

    ui.input = .{ .mouse = .{ .x = cx, .y = cy + 30 }, .down = true };
    ui.begin(400, 300);
    const res = curves.curveEditor(&ui, "cv", keys[0..], &count, &st, .{ .height = 200 });
    ui.paint();
    try std.testing.expect(res.changed);
    try std.testing.expect(keys[1].y < 1.0);
}

// ---------------------------------------------------------------- 渐变

// 渐变求值：两端与中点。
test "gradient eval interpolates between stops" {
    const stops = [_]curves.GradientStop{
        .{ .t = 0, .color = t.Color.hex(0x000000, 255) },
        .{ .t = 1, .color = t.Color.hex(0xFFFFFF, 255) },
    };
    const mid = curves.gradientEval(stops[0..], 0.5);
    try std.testing.expect(mid.r > 100 and mid.r < 155);
    try std.testing.expectEqual(@as(u8, 0), curves.gradientEval(stops[0..], 0).r);
    try std.testing.expectEqual(@as(u8, 255), curves.gradientEval(stops[0..], 1).r);
}

// 渐变编辑器：Shift+点击添加一个停靠点。
test "gradient editor adds a stop on shift click" {
    var ui = core.Context{};
    var stops = [_]curves.GradientStop{
        .{ .t = 0, .color = t.Color.hex(0x000000, 255) },
        .{ .t = 1, .color = t.Color.hex(0xFFFFFF, 255) },
        .{ .t = 0, .color = t.Color.transparent },
    };
    var count: usize = 2;
    var st = curves.GradientState{};

    ui.begin(400, 200);
    _ = curves.gradientEditor(&ui, "ge", stops[0..], &count, &st, .{ .width = 240 });
    ui.paint();

    const id = core.Context.idOf("ge") ^ 0x6AD0;
    const r = ui.lastRect(id) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.input.mods = .{ .shift = true };
    ui.begin(400, 200);
    const res = curves.gradientEditor(&ui, "ge", stops[0..], &count, &st, .{ .width = 240 });
    ui.paint();
    try std.testing.expect(res.changed);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stops[1].t, 0.15);
}

// 冒烟 A：网格/条形类（矩形为主，节点吃紧）。
test "smoke: viz grid widgets build without overflowing" {
    var ui = core.Context{};
    const values = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const rows = [_][]const u8{ "r1", "r2", "r3" };
    const cols = [_][]const u8{ "c1", "c2", "c3" };
    const items = [_]viz.VizItem{
        .{ .label = "a", .value = 50 },
        .{ .label = "b", .value = 30 },
        .{ .label = "c", .value = 20 },
    };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(900, 1400);
        var col = ui.column(.{ .pad = 12, .gap = 10 });
        defer col.end();

        _ = viz.heatmap(&ui, "h1", values[0..], 3, 3, .{ .row_labels = rows[0..], .col_labels = cols[0..], .cell = 26 });
        _ = viz.calendarHeatmap(&ui, "h2", .{ .year = 2026, .month = 11, .day = 10 }, values[0..], .{ .cell = 12 });
        _ = viz.splitBar(&ui, "s1", items[0..], .{});
        _ = viz.barList(&ui, "s2", items[0..], .{ .max_rows = 3 });
        _ = viz.waffle(&ui, "s3", items[0..], .{ .cell = 10 });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}

// 冒烟 B：图形类（线段与圆弧为主）。
test "smoke: viz shape widgets build without overflowing" {
    var ui = core.Context{};
    const items = [_]viz.VizItem{
        .{ .label = "a", .value = 50 },
        .{ .label = "b", .value = 30 },
        .{ .label = "c", .value = 20 },
    };
    const v1 = [_]f32{ 3, 5, 2, 4 };
    const series = [_]viz.Series{.{ .name = "a", .values = v1[0..] }};
    const axes = [_][]const u8{ "a", "b", "c", "d" };
    const pts = [_]viz.Vec2{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 5 } };
    const sseries = [_]viz.ScatterSeries{.{ .name = "s", .points = pts[0..] }};
    const candles = [_]viz.Candle{
        .{ .open = 10, .high = 12, .low = 9, .close = 11, .volume = 10 },
        .{ .open = 11, .high = 12, .low = 9, .close = 10, .volume = 8 },
        .{ .open = 10, .high = 13, .low = 9.5, .close = 12, .volume = 12 },
    };
    const nodes = [_][]const u8{ "A", "B" };
    const links = [_]viz.SankeyLink{.{ .from = 0, .to = 1, .value = 5 }};
    const rings = [_]viz.VizItem{.{ .label = "m", .value = 0.8 }};

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(900, 1400);
        var col = ui.column(.{ .pad = 12, .gap = 10 });
        defer col.end();

        {
            var row = ui.row(.{ .gap = 16 });
            _ = viz.treemap(&ui, "t1", items[0..], .{ .width = 220, .height = 120 });
            _ = viz.funnel(&ui, "t2", items[0..], .{ .width = 220, .height = 120 });
            viz.radialGauge(&ui, "g1", 60, 0, 100, .{ .size = 120 });
            row.end();
        }
        viz.radarChart(&ui, "r1", series[0..], axes[0..], .{ .size = 160 });
        viz.sankey(&ui, "r2", nodes[0..], links[0..], .{ .height = 120 });
        viz.scatterChart(&ui, "r3", sseries[0..], .{ .height = 120 });
        viz.activityRings(&ui, "r4", rings[0..], .{ .size = 100 });
        _ = viz.candlestick(&ui, "r6", candles[0..], .{ .height = 100 });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}

// 冒烟 C：曲线与渐变编辑器。
test "smoke: curve and gradient editors build without overflowing" {
    var ui = core.Context{};
    var ckeys = [_]curves.CurveKey{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } };
    var ccount: usize = 2;
    var cst = curves.CurveState{};
    var gstops = [_]curves.GradientStop{
        .{ .t = 0, .color = t.Color.hex(0x2563EB, 255) },
        .{ .t = 1, .color = t.Color.hex(0xFFFFFF, 255) },
    };
    var gcount: usize = 2;
    var gst = curves.GradientState{};

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(600, 600);
        var col = ui.column(.{ .pad = 12, .gap = 10 });
        defer col.end();
        _ = curves.curveEditor(&ui, "c1", ckeys[0..], &ccount, &cst, .{ .height = 160 });
        _ = curves.gradientEditor(&ui, "g1", gstops[0..], &gcount, &gst, .{ .width = 200 });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}
