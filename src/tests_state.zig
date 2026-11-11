//! 状态池测试（「状态回收」）：跨帧保留的按 id 池必须**有界**且**不串味**。
//! 这三条都是真实 bug 的护栏：
//! - `tips` 满了原来直接不记 -> 第 17 个 tooltip 永远不出现；
//! - `scrolls` 满了原来返回槽 0 -> 两个滚动区共用同一个偏移（一滚就串）；
//! - `focus_curr` 满了原来静默丢弃 -> Tab 顺序悄悄少控件（现在会被 markOverflow 抓到）。
const std = @import("std");
const core = @import("core.zig");

test "state: hover pool evicts the least recently used instead of dropping" {
    var ui = core.Context{};
    var i: usize = 0;
    // 建出超过池容量的悬停计时
    while (i < core.MAX_TIPS + 6) : (i += 1) {
        ui.time = 10.0 + @as(f64, @floatFromInt(i));
        _ = ui.hoverStart(@intCast(i));
    }
    try std.testing.expect(ui.tip_n <= core.MAX_TIPS);

    // 最新的那个必须被记住：再问一次得到的仍是它原来的起始时间（不是"从现在开始"）
    const newest: u64 = core.MAX_TIPS + 5;
    const started = ui.time;
    ui.time += 5;
    try std.testing.expectApproxEqAbs(started, ui.hoverStart(newest), 0.001);

    // 最老的那个已被淘汰：重新记录时从当前时间算起
    ui.time = 100;
    try std.testing.expectApproxEqAbs(@as(f64, 100), ui.hoverStart(0), 0.001);
}

test "state: scroll pool keeps distinct offsets for many scroll areas" {
    var ui = core.Context{};
    // 16 个滚动区之内：各记各的
    var i: usize = 0;
    while (i < core.MAX_SCROLLS) : (i += 1) {
        ui.time = 1.0 + @as(f64, @floatFromInt(i));
        var name: [8]u8 = @splat(0);
        name[0] = 'a' + @as(u8, @intCast(i % 26));
        ui.scrollTo(name[0..1], @floatFromInt(i * 10));
    }
    i = 0;
    while (i < core.MAX_SCROLLS) : (i += 1) {
        var name: [8]u8 = @splat(0);
        name[0] = 'a' + @as(u8, @intCast(i % 26));
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(i * 10)), ui.scrollOffset(name[0..1]), 0.01);
    }

    // 超过容量：池仍有界，且**最新写入的不会串到别人的槽**（原来会直接落回槽 0）
    ui.time = 50;
    ui.scrollTo("zz", 777);
    try std.testing.expect(ui.scroll_n <= core.MAX_SCROLLS);
    try std.testing.expectApproxEqAbs(@as(f32, 777), ui.scrollOffset("zz"), 0.01);
    // 槽 0（最早那条）已被淘汰
    try std.testing.expectApproxEqAbs(@as(f32, 0), ui.scrollOffset("a"), 0.01);
}

test "state: focus pool overflow is observable" {
    const widgets = @import("widgets.zig");
    var ui = core.Context{};
    ui.begin(400, 4000);
    var i: usize = 0;
    // 造出超过焦点池的控件（按钮是 focusable）
    while (i < core.MAX_FOCUS + 4) : (i += 1) {
        var buf: [12]u8 = @splat(0);
        buf[0] = 'b';
        buf[1] = '0' + @as(u8, @intCast(i / 10));
        buf[2] = '0' + @as(u8, @intCast(i % 10));
        _ = widgets.button(&ui, buf[0..3], .{});
    }
    try std.testing.expectEqual(core.MAX_FOCUS, ui.focus_curr_n);
    try std.testing.expect(ui.overflowed); // 溢出必须可见，不能静默截断
}

// 帧末回填尺寸（「帧末统一布局」在立即模式里的形态）：本帧画完才知道多高，
// 下一帧才排得上。这里断言的是**顺序**：第一帧量、第二帧用。
test "state: panel auto height is measured at frame end and reused next frame" {
    var ui = core.Context{};
    const key: u64 = 0x5EA1;
    try std.testing.expect(ui.knownSize(key) == null); // 还没量过

    ui.begin(400, 300);
    {
        var p = ui.panel(.{ .x = 10, .y = 10, .w = 200, .h = 0 }, .{
            .pad = 8,
            .auto_height = true,
            .size_key = key,
        });
        _ = ui.reserve(0, 30, true);
        _ = ui.reserve(0, 12, true);
        p.end(); // 帧末：cursor = 30 + gap*1 + 12，pad*2 = 16
    }
    const s = ui.knownSize(key) orelse return error.NotRemembered;
    try std.testing.expectApproxEqAbs(@as(f32, 200), s.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 42 + 16), s.h, 0.01);
}

test "state: popover places itself with last frame's real height" {
    const overlay = @import("overlay.zig");
    const types = @import("types.zig");
    var ui = core.Context{};
    var open = true;
    const anchor = types.Rect{ .x = 20, .y = 230, .w = 60, .h = 20 }; // 靠近窗口底边，必须翻转上去

    // 第一帧：没有历史高度，只能用 estimate_h = 40
    ui.begin(300, 300);
    if (overlay.popoverBegin(&ui, "pop", anchor, &open, .{ .width = 180, .estimate_h = 40 })) {
        _ = ui.reserve(0, 10, true);
        _ = ui.reserve(0, 10, true);
        overlay.popoverEnd(&ui);
    }
    const first_y = ui.nodes[0].rect.y;
    try std.testing.expectApproxEqAbs(@as(f32, 230 - 40 - 6), first_y, 0.01);

    // 第二帧：用上一帧量到的真高（内容 10 + gap 8 + 10 = 28，加 pad 24 = 52）定位
    ui.begin(300, 300);
    if (overlay.popoverBegin(&ui, "pop", anchor, &open, .{ .width = 180, .estimate_h = 40 })) {
        _ = ui.reserve(0, 10, true);
        _ = ui.reserve(0, 10, true);
        overlay.popoverEnd(&ui);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 230 - 52 - 6), ui.nodes[0].rect.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 52), ui.nodes[0].rect.h, 0.01);
}
