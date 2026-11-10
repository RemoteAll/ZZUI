//! 数据网格 / 树表 / 面包屑 / 筛选条的测试（由 `tests.zig` 引入）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const grid = @import("grid.zig");
const t = @import("types.zig");

const cols3 = [_]grid.GridColumn{
    .{ .title = "Name", .width = 120, .sortable = true },
    .{ .title = "Size", .width = 80, .text_align = .end },
    .{ .title = "Kind", .width = 0 },
};

// 数据网格：Ctrl+点击切换多选，普通点击单选。
test "data grid selects rows with click and ctrl click" {
    var ui = core.Context{};
    var sel = [_]bool{ false, false, false };
    var st = grid.GridState{};
    const texts = [_][]const u8{ "alpha", "beta", "gamma" };

    ui.begin(480, 400);
    if (grid.dataGridBegin(&ui, "g1", cols3[0..], 3, sel[0..], &st, .{ .checkboxes = true })) {
        for (texts, 0..) |s, i| {
            if (grid.dataGridRow(&ui, i)) |row| row.text(0, s, theme.text);
        }
        grid.dataGridEnd(&ui);
    }
    ui.paint();

    // 点第 2 行
    const rid = core.Context.idOf("g1") ^ 0x1200;
    const r0 = ui.lastRect(rid) orelse return error.NoHit;
    const cy0 = r0.y + r0.h / 2;
    ui.input = .{ .mouse = .{ .x = r0.x + 200, .y = cy0 }, .click = .{ .x = r0.x + 200, .y = cy0 } };
    ui.begin(480, 400);
    if (grid.dataGridBegin(&ui, "g1", cols3[0..], 3, sel[0..], &st, .{ .checkboxes = true })) {
        for (texts, 0..) |s, i| {
            if (grid.dataGridRow(&ui, i)) |row| row.text(0, s, theme.text);
        }
        grid.dataGridEnd(&ui);
    }
    ui.paint();
    try std.testing.expect(sel[0]);
    try std.testing.expect(!sel[1]);

    // Ctrl+点第 2 行 → 第 1 行仍选中
    const rid1 = core.Context.idOf("g1") ^ (0x1200 + 1);
    const r1 = ui.lastRect(rid1) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r1.x + 200, .y = r1.y + r1.h / 2 }, .click = .{ .x = r1.x + 200, .y = r1.y + r1.h / 2 } };
    ui.input.mods = .{ .ctrl = true };
    ui.begin(480, 400);
    if (grid.dataGridBegin(&ui, "g1", cols3[0..], 3, sel[0..], &st, .{ .checkboxes = true })) {
        for (texts, 0..) |s, i| {
            if (grid.dataGridRow(&ui, i)) |row| row.text(0, s, theme.text);
        }
        grid.dataGridEnd(&ui);
    }
    ui.paint();
    try std.testing.expect(sel[0]);
    try std.testing.expect(sel[1]);
}

// Shift+点击选中区间。
test "data grid shift click selects a range" {
    var ui = core.Context{};
    var sel = [_]bool{ false, false, false, false };
    var st = grid.GridState{};

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(480, 400);
        if (grid.dataGridBegin(&ui, "g2", cols3[0..], 4, sel[0..], &st, .{})) {
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                if (grid.dataGridRow(&ui, i)) |row| row.text(0, "x", theme.text);
            }
            grid.dataGridEnd(&ui);
        }
        ui.paint();
        if (frame == 0) {
            // 先单选第 0 行建立 anchor
            const rid = core.Context.idOf("g2") ^ 0x1200;
            const r0 = ui.lastRect(rid) orelse return error.NoHit;
            ui.input = .{ .mouse = .{ .x = r0.x + 200, .y = r0.y + r0.h / 2 }, .click = .{ .x = r0.x + 200, .y = r0.y + r0.h / 2 } };
        }
    }

    // 现在 anchor=0，Shift+点第 2 行
    const rid2 = core.Context.idOf("g2") ^ (0x1200 + 2);
    const r2 = ui.lastRect(rid2) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r2.x + 200, .y = r2.y + r2.h / 2 }, .click = .{ .x = r2.x + 200, .y = r2.y + r2.h / 2 } };
    ui.input.mods = .{ .shift = true };
    ui.begin(480, 400);
    if (grid.dataGridBegin(&ui, "g2", cols3[0..], 4, sel[0..], &st, .{})) {
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            if (grid.dataGridRow(&ui, i)) |row| row.text(0, "x", theme.text);
        }
        grid.dataGridEnd(&ui);
    }
    ui.paint();
    try std.testing.expect(sel[0]);
    try std.testing.expect(sel[1]);
    try std.testing.expect(sel[2]);
    try std.testing.expect(!sel[3]);
}

