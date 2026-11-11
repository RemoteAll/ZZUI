//! 图族：提交图（泳道分配 / refs / 点击与键盘）、依赖图（分层 / 成环 / 缩放平移 / 键盘 / 容量）。
const std = @import("std");
const core = @import("core.zig");
const graph = @import("graph.zig");
const types = @import("types.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

fn keysOf(k: types.Key) [8]types.Key {
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = k;
    return keys;
}

// ------------------------------------------------------------------ 提交图

const GFix = struct {
    ui: core.Context = .{},
    st: graph.CommitState = .{},
    res: graph.CommitResult = .{},
    commits: [4]graph.Commit = .{
        .{ .hash = "a1b2c3d4e5", .message = "Add the graph view\n\nBody text", .author = "Ann", .date = "2 hours ago", .parent = .{ 1, -1 } },
        .{ .hash = "b2c3d4e5f6", .message = "Fix lanes", .author = "Bob", .date = "yesterday", .refs = "main, origin/main", .parent = .{ 2, -1 } },
        .{ .hash = "c3d4e5f6a7", .message = "Initial import", .author = "Ann", .date = "Mar 3", .refs = "tag: v0.1", .parent = .{ 3, -1 } },
        .{ .hash = "d4e5f6a7b8", .message = "Root", .author = "Ann", .date = "Mar 1", .parent = .{ -1, -1 } },
    },
    n: usize = 4,

    fn frame(self: *GFix) void {
        self.ui.begin(760, 460);
        self.res = graph.commitGraph(&self.ui, "commits", self.commits[0..self.n], &self.st, .{ .height = 300 });
        self.ui.paint();
    }

    fn rowId(self: *GFix, i: usize) u64 {
        _ = self;
        return core.Context.idOf("commits") ^ (@as(u64, @intCast(i)) *% 0xC0DE);
    }
};

test "graph: commit lanes keep a linear history on one lane" {
    var rows: [8]graph.LaneRow = @splat(.{});
    var cs: [3]graph.Commit = .{
        .{ .parent = .{ 1, -1 } },
        .{ .parent = .{ 2, -1 } },
        .{ .parent = .{ -1, -1 } },
    };
    const lanes = graph.commitLanes(cs[0..], rows[0..]);
    try std.testing.expectEqual(@as(usize, 1), lanes);
    try std.testing.expectEqual(@as(i8, -1), rows[0].in[0]); // 首行没有上方来线
    var i: usize = 1;
    while (i < 3) : (i += 1) {
        try std.testing.expectEqual(@as(i8, 0), rows[i].lane);
        try std.testing.expectEqual(@as(i8, 0), rows[i].in[0]);
    }
    try std.testing.expectEqual(@as(i8, 0), rows[0].out[0]);
    try std.testing.expectEqual(@as(i8, 0), rows[1].out[0]);
    try std.testing.expect(!rows[0].merge);
    try std.testing.expect(!rows[1].merge);
    // 最后一行不再有向下的连线
    try std.testing.expectEqual(@as(i8, -1), rows[2].out[0]);
}

test "graph: a second parent opens a lane and marks the row as a merge" {
    var rows: [8]graph.LaneRow = @splat(.{});
    var cs: [4]graph.Commit = .{
        .{ .parent = .{ 1, 2 } },
        .{ .parent = .{ 3, -1 } },
        .{ .parent = .{ 3, -1 } },
        .{ .parent = .{ -1, -1 } },
    };
    const lanes = graph.commitLanes(cs[0..], rows[0..]);
    try std.testing.expectEqual(@as(usize, 2), lanes);
    try std.testing.expect(rows[0].merge);
    try std.testing.expectEqual(@as(i8, 0), rows[0].lane);
    // 第二个父提交占到了 1 号泳道
    try std.testing.expectEqual(@as(i8, 0), rows[0].out[0]);
    try std.testing.expectEqual(@as(i8, 0), rows[0].out[1]);
    // 第三行的父提交已经在 0 号泳道等着 → 并进去（join），不是新泳道
    try std.testing.expectEqual(@as(i8, 0), rows[2].join[0]);
}

test "graph: parents pointing at or above the row are ignored" {
    var rows: [8]graph.LaneRow = @splat(.{});
    var cs: [3]graph.Commit = .{
        .{ .parent = .{ 0, 9 } }, // 自己 / 越界
        .{ .parent = .{ -1, -1 } },
        .{ .parent = .{ -1, -1 } },
    };
    const lanes = graph.commitLanes(cs[0..], rows[0..]);
    try std.testing.expectEqual(@as(usize, 1), lanes);
    try std.testing.expectEqual(@as(i8, -1), rows[0].out[0]);
}

test "graph: clicking a commit row selects and reports it" {
    var f = GFix{};
    f.frame();
    const r = f.ui.lastRect(f.rowId(1)).?;
    f.ui.input = .{ .mouse = at(r.x + 40, r.y + 10), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(r.x + 40, r.y + 10), .click = at(r.x + 40, r.y + 10) };
    f.frame();
    try std.testing.expectEqual(@as(i32, 1), f.st.sel);
    try std.testing.expectEqual(@as(i32, 1), f.res.clicked);
    try std.testing.expect(!f.ui.overflowed);
}

test "graph: arrows move the selection and enter activates it" {
    var f = GFix{};
    f.ui.focus_id = core.Context.idOf("commits") ^ 0xC01D;
    f.frame();
    f.ui.input = .{ .keys = keysOf(.down), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 0), f.st.sel);
    f.ui.input = .{ .keys = keysOf(.down), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 1), f.st.sel);
    f.ui.input = .{ .keys = keysOf(.end), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 3), f.st.sel);
    f.ui.input = .{ .keys = keysOf(.enter), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 3), f.res.activated);
    // 顶到第一行后不再继续往上
    f.ui.input = .{ .keys = keysOf(.home), .key_count = 1 };
    f.frame();
    f.ui.input = .{ .keys = keysOf(.up), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 0), f.st.sel);
}

