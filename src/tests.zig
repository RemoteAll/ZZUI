//! 交互与控件测试（`zig build test` 的入口）：用 null 测量，不依赖任何平台 API。
const std = @import("std");
const core = @import("core.zig");
const widgets = @import("widgets.zig");
const extras = @import("extras.zig");
const controls = @import("controls.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

test "checkbox toggles on click (last-frame hit test)" {
    var ui = core.Context{};
    var value = false;

    ui.begin(300, 200);
    widgets.checkbox(&ui, "auto", &value);
    ui.paint();

    // 第二帧：点击落在上一帧矩形内
    ui.input = .{ .mouse = .{ .x = 10, .y = 10 }, .click = .{ .x = 10, .y = 10 } };
    ui.begin(300, 200);
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

test "text wraps within the column width" {
    var ui = core.Context{};
    ui.begin(300, 400);
    var col = ui.column(.{ .pad = 10, .gap = 0 });
    const r = ui.textRun("The quick brown fox jumps over the lazy dog again and again", 14, theme.text);
    col.end();
    ui.paint();
    try std.testing.expect(r.h > 14);
    var i: usize = 0;
    var lines: usize = 0;
    while (i < ui.node_count) : (i += 1) {
        if (ui.nodes[i].kind == .text) {
            lines += 1;
            try std.testing.expect(ui.measureText(ui.nodes[i].text, 14).w <= 280.01);
        }
    }
    try std.testing.expect(lines >= 2);
}

test "input edits text and moves the caret" {
    var ui = core.Context{};
    var buf: [32]u8 = @splat(0);
    var len: usize = 0;
    var caret: usize = 0;

    ui.begin(300, 200);
    var c1 = ui.column(.{ .pad = 0, .gap = 0 });
    _ = widgets.input(&ui, "name", &buf, &len, &caret, .{});
    c1.end();
    ui.paint();

    ui.input = .{ .mouse = .{ .x = 20, .y = 10 }, .click = .{ .x = 20, .y = 10 } };
    ui.begin(300, 200);
    var c2 = ui.column(.{ .pad = 0, .gap = 0 });
    _ = widgets.input(&ui, "name", &buf, &len, &caret, .{});
    c2.end();
    ui.paint();

    ui.input = .{};
    ui.input.addCharBytes("ab");
    ui.begin(300, 200);
    var c3 = ui.column(.{ .pad = 0, .gap = 0 });
    _ = widgets.input(&ui, "name", &buf, &len, &caret, .{});
    c3.end();
    ui.paint();
    try std.testing.expectEqualStrings("ab", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), caret);

    ui.input = .{};
    ui.input.addKey(.backspace);
    ui.begin(300, 200);
    var c4 = ui.column(.{ .pad = 0, .gap = 0 });
    _ = widgets.input(&ui, "name", &buf, &len, &caret, .{});
    c4.end();
    ui.paint();
    try std.testing.expectEqualStrings("a", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), caret);

    ui.input = .{};
    ui.input.addKey(.left);
    ui.begin(300, 200);
    var c5 = ui.column(.{ .pad = 0, .gap = 0 });
    _ = widgets.input(&ui, "name", &buf, &len, &caret, .{});
    c5.end();
    ui.paint();
    try std.testing.expectEqual(@as(usize, 0), caret);

    ui.input = .{};
    ui.input.addKey(.end);
    ui.input.addCharBytes("你");
    ui.begin(300, 200);
    var c6 = ui.column(.{ .pad = 0, .gap = 0 });
    _ = widgets.input(&ui, "name", &buf, &len, &caret, .{});
    c6.end();
    ui.paint();
    try std.testing.expectEqualStrings("a你", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 4), caret);
}

test "dialog blocks page clicks and closes on backdrop" {
    var ui = core.Context{};
    var page: u32 = 0;
    var open = true;

    ui.begin(400, 300);
    if (widgets.button(&ui, "page", .{ .width = 360 })) page += 1;
    _ = widgets.dialog(&ui, &open, .{ .title = "T", .message = "M" });
    ui.paint();

    ui.input = .{ .mouse = .{ .x = 100, .y = 20 }, .click = .{ .x = 100, .y = 20 } };
    ui.begin(400, 300);
    if (widgets.button(&ui, "page", .{ .width = 360 })) page += 1;
    _ = widgets.dialog(&ui, &open, .{ .title = "T", .message = "M" });
    ui.paint();

    try std.testing.expectEqual(@as(u32, 0), page);
    try std.testing.expect(!open);
}

