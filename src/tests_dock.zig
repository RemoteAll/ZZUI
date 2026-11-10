//! 程序坞与面板停靠的测试（由 `tests.zig` 引入）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const dock = @import("dock.zig");
const dockspace = @import("dockspace.zig");
const t = @import("types.zig");

// ---------------------------------------------------------------- 程序坞

// 程序坞：点第 2 个图标返回 true，并把 at 归零后重新计数。
test "dock reports the clicked icon" {
    var ui = core.Context{};
    var st = dock.DockState{};

    ui.begin(480, 200);
    dock.dockBegin(&ui, "dk", &st, .{ .size = 40 });
    _ = dock.dockItem(&ui, "dk", "A", "App A", .{});
    _ = dock.dockItem(&ui, "dk", "B", "App B", .{ .running = true, .badge = 3 });
    _ = dock.dockItem(&ui, "dk", "C", "App C", .{});
    dock.dockEnd(&ui);
    ui.paint();

    const bid = core.Context.idOf("dk") ^ (0xD0C0 + 1);
    const br = ui.lastRect(bid) orelse return error.NoHit;
    const cx = br.x + br.w / 2;
    const cy = br.y + br.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(480, 200);
    dock.dockBegin(&ui, "dk", &st, .{ .size = 40 });
    _ = dock.dockItem(&ui, "dk", "A", "App A", .{});
    const clicked_b = dock.dockItem(&ui, "dk", "B", "App B", .{ .running = true, .badge = 3 });
    _ = dock.dockItem(&ui, "dk", "C", "App C", .{});
    dock.dockEnd(&ui);
    ui.paint();
    try std.testing.expect(clicked_b);
    try std.testing.expect(!ui.overflowed);
}

// 程序坞：分隔符把后续图标推后。
test "dock separator shifts the following icons" {
    var ui = core.Context{};
    var st = dock.DockState{};

    ui.begin(480, 200);
    dock.dockBegin(&ui, "dk2", &st, .{ .size = 32, .gap = 6 });
    _ = dock.dockItem(&ui, "dk2", "A", "A", .{});
    const first_id = core.Context.idOf("dk2") ^ 0xD0C0;
    dock.dockSeparator(&ui);
    _ = dock.dockItem(&ui, "dk2", "B", "B", .{});
    dock.dockEnd(&ui);
    ui.paint();

    const a = ui.lastRect(first_id) orelse return error.NoHit;
    const bid = core.Context.idOf("dk2") ^ (0xD0C0 + 1);
    const b = ui.lastRect(bid) orelse return error.NoHit;
    // 中间有 12px 分隔符
    try std.testing.expect(b.x - (a.x + a.w) >= 12);
}

// ---------------------------------------------------------------- 面板停靠

const three_titles = [_][]const u8{ "Scene", "Viewport", "Console" };

fn buildSpace(ui: *core.Context, st: *dockspace.DockspaceState, opens: *[3]bool) void {
    dockspace.begin(ui, "ds", st, .{ .height = 400 });
    if (dockspace.panelBegin(ui, st, three_titles[0], &opens[0])) {
        _ = ui.textRun("scene tree", theme.font_body, theme.text);
        dockspace.panelEnd(ui);
    }
    if (dockspace.panelBegin(ui, st, three_titles[1], &opens[1])) {
        _ = ui.textRun("viewport", theme.font_body, theme.text);
        dockspace.panelEnd(ui);
    }
    if (dockspace.panelBegin(ui, st, three_titles[2], &opens[2])) {
        _ = ui.textRun("console output", theme.font_body, theme.text);
        dockspace.panelEnd(ui);
    }
    dockspace.end(ui);
}

// 停靠区：默认布局把三个面板分到不同叶子，只有一个叶子选中项能拿到内容区。
test "dockspace lays out three panels into leaves" {
    var ui = core.Context{};
    var st = dockspace.DockspaceState{};
    var opens = [_]bool{ true, true, true };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(700, 600);
        buildSpace(&ui, &st, &opens);
        ui.paint();
    }
    try std.testing.expect(st.root >= 0);
    try std.testing.expect(st.n_panels == 3);
    // 三个面板分别落在叶子
    try std.testing.expect(st.panels[0].leaf >= 0);
    try std.testing.expect(st.panels[1].leaf >= 0);
    try std.testing.expect(st.panels[2].leaf >= 0);
    try std.testing.expect(!ui.overflowed);
}

