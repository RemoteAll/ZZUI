//! 主题切换测试：`setMode` 必须**整包替换**（不能出现半套配色），且能切回。
const std = @import("std");
const theme = @import("theme.zig");
const core = @import("core.zig");
const render = @import("render.zig");

fn snap(p: theme.Palette) void {
    // 逐字段比对：当前令牌必须与选中的选色板完全一致
    inline for (@typeInfo(theme.Palette).@"struct".field_names) |name| {
        const want = @field(p, name);
        const got = @field(theme, name);
        if (!std.meta.eql(want, got)) {
            std.debug.print("\n[schema mismatch] {s}: want {any} got {any}\n", .{ name, want, got });
            @panic("theme field mismatch");
        }
    }
}

test "theme: setMode swaps every token and can go back" {
    theme.setMode(.light);
    snap(theme.light);
    try std.testing.expectEqual(theme.Mode.light, theme.mode);
    try std.testing.expect(!theme.isDark());

    theme.setMode(.dark);
    snap(theme.dark);
    try std.testing.expectEqual(theme.Mode.dark, theme.mode);
    try std.testing.expect(theme.isDark());
    // 深色底必须真的变暗（不是只把 mode 标记改了）
    try std.testing.expect(theme.bg.r < 0x40 and theme.text.r > 0xC0);

    theme.toggle();
    snap(theme.light);
    try std.testing.expectEqual(theme.Mode.light, theme.mode);
}

test "theme: render clears the frame with the active background" {
    var ui = core.Context{};
    ui.begin(8, 8);
    ui.paint();

    var buf: [8 * 8 * 4]u8 = @splat(0);
    theme.setMode(.dark);
    defer theme.setMode(.light);
    render.render(&ui, &buf, 8, 8, 1, 0);
    // BGRA：深色底 0x15171A
    try std.testing.expectEqual(@as(u8, 0x1A), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x17), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x15), buf[2]);

    theme.setMode(.light);
    render.render(&ui, &buf, 8, 8, 1, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
}

test "theme: withAlpha keeps rgb and replaces alpha" {
    const c = theme.withAlpha(theme.light.accent, 48);
    try std.testing.expectEqual(theme.light.accent.r, c.r);
    try std.testing.expectEqual(theme.light.accent.g, c.g);
    try std.testing.expectEqual(theme.light.accent.b, c.b);
    try std.testing.expectEqual(@as(u8, 48), c.a);
}
