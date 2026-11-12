//! 颜色选择 + 主题切换（对位 `cui_color_picker` / `cui_theme_switcher` / `cui_theme_toggle`），
//! 以及这轮补的 `cui_draw_polyline` / `cui_draw_rect_gradient` / `cui_draw_shadow`。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const colorpicker = @import("colorpicker.zig");
const types = @import("types.zig");

fn frame(ui: *core.Context, id: []const u8, value: *types.Color, opts: colorpicker.Opts) bool {
    ui.begin(600, 600);
    var col = ui.column(.{});
    const changed = colorpicker.colorPicker(ui, id, value, opts);
    col.end();
    ui.paint();
    return changed;
}

test "colorpicker: hsv round trips through rgb" {
    const red = types.Color.hex(0xFF0000, 255);
    const hsv = colorpicker.rgbToHsv(red);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hsv.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hsv.v, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hsv.h, 0.01);
    const back = colorpicker.hsvToRgb(hsv);
    try std.testing.expectEqual(@as(u8, 255), back.r);
    try std.testing.expectEqual(@as(u8, 0), back.g);
    try std.testing.expectEqual(@as(u8, 0), back.b);

    // 灰阶：s = 0，v 由亮度决定
    const gray = colorpicker.rgbToHsv(types.Color.hex(0x808080, 255));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), gray.s, 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 0.502), gray.v, 0.02);

    // 色相绕一圈都能还原
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const h = @as(f32, @floatFromInt(i)) / 12.0;
        const c = colorpicker.hsvToRgb(.{ .h = h, .s = 0.8, .v = 0.9 });
        const round = colorpicker.rgbToHsv(c);
        try std.testing.expectApproxEqAbs(h, round.h, 0.02);
        try std.testing.expectApproxEqAbs(@as(f32, 0.8), round.s, 0.03);
    }
}

test "colorpicker: hex formatting and parsing" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("#3A7BD5", colorpicker.hexOf(types.Color.hex(0x3A7BD5, 255), buf[0..]));

    const c = colorpicker.parseHex("#3a7bd5") orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, 0x3A), c.r);
    try std.testing.expectEqual(@as(u8, 0x7B), c.g);
    try std.testing.expectEqual(@as(u8, 0xD5), c.b);

    // 三位简写 #f80 = #ff8800
    const short = colorpicker.parseHex("#f80") orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, 0xFF), short.r);
    try std.testing.expectEqual(@as(u8, 0x88), short.g);
    try std.testing.expectEqual(@as(u8, 0x00), short.b);

    // 非法输入一律 null（不猜）
    try std.testing.expect(colorpicker.parseHex("#12") == null);
    try std.testing.expect(colorpicker.parseHex("#gggggg") == null);
    try std.testing.expect(colorpicker.parseHex("") == null);
}

test "colorpicker: clicking the saturation square and the hue bar changes the value" {
    var ui = core.Context{};
    var value = types.Color.hex(0x808080, 255);
    var changed = frame(&ui, "cp", &value, .{});
    try std.testing.expect(!changed);

    // 方块右上角 = 全饱和 + 全亮；灰阶起步色相为 0 → 红
    const rect = ui.lastRect(core.Context.idOf("cp")).?;
    ui.input = .{ .mouse = .{ .x = rect.x + rect.w - 2, .y = rect.y + 2 }, .pressed = true, .down = true };
    changed = frame(&ui, "cp", &value, .{});
    try std.testing.expect(changed);
    try std.testing.expect(value.r > 200);
    try std.testing.expect(value.b < 60);

    // 色相条右端 → 色相接近 1（又回到红），中段应变成青/蓝系
    const hue_y = rect.y + @round(rect.w * 0.55) + 8 + 7;
    ui.input = .{ .mouse = .{ .x = rect.x + rect.w * 0.5, .y = hue_y }, .pressed = true, .down = true };
    changed = frame(&ui, "cp", &value, .{});
    try std.testing.expect(changed);
    // 0.5 色相 = 青（G/B 高、R 低）
    try std.testing.expect(value.r < 80);
    try std.testing.expect(value.g > 180);
    try std.testing.expect(!ui.overflowed);
}