// 停靠区：关闭面板写回 open=false；再打开时仍能拿到内容区。
test "dockspace closes a panel through its tab" {
    var ui = core.Context{};
    var st = dockspace.DockspaceState{};
    var opens = [_]bool{ true, true, true };

    var frame: usize = 0;
    while (frame < 3) : (frame += 1) {
        ui.begin(700, 600);
        buildSpace(&ui, &st, &opens);
        ui.paint();
    }
    try std.testing.expect(opens[0]);

    // 点第一个叶子的关闭 ×
    const xid = core.Context.idOf("ds") ^ (0xC105);
    const xr = ui.lastRect(xid) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = xr.x + xr.w / 2, .y = xr.y + xr.h / 2 }, .click = .{ .x = xr.x + xr.w / 2, .y = xr.y + xr.h / 2 } };
    ui.begin(700, 600);
    buildSpace(&ui, &st, &opens);
    ui.paint();
    try std.testing.expect(!opens[0]);
    try std.testing.expect(!st.panels[0].open);

    // 重开
    opens[0] = true;
    ui.input = .{};
    ui.begin(700, 600);
    buildSpace(&ui, &st, &opens);
    ui.paint();
    try std.testing.expect(st.panels[0].open);
}

// 停靠区：分隔条拖拽改变 ratio。
test "dockspace drags a split bar" {
    var ui = core.Context{};
    var st = dockspace.DockspaceState{};
    var opens = [_]bool{ true, true, true };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(700, 600);
        buildSpace(&ui, &st, &opens);
        ui.paint();
    }
    const root = st.root;
    const r0 = st.nodes[@intCast(root)].ratio;

    // 根是 h 分割，bar 在 x = rect.x + w*ratio
    const bar_id = core.Context.idOf("ds") ^ (0x5B117 +% @as(u64, @intCast(root)));
    const br = ui.lastRect(bar_id) orelse return error.NoHit;
    const bx = br.x + br.w / 2;
    const by = br.y + 40;

    ui.input = .{ .mouse = .{ .x = bx, .y = by }, .down = true, .pressed = true };
    ui.begin(700, 600);
    buildSpace(&ui, &st, &opens);
    ui.paint();
    try std.testing.expectEqual(root, st.drag_split);

    ui.input = .{ .mouse = .{ .x = bx + 60, .y = by }, .down = true };
    ui.begin(700, 600);
    buildSpace(&ui, &st, &opens);
    ui.paint();
    try std.testing.expect(st.nodes[@intCast(root)].ratio > r0);
}

// 停靠区：保存后能原样加载回来。
test "dockspace saves and loads its layout" {
    var ui = core.Context{};
    var st = dockspace.DockspaceState{};
    var opens = [_]bool{ true, true, true };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(700, 600);
        buildSpace(&ui, &st, &opens);
        ui.paint();
    }

    var buf: [256]u8 = @splat(0);
    const n = dockspace.save(&st, &buf);
    try std.testing.expect(n > 0);
    // 例如 h0.240([*Scene],v0.680([*Viewport],[*Console]))
    try std.testing.expect(buf[0] == 'h');
    try std.testing.expect(std.mem.indexOfScalar(u8, buf[0..n], '[') != null);

    // 改一下 ratio 再加载回来
    const root = st.root;
    st.nodes[@intCast(root)].ratio = 0.5;
    const ok = dockspace.load(&st, buf[0..n]);
    try std.testing.expect(ok);
    try std.testing.expectApproxEqAbs(@as(f32, 0.24), st.nodes[@intCast(st.root)].ratio, 0.01);
}

// 停靠区：格式错误不改动现有布局。
test "dockspace rejects malformed layout text" {
    var ui = core.Context{};
    var st = dockspace.DockspaceState{};
    var opens = [_]bool{ true, true, true };
    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(700, 600);
        buildSpace(&ui, &st, &opens);
        ui.paint();
    }
    const root_before = st.root;
    const n_before = st.n_nodes;
    try std.testing.expect(!dockspace.load(&st, "h0.5([A],"));
    try std.testing.expectEqual(root_before, st.root);
    try std.testing.expectEqual(n_before, st.n_nodes);
}

// 冒烟：程序坞 + 停靠区同页不溢出。
test "smoke: dock + dockspace build without overflowing" {
    var ui = core.Context{};
    var dst = dock.DockState{};
    var sp = dockspace.DockspaceState{};
    var opens = [_]bool{ true, true, true };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(800, 900);
        var col = ui.column(.{ .pad = 12, .gap = 12 });
        defer col.end();
        buildSpace(&ui, &sp, &opens);
        dock.dockBegin(&ui, "dks", &dst, .{ .size = 36 });
        _ = dock.dockItem(&ui, "dks", "A", "Editor", .{ .running = true });
        _ = dock.dockItem(&ui, "dks", "B", "Browser", .{});
        dock.dockSeparator(&ui);
        _ = dock.dockItem(&ui, "dks", "C", "Trash", .{ .badge = 2 });
        dock.dockEnd(&ui);
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}