test "graph: an empty commit list draws the empty state without scrolling" {
    var f = GFix{};
    f.n = 0;
    f.frame();
    try std.testing.expectEqual(@as(i32, -1), f.res.clicked);
    try std.testing.expectEqual(@as(f32, 0), f.st.max_scroll);
    try std.testing.expect(!f.ui.overflowed);
}

// ------------------------------------------------------------------ 依赖图

const DFix = struct {
    ui: core.Context = .{},
    st: graph.DepState = .{},
    res: graph.DepResult = .{},
    nodes: [6]graph.DepNode = .{
        .{ .label = "core" },
        .{ .label = "render", .detail = "rects" },
        .{ .label = "widgets" },
        .{ .label = "app", .tone = .success },
        .{ .label = "tests" },
        .{ .label = "docs" },
    },
    edges: [8]graph.DepEdge = @splat(.{}),
    m: usize = 0,
    n: usize = 6,

    fn chain(self: *DFix) void {
        self.n = 3;
        self.m = 2;
        self.edges[0] = .{ .from = 0, .to = 1 };
        self.edges[1] = .{ .from = 1, .to = 2 };
    }

    fn frame(self: *DFix, top_down: bool) void {
        self.ui.begin(700, 460);
        self.res = graph.depGraph(&self.ui, "deps", self.nodes[0..self.n], self.edges[0..self.m], &self.st, .{ .height = 380, .top_down = top_down });
        self.ui.paint();
    }
};

test "graph: a chain is layered left to right and fits inside the panel" {
    var f = DFix{};
    f.chain();
    f.frame(false);
    try std.testing.expectEqual(@as(usize, 3), f.st.n);
    try std.testing.expectEqual(@as(usize, 2), f.st.m);
    try std.testing.expect(f.st.box[0].x < f.st.box[1].x);
    try std.testing.expect(f.st.box[1].x < f.st.box[2].x);
    // 每层只有一个节点 → 沿跨轴居中（高度不同，差值是两行小字的一半）
    try std.testing.expect(@abs(f.st.box[0].y - f.st.box[1].y) < 20);
    try std.testing.expect(f.st.gw > 0 and f.st.gh > 0);
    try std.testing.expect(f.st.zoom <= 1.0 and f.st.zoom >= 0.2);
    try std.testing.expect(!f.res.overflow);
}

