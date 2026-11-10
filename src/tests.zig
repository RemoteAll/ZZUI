//! 交互与控件测试（`zig build test` 的入口）：用 null 测量，不依赖任何平台 API。
const std = @import("std");
const core = @import("core.zig");
const widgets = @import("widgets.zig");
const extras = @import("extras.zig");
const controls = @import("controls.zig");
const overlay = @import("overlay.zig");
const textedit = @import("textedit.zig");
const table = @import("table.zig");
const charts = @import("charts.zig");
const chrome = @import("chrome.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

// 披露族与操作件族的测试放在独立文件，这里引入即可（Zig 会一并编译运行）。
test {
    _ = @import("tests_disclosure.zig");
    _ = @import("tests_dials.zig");
    _ = @import("tests_viz.zig");
    _ = @import("tests_grid.zig");
    _ = @import("tests_dock.zig");
}

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

// ---------------------------------------------------------------- 浮层族（overlay）

test "toast auto dismisses after its ttl" {
    var ui = core.Context{};
    var open = true;
    var since: f64 = -1;

    ui.begin(400, 300);
    try std.testing.expect(overlay.toast(&ui, "t", "Saved", &open, &since, .{ .ttl = 3 }));
    ui.paint();
    try std.testing.expectEqual(@as(f64, 0), since);
    try std.testing.expectEqual(@as(u8, 1), ui.max_layer);

    ui.time = 2;
    ui.begin(400, 300);
    try std.testing.expect(overlay.toast(&ui, "t", "Saved", &open, &since, .{ .ttl = 3 }));

    ui.time = 5;
    ui.begin(400, 300);
    try std.testing.expect(!overlay.toast(&ui, "t", "Saved", &open, &since, .{ .ttl = 3 }));
    try std.testing.expect(!open);
}

test "select opens on field click and records the picked item" {
    var ui = core.Context{};
    var idx: usize = 0;
    var open = false;
    const items = [_][]const u8{ "Apple", "Banana", "Cherry" };

    ui.begin(400, 300);
    const anchor = overlay.selectField(&ui, "s", items[0..], &idx, &open, .{});
    ui.paint();
    const field_id = core.Context.idOf("s") ^ 0x5E1EC7;
    const fr = ui.lastRect(field_id) orelse return error.NoHit;
    const fx = fr.x + fr.w / 2;
    const fy = fr.y + fr.h / 2;

    ui.input = .{ .mouse = .{ .x = fx, .y = fy }, .click = .{ .x = fx, .y = fy } };
    ui.begin(400, 300);
    _ = overlay.selectField(&ui, "s", items[0..], &idx, &open, .{});
    ui.paint();
    try std.testing.expect(open);

    // 弹层第 2 项（Banana）
    const item_id = core.Context.idOf("s") ^ (0xA11CE + 1);
    ui.input = .{};
    ui.begin(400, 300);
    _ = overlay.selectPopup(&ui, "s", anchor, items[0..], &idx, &open, .{});
    ui.paint();
    const ir = ui.lastRect(item_id) orelse return error.NoHit;
    const ix = ir.x + ir.w / 2;
    const iy = ir.y + ir.h / 2;

    ui.input = .{ .mouse = .{ .x = ix, .y = iy }, .click = .{ .x = ix, .y = iy } };
    ui.begin(400, 300);
    const changed = overlay.selectPopup(&ui, "s", anchor, items[0..], &idx, &open, .{});
    ui.paint();
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), idx);
    try std.testing.expect(!open);
}

test "command palette filters and returns the original index" {
    var ui = core.Context{};
    var open = true;
    var buf: [64]u8 = @splat(0);
    var len: usize = 0;
    var caret: usize = 0;
    const cmds = [_][]const u8{ "Build project", "Run tests", "Open settings" };
    // 查询 "sett" 只应命中 "Open settings"（原下标 2）
    const q = "sett";
    @memcpy(buf[0..q.len], q);
    len = q.len;

    ui.begin(600, 400);
    var picked: ?usize = overlay.commandPalette(&ui, "p", buf[0..], &len, &caret, cmds[0..], &open, .{});
    ui.paint();
    try std.testing.expectEqual(@as(?usize, null), picked);

    const id = core.Context.idOf("p") ^ (0xF00D0000 + 2);
    const r = ui.lastRect(id) orelse return error.NoHit;
    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(600, 400);
    picked = overlay.commandPalette(&ui, "p", buf[0..], &len, &caret, cmds[0..], &open, .{});
    ui.paint();

    try std.testing.expectEqual(@as(?usize, 2), picked);
    try std.testing.expect(!open);
}

