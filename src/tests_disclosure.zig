//! 披露族 + 操作件族的测试（由 `tests.zig` 引入，`zig build test` 一并运行）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const disclosure = @import("disclosure.zig");
const actions = @import("actions.zig");
const num = @import("num.zig");
const t = @import("types.zig");

// ---------------------------------------------------------------- 操作件族

// 点两次才确认：第一次进入待确认，第二次才返回 true。
test "confirm button needs two clicks" {
    var ui = core.Context{};
    var st = actions.ConfirmState{};
    const id = core.Context.idOf("Delete") ^ 0x3C6EF372;

    ui.begin(300, 200);
    _ = actions.confirmButton(&ui, "Delete", &st, .{ .confirm_label = "Sure?" });
    ui.paint();
    const r = ui.lastRect(id) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    // 第一次：进入待确认，尚未确认
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(300, 200);
    const first = actions.confirmButton(&ui, "Delete", &st, .{ .confirm_label = "Sure?" });
    ui.paint();
    try std.testing.expect(!first);
    try std.testing.expect(st.armed);

    // 第二次：确认
    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(300, 200);
    const second = actions.confirmButton(&ui, "Delete", &st, .{ .confirm_label = "Sure?" });
    ui.paint();
    try std.testing.expect(second);
    try std.testing.expect(!st.armed);
}

// 待确认超时自动复位（避免一直挂在危险态）。
test "confirm button disarms after its timeout" {
    var ui = core.Context{};
    var st = actions.ConfirmState{ .armed = true, .since = 0 };
    ui.time = 10;
    ui.begin(300, 200);
    _ = actions.confirmButton(&ui, "Delete", &st, .{ .timeout = 3 });
    ui.paint();
    try std.testing.expect(!st.armed);
}

// 横向拖拽取数：拖多少像素就改多少比例。
test "scrub drags the value across its range" {
    var ui = core.Context{};
    var v: f32 = 0;
    var st = actions.ScrubState{};
    const id = core.Context.idOf("Vol") ^ 0x51C0BBED;

    ui.begin(400, 200);
    var row = ui.row(.{});
    _ = actions.scrub(&ui, "Vol", &v, 0, 100, &st, .{ .travel = 100, .step = 1 });
    row.end();
    ui.paint();
    const r = ui.lastRect(id) orelse return error.NoHit;

    // 按下：记录起点
    ui.input = .{ .mouse = .{ .x = r.x + 5, .y = r.y + r.h / 2 }, .down = true, .pressed = true };
    ui.begin(400, 200);
    var row2 = ui.row(.{});
    _ = actions.scrub(&ui, "Vol", &v, 0, 100, &st, .{ .travel = 100, .step = 1 });
    row2.end();
    ui.paint();

    // 右移 50px（travel=100 → 半个范围）
    ui.input = .{ .mouse = .{ .x = r.x + 55, .y = r.y + r.h / 2 }, .down = true };
    ui.begin(400, 200);
    var row3 = ui.row(.{});
    const changed = actions.scrub(&ui, "Vol", &v, 0, 100, &st, .{ .travel = 100, .step = 1 });
    row3.end();
    ui.paint();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 50), v, 2);
}

// 快捷键录制：聚焦后按下组合键就记下来。
test "shortcut recorder captures modifiers and key" {
    var ui = core.Context{};
    var combo = actions.KeyCombo{};
    const id = core.Context.idOf("sc") ^ 0x5EA1C0DE;

    ui.begin(300, 200);
    _ = actions.shortcutRecorder(&ui, "sc", &combo, .{ .width = 200 });
    ui.paint();
    const r = ui.lastRect(id) orelse return error.NoHit;

    // 点击聚焦
    ui.input = .{ .mouse = .{ .x = r.x + 5, .y = r.y + 5 }, .click = .{ .x = r.x + 5, .y = r.y + 5 } };
    ui.begin(300, 200);
    _ = actions.shortcutRecorder(&ui, "sc", &combo, .{ .width = 200 });
    ui.paint();

    // 按 Ctrl+Shift+K
    ui.input = .{ .mouse = .{ .x = r.x + 5, .y = r.y + 5 } };
    ui.input.mods = .{ .ctrl = true, .shift = true };
    ui.input.addKey(.K);
    ui.begin(300, 200);
    const changed = actions.shortcutRecorder(&ui, "sc", &combo, .{ .width = 200 });
    ui.paint();

    try std.testing.expect(changed);
    try std.testing.expectEqual(t.Key.K, combo.key);
    try std.testing.expect(combo.mods.ctrl);
    try std.testing.expect(combo.mods.shift);
}

