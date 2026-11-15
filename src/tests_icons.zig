//! 矢量图标测试：段数预算、绘制指令数、图标按钮/图标行点击。
const std = @import("std");
const core = @import("core.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const types = @import("types.zig");

fn frameStart(ui: *core.Context) void {
    ui.begin(600, 400);
}

test "icons: segment counts stay inside the documented budget" {
    try std.testing.expectEqual(@as(usize, 2), icons.segCount(.check));
    try std.testing.expectEqual(@as(usize, 2), icons.segCount(.x));
    try std.testing.expectEqual(@as(usize, 1), icons.segCount(.minus));
    try std.testing.expectEqual(@as(usize, 5), icons.segCount(.settings));
    // 全表里最复杂的图标也不该超过 12 段（一屏 25 个图标 ≈ 300 段，仍低于 MAX_OVERLAYS）
    var worst: usize = 0;
    inline for (@typeInfo(icons.Icon).@"enum".field_names) |f| {
        const n = icons.segCount(@field(icons.Icon, f));
        if (n > worst) worst = n;
    }
    try std.testing.expect(worst <= 12);
}

test "icons: draw emits only overlay commands and never overflows for a single icon" {
    var ui = core.Context{};
    frameStart(&ui);
    const before = ui.overlay_count;
    icons.draw(&ui, .check, .{ .x = 10, .y = 10, .w = 24, .h = 24 }, theme.text);
    try std.testing.expectEqual(before + 2, ui.overlay_count);

    icons.draw(&ui, .grid, .{ .x = 40, .y = 10, .w = 24, .h = 24 }, theme.text);
    try std.testing.expectEqual(before + 2 + 16, ui.overlay_count); // 4 个矩形 × 4 段

    // 退化尺寸不画
    const after = ui.overlay_count;
    icons.draw(&ui, .star, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, theme.text);
    try std.testing.expectEqual(after, ui.overlay_count);
    try std.testing.expect(!ui.overflowed);
}

test "icons: icon button reports clicks and honors disabled" {
    var ui = core.Context{};
    frameStart(&ui);
    var col = ui.column(.{});
    var clicked = icons.iconButton(&ui, "ib", .plus, .{});
    col.end();
    ui.paint();
    try std.testing.expect(!clicked);
    const r = ui.lastRect(core.Context.idOf("ib")).?;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .pressed = true, .down = true };
    frameStart(&ui);
    col = ui.column(.{});
    _ = icons.iconButton(&ui, "ib", .plus, .{});
    col.end();
    ui.paint();
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    frameStart(&ui);
    col = ui.column(.{});
    clicked = icons.iconButton(&ui, "ib", .plus, .{});
    col.end();
    ui.paint();
    try std.testing.expect(clicked);

    // 禁用：点也不回 true
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    frameStart(&ui);
    col = ui.column(.{});
    clicked = icons.iconButton(&ui, "ib", .plus, .{ .disabled = true });
    col.end();
    ui.paint();
    try std.testing.expect(!clicked);
}

test "icons: icon label reports clicks on the row" {
    var ui = core.Context{};
    frameStart(&ui);
    var col = ui.column(.{});
    _ = icons.iconLabel(&ui, "il", .folder, "Documents");
    col.end();
    ui.paint();
    const r = ui.lastRect(core.Context.idOf("il")).?;
    const cx = r.x + 20;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .pressed = true, .down = true };
    frameStart(&ui);
    col = ui.column(.{});
    _ = icons.iconLabel(&ui, "il", .folder, "Documents");
    col.end();
    ui.paint();
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    frameStart(&ui);
    col = ui.column(.{});
    const clicked = icons.iconLabel(&ui, "il", .folder, "Documents");
    col.end();
    ui.paint();
    try std.testing.expect(clicked);
    try std.testing.expect(!ui.overflowed);
}

test "icons: every icon draws at two sizes without panicking" {
    var ui = core.Context{};
    frameStart(&ui);
    const sizes = [_]f32{ 12, 32 };
    inline for (@typeInfo(icons.Icon).@"enum".field_names) |f| {
        for (sizes) |s| {
            icons.draw(&ui, @field(icons.Icon, f), .{ .x = 0, .y = 0, .w = s, .h = s }, types.Color.hex(0x333333, 255));
            // 画满一屏会超预算，这是文档里写明的；这里每画完一个就重置，只看单图标不出错
            ui.begin(600, 400);
        }
    }
    try std.testing.expect(!ui.overflowed);
}