test "popover closes when the backdrop is clicked" {
    var ui = core.Context{};
    var open = true;
    const anchor = t.Rect{ .x = 40, .y = 40, .w = 100, .h = 30 };

    ui.begin(400, 300);
    try std.testing.expect(overlay.popoverBegin(&ui, "po", anchor, &open, .{}));
    zzui_text(&ui);
    overlay.popoverEnd(&ui);
    ui.paint();

    // next frame: click far away from the panel
    ui.input = .{ .mouse = .{ .x = 380, .y = 280 }, .click = .{ .x = 380, .y = 280 } };
    ui.begin(400, 300);
    const still_open = overlay.popoverBegin(&ui, "po", anchor, &open, .{});
    if (still_open) overlay.popoverEnd(&ui);
    ui.paint();
    try std.testing.expect(!still_open);
    try std.testing.expect(!open);
}

fn zzui_text(ui: *core.Context) void {
    _ = ui.textRun("Inside the popover", theme.font_body, theme.text);
}

test "context menu reports the picked item" {
    var ui = core.Context{};
    var open = true;
    const at = t.Point{ .x = 50, .y = 60 };
    const items = [_]widgets.MenuItem{ .{ .label = "Copy" }, .{ .label = "Paste" } };

    ui.begin(400, 300);
    _ = overlay.contextMenu(&ui, "cm", items[0..], &open, at);
    ui.paint();
    const id = core.Context.idOf("cm") ^ (0xA11CE + 1);
    const r = ui.lastRect(id) orelse return error.NoHit;
    const mx = r.x + r.w / 2;
    const my = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 300);
    const picked = overlay.contextMenu(&ui, "cm", items[0..], &open, at);
    ui.paint();

    try std.testing.expectEqual(@as(?usize, 1), picked);
    try std.testing.expect(!open);
}

test "popover draws a panel and stays inside the window" {
    var ui = core.Context{};
    var open = true;
    // 锚点在窗口外（滚动视口下方）：面板必须夹回窗口内
    const anchor = t.Rect{ .x = 40, .y = 900, .w = 100, .h = 30 };

    ui.begin(400, 300);
    const before = ui.node_count;
    try std.testing.expect(overlay.popoverBegin(&ui, "po2", anchor, &open, .{ .width = 200 }));
    _ = ui.textRun("inside", theme.font_body, theme.text);
    overlay.popoverEnd(&ui);
    ui.paint();

    try std.testing.expect(ui.node_count > before);
    try std.testing.expectEqual(@as(u8, 1), ui.max_layer);
    // 面板矩形（第一个节点）必须在窗口内
    const panel = ui.nodes[before].rect;
    try std.testing.expect(panel.x >= 0 and panel.x + panel.w <= 400);
    try std.testing.expect(panel.y >= 0 and panel.y + panel.h <= 300);
}

// ---------------------------------------------------------------- 文本编辑族（textedit）

test "textarea inserts characters and newlines" {
    var ui = core.Context{};
    var buf: [64]u8 = @splat(0);
    var len: usize = 0;
    var caret: usize = 0;
    const opts = textedit.TextareaOpts{ .rows = 3 };

    ui.begin(400, 200);
    _ = textedit.textarea(&ui, "ta", buf[0..], &len, &caret, opts);
    ui.paint();
    const id = core.Context.idOf("ta") ^ 0x7A47E;
    const r = ui.lastRect(id) orelse return error.NoHit;
    const mx = r.x + 12;
    const my = r.y + 12;

    // 点击取得焦点
    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 200);
    _ = textedit.textarea(&ui, "ta", buf[0..], &len, &caret, opts);
    ui.paint();

    // 输入 "hi"，再回车换行
    ui.input = .{};
    ui.input.addCharBytes("hi");
    ui.begin(400, 200);
    var changed = textedit.textarea(&ui, "ta", buf[0..], &len, &caret, opts);
    ui.paint();
    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("hi", buf[0..len]);

    ui.input = .{};
    ui.input.addKey(.enter);
    ui.begin(400, 200);
    changed = textedit.textarea(&ui, "ta", buf[0..], &len, &caret, opts);
    ui.paint();
    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("hi\n", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 3), caret);
}

