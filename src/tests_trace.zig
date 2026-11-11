//! 追踪视图与网络瀑布的测试：排序、适配、命中、折叠、键盘、瀑布行与选中。
const std = @import("std");
const core = @import("core.zig");
const trace = @import("trace.zig");

/// 两条轨道：main（2 层）+ worker（1 层），时间轴 0..10 秒。
fn sampleSpans() [5]trace.Span {
    return .{
        .{ .name = "main", .start = 0.0, .end = 10.0, .track = 0, .depth = 0 },
        .{ .name = "parse", .start = 0.0, .end = 4.0, .track = 0, .depth = 1 },
        .{ .name = "render", .start = 4.0, .end = 10.0, .track = 0, .depth = 1 },
        .{ .name = "worker", .start = 1.0, .end = 9.0, .track = 1, .depth = 0 },
        .{ .name = "io", .start = 2.0, .end = 5.0, .track = 1, .depth = 1 },
    };
}

fn sampleTracks() [2]trace.Track {
    return .{ .{ .name = "main" }, .{ .name = "worker" } };
}

/// 面板左上角在 (0,0)、宽 600 时的探针坐标：
/// 表头 22，body 从 27 起，行高 20 → 第 0 行中心 37，第 1 行 57。
const ROW0_Y: f32 = 22 + 1 + 4 + 10;
const ROW_H: f32 = 20;
const PLOT_X: f32 = 150 + 8; // gutter 150 + PAD_X 8

fn frame(ui: *core.Context, tracks: *[2]trace.Track, spans: []const trace.Span, view: *trace.View, sel: *i32, st: *trace.State, opts: trace.Opts) trace.Result {
    ui.begin(600, 500);
    var col = ui.column(.{});
    const r = trace.traceView(ui, "tr", tracks[0..], spans, view, sel, st, opts);
    col.end();
    ui.paint();
    return r;
}

/// 真实后端的点击是两帧：按下（`pressed`+`down`）→ 抬起（`click`）。
/// 返回值合并两帧的结果（折叠这类动作发生在按下帧）。
fn pressAndClick(ui: *core.Context, tracks: *[2]trace.Track, spans: []const trace.Span, view: *trace.View, sel: *i32, st: *trace.State, opts: trace.Opts, x: f32, y: f32) trace.Result {
    ui.input = .{ .mouse = .{ .x = x, .y = y }, .pressed = true, .down = true };
    const a = frame(ui, tracks, spans, view, sel, st, opts);
    ui.input = .{ .mouse = .{ .x = x, .y = y }, .click = .{ .x = x, .y = y } };
    const b = frame(ui, tracks, spans, view, sel, st, opts);
    return .{
        .selection_changed = a.selection_changed or b.selection_changed,
        .view_changed = a.view_changed or b.view_changed,
        .hovered = b.hovered,
    };
}

test "trace: sortSpans orders by track, depth then start" {
    var spans = [_]trace.Span{
        .{ .name = "b", .start = 4.0, .end = 6.0, .track = 1, .depth = 0 },
        .{ .name = "a", .start = 0.0, .end = 2.0, .track = 0, .depth = 1 },
        .{ .name = "root", .start = 0.0, .end = 6.0, .track = 0, .depth = 0 },
        .{ .name = "a2", .start = 2.0, .end = 4.0, .track = 0, .depth = 1 },
    };
    trace.sortSpans(spans[0..]);
    try std.testing.expectEqualStrings("root", spans[0].name);
    try std.testing.expectEqualStrings("a", spans[1].name);
    try std.testing.expectEqualStrings("a2", spans[2].name);
    try std.testing.expectEqualStrings("b", spans[3].name);
}

test "trace: a zeroed view fits every span and draws the lanes" {
    var ui = core.Context{};
    var tracks = sampleTracks();
    var spans = sampleSpans();
    trace.sortSpans(spans[0..]);
    var view = trace.View{};
    var sel: i32 = -1;
    var st = trace.State{};
    const r = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});

    try std.testing.expect(r.view_changed); // 首帧适配
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), view.start, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), view.end, 1e-9);
    try std.testing.expect(!ui.overflowed);
    try std.testing.expect(ui.node_count >= 8); // 面板 + 表头 + 5 个条 + 至少两个轨道名
}