// 列宽拖拽：拖右边缘改宽度，且持久化在 state 里。
test "data grid drags a column edge" {
    var ui = core.Context{};
    var st = grid.GridState{};

    ui.begin(480, 400);
    _ = grid.dataGridBegin(&ui, "g3", cols3[0..], 2, null, &st, .{});
    grid.dataGridEnd(&ui);
    ui.paint();
    const w0 = st.widths[0];

    // 手柄在列头右边缘 8px 内
    const grip_id = core.Context.idOf("g3") ^ 0x6B1B;
    const gr = ui.lastRect(grip_id) orelse return error.NoHit;
    const gx = gr.x + gr.w / 2;
    const gy = gr.y + gr.h / 2;

    ui.input = .{ .mouse = .{ .x = gx, .y = gy }, .down = true, .pressed = true };
    ui.begin(480, 400);
    _ = grid.dataGridBegin(&ui, "g3", cols3[0..], 2, null, &st, .{});
    grid.dataGridEnd(&ui);
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), st.drag_col);

    ui.input = .{ .mouse = .{ .x = gx + 40, .y = gy }, .down = true };
    ui.begin(480, 400);
    _ = grid.dataGridBegin(&ui, "g3", cols3[0..], 2, null, &st, .{});
    grid.dataGridEnd(&ui);
    ui.paint();
    try std.testing.expect(st.widths[0] > w0 + 30);
}

// 排序：点可排序表头切换方向。
test "data grid header toggles sort" {
    var ui = core.Context{};
    var st = grid.GridState{};
    var sort = grid.GridSort{};

    ui.begin(480, 400);
    _ = grid.dataGridBegin(&ui, "g4", cols3[0..], 2, null, &st, .{ .sort = &sort });
    grid.dataGridEnd(&ui);
    ui.paint();

    const hid = core.Context.idOf("g4") ^ 0x1EAD;
    const hr = ui.lastRect(hid) orelse return error.NoHit;
    const hx = hr.x + 20;
    const hy = hr.y + hr.h / 2;

    ui.input = .{ .mouse = .{ .x = hx, .y = hy }, .click = .{ .x = hx, .y = hy } };
    ui.begin(480, 400);
    _ = grid.dataGridBegin(&ui, "g4", cols3[0..], 2, null, &st, .{ .sort = &sort });
    grid.dataGridEnd(&ui);
    ui.paint();
    try std.testing.expectEqual(@as(?usize, 0), sort.column);
    try std.testing.expect(!sort.desc);

    ui.input = .{ .mouse = .{ .x = hx, .y = hy }, .click = .{ .x = hx, .y = hy } };
    ui.begin(480, 400);
    _ = grid.dataGridBegin(&ui, "g4", cols3[0..], 2, null, &st, .{ .sort = &sort });
    grid.dataGridEnd(&ui);
    ui.paint();
    try std.testing.expect(sort.desc);
}

// 内联编辑：Shift+点击进入、输入字符、Enter 提交。
test "data grid cell edits inline" {
    var ui = core.Context{};
    var st = grid.GridState{};
    var buf: [32]u8 = @splat(0);
    @memcpy(buf[0..3], "abc");
    var len: usize = 3;

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(480, 400);
        if (grid.dataGridBegin(&ui, "g5", cols3[0..], 1, null, &st, .{})) {
            if (grid.dataGridRow(&ui, 0)) |row| {
                row.text(0, buf[0..len], theme.text);
                _ = row.edit(0, &buf, &len);
            }
            grid.dataGridEnd(&ui);
        }
        ui.paint();
        if (frame == 0) {
            // 单元格命中区在 cell(0)
            const cell_id = core.Context.idOf("g5") ^ 0xE0D0;
            const cr = ui.lastRect(cell_id) orelse return error.NoHit;
            ui.input = .{ .mouse = .{ .x = cr.x + 20, .y = cr.y + cr.h / 2 }, .click = .{ .x = cr.x + 20, .y = cr.y + cr.h / 2 } };
            ui.input.mods = .{ .shift = true };
        }
    }
    try std.testing.expectEqual(@as(i32, 0), st.editing_row);
    try std.testing.expectEqual(@as(i32, 0), st.editing_col);

    // 输入并提交
    ui.input = .{};
    ui.input.addCharBytes("!");
    ui.input.addKey(.enter);
    ui.begin(480, 400);
    var committed = false;
    if (grid.dataGridBegin(&ui, "g5", cols3[0..], 1, null, &st, .{})) {
        if (grid.dataGridRow(&ui, 0)) |row| {
            committed = row.edit(0, &buf, &len);
        }
        grid.dataGridEnd(&ui);
    }
    ui.paint();
    try std.testing.expect(committed);
    try std.testing.expectEqualStrings("abc!", buf[0..len]);
    try std.testing.expectEqual(@as(i32, -1), st.editing_row);
}