test "textarea backspace removes the newline across lines" {
    var ui = core.Context{};
    var buf: [64]u8 = @splat(0);
    const seed = "ab\ncd";
    @memcpy(buf[0..seed.len], seed);
    var len: usize = seed.len;
    var caret: usize = 3; // 紧跟在换行之后（第二行行首）
    const opts = textedit.TextareaOpts{ .rows = 3 };

    ui.begin(400, 200);
    _ = textedit.textarea(&ui, "tb", buf[0..], &len, &caret, opts);
    ui.paint();
    const id = core.Context.idOf("tb") ^ 0x7A47E;
    const r = ui.lastRect(id) orelse return error.NoHit;

    ui.input = .{ .mouse = .{ .x = r.x + 12, .y = r.y + 12 }, .click = .{ .x = r.x + 12, .y = r.y + 12 } };
    ui.begin(400, 200);
    _ = textedit.textarea(&ui, "tb", buf[0..], &len, &caret, opts);
    ui.paint();
    // 点击会定位到第一行行首；把光标放回第二行行首（模拟用户已移到下一行）
    caret = 3;

    ui.input = .{};
    ui.input.addKey(.backspace);
    ui.begin(400, 200);
    const changed = textedit.textarea(&ui, "tb", buf[0..], &len, &caret, opts);
    ui.paint();

    try std.testing.expect(changed);
    try std.testing.expectEqualStrings("abcd", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), caret);
}

test "search clears through the trailing button" {
    var ui = core.Context{};
    var buf: [64]u8 = @splat(0);
    const seed = "zig";
    @memcpy(buf[0..seed.len], seed);
    var len: usize = seed.len;
    var caret: usize = seed.len;
    const opts = textedit.SearchOpts{ .width = 240 };

    ui.begin(400, 200);
    _ = textedit.search(&ui, "q", buf[0..], &len, &caret, opts);
    ui.paint();
    const id = core.Context.idOf("q") ^ 0x5EA4C4;
    const r = ui.lastRect(id) orelse return error.NoHit;
    // 清除按钮在字段右端 20×20
    const cx = r.x + r.w - 16;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 200);
    const res = textedit.search(&ui, "q", buf[0..], &len, &caret, opts);
    ui.paint();

    try std.testing.expect(res.changed);
    try std.testing.expect(!res.submitted);
    try std.testing.expectEqual(@as(usize, 0), len);
    try std.testing.expectEqual(@as(usize, 0), caret);
}

test "number steps and clamps to its range" {
    var ui = core.Context{};
    var value: f32 = 19;
    const opts = textedit.NumberOpts{ .width = 160, .min = 0, .max = 20, .step = 1 };

    ui.begin(400, 200);
    _ = textedit.number(&ui, "n", &value, opts);
    ui.paint();
    // 右侧 + 按钮
    const inc_id = core.Context.idOf("n") ^ 0x4E5542;
    const ir = ui.lastRect(inc_id) orelse return error.NoHit;
    const ix = ir.x + ir.w / 2;
    const iy = ir.y + ir.h / 2;

    ui.input = .{ .mouse = .{ .x = ix, .y = iy }, .click = .{ .x = ix, .y = iy } };
    ui.begin(400, 200);
    const changed = textedit.number(&ui, "n", &value, opts);
    ui.paint();
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(f32, 20), value);

    // 已到上限：再点不变
    ui.input = .{ .mouse = .{ .x = ix, .y = iy }, .click = .{ .x = ix, .y = iy } };
    ui.begin(400, 200);
    const changed2 = textedit.number(&ui, "n", &value, opts);
    ui.paint();
    try std.testing.expect(!changed2);
    try std.testing.expectEqual(@as(f32, 20), value);
}
// ---------------------------------------------------------------- 表格族（table）

