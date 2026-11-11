//! 节点编辑器：卡片 / 引脚构建、点选与多选、拖动、连线（吸附 / 摘线 / 查重）、
//! 框选、删除、缩放与平移、内容宿主、空编辑器。
const std = @import("std");
const core = @import("core.zig");
const nodes = @import("nodes.zig");
const types = @import("types.zig");
const widgets = @import("widgets.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

fn keysOf(k: types.Key) [8]types.Key {
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = k;
    return keys;
}

const N = 3;

const Fx = struct {
    ui: core.Context = .{},
    st: nodes.State = .{},
    view: nodes.View = .{},
    xs: [N]f32 = .{ 20, 260, 20 },
    ys: [N]f32 = .{ 20, 20, 200 },
    built: bool = false,
    made: bool = false,
    made_from: i32 = 0,
    made_to: i32 = 0,
    rm_hit: bool = false,
    removed: i32 = 0,
    del_hit: bool = false,
    deleted: i32 = 0,
    link_declared: bool = true,

    fn frame(self: *Fx) void {
        self.ui.begin(760, 520);
        self.built = nodes.editorBegin(&self.ui, "ne", &self.st, &self.view, .{ .height = 460, .minimap = true });
        if (self.built) {
            _ = nodes.nodeBegin(&self.ui, &self.st, 0, &self.xs[0], &self.ys[0], "Source", .{});
            _ = nodes.nodeOutput(&self.ui, &self.st, 100, "out", .{ .type = 1 });
            nodes.nodeEnd(&self.ui, &self.st);

            _ = nodes.nodeBegin(&self.ui, &self.st, 1, &self.xs[1], &self.ys[1], "Sink", .{});
            _ = nodes.nodeInput(&self.ui, &self.st, 200, "in", .{ .type = 1 });
            nodes.nodeEnd(&self.ui, &self.st);

            _ = nodes.nodeBegin(&self.ui, &self.st, 2, &self.xs[2], &self.ys[2], "Loose", .{});
            nodes.nodeEnd(&self.ui, &self.st);

            if (self.link_declared) _ = nodes.nodeLink(&self.ui, &self.st, 900, 100, 200);

            self.made = nodes.linkCreated(&self.st, &self.made_from, &self.made_to);
            self.rm_hit = nodes.linkRemoved(&self.st, &self.removed);
            if (self.rm_hit) self.link_declared = false;
            self.del_hit = nodes.nodeDeleted(&self.st, &self.deleted);
            nodes.editorEnd(&self.ui, &self.st);
        }
        self.ui.paint();
    }

    fn cardRect(self: *Fx, node: i32) types.Rect {
        return self.ui.lastRect(nodesTestKey(0x71, node)).?;
    }
};

/// 与 `nodes.nodeKey` 同构（卡片的命中矩形用 0x71）。
fn nodesTestKey(kind: u64, id: i32) u64 {
    return core.Context.idOf("ne") ^ (kind *% 0x9E3779B1) ^ (@as(u64, @intCast(@as(u32, @bitCast(id)))) *% 0xC0DE);
}

test "nodes: cards and pins are built and nothing overflows" {
    var f = Fx{};
    f.frame();
    try std.testing.expect(f.built);
    try std.testing.expectEqual(@as(usize, 3), f.st.prev.node_n);
    try std.testing.expectEqual(@as(usize, 2), f.st.prev.pin_n);
    try std.testing.expectEqual(@as(usize, 1), f.st.prev.link_n);
    try std.testing.expect(!f.ui.overflowed);
}

test "nodes: the card height is measured after one frame and then stays stable" {
    var f = Fx{};
    f.frame();
    const h1 = f.st.prev.nodes[0].h;
    f.frame();
    const h2 = f.st.prev.nodes[0].h;
    try std.testing.expect(h1 > 34);
    try std.testing.expectEqual(h1, h2);
}

test "nodes: clicking a card selects it" {
    var f = Fx{};
    f.frame();
    const r = f.cardRect(2);
    f.ui.input = .{ .mouse = at(r.x + 10, r.y + 8), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(r.x + 10, r.y + 8), .down = false };
    f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.st.sel_n);
    try std.testing.expectEqual(@as(i32, 2), f.st.sel[0]);
    try std.testing.expect(nodes.isSelected(&f.st, 2));
    try std.testing.expect(!nodes.isSelected(&f.st, 0));
}