test "graph: top down puts deeper layers below" {
    var f = DFix{};
    f.chain();
    f.frame(true);
    try std.testing.expect(f.st.box[0].y < f.st.box[1].y);
    try std.testing.expect(f.st.box[1].y < f.st.box[2].y);
    // 同层并排：第 1、2 层都在 x 上居中（宽度可能不同但左边界接近）
    try std.testing.expect(@abs(f.st.box[0].x - f.st.box[1].x) < 40);
}

test "graph: a cycle still lays out (back edge is not used for ordering)" {
    var f = DFix{};
    f.n = 3;
    f.m = 3;
    f.edges[0] = .{ .from = 0, .to = 1 };
    f.edges[1] = .{ .from = 1, .to = 2 };
    f.edges[2] = .{ .from = 2, .to = 0 };
    f.frame(false);
    try std.testing.expectEqual(@as(usize, 3), f.st.n);
    try std.testing.expectEqual(@as(usize, 3), f.st.m);
    // 三条边都要能画出来（回边留在边表里，只是不参与分层）
    try std.testing.expect(f.st.gw > 0);
    try std.testing.expect(!f.ui.overflowed);
}

test "graph: invalid and self edges are dropped" {
    var f = DFix{};
    f.m = 4;
    f.edges[0] = .{ .from = 0, .to = 1 };
    f.edges[1] = .{ .from = 2, .to = 2 }; // 自环
    f.edges[2] = .{ .from = -1, .to = 1 }; // 负下标
    f.edges[3] = .{ .from = 1, .to = 99 }; // 越界
    f.frame(false);
    try std.testing.expectEqual(@as(usize, 1), f.st.m);
}

test "graph: more nodes than the fixed capacity is reported, not silently clipped" {
    var f = DFix{};
    var many: [graph.MAX_NODES + 8]graph.DepNode = @splat(.{ .label = "n" });
    f.m = 0;
    f.ui.begin(700, 460);
    const res = graph.depGraph(&f.ui, "big", many[0..], f.edges[0..0], &f.st, .{ .height = 380 });
    f.ui.paint();
    try std.testing.expect(res.overflow);
    try std.testing.expectEqual(graph.MAX_NODES, f.st.n);
}

test "graph: clicking a node selects it without panning" {
    var f = DFix{};
    f.chain();
    f.frame(false);
    const b = f.st.box[1];
    // 面板在页面里的上一帧矩形 + 图平移/缩放
    const panel = f.ui.lastRect(core.Context.idOf("deps") ^ 0x6A90).?;
    const px = panel.x + f.st.px + (b.x + b.w * 0.5) * f.st.zoom;
    const py = panel.y + f.st.py + (b.y + b.h * 0.5) * f.st.zoom;
    const px0 = f.st.px;
    f.ui.input = .{ .mouse = at(px, py), .pressed = true, .down = true };
    f.frame(false);
    f.ui.input = .{ .mouse = at(px, py), .click = at(px, py) };
    f.frame(false);
    try std.testing.expectEqual(@as(i32, 1), f.st.sel);
    try std.testing.expectEqual(@as(i32, 1), f.res.clicked);
    try std.testing.expectEqual(px0, f.st.px); // 没拖动 → 不平移
}

test "graph: dragging the background pans the view and keeps the selection" {
    var f = DFix{};
    f.chain();
    f.st.sel = 2;
    f.frame(false);
    const px0 = f.st.px;
    const py0 = f.st.py;
    // 在左下角空白处按下（节点都在中上部）
    const panel = f.ui.lastRect(core.Context.idOf("deps") ^ 0x6A90).?;
    const sx = panel.x + 6;
    const sy = panel.y + panel.h - 6;
    f.ui.input = .{ .mouse = at(sx, sy), .pressed = true, .down = true };
    f.frame(false);
    f.ui.input = .{ .mouse = at(sx + 30, sy - 20), .down = true };
    f.frame(false);
    f.ui.input = .{ .mouse = at(sx + 30, sy - 20), .down = false };
    f.frame(false);
    try std.testing.expect(f.st.px > px0);
    try std.testing.expect(f.st.py < py0);
    try std.testing.expectEqual(@as(i32, 2), f.st.sel);
}