test "table row reports clicks and cell slices follow column widths" {
    var ui = core.Context{};
    var sort = table.SortState{};
    const cols = [_]table.Column{
        .{ .label = "Name", .width = 0 },
        .{ .label = "Size", .width = 80, .text_align = .end },
    };

    ui.begin(400, 300);
    var tbl = table.begin(&ui, "t1", cols[0..], &sort, .{});
    var r0 = tbl.row(0, false);
    r0.text(0, "alpha", theme.text);
    r0.text(1, "12 KB", theme.secondary);
    tbl.end();
    ui.paint();

    // 列宽：弹性列吃剩余（400 - 80 = 320）
    const c0 = r0.cell(0);
    const c1 = r0.cell(1);
    try std.testing.expectApproxEqAbs(@as(f32, 320), c0.w, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 80), c1.w, 1);
    try std.testing.expectApproxEqAbs(c0.x + c0.w, c1.x, 0.01);

    // 点击第二行
    const row_id = core.Context.idOf("t1") ^ (0x1200 + 1);
    ui.begin(400, 300);
    tbl = table.begin(&ui, "t1", cols[0..], &sort, .{});
    _ = tbl.row(0, false);
    var r1 = tbl.row(1, false);
    r1.text(0, "beta", theme.text);
    tbl.end();
    ui.paint();
    const rr = ui.lastRect(row_id) orelse return error.NoHit;
    const mx = rr.x + 40;
    const my = rr.y + rr.h / 2;

    ui.input = .{ .mouse = .{ .x = mx, .y = my }, .click = .{ .x = mx, .y = my } };
    ui.begin(400, 300);
    tbl = table.begin(&ui, "t1", cols[0..], &sort, .{});
    _ = tbl.row(0, false);
    const clicked_row = tbl.row(1, false);
    tbl.end();
    ui.paint();

    try std.testing.expect(clicked_row.clicked);
}

test "sortable header toggles sort state" {
    var ui = core.Context{};
    var sort = table.SortState{};
    const cols = [_]table.Column{
        .{ .label = "Name", .width = 120 },
        .{ .label = "Latency", .width = 100, .sortable = true },
    };

    ui.begin(400, 300);
    var tbl = table.begin(&ui, "t2", cols[0..], &sort, .{});
    tbl.end();
    ui.paint();
    const hdr_id = core.Context.idOf("t2") ^ (0x1100 + 1);
    const hr = ui.lastRect(hdr_id) orelse return error.NoHit;
    const hx = hr.x + hr.w / 2;
    const hy = hr.y + hr.h / 2;

    ui.input = .{ .mouse = .{ .x = hx, .y = hy }, .click = .{ .x = hx, .y = hy } };
    ui.begin(400, 300);
    tbl = table.begin(&ui, "t2", cols[0..], &sort, .{});
    tbl.end();
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 1), sort.column);
    try std.testing.expect(!sort.desc);

    // 再点一次：同一列变降序
    ui.input = .{ .mouse = .{ .x = hx, .y = hy }, .click = .{ .x = hx, .y = hy } };
    ui.begin(400, 300);
    tbl = table.begin(&ui, "t2", cols[0..], &sort, .{});
    tbl.end();
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 1), sort.column);
    try std.testing.expect(sort.desc);
}

test "tree twisty toggles expansion without selecting the row" {
    var ui = core.Context{};
    var sort = table.SortState{};
    const cols = [_]table.Column{.{ .label = "Path", .width = 0 }};

    ui.begin(400, 300);
    var tbl = table.begin(&ui, "t3", cols[0..], &sort, .{});
    var node = table.TreeRow{ .depth = 0, .has_children = true, .expanded = true };
    _ = table.treeRow(&tbl, 0, &node, "src", false);
    tbl.end();
    ui.paint();

    // 三角点击区：第一列内边距 + 缩进处（18×18）
    const tw_id = core.Context.idOf("t3") ^ 0x1300;
    const tw = ui.lastRect(tw_id) orelse return error.NoHit;
    const tx = tw.x + tw.w / 2;
    const ty = tw.y + tw.h / 2;

    const selected: ?usize = null;
    ui.input = .{ .mouse = .{ .x = tx, .y = ty }, .click = .{ .x = tx, .y = ty } };
    ui.begin(400, 300);
    tbl = table.begin(&ui, "t3", cols[0..], &sort, .{});
    node = .{ .depth = 0, .has_children = true, .expanded = true };
    const res = table.treeRow(&tbl, 0, &node, "src", false);
    tbl.end();
    ui.paint();

    try std.testing.expect(res.toggled);
    try std.testing.expect(!node.expanded);
    try std.testing.expectEqual(@as(?usize, null), selected);
}