test "nodes: shift-click adds, ctrl-click toggles the card off" {
    var f = Fx{};
    f.frame();
    const a = f.cardRect(0);
    f.ui.input = .{ .mouse = at(a.x + 10, a.y + 8), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(a.x + 10, a.y + 8), .down = false };
    f.frame();
    const b = f.cardRect(1);
    f.ui.input = .{ .mouse = at(b.x + 10, b.y + 8), .pressed = true, .down = true, .mods = .{ .shift = true } };
    f.frame();
    f.ui.input = .{ .mouse = at(b.x + 10, b.y + 8), .down = false, .mods = .{ .shift = true } };
    f.frame();
    try std.testing.expectEqual(@as(usize, 2), f.st.sel_n);
    f.ui.input = .{ .mouse = at(b.x + 10, b.y + 8), .pressed = true, .down = true, .mods = .{ .ctrl = true } };
    f.frame();
    f.ui.input = .{ .mouse = at(b.x + 10, b.y + 8), .down = false, .mods = .{ .ctrl = true } };
    f.frame();
    try std.testing.expectEqual(@as(usize, 1), f.st.sel_n);
    try std.testing.expectEqual(@as(i32, 0), f.st.sel[0]);
}

test "nodes: dragging a card moves its position in canvas units" {
    var f = Fx{};
    f.frame();
    const a = f.cardRect(0);
    const x0 = f.xs[0];
    f.ui.input = .{ .mouse = at(a.x + 20, a.y + 8), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(a.x + 60, a.y + 40), .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(a.x + 60, a.y + 40), .down = false };
    f.frame();
    try std.testing.expect(f.xs[0] > x0 + 20);
    try std.testing.expectEqual(nodes.Mode.idle, f.st.mode);
}

test "nodes: dragging an input pin that has a link detaches and removes it" {
    var f = Fx{};
    f.frame();
    const b = f.cardRect(1);
    const qx = b.x;
    const qy = b.y + 34 + 6 + 13;
    f.ui.input = .{ .mouse = at(qx, qy), .pressed = true, .down = true };
    f.frame();
    try std.testing.expectEqual(nodes.Mode.wire, f.st.mode);
    try std.testing.expect(f.st.wire_detached);
    // 松在空处 → 报告那条线被摘掉
    f.ui.input = .{ .mouse = at(qx + 320, qy + 220), .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(qx + 320, qy + 220), .down = false };
    f.frame();
    try std.testing.expect(f.rm_hit);
    try std.testing.expectEqual(@as(i32, 900), f.removed);
}

test "nodes: dragging a wire between two pins reports the new link" {
    var f = Fx{};
    f.frame();
    const b = f.cardRect(1);
    const qx = b.x;
    const qy = b.y + 34 + 6 + 13;
    // 先把已有那条摘掉，才会有「新建」事件
    f.ui.input = .{ .mouse = at(qx, qy), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(qx + 320, qy + 220), .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(qx + 320, qy + 220), .down = false };
    f.frame();
    try std.testing.expect(f.rm_hit);

    const a = f.cardRect(0);
    const px = a.x + a.w;
    const py = a.y + 34 + 6 + 13;
    f.ui.input = .{ .mouse = at(px, py), .pressed = true, .down = true };
    f.frame();
    try std.testing.expectEqual(nodes.Mode.wire, f.st.mode);
    f.ui.input = .{ .mouse = at(qx - 2, qy + 2), .down = true };
    f.frame();
    try std.testing.expect(f.st.has_target);
    f.ui.input = .{ .mouse = at(qx - 2, qy + 2), .down = false };
    f.frame();
    try std.testing.expect(f.made);
    try std.testing.expectEqual(@as(i32, 100), f.made_from);
    try std.testing.expectEqual(@as(i32, 200), f.made_to);
}

test "nodes: marquee drag selects the cards it touches" {
    var f = Fx{};
    f.frame();
    const r = f.st.rect;
    const a = f.cardRect(0);
    const c = f.cardRect(2);
    // 从画布左上角（卡片外面）拖到盖住 A 与 C
    const x0 = r.x + 4;
    const y0 = r.y + 4;
    const x1 = @max(c.x + c.w, a.x + a.w) + 20;
    const y1 = c.y + c.h + 10;
    f.ui.input = .{ .mouse = at(x0, y0), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(x1, y1), .down = true };
    f.frame();
    try std.testing.expectEqual(nodes.Mode.marquee, f.st.mode);
    try std.testing.expect(f.st.sel_n >= 2);
    f.ui.input = .{ .mouse = at(x1, y1), .down = false };
    f.frame();
}