test "graph: the wheel zooms around the pointer and clamps" {
    var f = DFix{};
    f.chain();
    f.frame(false);
    const panel = f.ui.lastRect(core.Context.idOf("deps") ^ 0x6A90).?;
    const cx = panel.x + panel.w * 0.5;
    const cy = panel.y + panel.h * 0.5;
    const z0 = f.st.zoom;
    f.ui.input = .{ .mouse = at(cx, cy), .wheel = 3 };
    f.frame(false);
    try std.testing.expect(f.st.zoom > z0);
    // 一直往上滚 → 夹到 2.5
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        f.ui.input = .{ .mouse = at(cx, cy), .wheel = 5 };
        f.frame(false);
    }
    try std.testing.expectEqual(@as(f32, 2.5), f.st.zoom);
    // 一直往下滚 → 夹到 0.2
    i = 0;
    while (i < 30) : (i += 1) {
        f.ui.input = .{ .mouse = at(cx, cy), .wheel = -5 };
        f.frame(false);
    }
    try std.testing.expectEqual(@as(f32, 0.2), f.st.zoom);
}

test "graph: F refits and escape clears the selection" {
    var f = DFix{};
    f.chain();
    f.ui.focus_id = core.Context.idOf("deps") ^ 0x6A90;
    f.frame(false);
    f.st.zoom = 2.4;
    f.st.px = -400;
    f.st.sel = 1;
    f.ui.input = .{ .keys = keysOf(.F), .key_count = 1 };
    f.frame(false);
    try std.testing.expect(f.st.zoom <= 1.0 and f.st.zoom >= 0.2);
    try std.testing.expect(f.st.px > -400);
    f.ui.input = .{ .keys = keysOf(.escape), .key_count = 1 };
    f.frame(false);
    try std.testing.expectEqual(@as(i32, -1), f.st.sel);
}

test "graph: arrows follow edges and cross the layer sideways" {
    var f = DFix{};
    f.n = 3;
    f.m = 2;
    f.edges[0] = .{ .from = 0, .to = 1 };
    f.edges[1] = .{ .from = 0, .to = 2 }; // 同层（都由 core 指向 → 1、2 同层）
    f.ui.focus_id = core.Context.idOf("deps") ^ 0x6A90;
    f.st.sel = 0;
    f.frame(false);
    try std.testing.expectEqual(f.st.layer[1], f.st.layer[2]); // 同层
    f.ui.input = .{ .keys = keysOf(.right), .key_count = 1 };
    f.frame(false);
    try std.testing.expect(f.st.sel == 1 or f.st.sel == 2);
    const first = f.st.sel;
    f.ui.input = .{ .keys = keysOf(.down), .key_count = 1 };
    f.frame(false);
    try std.testing.expect(f.st.sel != first); // 同层内跨轴移动
    f.ui.input = .{ .keys = keysOf(.enter), .key_count = 1 };
    f.frame(false);
    try std.testing.expectEqual(f.st.sel, f.res.activated);
}

test "graph: hovering a node lights it up and its neighbours" {
    var f = DFix{};
    f.chain();
    f.frame(false);
    const b = f.st.box[1];
    const panel = f.ui.lastRect(core.Context.idOf("deps") ^ 0x6A90).?;
    f.ui.input = .{ .mouse = at(panel.x + f.st.px + (b.x + b.w * 0.5) * f.st.zoom, panel.y + f.st.py + (b.y + b.h * 0.5) * f.st.zoom) };
    f.frame(false);
    try std.testing.expectEqual(@as(i32, 1), f.res.hovered);
    try std.testing.expectEqual(@as(u8, 1), f.st.lit[1]);
    try std.testing.expectEqual(@as(u8, 2), f.st.lit[0]);
    try std.testing.expectEqual(@as(u8, 2), f.st.lit[2]);
}
