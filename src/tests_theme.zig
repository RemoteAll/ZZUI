//! 主题切换测试：`setMode` 必须**整包替换**（不能出现半套配色），且能切回。
const std = @import("std");
const theme = @import("theme.zig");
const core = @import("core.zig");
const render = @import("render.zig");
const types = @import("types.zig");

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

test "theme: mix interpolates both ends and clamps k" {
    const a = types.Color{ .r = 0, .g = 10, .b = 20, .a = 7 };
    const b = types.Color{ .r = 100, .g = 110, .b = 120, .a = 9 };
    const mid = theme.mix(a, b, 0.5);
    try std.testing.expectEqual(@as(u8, 50), mid.r);
    try std.testing.expectEqual(@as(u8, 60), mid.g);
    try std.testing.expectEqual(@as(u8, 70), mid.b);
    try std.testing.expectEqual(@as(u8, 255), mid.a);
    // k 越界夹紧（-1 当 0、2 当 1）
    const lo = theme.mix(a, b, -1);
    try std.testing.expectEqual(@as(u8, 0), lo.r);
    const hi = theme.mix(a, b, 2);
    try std.testing.expectEqual(@as(u8, 100), hi.r);
}

test "theme: setAccent derives active/text/bg tokens" {
    theme.setMode(.light);
    theme.setAccent(types.Color.hex(0x2266FF, 255));
    try std.testing.expectEqual(@as(u8, 0x22), theme.accent.r);
    // 深色强调 → 白字
    try std.testing.expectEqual(@as(u8, 0xff), theme.accent_text.r);
    // active 比 accent 更暗，bg 带透明度
    try std.testing.expect(theme.accent_active.r < theme.accent.r);
    try std.testing.expectEqual(@as(u8, 32), theme.accent_bg.a);

    // 浅黄强调 → 深字（对比度）
    theme.setAccent(types.Color.hex(0xFFE066, 255));
    try std.testing.expectEqual(@as(u8, 0x11), theme.accent_text.r);
    try std.testing.expectEqual(@as(u8, 0x11), theme.accent_text.g);
    theme.setMode(.light);
    snap(theme.light);
}

test "theme: animated switch interpolates tokens and lands exactly on the target" {
    theme.setMode(.light);
    defer theme.setMode(.light);

    theme.animateTo(.dark, 0.2);
    try std.testing.expectEqual(theme.Mode.dark, theme.mode);
    try std.testing.expect(theme.isAnimating());

    // 走到一半：既不是浅底也不是深底（往深处去）
    _ = theme.step(0.1);
    try std.testing.expect(theme.isAnimating());
    try std.testing.expect(theme.bg.r < theme.light.bg.r);
    try std.testing.expect(theme.bg.r > theme.dark.bg.r);
    // 文字色反过来：浅色主题是深字，深色主题是浅字，中点应该在两者之间
    try std.testing.expect(theme.text.r > theme.light.text.r);
    try std.testing.expect(theme.text.r < theme.dark.text.r);

    // 再推进到底：逐个令牌与深色调色板一致
    _ = theme.step(0.5);
    try std.testing.expect(!theme.isAnimating());
    inline for (@typeInfo(theme.Palette).@"struct".field_names) |name| {
        try std.testing.expectEqual(@field(theme.dark, name), @field(theme, name));
    }
}

test "theme: setMode cancels a running transition" {
    theme.setMode(.light);
    defer theme.setMode(.light);

    theme.animateTo(.dark, 1.0);
    _ = theme.step(0.1);
    theme.setMode(.light);
    try std.testing.expect(!theme.isAnimating());
    try std.testing.expectEqual(theme.light.bg.r, theme.bg.r);

    // 同一个目标重复调 animateTo 不应重开窗口
    theme.animateTo(.light, 0.2);
    try std.testing.expect(!theme.isAnimating());
}