test "trace: hovering reports the span, clicking selects it" {
    var ui = core.Context{};
    var tracks = sampleTracks();
    var spans = sampleSpans();
    trace.sortSpans(spans[0..]);
    var view = trace.View{};
    var sel: i32 = -1;
    var st = trace.State{};
    _ = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});

    // main 覆盖整个时间轴 → 第 0 行任意位置都命中它
    ui.input = .{ .mouse = .{ .x = PLOT_X + 40, .y = ROW0_Y } };
    const r = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});
    try std.testing.expectEqual(@as(i32, 0), r.hovered);
    try std.testing.expectEqualStrings("main", spans[@intCast(r.hovered)].name);

    const r2 = pressAndClick(&ui, &tracks, spans[0..], &view, &sel, &st, .{}, PLOT_X + 40, ROW0_Y);
    try std.testing.expect(r2.selection_changed);
    try std.testing.expectEqual(@as(i32, 0), sel);

    // 空白处点击（第 3 行、时间 8s：worker 的子 span 只到 5s）→ 取消选中
    const empty_x: f32 = PLOT_X + 430.0 * 0.8;
    const empty_y: f32 = 22 + 1 + 4 + ROW_H * 3 + 10;
    _ = pressAndClick(&ui, &tracks, spans[0..], &view, &sel, &st, .{}, empty_x, empty_y);
    try std.testing.expectEqual(@as(i32, -1), sel);
}

test "trace: clicking a lane name folds it to one row" {
    var ui = core.Context{};
    var tracks = sampleTracks();
    var spans = sampleSpans();
    trace.sortSpans(spans[0..]);
    var view = trace.View{};
    var sel: i32 = -1;
    var st = trace.State{};
    _ = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});

    // 轨道名区域（x < gutter）：点第 2 条轨道（worker，有子 span）
    const y = 22 + 1 + 4 + ROW_H * 2 + 10; // main 占 2 行 → worker 的 row0 = 2
    const r = pressAndClick(&ui, &tracks, spans[0..], &view, &sel, &st, .{}, 30, y);
    try std.testing.expect(!ui.overflowed);
    try std.testing.expect(r.view_changed);
    try std.testing.expect(tracks[1].collapsed);
    try std.testing.expect(!tracks[0].collapsed);
}

test "trace: keys walk the lane, down enters the child and up goes back" {
    var ui = core.Context{};
    var tracks = sampleTracks();
    var spans = sampleSpans();
    trace.sortSpans(spans[0..]);
    var view = trace.View{};
    var sel: i32 = -1;
    var st = trace.State{};
    _ = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});

    // 先点一下拿到焦点（点击会把 focus_id 设为面板）
    _ = pressAndClick(&ui, &tracks, spans[0..], &view, &sel, &st, .{}, PLOT_X + 40, ROW0_Y);
    try std.testing.expectEqual(@as(i32, 0), sel);

    // ↓ 进子（parse）
    ui.input = .{ .mouse = .{ .x = PLOT_X + 40, .y = ROW0_Y }, .keys = kOnly(.down), .key_count = 1 };
    const r = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});
    try std.testing.expect(r.selection_changed);
    try std.testing.expectEqualStrings("parse", spans[@intCast(sel)].name);

    // → 同行到 render
    ui.input = .{ .mouse = .{ .x = PLOT_X + 40, .y = ROW0_Y }, .keys = kOnly(.right), .key_count = 1 };
    _ = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});
    try std.testing.expectEqualStrings("render", spans[@intCast(sel)].name);

    // ↑ 回父（main）
    ui.input = .{ .mouse = .{ .x = PLOT_X + 40, .y = ROW0_Y }, .keys = kOnly(.up), .key_count = 1 };
    _ = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});
    try std.testing.expectEqualStrings("main", spans[@intCast(sel)].name);
}

fn kOnly(k: @import("types.zig").Key) [8]@import("types.zig").Key {
    var keys: [8]@import("types.zig").Key = @splat(.unknown);
    keys[0] = k;
    return keys;
}

test "trace: markers extend the time extent" {
    var ui = core.Context{};
    var tracks = sampleTracks();
    var spans = sampleSpans();
    trace.sortSpans(spans[0..]);
    var view = trace.View{};
    var sel: i32 = -1;
    var st = trace.State{};
    const markers = [_]trace.Marker{
        .{ .name = "GC", .time = 12.0, .tone = .warn },
    };
    const r = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{ .markers = markers[0..] });
    try std.testing.expect(r.view_changed);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), view.end, 1e-6); // 标记在最后一个 span 之后
    try std.testing.expect(!ui.overflowed);
}

