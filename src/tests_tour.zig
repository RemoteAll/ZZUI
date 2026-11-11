//! 引导（tour）与文案表（strings）测试。
const std = @import("std");
const core = @import("core.zig");
const tour = @import("tour.zig");
const strings = @import("strings.zig");
const month = @import("month.zig");
const widgets = @import("widgets.zig");

test "strings: defaults are English and a table overrides them" {
    var ui = core.Context{};
    try std.testing.expectEqualStrings("January", strings.monthName(&ui, 1));
    try std.testing.expectEqualStrings("Sun", strings.weekdayShort(&ui, 6));
    try std.testing.expectEqualStrings("Today", strings.todayLabel(&ui));

    var zh = strings.Strings{};
    zh.month[0] = "一月";
    zh.month[6] = "七月";
    zh.weekday_min[0] = "一";
    zh.today = "今天";
    strings.set(&ui, &zh);
    try std.testing.expectEqualStrings("一月", strings.monthName(&ui, 1));
    try std.testing.expectEqualStrings("七月", strings.monthName(&ui, 7));
    try std.testing.expectEqualStrings("February", strings.monthName(&ui, 2)); // 没翻译的回退英文
    try std.testing.expectEqualStrings("一", strings.weekdayMin(&ui, 0));
    try std.testing.expectEqualStrings("今天", strings.todayLabel(&ui));

    strings.set(&ui, null);
    try std.testing.expectEqualStrings("January", strings.monthName(&ui, 1));
}

test "strings: the month calendar picks up the table" {
    var ui = core.Context{};
    var zh = strings.Strings{};
    zh.month[10] = "十一月";
    strings.set(&ui, &zh);

    ui.begin(500, 700);
    var m = month.Date{ .year = 2026, .month = 11, .day = 1 };
    var col = ui.column(.{});
    _ = month.monthCalendar(&ui, "cal", &m, &.{}, .{});
    col.end();
    ui.paint();

    // 标题里应该有「十一月」这三个汉字（按 UTF-8 字节找）
    var found = false;
    var i: usize = 0;
    while (i < ui.node_count) : (i += 1) {
        if (ui.nodes[i].kind == .text and std.mem.indexOf(u8, ui.nodes[i].text, "十一月") != null) found = true;
    }
    try std.testing.expect(found);
    strings.set(&ui, null);
}

test "tour: steps advance, go back and finish" {
    var ui = core.Context{};
    var step: i32 = 0;
    const steps = [_]tour.Step{
        .{ .title = "One", .body = "first" },
        .{ .title = "Two", .body = "second" },
    };

    // 第一帧：没有输入，停在 0
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const a = tour.tour(&ui, "tr", steps[0..], &step, .{});
        col.end();
        try std.testing.expectEqual(tour.Action.none, a);
    }
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), step);

    // 右方向键 → 下一步
    ui.input = .{ .keys = .{ .right, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown }, .key_count = 1 };
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const a = tour.tour(&ui, "tr", steps[0..], &step, .{});
        col.end();
        try std.testing.expectEqual(tour.Action.next, a);
    }
    ui.paint();
    try std.testing.expectEqual(@as(i32, 1), step);

    // 左方向键 → 上一步
    ui.input = .{ .keys = .{ .left, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown }, .key_count = 1 };
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const a = tour.tour(&ui, "tr", steps[0..], &step, .{});
        col.end();
        try std.testing.expectEqual(tour.Action.back, a);
    }
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), step);

    // 走最后一步的 Next → done，step 置 -1
    step = 1;
    ui.input = .{};
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        // 找 Done 按钮点它
        _ = tour.tour(&ui, "tr", steps[0..], &step, .{});
        col.end();
    }
    ui.paint();
    step = 1;
    ui.input = .{ .keys = .{ .enter, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown }, .key_count = 1 };
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        const a = tour.tour(&ui, "tr", steps[0..], &step, .{});
        col.end();
        try std.testing.expectEqual(tour.Action.done, a);
    }
    ui.paint();
    try std.testing.expectEqual(@as(i32, -1), step);
}

test "tour: esc skips and shuts the whole thing down" {
    var ui = core.Context{};
    var step: i32 = 0;
    const steps = [_]tour.Step{.{ .title = "Only", .body = "" }};
    ui.begin(500, 400);
    {
        var col = ui.column(.{});
        _ = tour.tour(&ui, "tr2", steps[0..], &step, .{});
        col.end();
    }
    ui.paint();

    ui.input = .{ .keys = .{ .escape, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown, .unknown }, .key_count = 1 };
    ui.begin(500, 400);
    {
        var col = ui.column(.{});
        const a = tour.tour(&ui, "tr2", steps[0..], &step, .{});
        col.end();
        try std.testing.expectEqual(tour.Action.skipped, a);
    }
    ui.paint();
    try std.testing.expectEqual(@as(i32, -1), step);

    // 已结束后再调：什么都不做
    ui.input = .{};
    ui.begin(500, 400);
    {
        var col = ui.column(.{});
        try std.testing.expectEqual(tour.Action.none, tour.tour(&ui, "tr2", steps[0..], &step, .{}));
        col.end();
    }
    ui.paint();
}

test "tour: a target id turns into a spotlight around that control" {
    var ui = core.Context{};
    var step: i32 = 0;
    var target_id: u64 = 0;

    // 先建一个按钮，记住它的 id
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        _ = widgets.button(&ui, "Save", .{});
        col.end();
        target_id = core.Context.idOf("Save") ^ 0x9E3779B97F4A7C15;
    }
    ui.paint();

    // 交给 tour：它从上一帧命中里取矩形，压暗四周
    var steps = [_]tour.Step{.{ .target = target_id, .title = "Save", .body = "stores the file" }};
    ui.input = .{};
    ui.begin(600, 400);
    {
        var col = ui.column(.{});
        _ = widgets.button(&ui, "Save", .{});
        col.end();
        _ = tour.tour(&ui, "tr3", steps[0..], &step, .{ .padding = 4 });
    }
    ui.paint();
    try std.testing.expect(!ui.overflowed);
    // 压暗 4 块（目标在左上角时可能少于 4 块）+ 聚光边框都在节点通道里，
    // 卡片与它的文本也占节点 → 节点数明显多于不加引导时
    try std.testing.expect(ui.node_count >= 6);
}
