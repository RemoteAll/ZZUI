//! 火焰图测试：排序、视口适配、命中、缩放与「不溢出节点预算」。
const std = @import("std");
const core = @import("core.zig");
const flame = @import("flame.zig");

fn sample() [5]flame.Span {
    return .{
        .{ .name = "main", .start = 0.0, .end = 10.0, .depth = 0 },
        .{ .name = "parse", .start = 0.0, .end = 4.0, .depth = 1 },
        .{ .name = "render", .start = 4.0, .end = 10.0, .depth = 1 },
        .{ .name = "lex", .start = 0.0, .end = 2.5, .depth = 2 },
        .{ .name = "ast", .start = 2.5, .end = 4.0, .depth = 2 },
    };
}

test "flame: sortSpans orders by depth then start" {
    var spans = [_]flame.Span{
        .{ .name = "b", .start = 4.0, .end = 6.0, .depth = 1 },
        .{ .name = "a", .start = 0.0, .end = 2.0, .depth = 1 },
        .{ .name = "root", .start = 0.0, .end = 6.0, .depth = 0 },
    };
    flame.sortSpans(spans[0..]);
    try std.testing.expectEqualStrings("root", spans[0].name);
    try std.testing.expectEqualStrings("a", spans[1].name);
    try std.testing.expectEqualStrings("b", spans[2].name);
}

test "flame: empty input reports nothing" {
    var ui = core.Context{};
    ui.begin(600, 400);
    var view = flame.View{};
    var sel: i32 = -1;
    const r = flame.flameGraph(&ui, "fl", &.{}, &view, &sel, .{});
    try std.testing.expectEqual(@as(i32, -1), r.hovered);
    try std.testing.expect(!r.view_changed);
}

test "flame: a zeroed view fits every span and draws rows" {
    var ui = core.Context{};
    ui.begin(600, 400);
    var spans = sample();
    flame.sortSpans(spans[0..]);
    var view = flame.View{};
    var sel: i32 = -1;
    var col = ui.column(.{});
    const r = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
    col.end();
    ui.paint();

    try std.testing.expect(r.view_changed); // 首帧适配
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), view.start, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), view.end, 1e-9);
    try std.testing.expect(!ui.overflowed);
    // 5 个 span → 至少 5 个条 + 面板 + 刻度栏
    try std.testing.expect(ui.node_count >= 7);
}

test "flame: hovering a bar reports its index and clicking selects it" {
    var ui = core.Context{};
    var spans = sample();
    flame.sortSpans(spans[0..]);
    var view = flame.View{};
    var sel: i32 = -1;

    // 第一帧：适配 + 建矩形
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        _ = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
    }
    ui.paint();

    // main 条在 depth 0 行：y = 面板顶 + 刻度(22) + pad(4) + row*0 ; x 在左半边
    // 面板从 (0,0) 开始（column 无 pad），宽 600
    const probe_y: f32 = 22 + 4 + 10;
    const probe_x: f32 = 8 + 4; // PAD_X 之后一点点
    ui.input = .{ .mouse = .{ .x = probe_x, .y = probe_y } };
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const r = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
        try std.testing.expect(r.hovered >= 0);
        try std.testing.expectEqualStrings("main", spans[@intCast(r.hovered)].name);
    }
    ui.paint();

    // 点击同一位置 → 选中
    ui.input = .{ .mouse = .{ .x = probe_x, .y = probe_y }, .click = .{ .x = probe_x, .y = probe_y } };
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const r = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
        try std.testing.expect(r.selection_changed);
    }
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), sel);
}

test "flame: wheel zooms the visible range around the pointer" {
    var ui = core.Context{};
    var spans = sample();
    flame.sortSpans(spans[0..]);
    var view = flame.View{};
    var sel: i32 = -1;

    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        _ = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
    }
    ui.paint();

    const before = view.end - view.start;
    ui.input = .{ .mouse = .{ .x = 300, .y = 60 }, .wheel = 1 };
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const r = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
        try std.testing.expect(r.view_changed);
    }
    ui.paint();
    try std.testing.expect(view.end - view.start < before); // 向上滚 = 放大
}

test "flame: spanRect maps a span into panel coordinates" {
    var ui = core.Context{};
    var spans = sample();
    flame.sortSpans(spans[0..]);
    var view = flame.View{};
    var sel: i32 = -1;

    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        _ = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
    }
    ui.paint();

    const r = flame.spanRect(&ui, "fl", spans[0..], view, spans[0]);
    try std.testing.expect(r.w > 100);
    try std.testing.expect(r.h > 10);
    // main 覆盖整个时间轴
    const r2 = flame.spanRect(&ui, "fl", spans[0..], view, spans[2]); // render 在后半段
    try std.testing.expect(r2.x > r.x);
}

test "flame: home key fits everything again after zooming" {
    var ui = core.Context{};
    var spans = sample();
    flame.sortSpans(spans[0..]);
    var view = flame.View{};
    var sel: i32 = -1;

    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        _ = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
    }
    ui.paint();

    // 先缩小
    view.start = 2.0;
    view.end = 6.0;
    ui.input = .{ .keys = .{ .home, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown }, .key_count = 1 };
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const r = flame.flameGraph(&ui, "fl", spans[0..], &view, &sel, .{});
        col.end();
        try std.testing.expect(r.view_changed);
    }
    ui.paint();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), view.start, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), view.end, 1e-9);
}