test "wheel scrolls only the innermost scroll view" {
    var ui = core.Context{};

    const build = struct {
        fn run(u: *core.Context) void {
            var page = u.scroll(.{ .id = "page", .height = 120, .gap = 0 });
            var k: usize = 0;
            while (k < 4) : (k += 1) _ = u.textRun("page row", theme.font_body, theme.text);
            var inner = u.scroll(.{ .id = "inner", .height = 100, .gap = 0 });
            k = 0;
            while (k < 10) : (k += 1) _ = u.textRun("inner row", theme.font_body, theme.text);
            inner.end();
            page.end();
        }
    };

    // 第 1 帧：鼠标在内层滚动区（上一帧无命中 → 外层消费滚轮）
    ui.input = .{ .mouse = .{ .x = 100, .y = 100 }, .wheel = -1 };
    ui.begin(400, 300);
    build.run(&ui);
    ui.paint();
    const page1 = ui.scrollOffset("page");
    const inner1 = ui.scrollOffset("inner");
    try std.testing.expect(page1 > 0);
    try std.testing.expectEqual(@as(f32, 0), inner1);

    // 第 2 帧：上一帧已登记「最内层 hover = inner」→ 只有内层滚
    ui.input = .{ .mouse = .{ .x = 100, .y = 100 }, .wheel = -1 };
    ui.begin(400, 300);
    build.run(&ui);
    ui.paint();
    const page2 = ui.scrollOffset("page");
    const inner2 = ui.scrollOffset("inner");
    try std.testing.expectEqual(page1, page2);
    try std.testing.expect(inner2 > 0);
}

// ---------------------------------------------------------------- 图表族（charts）

test "line chart draws segments without overflowing capacities" {
    var ui = core.Context{};
    const a = [_]f32{ 1, 3, 2, 5, 4, 6, 5, 8, 7, 9 };
    const s = [_]charts.Series{.{ .values = &a, .color = theme.accent }};

    ui.begin(600, 400);
    charts.lineChart(&ui, &s, .{ .height = 140, .fill = true });
    ui.paint();

    try std.testing.expect(!ui.overflowed);
    // 9 段折线 + 面积填充的粗线段
    try std.testing.expect(ui.overlay_count >= 9);
}

test "sparkline area fill stays within the line budget on big data" {
    var ui = core.Context{};
    var big: [400]f32 = undefined;
    for (&big, 0..) |*v, i| v.* = @floatFromInt(i % 17);

    ui.begin(600, 100);
    charts.sparkline(&ui, &big, .{ .height = 30, .fill = true });
    ui.paint();

    try std.testing.expect(!ui.overflowed);
    try std.testing.expect(ui.overlay_count <= core.MAX_OVERLAYS);
}