// ---------------------------------------------------------------- 树表

const nodes = [_]grid.TreeNode{
    // 0 root "src"
    .{ .parent = -1, .first_child = 1, .next_sibling = 4 },
    // 1 a.zig, 2 b.zig
    .{ .parent = 0, .first_child = -1, .next_sibling = 2 },
    .{ .parent = 0, .first_child = -1, .next_sibling = 3 },
    .{ .parent = 0, .first_child = -1, .next_sibling = -1 },
    // 4 README (root 的兄弟)
    .{ .parent = -1, .first_child = -1, .next_sibling = -1 },
};

fn treeLabel(_: []const grid.TreeNode, i: usize) []const u8 {
    return switch (i) {
        0 => "src",
        1 => "a.zig",
        2 => "b.zig",
        3 => "c.zig",
        4 => "README",
        else => "?",
    };
}

// 树表：默认折叠 → 只有两个顶层节点；展开后多出子行。
test "tree table flattens only the expanded part" {
    var ui = core.Context{};
    var tnodes = nodes;
    var st = grid.TreeTableState{};
    var grid_st = grid.GridState{};
    _ = &grid_st;

    ui.begin(480, 400);
    if (grid.treeTableBegin(&ui, "tt", cols3[0..], tnodes[0..], &st, .{ .labelFn = treeLabel })) {
        while (grid.treeTableRow(&ui, &st)) |_| {}
        grid.treeTableEnd(&ui);
    }
    ui.paint();
    try std.testing.expectEqual(@as(usize, 2), st.row_count);

    // 展开 root：点它前面的三角
    const arrow_id = core.Context.idOf("tree") ^ (0xA000 + 1);
    const ar = ui.lastRect(arrow_id) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = ar.x + ar.w / 2, .y = ar.y + ar.h / 2 }, .click = .{ .x = ar.x + ar.w / 2, .y = ar.y + ar.h / 2 } };
    ui.begin(480, 400);
    if (grid.treeTableBegin(&ui, "tt", cols3[0..], tnodes[0..], &st, .{ .labelFn = treeLabel })) {
        while (grid.treeTableRow(&ui, &st)) |_| {}
        grid.treeTableEnd(&ui);
    }
    ui.paint();
    // 展开发生在「点击那一帧的 flatten 之后」，所以再渲一帧才看到子行
    ui.input = .{};
    ui.begin(480, 400);
    if (grid.treeTableBegin(&ui, "tt", cols3[0..], tnodes[0..], &st, .{ .labelFn = treeLabel })) {
        while (grid.treeTableRow(&ui, &st)) |_| {}
        grid.treeTableEnd(&ui);
    }
    ui.paint();
    try std.testing.expect((tnodes[0].flags & grid.TreeFlag.expanded) != 0);
    try std.testing.expectEqual(@as(usize, 5), st.row_count);
}

// 树排序：按标签降序重接兄弟链。
fn lessByLabel(_: void, a: i32, b: i32) bool {
    return std.mem.order(u8, treeLabel(&nodes, @intCast(a)), treeLabel(&nodes, @intCast(b))) == .gt;
}

test "tree sort reorders sibling links" {
    var tnodes = nodes;
    const head = grid.treeSort(tnodes[0..], 0, {}, lessByLabel);
    try std.testing.expectEqual(@as(i32, 3), head);
    // 链：3 → 2 → 1 → -1
    try std.testing.expectEqual(@as(i32, 2), tnodes[3].next_sibling);
    try std.testing.expectEqual(@as(i32, 1), tnodes[2].next_sibling);
    try std.testing.expectEqual(@as(i32, -1), tnodes[1].next_sibling);
}

// ---------------------------------------------------------------- 面包屑