test "dialog OK button returns ok" {
    var ui = core.Context{};
    var open = true;

    ui.begin(400, 300);
    _ = widgets.dialog(&ui, &open, .{ .title = "T", .message = "M" });
    ui.paint();

    // OK 居中按钮中心：x=296, y=201（400x300 窗口，320x176 卡片）
    ui.input = .{ .mouse = .{ .x = 296, .y = 201 }, .click = .{ .x = 296, .y = 201 } };
    ui.begin(400, 300);
    const r = widgets.dialog(&ui, &open, .{ .title = "T", .message = "M" });
    ui.paint();

    try std.testing.expectEqual(widgets.DialogResult.ok, r);
    try std.testing.expect(!open);
}

test "escape closes the dialog" {
    var ui = core.Context{};
    var open = true;

    ui.begin(400, 300);
    _ = widgets.dialog(&ui, &open, .{ .title = "T", .message = "M" });
    ui.paint();

    ui.input = .{};
    ui.input.addKey(.escape);
    ui.begin(400, 300);
    const r = widgets.dialog(&ui, &open, .{ .title = "T", .message = "M" });
    ui.paint();

    try std.testing.expectEqual(widgets.DialogResult.cancel, r);
    try std.testing.expect(!open);
}

test "scroll clips children to the viewport" {
    var ui = core.Context{};
    ui.begin(300, 400);
    var sc = ui.scroll(.{ .id = "s", .height = 100 });
    const r = ui.reserve(100, 20, false);
    ui.addText(r, "x", 14, theme.text);
    sc.end();
    ui.paint();

    var found = false;
    var i: usize = 0;
    while (i < ui.node_count) : (i += 1) {
        if (ui.nodes[i].kind == .text) {
            const cl = ui.nodes[i].clip orelse return error.MissingClip;
            try std.testing.expectApproxEqAbs(@as(f32, 300), cl.w, 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 100), cl.h, 0.01);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "scroll clamps offset to content height" {
    var ui = core.Context{};
    const id = core.Context.idOf("list");
    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        if (frame == 1) {
            ui.input = .{ .mouse = .{ .x = 50, .y = 50 }, .wheel = -50 };
        } else {
            ui.input = .{};
        }
        ui.begin(300, 400);
        var sc = ui.scroll(.{ .id = "list", .height = 100, .gap = 4 });
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            _ = ui.reserve(100, 20, false);
        }
        sc.end();
        ui.paint();
    }

    var off: f32 = -1;
    var i: usize = 0;
    while (i < ui.scroll_n) : (i += 1) {
        if (ui.scrolls[i].id == id) off = ui.scrolls[i].offset;
    }
    // 内容高 = 20*20 + 19*4 = 476；max offset = 476 - 100 = 376
    try std.testing.expectApproxEqAbs(@as(f32, 376), off, 0.01);
}
test "menu selects an item and closes" {
    var ui = core.Context{};
    var open = true;
    const anchor = t.Rect{ .x = 10, .y = 10, .w = 100, .h = 30 };
    const items = [_]widgets.MenuItem{ .{ .label = "A" }, .{ .label = "B" } };

    ui.begin(400, 300);
    _ = widgets.menu(&ui, "m", anchor, &items, &open, .{});
    ui.paint();

    // 首项中心 ≈ (16..184, 52..82)
    ui.input = .{ .mouse = .{ .x = 60, .y = 67 }, .click = .{ .x = 60, .y = 67 } };
    ui.begin(400, 300);
    const sel = widgets.menu(&ui, "m", anchor, &items, &open, .{});
    ui.paint();

    try std.testing.expectEqual(@as(?usize, 0), sel);
    try std.testing.expect(!open);
}

test "tooltip appears after the hover delay and adds no hit" {
    var ui = core.Context{};
    const anchor = t.Rect{ .x = 20, .y = 20, .w = 60, .h = 20 };

    ui.input = .{ .mouse = .{ .x = 30, .y = 30 } };
    ui.begin(300, 200);
    widgets.tooltip(&ui, "tip", anchor, "Hello", true, 0.35);
    ui.paint();
    try std.testing.expectEqual(@as(u8, 0), ui.max_layer);

    ui.time = 0.4;
    ui.input = .{ .mouse = .{ .x = 30, .y = 30 } };
    ui.begin(300, 200);
    widgets.tooltip(&ui, "tip", anchor, "Hello", true, 0.35);
    ui.paint();
    try std.testing.expectEqual(@as(u8, 1), ui.max_layer);

    ui.input = .{};
    ui.begin(300, 200);
    widgets.tooltip(&ui, "tip", anchor, "Hello", false, 0.35);
    ui.paint();
    try std.testing.expectEqual(@as(u8, 0), ui.max_layer);
}

// ---------------------------------------------------------------- 控件族（extras / controls）