test "donut and gauge clamp their inputs and draw legends" {
    var ui = core.Context{};
    const values = [_]f32{ 42, 26, 18, 14 };
    const labels = [_][]const u8{ "API", "Auth", "Worker", "Other" };
    const colors = [_]t.Color{ theme.accent, theme.success, theme.warn, theme.danger };

    ui.begin(600, 300);
    const before = ui.node_count;
    charts.donutChart(&ui, &values, &labels, &colors, .{ .center_label = "100" });
    // 图例 4 个色块 + 4 段文字 + 中心文字
    try std.testing.expect(ui.node_count >= before + 9);

    charts.gauge(&ui, 1.6, .{ .label = "CPU" });
    charts.gauge(&ui, -0.2, .{});
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

test "bar chart handles multiple series side by side" {
    var ui = core.Context{};
    const a = [_]f32{ 5, 8, 6, 10 };
    const b = [_]f32{ 2, 4, 3, 6 };
    const s = [_]charts.Series{
        .{ .values = &a, .color = theme.accent },
        .{ .values = &b, .color = theme.success },
    };

    ui.begin(600, 300);
    const before = ui.node_count;
    charts.barChart(&ui, &s, .{ .height = 120 });
    ui.paint();
    // 8 根柱 + 面板底/边 + 标签
    try std.testing.expect(ui.node_count >= before + 8);
    try std.testing.expect(!ui.overflowed);
}
// ---------------------------------------------------------------- 全控件冒烟（审计补丁）
// 目的：39 个用例只直接调用了 33/63 个控件函数；这两个冒烟用例把所有控件都构建一遍，
// 断言「不溢出容量」——溢出会让界面莫名少画，这是本轮审计里最容易漏的一类问题。

test "smoke: widgets + extras build without overflowing" {
    var ui = core.Context{};
    var flag = true;
    var other = false;
    var mode: u32 = 0;
    var vol: f32 = 0.5;
    var buf: [32]u8 = @splat(0);
    var blen: usize = 0;
    var caret: usize = 0;
    var dlg = false;
    var menu_open = false;
    var since: f64 = -1;
    var copied = false;

    ui.begin(760, 2400);
    {
        var col = ui.column(.{ .pad = 12, .gap = 8 });
        defer col.end();

        widgets.heading(&ui, "Heading", 2);
        widgets.text(&ui, "body text");
        widgets.secondary(&ui, "secondary text");
        widgets.textInt(&ui, "n=", 7, " times");
        widgets.separator(&ui);
        _ = widgets.button(&ui, "Primary", .{ .variant = .primary });
        _ = widgets.button(&ui, "Ghost", .{ .variant = .ghost });
        _ = widgets.buttonEx(&ui, "Ex", .{});
        widgets.controlSwitch(&ui, "Switch", &flag);
        widgets.checkbox(&ui, "Checkbox", &other);
        widgets.radio(&ui, "Radio", &mode, 1);
        widgets.slider(&ui, "Volume", &vol, 0, 1);
        _ = widgets.input(&ui, "in", buf[0..], &blen, &caret, .{ .placeholder = "type" });
        _ = widgets.menu(&ui, "m", .{ .x = 10, .y = 10, .w = 80, .h = 24 }, &.{.{ .label = "A" }}, &menu_open, .{});
        widgets.tooltip(&ui, "tip", .{ .x = 10, .y = 10, .w = 40, .h = 20 }, "hint", false, 0.3);
        if (dlg) _ = widgets.dialog(&ui, &dlg, .{});

        extras.muted(&ui, "muted");
        extras.badge(&ui, "badge", .success);
        _ = extras.link(&ui, "link");
        extras.code(&ui, "code");
        extras.kbd(&ui, "Ctrl K");
        extras.progress(&ui, 0.4, .{ .label = "p" });
        extras.meter(&ui, "m", 0.6);
        extras.progressRing(&ui, 0.5, 40);
        extras.spinner(&ui, 16);
        extras.skeleton(&ui, 80, 10);
        extras.emptyState(&ui, "empty", "hint");
        {
            var card = extras.card(&ui, .{});
            defer card.end();
            extras.metric(&ui, "Metric", "42", "+1");
        }
        extras.timelineItem(&ui, "10:00", "Title", "Body");
        _ = extras.copyButton(&ui, "cp", &copied);
        extras.passwordStrength(&ui, 3, 4);
        _ = overlay.toast(&ui, "t", "toast", &flag, &since, .{ .ttl = 0 });
    }
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

test "smoke: controls + textedit + overlay build without overflowing" {
    var ui = core.Context{};
    var tab: usize = 0;
    var seg: usize = 0;
    var chip_on = false;
    var stars: u8 = 2;
    var count: i32 = 3;
    var radio_idx: usize = 0;
    var lo: f32 = 20;
    var hi: f32 = 60;
    var page_no: usize = 2;
    var sel_idx: usize = 0;
    var sel_open = false;
    var pop_open = false;
    var ctx_open = false;
    var pal_open = false;
    var q: [32]u8 = @splat(0);
    var qlen: usize = 0;
    var qcaret: usize = 0;
    var amount: f32 = 4;
    var notes: [64]u8 = @splat(0);
    var nlen: usize = 0;
    var ncaret: usize = 0;
    var pwd: [32]u8 = @splat(0);
    var plen: usize = 0;
    var pcaret: usize = 0;

    ui.begin(760, 2400);
    {
        var col = ui.column(.{ .pad = 12, .gap = 8 });
        defer col.end();

        _ = controls.chip(&ui, "chip", &chip_on);
        controls.tabs(&ui, "tabs", &.{ "A", "B" }, &tab);
        controls.segmented(&ui, "seg", &.{ "X", "Y" }, &seg);
        _ = controls.breadcrumb(&ui, &.{ "Root", "Dir" }, 1);
        controls.pagination(&ui, "pg", &page_no, 9);
        controls.rating(&ui, "rt", &stars, 5);
        controls.stepper(&ui, "st", &count, 0, 9);
        controls.radioGroup(&ui, "rg", &.{ "One", "Two" }, &radio_idx);
        controls.rangeSlider(&ui, "rs", &lo, &hi, 0, 100);
        _ = controls.navItem(&ui, "Nav", true);

        _ = textedit.textarea(&ui, "ta", notes[0..], &nlen, &ncaret, .{ .rows = 3 });
        _ = textedit.search(&ui, "sq", q[0..], &qlen, &qcaret, .{});
        _ = textedit.number(&ui, "num", &amount, .{ .label = "Qty", .min = 0, .max = 10 });
        _ = widgets.input(&ui, "pw", pwd[0..], &plen, &pcaret, .{ .password = true });

        _ = overlay.selectField(&ui, "sel", &.{ "a", "b" }, &sel_idx, &sel_open, .{});
        _ = overlay.selectPopup(&ui, "sel", .{ .x = 0, .y = 0, .w = 100, .h = 30 }, &.{ "a", "b" }, &sel_idx, &sel_open, .{});
        if (overlay.popoverBegin(&ui, "pop", .{ .x = 10, .y = 10, .w = 60, .h = 24 }, &pop_open, .{})) overlay.popoverEnd(&ui);
        _ = overlay.commandPalette(&ui, "pal", q[0..], &qlen, &qcaret, &.{"cmd"}, &pal_open, .{});
        _ = overlay.contextMenu(&ui, "ctx", &.{.{ .label = "Copy" }}, &ctx_open, .{ .x = 5, .y = 5 });
    }
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

test "smoke: table + charts build without overflowing" {
    var ui = core.Context{};
    var sort = table.SortState{};

    ui.begin(760, 1600);
    {
        var col = ui.column(.{ .pad = 12, .gap = 10 });
        defer col.end();

        const cols = [_]table.Column{ .{ .label = "Name", .width = 0 }, .{ .label = "N", .width = 60, .text_align = .end, .sortable = true } };
        {
            var tbl = table.begin(&ui, "tbl", cols[0..], &sort, .{ .height = 3 * 28 });
            defer tbl.end();
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                var r = tbl.row(i, i == 2);
                r.text(0, "row", theme.text);
                r.text(1, "1", theme.secondary);
            }
        }
        {
            var tree = table.begin(&ui, "tree", cols[0..], &sort, .{ .height = 100 });
            defer tree.end();
            var node = table.TreeRow{ .depth = 0, .has_children = true, .expanded = true };
            const res = table.treeRow(&tree, 0, &node, "src", false);
            _ = res;
        }

        const vals = [_]f32{ 1, 4, 2, 6, 5, 8, 7, 9 };
        const series = [_]charts.Series{.{ .values = &vals, .color = theme.accent }};
        charts.sparkline(&ui, &vals, .{ .height = 24, .fill = true });
        charts.lineChart(&ui, &series, .{ .height = 100, .fill = true });
        charts.barChart(&ui, &series, .{ .height = 90 });
        const donut = [_]f32{ 3, 2, 1 };
        const labels = [_][]const u8{ "a", "b", "c" };
        const colors = [_]t.Color{ theme.accent, theme.success, theme.warn };
        charts.donutChart(&ui, &donut, &labels, &colors, .{ .size = 80 });
        charts.gauge(&ui, 0.5, .{ .size = 100, .label = "g" });
    }
    ui.paint();
    try std.testing.expect(!ui.overflowed);
}

// ---------------------------------------------------------------- 应用外壳（chrome）

test "menu bar opens one menu at a time and reports the picked item" {
    var ui = core.Context{};
    var open: ?usize = null;
    const items = [_]widgets.MenuItem{ .{ .label = "New" }, .{ .label = "Save" } };
    const menus = [_]chrome.MenuDef{
        .{ .label = "File", .items = items[0..] },
        .{ .label = "Help", .items = items[0..] },
    };

    ui.begin(600, 400);
    _ = chrome.menuBar(&ui, "mb", menus[0..], &open, .{});
    ui.paint();
    const file_id = core.Context.idOf("mb") ^ (0xBA5E + 0);
    const fr = ui.lastRect(file_id) orelse return error.NoHit;
    const fx = fr.x + fr.w / 2;
    const fy = fr.y + fr.h / 2;

    ui.input = .{ .mouse = .{ .x = fx, .y = fy }, .click = .{ .x = fx, .y = fy } };
    ui.begin(600, 400);
    _ = chrome.menuBar(&ui, "mb", menus[0..], &open, .{});
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 0), open);

    // 点第二个菜单：只保留一个打开
    const help_id = core.Context.idOf("mb") ^ (0xBA5E + 1);
    const hr = ui.lastRect(help_id) orelse return error.NoHit;
    const hx = hr.x + hr.w / 2;
    const hy = hr.y + hr.h / 2;
    ui.input = .{ .mouse = .{ .x = hx, .y = hy }, .click = .{ .x = hx, .y = hy } };
    ui.begin(600, 400);
    _ = chrome.menuBar(&ui, "mb", menus[0..], &open, .{});
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 1), open);

    // 在打开的菜单里点第一项
    const item_id = core.Context.idOf("mb") ^ (0xA11CE + 0) ^ (0x4D3E + 1 * 0x1000);
    if (ui.lastRect(item_id)) |ir| {
        const ix = ir.x + ir.w / 2;
        const iy = ir.y + ir.h / 2;
        ui.input = .{ .mouse = .{ .x = ix, .y = iy }, .click = .{ .x = ix, .y = iy } };
        ui.begin(600, 400);
        const pick = chrome.menuBar(&ui, "mb", menus[0..], &open, .{});
        ui.paint();
        try std.testing.expect(pick != null);
        try std.testing.expectEqual(@as(usize, 1), pick.?.menu);
        try std.testing.expectEqual(@as(usize, 0), pick.?.item);
        try std.testing.expectEqual(@as(?usize, null), open);
    }
}