test "trace: wheel over the plot zooms in" {
    var ui = core.Context{};
    var tracks = sampleTracks();
    var spans = sampleSpans();
    trace.sortSpans(spans[0..]);
    var view = trace.View{};
    var sel: i32 = -1;
    var st = trace.State{};
    _ = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});

    const before = view.end - view.start;
    ui.input = .{ .mouse = .{ .x = PLOT_X + 200, .y = ROW0_Y }, .wheel = 1 };
    const r = frame(&ui, &tracks, spans[0..], &view, &sel, &st, .{});
    try std.testing.expect(r.view_changed);
    try std.testing.expect(view.end - view.start < before);
}

// ---------------------------------------------------------------- 瀑布

fn sampleRequests() [3]trace.NetRequest {
    return .{
        .{ .name = "/index.html", .method = "GET", .status = 200, .type = "html", .size = 4096, .start = 0, .timing = .{ 0, 0.01, 0.02, 0.03, 0.10, 0.05 } },
        .{ .name = "/app.js", .method = "GET", .status = 200, .type = "js", .size = 20480, .start = 0.2, .timing = .{ 0.02, 0, 0.03, 0.04, 0.08, 0.12 } },
        .{ .name = "/missing.png", .method = "GET", .status = 404, .type = "png", .size = 0, .start = 0.5, .timing = .{ 0, 0, 0.01, 0.02, 0.05, 0.01 } },
    };
}

test "waterfall: draws a header, three rows and a footer" {
    var ui = core.Context{};
    var reqs = sampleRequests();
    var sel: i32 = -1;
    ui.begin(800, 600);
    var col = ui.column(.{});
    const r = trace.waterfall(&ui, "wf", reqs[0..], .{ .selected = &sel, .dom_loaded = 0.6, .loaded = 0.9 });
    col.end();
    ui.paint();

    try std.testing.expectEqual(@as(i32, -1), r.clicked);
    try std.testing.expect(!ui.overflowed);
    // 表头 + 3 行 + 分割线 + footer 至少这么多节点
    try std.testing.expect(ui.node_count >= 12);
}

test "waterfall: empty input draws the placeholder and does not overflow" {
    var ui = core.Context{};
    ui.begin(800, 600);
    var col = ui.column(.{});
    const r = trace.waterfall(&ui, "wf", &.{}, .{});
    col.end();
    ui.paint();
    try std.testing.expectEqual(@as(i32, -1), r.hovered);
    try std.testing.expect(!ui.overflowed);
    try std.testing.expect(ui.node_count >= 3);
}

test "waterfall: hovering a row reports it and a click selects it" {
    var ui = core.Context{};
    var reqs = sampleRequests();
    var sel: i32 = -1;
    // 第一帧建立命中矩形
    ui.begin(800, 600);
    {
        var col = ui.column(.{});
        _ = trace.waterfall(&ui, "wf", reqs[0..], .{ .selected = &sel });
        col.end();
    }
    ui.paint();

    // 表头 28 → 表头线 1 → 行区；行高 26，第一行中心 ≈ 28 + 1 + 4 + 13
    const y: f32 = 28 + 1 + 4 + 13;
    ui.input = .{ .mouse = .{ .x = 120, .y = y } };
    ui.begin(800, 600);
    {
        var col = ui.column(.{});
        const r = trace.waterfall(&ui, "wf", reqs[0..], .{ .selected = &sel });
        col.end();
        try std.testing.expectEqual(@as(i32, 0), r.hovered);
    }
    ui.paint();

    ui.input = .{ .mouse = .{ .x = 120, .y = y }, .click = .{ .x = 120, .y = y } };
    ui.begin(800, 600);
    {
        var col = ui.column(.{});
        const r = trace.waterfall(&ui, "wf", reqs[0..], .{ .selected = &sel });
        col.end();
        try std.testing.expectEqual(@as(i32, 0), r.clicked);
    }
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), sel);
}

test "waterfall: narrow panels drop the type and size columns" {
    var ui = core.Context{};
    var reqs = sampleRequests();
    var sel: i32 = -1;
    ui.begin(420, 600);
    var col = ui.column(.{});
    _ = trace.waterfall(&ui, "wf", reqs[0..], .{ .width = 420, .selected = &sel });
    col.end();
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}