// 面包屑：点分段返回下标；点最后一段进入编辑。
test "path bar reports segments and edits the tail" {
    var ui = core.Context{};
    var st = grid.PathBarState{};
    const segs = [_][]const u8{ "root", "src", "widgets" };

    ui.begin(600, 200);
    const r1 = grid.pathBar(&ui, "pb", segs[0..], &st, .{ .icon = ">" });
    ui.paint();
    try std.testing.expectEqual(@as(i32, -1), r1.clicked);

    // 点第一个分段
    const sid = core.Context.idOf("pb") ^ 0x9A00;
    const sr = ui.lastRect(sid) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = sr.x + 4, .y = sr.y + sr.h / 2 }, .click = .{ .x = sr.x + 4, .y = sr.y + sr.h / 2 } };
    ui.begin(600, 200);
    const r2 = grid.pathBar(&ui, "pb", segs[0..], &st, .{ .icon = ">" });
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), r2.clicked);

    // 点最后一段 → 进入编辑，预填 "root/src/widgets"
    const lid = core.Context.idOf("pb") ^ (0x9A00 + 2);
    const lr = ui.lastRect(lid) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = lr.x + 4, .y = lr.y + lr.h / 2 }, .click = .{ .x = lr.x + 4, .y = lr.y + lr.h / 2 } };
    ui.begin(600, 200);
    const r3 = grid.pathBar(&ui, "pb", segs[0..], &st, .{ .icon = ">" });
    ui.paint();
    try std.testing.expect(r3.editing);
    try std.testing.expectEqualStrings("root/src/widgets", st.buf[0..st.len]);
}

// ---------------------------------------------------------------- 筛选条

// 筛选条：+Filter 打开下拉，勾选选项后写入位掩码。
test "filter bar sets option bits" {
    var ui = core.Context{};
    const options = [_][]const u8{ "open", "closed" };
    const fields = [_]grid.FilterField{.{ .name = "Status", .options = options[0..] }};
    var selected = [_]u32{0};
    var search: [32]u8 = @splat(0);
    var st = grid.FilterBarState{};

    ui.begin(600, 300);
    _ = grid.filterBar(&ui, "fb", fields[0..], selected[0..], &search, &st, 500);
    ui.paint();

    // 点 + Filter 打开下拉
    const bid = core.Context.idOf("fb") ^ 0xF117;
    const br = ui.lastRect(bid) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = br.x + br.w / 2, .y = br.y + br.h / 2 }, .click = .{ .x = br.x + br.w / 2, .y = br.y + br.h / 2 } };
    ui.begin(600, 300);
    _ = grid.filterBar(&ui, "fb", fields[0..], selected[0..], &search, &st, 500);
    ui.paint();
    try std.testing.expectEqual(@as(i32, 0), st.open_field);

    // 点选项「open」：checkbox 的交互 id = idOf(label) ^ 0x1B873593
    const cid = core.Context.idOf("open") ^ 0x1B873593;
    const cr = ui.lastRect(cid) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = cr.x + 6, .y = cr.y + cr.h / 2 }, .click = .{ .x = cr.x + 6, .y = cr.y + cr.h / 2 } };
    ui.begin(600, 300);
    const changed = grid.filterBar(&ui, "fb", fields[0..], selected[0..], &search, &st, 500);
    ui.paint();
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(u32, 1), selected[0]);
}

// 冒烟：网格 + 树表 + 面包屑 + 筛选条同页不溢出。
test "smoke: grid widgets build without overflowing" {
    var ui = core.Context{};
    var sel = [_]bool{ false, false, true };
    var gst = grid.GridState{};
    var tnodes = nodes;
    var tst = grid.TreeTableState{};
    var pst = grid.PathBarState{};
    const segs = [_][]const u8{ "root", "src", "widgets" };
    const options = [_][]const u8{ "open", "closed" };
    const fields = [_]grid.FilterField{.{ .name = "Status", .options = options[0..] }};
    var fsel = [_]u32{1};
    var search: [32]u8 = @splat(0);
    var fst = grid.FilterBarState{};
    var sort = grid.GridSort{};

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(700, 1200);
        var col = ui.column(.{ .pad = 12, .gap = 12 });
        defer col.end();

        _ = grid.pathBar(&ui, "pb2", segs[0..], &pst, .{ .icon = ">" });
        _ = grid.filterBar(&ui, "fb2", fields[0..], fsel[0..], &search, &fst, 600);

        if (grid.dataGridBegin(&ui, "g9", cols3[0..], 3, sel[0..], &gst, .{ .checkboxes = true, .sort = &sort, .height = 160 })) {
            const rows = [_][]const u8{ "alpha", "beta", "gamma" };
            for (rows, 0..) |s, i| {
                if (grid.dataGridRow(&ui, i)) |row| {
                    row.text(0, s, theme.text);
                    row.text(1, "12 KB", theme.secondary);
                    row.text(2, "file", theme.secondary);
                }
            }
            grid.dataGridEnd(&ui);
        }

        if (grid.treeTableBegin(&ui, "tt9", cols3[0..], tnodes[0..], &tst, .{ .labelFn = treeLabel, .height = 140 })) {
            while (grid.treeTableRow(&ui, &tst)) |_| {}
            grid.treeTableEnd(&ui);
        }
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}