test "nodes: delete removes the selection and reports the deleted node" {
    var f = Fx{};
    f.ui.focus_id = core.Context.idOf("ne") ^ 0x4E0D;
    f.frame();
    const c = f.cardRect(2);
    f.ui.input = .{ .mouse = at(c.x + 10, c.y + 8), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(c.x + 10, c.y + 8), .down = false };
    f.frame();
    try std.testing.expect(nodes.isSelected(&f.st, 2));
    f.ui.input = .{ .keys = keysOf(.delete), .key_count = 1 };
    f.frame();
    try std.testing.expect(f.del_hit);
    try std.testing.expectEqual(@as(i32, 2), f.deleted);
    try std.testing.expectEqual(@as(usize, 0), f.st.sel_n);
}

test "nodes: the wheel zooms around the pointer and clamps to the limits" {
    var f = Fx{};
    f.frame();
    const r = f.st.rect;
    const cx = r.x + r.w * 0.5;
    const cy = r.y + r.h * 0.5;
    const z0 = f.view.zoom;
    f.ui.input = .{ .mouse = at(cx, cy), .wheel = 2 };
    f.frame();
    try std.testing.expect(f.view.zoom > z0);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        f.ui.input = .{ .mouse = at(cx, cy), .wheel = 5 };
        f.frame();
    }
    try std.testing.expectEqual(@as(f32, 2.0), f.view.zoom);
    i = 0;
    while (i < 30) : (i += 1) {
        f.ui.input = .{ .mouse = at(cx, cy), .wheel = -5 };
        f.frame();
    }
    try std.testing.expectEqual(@as(f32, 0.25), f.view.zoom);
}

test "nodes: F frames every node back into view" {
    var f = Fx{};
    f.ui.focus_id = core.Context.idOf("ne") ^ 0x4E0D;
    f.frame();
    f.view.zoom = 1.9;
    f.view.x = -900;
    f.view.y = -900;
    f.ui.input = .{ .keys = keysOf(.F), .key_count = 1 };
    f.frame();
    try std.testing.expect(f.view.zoom <= 1.0 and f.view.zoom >= 0.25);
    try std.testing.expect(f.view.x > -900);
}

test "nodes: alt-drag pans the canvas and keeps the selection" {
    var f = Fx{};
    f.frame();
    const r = f.st.rect;
    // 空画布右侧中段（避开左下卡片与右下最小地图）
    const sx0 = r.x + r.w - 40;
    const sy0 = r.y + 120;
    const vx = f.view.x;
    f.ui.input = .{ .mouse = at(sx0, sy0), .pressed = true, .down = true, .mods = .{ .alt = true } };
    f.frame();
    f.ui.input = .{ .mouse = at(sx0 - 60, sy0 - 30), .down = true, .mods = .{ .alt = true } };
    f.frame();
    f.ui.input = .{ .mouse = at(sx0 - 60, sy0 - 30), .down = false, .mods = .{ .alt = true } };
    f.frame();
    try std.testing.expect(f.view.x < vx);
    try std.testing.expectEqual(@as(usize, 0), f.st.sel_n);
}

test "nodes: an empty editor stays idle and draws nothing" {
    var f = Fx{};
    f.ui.begin(600, 400);
    const built = nodes.editorBegin(&f.ui, "empty", &f.st, &f.view, .{ .height = 300 });
    nodes.editorEnd(&f.ui, &f.st);
    f.ui.paint();
    try std.testing.expect(built);
    try std.testing.expectEqual(@as(usize, 0), f.st.prev.node_n);
    try std.testing.expectEqual(nodes.Mode.idle, f.st.mode);
    try std.testing.expect(!f.ui.overflowed);
}

test "nodes: a hosted content panel gets widgets and restores the pointer" {
    var f = Fx{};
    const mx = f.ui.input.mouse.x;
    const my = f.ui.input.mouse.y;
    f.ui.begin(700, 480);
    _ = nodes.editorBegin(&f.ui, "host", &f.st, &f.view, .{ .height = 400, .grid = false });
    _ = nodes.nodeBegin(&f.ui, &f.st, 7, &f.xs[0], &f.ys[0], "Host", .{});
    nodes.contentBegin(&f.ui, &f.st, 40);
    _ = widgets.button(&f.ui, "Inside", .{});
    nodes.contentEnd(&f.ui, &f.st);
    nodes.nodeEnd(&f.ui, &f.st);
    nodes.editorEnd(&f.ui, &f.st);
    f.ui.paint();
    try std.testing.expectEqual(mx, f.ui.input.mouse.x);
    try std.testing.expectEqual(my, f.ui.input.mouse.y);
    try std.testing.expectEqual(@as(usize, 1), f.st.prev.node_n);
    try std.testing.expect(f.st.prev.nodes[0].h > 34);
}