// 组合键展示文本与键名。
test "shortcut label formats modifiers in order" {
    var ui = core.Context{};
    ui.begin(200, 100);
    const label = actions.shortcutLabel(&ui, .{ .mods = .{ .ctrl = true, .shift = true }, .key = .K });
    try std.testing.expectEqualStrings("Ctrl+Shift+K", label);
    ui.paint();
    try std.testing.expectEqualStrings("F7", actions.keyName(.f7));
    try std.testing.expectEqualStrings("4", actions.keyName(.digit4));
    try std.testing.expectEqualStrings("Esc", actions.keyName(.escape));
}

// 金额格式化：千分位 + 小数位；解析回数值。
test "money formatting and lax parsing" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1,234,567.50", num.money(&buf, 1234567.5, 2));
    try std.testing.expectEqualStrings("999.00", num.money(&buf, 999, 2));
    try std.testing.expectEqualStrings("-1,000.00", num.money(&buf, -1000, 2));

    try std.testing.expectApproxEqAbs(@as(f32, 12.5), num.parseF32("12.5").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1234.0), num.parseF32("-1,234").?, 0.001);
    try std.testing.expect(num.parseF32("abc") == null);
}

// 就地编辑：点一下变输入框，Enter 提交。
test "inline edit switches to editing and commits on enter" {
    var ui = core.Context{};
    var buf: [32]u8 = @splat(0);
    @memcpy(buf[0..4], "text");
    var len: usize = 4;
    var st = actions.InlineEditState{};
    const id = core.Context.idOf("ie") ^ 0x1A2B3C4D;

    ui.begin(300, 200);
    _ = actions.inlineEdit(&ui, "ie", &buf, &len, &st, .{});
    ui.paint();
    const r = ui.lastRect(id) orelse return error.NoHit;

    // 点击进入编辑
    ui.input = .{ .mouse = .{ .x = r.x + 4, .y = r.y + 4 }, .click = .{ .x = r.x + 4, .y = r.y + 4 } };
    ui.begin(300, 200);
    const enter_res = actions.inlineEdit(&ui, "ie", &buf, &len, &st, .{});
    ui.paint();
    try std.testing.expect(enter_res.editing);
    try std.testing.expectEqual(@as(usize, 4), st.caret);

    // 输入字符 + Enter 提交
    ui.input = .{ .mouse = .{ .x = r.x + 4, .y = r.y + 4 } };
    ui.input.addCharBytes("!");
    ui.input.addKey(.enter);
    ui.begin(300, 200);
    const res = actions.inlineEdit(&ui, "ie", &buf, &len, &st, .{});
    ui.paint();
    try std.testing.expect(res.committed);
    try std.testing.expect(!st.editing);
    try std.testing.expectEqualStrings("text!", buf[0..len]);
}

// 反应条：点一下翻转并增减计数。
test "reactions toggle and count" {
    var ui = core.Context{};
    var items = [_]actions.Reaction{
        .{ .icon = "+1", .count = 2 },
        .{ .icon = "heart", .count = 0 },
    };

    ui.begin(400, 120);
    var row = ui.row(.{});
    _ = actions.reactions(&ui, "rx", items[0..]);
    row.end();
    ui.paint();

    const id1 = core.Context.idOf("rx") ^ (0x2EA87000 +% 1);
    const r = ui.lastRect(id1) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 120);
    var row2 = ui.row(.{});
    const picked = actions.reactions(&ui, "rx", items[0..]);
    row2.end();
    ui.paint();

    try std.testing.expectEqual(@as(?usize, 1), picked);
    try std.testing.expect(items[1].active);
    try std.testing.expectEqual(@as(u32, 1), items[1].count);
}

// ---------------------------------------------------------------- 披露族

// 横幅：关闭按钮把 open 写成 false。
test "banner dismisses through its close button" {
    var ui = core.Context{};
    var open = true;
    const msg = "Scheduled maintenance tonight at 22:00";

    ui.begin(480, 200);
    const r1 = disclosure.banner(&ui, "bn", msg, &open, .{});
    ui.paint();
    try std.testing.expect(!r1.dismissed);
    try std.testing.expect(open);

    const cid = core.Context.idOf("bn") ^ 0xD155155;
    const cr = ui.lastRect(cid) orelse return error.NoHit;
    const cx = cr.x + cr.w / 2;
    const cy = cr.y + cr.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(480, 200);
    const r2 = disclosure.banner(&ui, "bn", msg, &open, .{});
    ui.paint();
    try std.testing.expect(r2.dismissed);
    try std.testing.expect(!open);
}