test "colorpicker: presets write the picked color" {
    var ui = core.Context{};
    var value = types.Color.hex(0x000000, 255);
    const presets = [_]types.Color{
        types.Color.hex(0x2266FF, 255),
        types.Color.hex(0x22C55E, 255),
    };
    const opts = colorpicker.Opts{ .presets = presets[0..] };
    _ = frame(&ui, "cp2", &value, opts);
    const rect = ui.lastRect(core.Context.idOf("cp2")).?;
    const y = rect.y + rect.h - 10; // 预设行
    ui.input = .{ .mouse = .{ .x = rect.x + 24 + 10, .y = y }, .pressed = true, .down = true };
    const changed = frame(&ui, "cp2", &value, opts);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(u8, 0x22), value.r);
    try std.testing.expectEqual(@as(u8, 0xC5), value.g);
}

test "colorpicker: theme switcher applies the mode and reports system without switching" {
    theme.setMode(.light);
    defer theme.setMode(.light);

    var ui = core.Context{};
    var sel = colorpicker.Sel.light;

    ui.begin(400, 200);
    var row = ui.row(.{});
    _ = colorpicker.themeSwitcher(&ui, "ts", &sel, true);
    row.end();
    ui.paint();
    try std.testing.expectEqual(colorpicker.Sel.light, sel);
    try std.testing.expectEqual(theme.Mode.light, theme.mode);

    // 点「Dark」
    const dark_id = core.Context.idOf("ts") ^ (0x5E9 + 1);
    const dr = ui.lastRect(dark_id).?;
    const cx = dr.x + dr.w / 2;
    const cy = dr.y + dr.h / 2;
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .pressed = true, .down = true };
    ui.begin(400, 200);
    var row2 = ui.row(.{});
    _ = colorpicker.themeSwitcher(&ui, "ts", &sel, true);
    row2.end();
    ui.paint();
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 200);
    var row3 = ui.row(.{});
    const changed = colorpicker.themeSwitcher(&ui, "ts", &sel, true);
    row3.end();
    ui.paint();
    try std.testing.expect(changed);
    try std.testing.expectEqual(colorpicker.Sel.dark, sel);
    try std.testing.expectEqual(theme.Mode.dark, theme.mode);

    // 「跟随系统」只记录，不改主题
    sel = colorpicker.Sel.system;
    const before = theme.mode;
    ui.begin(400, 200);
    var row4 = ui.row(.{});
    _ = colorpicker.themeSwitcher(&ui, "ts", &sel, true);
    row4.end();
    ui.paint();
    try std.testing.expectEqual(before, theme.mode);

    // 一键切换（对位 cui_theme_toggle）
    const toggled = colorpicker.themeToggle();
    try std.testing.expect(toggled != before);
}

test "core: polyline, gradient and shadow only emit the documented command counts" {
    var ui = core.Context{};
    ui.begin(300, 300);
    const before = ui.node_count;
    const pts = [_]types.Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 } };

    ui.addPolyline(pts[0..], false, 2, types.Color.hex(0xFF0000, 255));
    try std.testing.expectEqual(before + 2, ui.overlay_count); // 2 段、不闭合
    ui.addPolyline(pts[0..], true, 1, types.Color.hex(0x00FF00, 255));
    try std.testing.expectEqual(before + 5, ui.overlay_count); // 3 段（含回首点）

    // 渐变：N 条色带 = N 个矩形节点；首末带圆角、中间直角
    const nodes_before = ui.node_count;
    ui.addGradientBox(.{ .x = 10, .y = 10, .w = 100, .h = 50 }, 6, types.Color.hex(0xFFFFFF, 255), types.Color.hex(0x000000, 255), 10);
    try std.testing.expectEqual(nodes_before + 10, ui.node_count);
    try std.testing.expectEqual(@as(f32, 6), ui.nodes[nodes_before].radius);
    try std.testing.expectEqual(@as(f32, 0), ui.nodes[nodes_before + 5].radius);

    // 阴影：layers 个矩形，**由外向内**（首个最大）
    const sh_before = ui.node_count;
    ui.addShadow(.{ .x = 40, .y = 40, .w = 60, .h = 30 }, 8, 12, 0, .{ .x = 0, .y = 4 }, types.Color.hex(0x000000, 120), 6);
    try std.testing.expectEqual(sh_before + 6, ui.node_count);
    try std.testing.expect(ui.nodes[sh_before].rect.w > ui.nodes[sh_before + 5].rect.w);
    try std.testing.expect(!ui.overflowed);

    // 退化输入不产指令
    const after = ui.node_count;
    ui.addGradientBox(.{ .x = 0, .y = 0, .w = 0, .h = 10 }, 0, types.Color.hex(0, 255), types.Color.hex(0, 255), 8);
    ui.addPolyline(pts[0..1], true, 1, types.Color.hex(0, 255));
    try std.testing.expectEqual(after, ui.node_count);
}
