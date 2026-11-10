//! 交互与控件测试（`zig build test` 的入口）：用 null 测量，不依赖任何平台 API。
const std = @import("std");
const core = @import("core.zig");
const widgets = @import("widgets.zig");
const theme = @import("theme.zig");

test "checkbox toggles on click (last-frame hit test)" {
    var ui = core.Context{};
    var value = false;

    ui.begin(300, 200);
    widgets.checkbox(&ui, "auto", &value);
    ui.paint();

    // 第二帧：点击落在上一帧矩形内
    ui.begin(300, 200);
    ui.input = .{ .mouse = .{ .x = 10, .y = 10 }, .click = .{ .x = 10, .y = 10 } };
    widgets.checkbox(&ui, "auto", &value);
    ui.paint();
    try std.testing.expect(value);
}

test "slider drag follows the pointer" {
    var ui = core.Context{};
    var value: f32 = 0;

    ui.begin(300, 200);
    var col = ui.column(.{ .pad = 0, .gap = 0 });
    widgets.slider(&ui, "vol", &value, 0, 1);
    col.end();
    ui.paint();

    // 拖动：按下在轨道内，鼠标到 3/4 处
    ui.begin(300, 200);
    ui.input = .{ .mouse = .{ .x = 225, .y = 40 }, .down = true, .pressed = true };
    var col2 = ui.column(.{ .pad = 0, .gap = 0 });
    widgets.slider(&ui, "vol", &value, 0, 1);
    col2.end();
    ui.paint();
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), value, 0.02);

    // 松开：不再跟随
    ui.begin(300, 200);
    ui.input = .{ .mouse = .{ .x = 30, .y = 40 }, .down = false };
    var col3 = ui.column(.{ .pad = 0, .gap = 0 });
    widgets.slider(&ui, "vol", &value, 0, 1);
    col3.end();
    ui.paint();
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), value, 0.02);
}

test "tab moves focus in build order" {
    var ui = core.Context{};
    const id_a = core.Context.idOf("A") ^ 0x9E3779B97F4A7C15;
    const id_b = core.Context.idOf("B") ^ 0x9E3779B97F4A7C15;

    // 第一帧：收集焦点顺序
    ui.begin(300, 200);
    _ = widgets.button(&ui, "A", .{});
    _ = widgets.button(&ui, "B", .{});
    ui.paint();

    // 第二帧：Tab -> 第一个可聚焦控件
    ui.input = .{};
    ui.input.addKey(.tab);
    ui.begin(300, 200);
    _ = widgets.button(&ui, "A", .{});
    _ = widgets.button(&ui, "B", .{});
    ui.paint();
    try std.testing.expectEqual(id_a, ui.focus_id);

    // 第三帧：再 Tab -> 第二个
    ui.input = .{};
    ui.input.addKey(.tab);
    ui.begin(300, 200);
    _ = widgets.button(&ui, "A", .{});
    _ = widgets.button(&ui, "B", .{});
    ui.paint();
    try std.testing.expectEqual(id_b, ui.focus_id);

    // 空格激活已聚焦的按钮（返回值应被忽略，但不能崩）
    ui.input = .{};
    ui.input.addKey(.space);
    ui.begin(300, 200);
    _ = widgets.button(&ui, "A", .{});
    _ = widgets.button(&ui, "B", .{});
    ui.paint();
}

test "frame string pool keeps generated text valid" {
    var ui = core.Context{};
    ui.begin(300, 200);
    ui.textIntRun("Clicked ", 42, " times", 14, theme.text);
    ui.paint();
    // 池里应出现完整的 "Clicked 42 times"
    try std.testing.expectEqualStrings("Clicked 42 times", ui.nodes[0].text);
}