// 倒计时：天数为 0 时不显示天数瓦片，总占用宽度随之变小。
test "countdown hides the day tile when there is none" {
    var ui = core.Context{};

    ui.begin(400, 200);
    var row = ui.row(.{ .gap = 6 });
    disclosure.countdown(&ui, "cd", 90061, .{});
    row.end();
    const with_days = ui.node_count;
    ui.paint();

    ui.begin(400, 200);
    var row2 = ui.row(.{ .gap = 6 });
    disclosure.countdown(&ui, "cd", 61, .{});
    row2.end();
    const without_days = ui.node_count;
    ui.paint();

    // 天数瓦片 = 1 个底框 + 2 段文本；少了它就少 3 个节点
    try std.testing.expect(with_days > without_days);
}

// 上手清单：点圆圈切换完成。
test "checklist toggles a step through its circle" {
    var ui = core.Context{};
    var steps = [_]disclosure.CheckStep{
        .{ .title = "Create a project", .action = "Start" },
        .{ .title = "Invite a teammate" },
    };

    ui.begin(420, 400);
    _ = disclosure.checklist(&ui, "cl", steps[0..], .{});
    ui.paint();
    try std.testing.expect(!steps[0].done);

    const sid = core.Context.idOf("Create a project") ^ 0x0C4EC ^ 0x11;
    const r = ui.lastRect(sid) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(420, 400);
    _ = disclosure.checklist(&ui, "cl", steps[0..], .{});
    ui.paint();
    try std.testing.expect(steps[0].done);
}

// 可展开文本：展开状态由调用方持有，点「Show more」切换。
test "expandable text toggles its state" {
    var ui = core.Context{};
    var st = disclosure.ExpandableTextState{};
    const body = "word word word word word word word word word word";

    ui.begin(320, 300);
    disclosure.expandableText(&ui, "et", body, &st, .{ .lines = 1 });
    ui.paint();
    try std.testing.expect(!st.expanded);

    // 「Show more」按钮高度固定 20，按这个特征找它的矩形
    const lw = ui.measureText("Show more", theme.font_small).w;
    var found: ?t.Rect = null;
    var i: usize = 0;
    while (i < ui.hits_curr_n) : (i += 1) {
        const h = ui.hits_curr[i];
        if (h.rect.w >= lw - 1 and h.rect.h == 20) found = h.rect;
    }
    const r = found orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(320, 300);
    disclosure.expandableText(&ui, "et", body, &st, .{ .lines = 1 });
    ui.paint();
    try std.testing.expect(st.expanded);
}

// 可展开卡片：点标题切换展开。
test "expandable card opens through its header" {
    var ui = core.Context{};
    var st = disclosure.ExpandableCardState{};
    const tid = core.Context.idOf("card") ^ 0xA331;

    ui.begin(400, 300);
    {
        const open = disclosure.expandableCardBegin(&ui, "card", "Advanced", &st, .{ .description = "More options" });
        try std.testing.expect(!open);
        disclosure.expandableCardEnd(&ui);
    }
    ui.paint();
    const r = ui.lastRect(tid) orelse return error.NoHit;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 300);
    {
        const open = disclosure.expandableCardBegin(&ui, "card", "Advanced", &st, .{ .description = "More options" });
        try std.testing.expect(open);
        disclosure.expandableCardEnd(&ui);
    }
    ui.paint();
    try std.testing.expect(st.open);
}

// 确认气泡：点确认按钮返回 confirmed 并关闭。
test "confirm popover reports confirmation" {
    var ui = core.Context{};
    var open = true;
    const anchor = t.Rect{ .x = 40, .y = 40, .w = 100, .h = 32 };

    ui.begin(600, 400);
    const r1 = disclosure.confirmPopover(&ui, "cp", anchor, &open, .{});
    ui.paint();
    try std.testing.expectEqual(disclosure.ConfirmPopoverResult.none, r1);

    const cid = core.Context.idOf("Confirm") ^ 0x9E3779B97F4A7C15 ^ 0xCF1;
    const cr = ui.lastRect(cid) orelse return error.NoHit;
    const cx = cr.x + cr.w / 2;
    const cy = cr.y + cr.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(600, 400);
    const r2 = disclosure.confirmPopover(&ui, "cp", anchor, &open, .{});
    ui.paint();
    try std.testing.expectEqual(disclosure.ConfirmPopoverResult.confirmed, r2);
    try std.testing.expect(!open);
}