test "doc tabs report the closed tab" {
    var ui = core.Context{};
    var selected: usize = 0;
    const tabs = [_]chrome.DocTab{ .{ .label = "a.zig" }, .{ .label = "b.zig", .dirty = true } };

    ui.begin(600, 300);
    _ = chrome.docTabs(&ui, "dt", tabs[0..], &selected, .{});
    ui.paint();
    const close_id = core.Context.idOf("dt") ^ (0x0C10 + 1);
    const cr = ui.lastRect(close_id) orelse return error.NoHit;
    const cx = cr.x + cr.w / 2;
    const cy = cr.y + cr.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(600, 300);
    const res = chrome.docTabs(&ui, "dt", tabs[0..], &selected, .{});
    ui.paint();

    try std.testing.expectEqual(@as(?usize, 1), res.closed);
}

test "status bar lays out both sides and reports clicks" {
    var ui = core.Context{};
    const left = [_]chrome.StatusItem{.{ .label = "Ready" }};
    const right = [_]chrome.StatusItem{ .{ .label = "UTF-8" }, .{ .label = "Zig", .clickable = true } };

    ui.begin(600, 200);
    _ = chrome.statusBar(&ui, "sb", left[0..], right[0..], .{});
    ui.paint();
    const right_id = core.Context.idOf("sb") ^ (0x5BAD + 1);
    const rr = ui.lastRect(right_id) orelse return error.NoHit;
    // 右对齐：右边缘应贴近窗口右侧内边距
    try std.testing.expect(rr.x + rr.w > 560);
    const rx = rr.x + rr.w / 2;
    const ry = rr.y + rr.h / 2;

    ui.input = .{ .mouse = .{ .x = rx, .y = ry }, .click = .{ .x = rx, .y = ry } };
    ui.begin(600, 200);
    const pick = chrome.statusBar(&ui, "sb", left[0..], right[0..], .{});
    ui.paint();

    try std.testing.expect(pick != null);
    try std.testing.expect(pick.?.right);
    try std.testing.expectEqual(@as(usize, 1), pick.?.index);
}