test "tabs switches to the clicked tab" {
    var ui = core.Context{};
    var active: usize = 0;
    const labels = [_][]const u8{ "A", "B", "C" };

    ui.begin(400, 200);
    controls.tabs(&ui, "t", labels[0..], &active);
    ui.paint();
    const id = core.Context.idOf("t") ^ (0x7AB5 + 1);
    const r = ui.lastRect(id) orelse return error.NoHit;

    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;
    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 200);
    controls.tabs(&ui, "t", labels[0..], &active);
    ui.paint();

    try std.testing.expectEqual(@as(usize, 1), active);
}

test "rating picks the star under the cursor" {
    var ui = core.Context{};
    var stars: u8 = 0;

    ui.begin(400, 200);
    controls.rating(&ui, "r", &stars, 5);
    ui.paint();
    const id = core.Context.idOf("r") ^ (0x5A7 + 4);
    const r = ui.lastRect(id) orelse return error.NoHit;

    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;
    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 200);
    controls.rating(&ui, "r", &stars, 5);
    ui.paint();

    try std.testing.expectEqual(@as(u8, 5), stars);
}

test "stepper increments and clamps" {
    var ui = core.Context{};
    var value: i32 = 98;
    const inc_id = core.Context.idOf("+") ^ 0x9E3779B97F4A7C15 ^ (core.Context.idOf("s") ^ 0xE12);
    const dec_id = core.Context.idOf("-") ^ 0x9E3779B97F4A7C15 ^ (core.Context.idOf("s") ^ 0xE11);

    ui.begin(400, 200);
    controls.stepper(&ui, "s", &value, 0, 99);
    ui.paint();
    const r = ui.lastRect(inc_id) orelse return error.NoHit;
    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 200);
    controls.stepper(&ui, "s", &value, 0, 99);
    ui.paint();
    try std.testing.expectEqual(@as(i32, 99), value);

    // 已到上限：再点一次不变
    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 200);
    controls.stepper(&ui, "s", &value, 0, 99);
    ui.paint();
    try std.testing.expectEqual(@as(i32, 99), value);
    _ = dec_id;
}

test "chip toggles its own state" {
    var ui = core.Context{};
    var on = false;
    const id = core.Context.idOf("alpha") ^ 0xC41F;

    ui.begin(400, 200);
    _ = controls.chip(&ui, "alpha", &on);
    ui.paint();
    const r = ui.lastRect(id) orelse return error.NoHit;
    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 200);
    _ = controls.chip(&ui, "alpha", &on);
    ui.paint();

    try std.testing.expect(on);
}

test "breadcrumb reports the clicked ancestor" {
    var ui = core.Context{};
    const items = [_][]const u8{ "Home", "Projects", "ZZUI" };
    var clicked: ?usize = null;

    ui.begin(400, 200);
    _ = controls.breadcrumb(&ui, items[0..], 2);
    ui.paint();
    const id = core.Context.idOf("Home") ^ 0xB4EA;
    const r = ui.lastRect(id) orelse return error.NoHit;
    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 200);
    clicked = controls.breadcrumb(&ui, items[0..], 2);
    ui.paint();

    try std.testing.expectEqual(@as(?usize, 0), clicked);
}

test "range slider drags the low thumb" {
    var ui = core.Context{};
    var lo: f32 = 20;
    var hi: f32 = 70;

    ui.begin(300, 100);
    controls.rangeSlider(&ui, "rg", &lo, &hi, 0, 100);
    ui.paint();

    // 轨道从 x=0 起、宽 300：20% 处按下
    ui.input = .{ .mouse = .{ .x = 60, .y = 13 }, .down = true, .pressed = true };
    ui.begin(300, 100);
    controls.rangeSlider(&ui, "rg", &lo, &hi, 0, 100);
    ui.paint();

    ui.input = .{ .mouse = .{ .x = 150, .y = 13 }, .down = true };
    ui.begin(300, 100);
    controls.rangeSlider(&ui, "rg", &lo, &hi, 0, 100);
    ui.paint();

    try std.testing.expectApproxEqAbs(@as(f32, 50), lo, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 70), hi, 0.01);
}

test "progress fills the bar proportionally" {
    var ui = core.Context{};
    ui.begin(300, 100);
    extras.progress(&ui, 0.5, .{ .height = 8 });
    ui.paint();

    try std.testing.expectEqual(@as(usize, 2), ui.cmd_count);
    const fill = ui.cmds[1].rect.rect;
    try std.testing.expectApproxEqAbs(@as(f32, 150), fill.w, 1);
}

test "badge tone controls foreground color" {
    const ok = extras.toneColors(.success);
    const bad = extras.toneColors(.danger);
    try std.testing.expect(ok.fg.g > ok.fg.r);
    try std.testing.expect(bad.fg.r > bad.fg.g);
}