// 悬停卡片：超过延时后才出现；移出后复位。
test "hover card appears only after the delay" {
    var ui = core.Context{};
    var st = disclosure.HoverCardState{};
    const anchor = t.Rect{ .x = 60, .y = 60, .w = 80, .h = 24 };

    ui.time = 0;
    ui.begin(500, 400);
    try std.testing.expect(!disclosure.hoverCardBegin(&ui, "hc", anchor, true, &st, .{ .delay = 0.35 }));
    ui.paint();

    ui.time = 0.2;
    ui.begin(500, 400);
    try std.testing.expect(!disclosure.hoverCardBegin(&ui, "hc", anchor, true, &st, .{ .delay = 0.35 }));
    ui.paint();

    ui.time = 1.0;
    ui.begin(500, 400);
    const shown = disclosure.hoverCardBegin(&ui, "hc", anchor, true, &st, .{ .delay = 0.35 });
    if (shown) {
        _ = ui.textRun("Details", theme.font_small, theme.accent_text);
        disclosure.hoverCardEnd(&ui);
    }
    ui.paint();
    try std.testing.expect(shown);

    // 移出后复位
    ui.begin(500, 400);
    try std.testing.expect(!disclosure.hoverCardBegin(&ui, "hc", anchor, false, &st, .{ .delay = 0.35 }));
    ui.paint();
    try std.testing.expect(st.start < 0);
}

// 冒烟：披露族 + 操作件族同页构建不溢出（节点/指令/线段/命中/文本池）。
test "smoke: disclosure + actions build without overflowing" {
    var ui = core.Context{};
    var banner_open = true;
    var steps = [_]disclosure.CheckStep{
        .{ .title = "Step one", .action = "Go" },
        .{ .title = "Step two", .done = true },
    };
    var et_state = disclosure.ExpandableTextState{};
    var card_state = disclosure.ExpandableCardState{};
    var ini_state = actions.InlineEditState{};
    var ini_buf: [32]u8 = @splat(0);
    @memcpy(ini_buf[0..5], "value");
    var ini_len: usize = 5;
    var conf_state = actions.ConfirmState{};
    var scrub_state = actions.ScrubState{};
    var scrub_value: f32 = 32;
    var combo = actions.KeyCombo{};
    var money_state = actions.MoneyState{};
    var money_value: f64 = 1999.5;
    var reaction_items = [_]actions.Reaction{
        .{ .icon = "+1", .count = 3, .active = true },
        .{ .icon = "heart", .count = 1 },
    };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(720, 900);
        var col = ui.column(.{ .pad = 16, .gap = 12 });
        defer col.end();

        _ = disclosure.banner(&ui, "b1", "Heads up: the workspace will be read only on Friday.", &banner_open, .{ .tone = .warn, .action = "Details" });
        var cdrow = ui.row(.{ .gap = 8 });
        disclosure.countdown(&ui, "cd", 90061, .{});
        cdrow.end();
        _ = disclosure.checklist(&ui, "cl", steps[0..], .{ .title = "Setup", .description = "Three quick steps" });
        disclosure.expandableText(&ui, "et", "Long body text that should wrap across several lines in the panel.", &et_state, .{ .lines = 2 });
        {
            _ = disclosure.expandableCardBegin(&ui, "ec", "Advanced", &card_state, .{ .description = "Extra options", .badge = "beta", .badge_tone = .accent });
            disclosure.expandableCardEnd(&ui);
        }
        _ = actions.confirmButton(&ui, "Delete project", &conf_state, .{ .confirm_label = "Sure?" });
        _ = actions.inlineEdit(&ui, "ie", &ini_buf, &ini_len, &ini_state, .{});
        _ = actions.scrub(&ui, "Volume", &scrub_value, 0, 100, &scrub_state, .{ .suffix = "%", .decimals = 0 });
        _ = actions.shortcutRecorder(&ui, "rec", &combo, .{ .width = 200 });
        _ = actions.moneyInput(&ui, "money", &money_value, &money_state, .{ .label = "Amount", .symbol = "$" });
        var rrow = ui.row(.{ .gap = 6 });
        _ = actions.reactions(&ui, "rx", reaction_items[0..]);
        rrow.end();
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}
