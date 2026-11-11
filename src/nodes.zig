//! 节点编辑器（对位 CUI `cui_nodes.c`）：画布上带引脚的卡片，用曲线连线。
//!
//! 调用方持有节点 / 引脚 / 连线；编辑器只负责画、拖动节点位置并汇报「连线建立 / 连线移除 /
//! 节点删除」三类事件。
//!
//! ```zig
//! if (nodes.editorBegin(ui, "graph", &st, &view, .{ .height = 480 })) {
//!     for (items) |*n| {
//!         _ = nodes.nodeBegin(ui, &st, n.id, &n.x, &n.y, n.title, .{});
//!         _ = nodes.nodeInput(ui, &st, n.in_pin, "Color", .{ .type = 1 });
//!         _ = nodes.nodeOutput(ui, &st, n.out_pin, "Result", .{ .type = 1 });
//!         nodes.nodeEnd(ui, &st);
//!     }
//!     for (links) |l| _ = nodes.nodeLink(ui, &st, l.id, l.from, l.to);
//!     var a: i32 = 0;
//!     var b: i32 = 0;
//!     while (nodes.linkCreated(&st, &a, &b)) addLink(a, b);
//!     nodes.editorEnd(ui, &st);
//! }
//! ```
//!
//! 交互：滚轮以指针为中心缩放（Shift+滚轮 / 横向滚轮平移）、**Alt+拖动**平移、拖卡片移动
//! （带上同选中的节点）、点击选中、Shift/Ctrl 加选、空画布拖出框选、从引脚拖出连线
//! （松手吸附最近的兼容引脚；从已连的输入引脚拖走会把线摘下来，一个输入只留一条）、
//! Delete 删除选中、`F` 框住全部、方向键移动选中、`+`/`-`/`0` 缩放、Esc 取消、点最小地图跳转。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **没有光标形状通道**，所以没有手型 / 移动光标；
//! - **框架没有中键通道、也没有「按住某键」的状态**（`Input.keys` 只表示本帧按下），
//!   CUI 的「中键拖 / 空格+拖」平移在 ZZUI 里换成 **Alt+拖动**；
//! - **连线走浮层通道**（`addOverlayLine` ⇒ 画在卡片之上），总段数上限 `MAX_WIRE_SEGS`；
//! - **没有弹簧动画**：拖动抬升、悬停渐变一律即时（不做 tween，省状态池）；
//! - **卡片高度帧末回填**（`rememberSize` / `knownSize`）：首帧用估计值，之后一直用真值 ——
//!   这是本框架既有的「帧末统一布局」形态，不是遗漏；
//! - **内容宿主按 100% 布局**（框架没有子树缩放）：指针在宿主内做反缩放映射，缩放到 50% 时
//!   内容控件尺寸不变、只跟着卡片走，超出卡片的部分被画布裁剪；
//! - **网格点有预算**：一屏最多 `GRID_DOTS` 个点，密集时自动放大步距（每点一个矩形，
//!   500+ 个会顶穿 `MAX_COMMANDS`）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const trace = @import("trace.zig");

pub const Tone = trace.Tone;

pub const MAX_NODES = 24;
pub const MAX_PINS = 40;
pub const MAX_LINKS = 32;
pub const MAX_SEL = 16;
pub const MAX_EVENTS = 8;
/// 每帧最多画多少段连线（浮层线预算 192，这里占大头，其余留给框选 / 最小地图）。
pub const MAX_WIRE_SEGS = 120;
/// 网格点上限（每点一个矩形，属于 `MAX_COMMANDS` 的预算）。
const GRID_DOTS = 140;

const HEAD_H: f32 = 34;
const ROW_H: f32 = 26;
const PAD_TOP: f32 = 6;
const PAD_BOT: f32 = 8;
const INSET: f32 = 14;
const PIN_R: f32 = 4.5;
const GRID: f32 = 24;
const SNAP: f32 = 18;
const DRAG: f32 = 3;
const NODE_W: f32 = 184;

pub const View = struct { x: f32 = 0, y: f32 = 0, zoom: f32 = 1 };

pub const EditorOpts = struct {
    width: f32 = 0,
    height: f32 = 440,
    min_zoom: f32 = 0.25,
    max_zoom: f32 = 2.0,
    grid: bool = true,
    minimap: bool = false,
};

pub const NodeOpts = struct {
    width: f32 = NODE_W,
};

pub const PinOpts = struct {
    /// 0 = 任意类型都能连；其余按类型配对（颜色也从类型来）。
    type: u8 = 0,
};

const Kind = enum { in, out };
pub const Mode = enum { idle, pan, pend_drag, drag, pend_marquee, marquee, wire, minimap };

const NodeRec = struct { id: i32 = 0, x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
const PinRec = struct { pin: i32 = 0, node: i32 = 0, kind: Kind = .in, type: u8 = 0, x: f32 = 0, y: f32 = 0 };
const LinkRec = struct { id: i32 = 0, from: i32 = 0, to: i32 = 0 };

const Set = struct {
    nodes: [MAX_NODES]NodeRec = @splat(.{}),
    node_n: usize = 0,
    pins: [MAX_PINS]PinRec = @splat(.{}),
    pin_n: usize = 0,
    links: [MAX_LINKS]LinkRec = @splat(.{}),
    link_n: usize = 0,
};

const Minimap = struct {
    valid: bool = false,
    rect: t.Rect = .{},
    s: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    bx: f32 = 0,
    by: f32 = 0,
};

pub const State = struct {
    /// 上一帧快照（本帧的命中判定用它）。
    prev: Set = .{},
    /// 本帧构建出来的快照（帧末 swap 进 `prev`）。
    cur: Set = .{},

    sel: [MAX_SEL]i32 = @splat(0),
    sel_n: usize = 0,
    mq_base: [MAX_SEL]i32 = @splat(0),
    mq_base_n: usize = 0,
    sel_link: i32 = -1,
    link_selected: bool = false,

    mode: Mode = .idle,
    press_x: f32 = 0,
    press_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    press_node: i32 = -1,
    press_mod: bool = false,
    press_was_sel: bool = false,

    mq_x0: f32 = 0,
    mq_y0: f32 = 0,
    mq_x1: f32 = 0,
    mq_y1: f32 = 0,

    wire_pin: i32 = 0,
    wire_kind: Kind = .in,
    wire_type: u8 = 0,
    wire_node: i32 = 0,
    wire_link: i32 = 0,
    wire_orig: i32 = 0,
    wire_detached: bool = false,
    has_target: bool = false,
    target_pin: i32 = 0,

    ev_new: [MAX_EVENTS * 2]i32 = @splat(0),
    ev_new_n: usize = 0,
    ev_new_read: usize = 0,
    ev_rm: [MAX_EVENTS]i32 = @splat(0),
    ev_rm_n: usize = 0,
    ev_rm_read: usize = 0,
    ev_del: [MAX_EVENTS]i32 = @splat(0),
    ev_del_n: usize = 0,
    ev_del_read: usize = 0,

    move_dx: f32 = 0,
    move_dy: f32 = 0,
    frame_all: bool = false,

    // ---- 构建期临时字段（不要跨帧依赖）
    in_node: bool = false,
    node_id: i32 = 0,
    node_x: f32 = 0,
    node_y: f32 = 0,
    node_w: f32 = 0,
    row_y: f32 = 0,
    row_n_card: usize = 0,
    card_sx: f32 = 0,
    card_sy: f32 = 0,
    in_content: bool = false,
    content_scope: core.Scope = undefined,
    saved_mx: f32 = 0,
    saved_my: f32 = 0,

    // ---- 编辑器上下文
    editing: bool = false,
    rect: t.Rect = .{},
    ox: f32 = 0,
    oy: f32 = 0,
    z: f32 = 1,
    view: View = .{},
    min_zoom: f32 = 0.25,
    max_zoom: f32 = 2,
    grid: bool = true,
    minimap: bool = false,
    consumed: bool = false,
    saved_clip: ?t.Rect = null,
    mm: Minimap = .{},
    // 本帧输入快照（手势函数只读这些）
    down: bool = false,
    pressed: bool = false,
    add_mod: bool = false,
    pan_mod: bool = false,
};

// ---------------------------------------------------------------- 小工具

fn typeColor(k: u8) t.Color {
    if (k == 0) return theme.secondary;
    return switch ((k - 1) % 6) {
        0 => trace.toneColor(.info),
        1 => trace.toneColor(.success),
        2 => trace.toneColor(.warn),
        3 => trace.toneColor(.violet),
        4 => trace.toneColor(.teal),
        else => trace.toneColor(.danger),
    };
}

fn hasNode(set: *const Set, id: i32) bool {
    for (set.nodes[0..set.node_n]) |n| {
        if (n.id == id) return true;
    }
    return false;
}

fn findPin(set: *const Set, pin: i32) ?*const PinRec {
    for (set.pins[0..set.pin_n]) |*p| {
        if (p.pin == pin) return p;
    }
    return null;
}

fn selHas(st: *const State, id: i32) bool {
    for (st.sel[0..st.sel_n]) |v| {
        if (v == id) return true;
    }
    return false;
}

fn selAdd(st: *State, id: i32) void {
    if (st.sel_n >= MAX_SEL or selHas(st, id)) return;
    st.sel[st.sel_n] = id;
    st.sel_n += 1;
}

fn selRemove(st: *State, id: i32) void {
    var i: usize = 0;
    while (i < st.sel_n) : (i += 1) {
        if (st.sel[i] == id) {
            st.sel[i] = st.sel[st.sel_n - 1];
            st.sel_n -= 1;
            return;
        }
    }
}

fn selOnly(st: *State, id: i32) void {
    st.sel_n = 0;
    selAdd(st, id);
    st.link_selected = false;
}

fn sx(st: *const State, x: f32) f32 {
    return st.ox + x * st.z;
}

fn sy(st: *const State, y: f32) f32 {
    return st.oy + y * st.z;
}

fn canvasX(st: *const State, x: f32) f32 {
    return (x - st.ox) / st.z;
}

fn canvasY(st: *const State, y: f32) f32 {
    return (y - st.oy) / st.z;
}

fn nodeKey(kind: u64, id: i32) u64 {
    return core.Context.idOf("ne") ^ (kind *% 0x9E3779B1) ^ (@as(u64, @intCast(@as(u32, @bitCast(id)))) *% 0xC0DE);
}

fn clipText(ui: *core.Context, s: []const u8, size: f32, max_w: f32) []const u8 {
    if (s.len == 0 or max_w <= 12) return "";
    if (ui.measureText(s, size).w <= max_w) return s;
    var take: usize = @min(s.len, 48);
    while (take > 0) : (take -= 1) {
        var n = take;
        while (n > 0 and (s[n - 1] & 0xC0) == 0x80) n -= 1;
        var buf: [56]u8 = undefined;
        if (n + 3 <= buf.len) {
            @memcpy(buf[0..n], s[0..n]);
            buf[n] = '.';
            buf[n + 1] = '.';
            buf[n + 2] = '.';
            if (ui.measureText(buf[0 .. n + 3], size).w <= max_w) return ui.frameStr(buf[0 .. n + 3]);
        }
    }
    return "";
}

/// 连线的三次贝塞尔采样点（两端水平出入），返回条数。
fn wirePoints(a: t.Point, d: t.Point, z: f32, out: []t.Point) usize {
    if (out.len < 2) return 0;
    const dx = d.x - a.x;
    const dy = d.y - a.y;
    var k = @max(@abs(dx) * 0.5, @min(40.0 * z, @sqrt(dx * dx + dy * dy) * 0.5));
    if (dx < 0) k = @max(k, @min(@abs(dx) * 0.5 + @abs(dy) * 0.25, 160.0 * z));
    const b = t.Point{ .x = a.x + k, .y = a.y };
    const c = t.Point{ .x = d.x - k, .y = d.y };
    const len = @sqrt(dx * dx + dy * dy) + 2 * k;
    const max_n: f32 = @floatFromInt(out.len - 1);
    const n: usize = @intFromFloat(std.math.clamp(len / 5.0, 12.0, max_n));
    var i: usize = 0;
    while (i <= n) : (i += 1) {
        const tt = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const u = 1 - tt;
        const w0 = u * u * u;
        const w1 = 3 * u * u * tt;
        const w2 = 3 * u * tt * tt;
        const w3 = tt * tt * tt;
        out[i] = .{
            .x = w0 * a.x + w1 * b.x + w2 * c.x + w3 * d.x,
            .y = w0 * a.y + w1 * b.y + w2 * c.y + w3 * d.y,
        };
    }
    return n + 1;
}

fn segDist(p: t.Point, a: t.Point, b: t.Point) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = p.x - a.x;
    const wy = p.y - a.y;
    const l2 = vx * vx + vy * vy;
    var tt: f32 = 0;
    if (l2 > 0) tt = std.math.clamp((wx * vx + wy * vy) / l2, 0, 1);
    const ex = a.x + vx * tt - p.x;
    const ey = a.y + vy * tt - p.y;
    return @sqrt(ex * ex + ey * ey);
}

fn wireThickness(z: f32) f32 {
    return std.math.clamp(1.75 * z, 1.1, 3.0);
}

fn zoomAt(st: *State, nz: f32, screen_x: f32, screen_y: f32) void {
    const z = std.math.clamp(nz, st.min_zoom, st.max_zoom);
    const cx = canvasX(st, screen_x);
    const cy = canvasY(st, screen_y);
    st.view.x = screen_x - st.rect.x - cx * z;
    st.view.y = screen_y - st.rect.y - cy * z;
    st.view.zoom = z;
    st.z = z;
    st.ox = st.rect.x + st.view.x;
    st.oy = st.rect.y + st.view.y;
}

/// 指针是否落在**本节点**上一帧的某个引脚命中区里（引脚注册在卡片之后，
/// 但卡片的按下处理先跑；不同位就会把「拖线」误判成「拖卡片」）。
fn pinAtPrev(st: *const State, node: i32, mx: f32, my: f32) bool {
    for (st.prev.pins[0..st.prev.pin_n]) |p| {
        if (p.node != node) continue;
        if (@abs(mx - sx(st, p.x)) <= 9 and @abs(my - sy(st, p.y)) <= 9) return true;
    }
    return false;
}

/// 上一帧的卡片 / 引脚是否盖住了这个屏幕点（决定空画布手势要不要启动）。
fn overCardOrPin(st: *const State, mx: f32, my: f32) bool {
    for (st.prev.nodes[0..st.prev.node_n]) |n| {
        const x = sx(st, n.x);
        const y = sy(st, n.y);
        if (mx >= x and mx <= x + n.w * st.z and my >= y and my <= y + n.h * st.z) return true;
    }
    for (st.prev.pins[0..st.prev.pin_n]) |p| {
        if (@abs(mx - sx(st, p.x)) <= 9 and @abs(my - sy(st, p.y)) <= 9) return true;
    }
    return false;
}

// ---------------------------------------------------------------- 事件

fn pushDel(st: *State, id: i32) void {
    if (st.ev_del_n >= MAX_EVENTS) return;
    st.ev_del[st.ev_del_n] = id;
    st.ev_del_n += 1;
}

fn pushRm(st: *State, id: i32) void {
    if (st.ev_rm_n >= MAX_EVENTS) return;
    for (st.ev_rm[0..st.ev_rm_n]) |v| {
        if (v == id) return;
    }
    st.ev_rm[st.ev_rm_n] = id;
    st.ev_rm_n += 1;
}

fn pushNew(st: *State, from: i32, to: i32) void {
    if (st.ev_new_n + 2 > st.ev_new.len) return;
    st.ev_new[st.ev_new_n] = from;
    st.ev_new[st.ev_new_n + 1] = to;
    st.ev_new_n += 2;
}

/// 删掉选中节点（以及挂在它们身上的连线）。
fn deleteSelection(st: *State) void {
    for (st.sel[0..st.sel_n]) |id| {
        if (hasNode(&st.prev, id)) pushDel(st, id);
    }
    for (st.prev.links[0..st.prev.link_n]) |l| {
        const pa = findPin(&st.prev, l.from);
        const pd = findPin(&st.prev, l.to);
        const touched = (pa != null and selHas(st, pa.?.node)) or (pd != null and selHas(st, pd.?.node));
        if (touched or (st.link_selected and st.sel_link == l.id)) pushRm(st, l.id);
    }
    st.sel_n = 0;
    st.link_selected = false;
}

/// 松手时结算正在拖的线。
fn finishWire(st: *State) void {
    const dx = st.last_x - st.press_x;
    const dy = st.last_y - st.press_y;
    if (dx * dx + dy * dy < DRAG * DRAG) return; // 点一下引脚不算操作
    const tgt: ?*const PinRec = if (st.has_target) findPin(&st.prev, st.target_pin) else null;
    if (st.wire_detached) {
        if (tgt != null and tgt.?.pin == st.wire_orig) return; // 放回原位
        pushRm(st, st.wire_link);
    }
    const tp = tgt orelse return;
    const out = if (st.wire_kind == .out) st.wire_pin else tp.pin;
    const in = if (st.wire_kind == .out) tp.pin else st.wire_pin;
    var dup = false;
    for (st.prev.links[0..st.prev.link_n]) |l| {
        if (st.wire_detached and l.id == st.wire_link) continue;
        if (l.to == in and l.from == out) {
            dup = true;
        } else if (l.to == in) {
            pushRm(st, l.id); // 一个输入只接一条线
        }
    }
    if (!dup) pushNew(st, out, in);
}

fn compatible(st: *const State, p: *const PinRec) bool {
    if (p.kind == st.wire_kind or p.node == st.wire_node) return false;
    return st.wire_type == 0 or p.type == 0 or p.type == st.wire_type;
}

/// 屏幕点上最近的连线（5pt 以内），返回它在 `prev.links` 里的下标。
fn linkAtP(st: *const State, mx: f32, my: f32) i32 {
    var best: f32 = 5;
    var hit: i32 = -1;
    var pts: [40]t.Point = undefined;
    for (st.prev.links[0..st.prev.link_n], 0..) |l, idx| {
        const pa = findPin(&st.prev, l.from) orelse continue;
        const pd = findPin(&st.prev, l.to) orelse continue;
        const n = wirePoints(
            .{ .x = sx(st, pa.x), .y = sy(st, pa.y) },
            .{ .x = sx(st, pd.x), .y = sy(st, pd.y) },
            st.z,
            pts[0..],
        );
        var k: usize = 0;
        while (k + 1 < n) : (k += 1) {
            const d = segDist(.{ .x = mx, .y = my }, pts[k], pts[k + 1]);
            if (d < best) {
                best = d;
                hit = @intCast(idx);
            }
        }
    }
    return hit;
}

// ---------------------------------------------------------------- 手势

fn dragNodes(st: *State, mx: f32, my: f32) void {
    if (st.mode == .pend_drag and st.down) {
        const dx = mx - st.press_x;
        const dy = my - st.press_y;
        if (dx * dx + dy * dy > DRAG * DRAG) st.mode = .drag;
    }
    if (st.mode == .drag) {
        st.move_dx += (mx - st.last_x) / st.z;
        st.move_dy += (my - st.last_y) / st.z;
    }
    st.last_x = mx;
    st.last_y = my;
    if (!st.down) {
        // 在多选里点其中一个（不按修饰键）→ 只留它
        if (st.mode == .pend_drag and !st.press_mod and st.press_was_sel) selOnly(st, st.press_node);
        st.mode = .idle;
    }
}

fn marqueeMove(st: *State, mx: f32, my: f32) void {
    if (st.mode == .pend_marquee and st.down) {
        const dx = mx - st.press_x;
        const dy = my - st.press_y;
        if (dx * dx + dy * dy > DRAG * DRAG) st.mode = .marquee;
    }
    st.mq_x1 = canvasX(st, mx);
    st.mq_y1 = canvasY(st, my);
    if (st.mode == .marquee) {
        const x0 = @min(st.mq_x0, st.mq_x1);
        const y0 = @min(st.mq_y0, st.mq_y1);
        const x1 = @max(st.mq_x0, st.mq_x1);
        const y1 = @max(st.mq_y0, st.mq_y1);
        st.sel_n = 0;
        for (st.mq_base[0..st.mq_base_n]) |id| selAdd(st, id);
        for (st.prev.nodes[0..st.prev.node_n]) |n| {
            const hit = n.x < x1 and n.x + n.w > x0 and n.y < y1 and n.y + n.h > y0;
            if (hit) selAdd(st, n.id);
        }
    }
    if (!st.down) st.mode = .idle;
}

fn wireMove(st: *State, mx: f32, my: f32) void {
    st.last_x = mx;
    st.last_y = my;
    st.has_target = false;
    var best = SNAP;
    for (st.prev.pins[0..st.prev.pin_n]) |p| {
        if (!compatible(st, &p)) continue;
        const px = sx(st, p.x);
        const py = sy(st, p.y);
        const dd = @sqrt((px - mx) * (px - mx) + (py - my) * (py - my));
        if (dd < best) {
            best = dd;
            st.has_target = true;
            st.target_pin = p.pin;
        }
    }
    if (!st.down) {
        finishWire(st);
        st.mode = .idle;
        st.has_target = false;
    }
}

fn gesture(st: *State, mx: f32, my: f32, over: bool) void {
    switch (st.mode) {
        .pan => {
            if (!st.down) {
                st.mode = .idle;
                return;
            }
            st.view.x += mx - st.last_x;
            st.view.y += my - st.last_y;
            st.ox = st.rect.x + st.view.x;
            st.oy = st.rect.y + st.view.y;
            st.last_x = mx;
            st.last_y = my;
        },
        .pend_drag, .drag => dragNodes(st, mx, my),
        .pend_marquee, .marquee => marqueeMove(st, mx, my),
        .wire => wireMove(st, mx, my),
        .minimap => {
            if (!st.down) {
                st.mode = .idle;
                return;
            }
            if (st.mm.valid and st.mm.s > 0) {
                const cx = st.mm.bx + (mx - st.mm.x) / st.mm.s;
                const cy = st.mm.by + (my - st.mm.y) / st.mm.s;
                st.view.x = st.rect.w * 0.5 - cx * st.z;
                st.view.y = st.rect.h * 0.5 - cy * st.z;
                st.ox = st.rect.x + st.view.x;
                st.oy = st.rect.y + st.view.y;
            }
        },
        .idle => {
            if (!over or !st.pressed) return;
            // 最小地图（用上一帧画出来的映射）
            if (st.mm.valid and st.mm.rect.contains(mx, my)) {
                st.mode = .minimap;
                st.consumed = true;
                return;
            }
            if (overCardOrPin(st, mx, my)) return;
            if (st.pan_mod) {
                st.mode = .pan;
                st.last_x = mx;
                st.last_y = my;
                st.consumed = true;
                return;
            }
            // 空画布按下：命中连线就选中它，否则开始框选
            st.consumed = true;
            const hitl = linkAtP(st, mx, my);
            if (hitl >= 0) {
                if (!st.add_mod) st.sel_n = 0;
                st.link_selected = true;
                st.sel_link = st.prev.links[@intCast(hitl)].id;
            } else {
                st.link_selected = false;
                st.mq_base_n = 0;
                if (st.add_mod) {
                    for (st.sel[0..st.sel_n]) |id| {
                        if (st.mq_base_n < MAX_SEL) {
                            st.mq_base[st.mq_base_n] = id;
                            st.mq_base_n += 1;
                        }
                    }
                } else st.sel_n = 0;
                st.mode = .pend_marquee;
                st.press_x = mx;
                st.press_y = my;
                st.mq_x0 = canvasX(st, mx);
                st.mq_y0 = canvasY(st, my);
                st.mq_x1 = st.mq_x0;
                st.mq_y1 = st.mq_y0;
            }
        },
    }
}

/// 缩放平移让所有节点都进视野（最多 100%）。
fn frameAll(st: *State) void {
    if (st.prev.node_n == 0) return;
    var bx0: f32 = 1e9;
    var by0: f32 = 1e9;
    var bx1: f32 = -1e9;
    var by1: f32 = -1e9;
    for (st.prev.nodes[0..st.prev.node_n]) |n| {
        bx0 = @min(bx0, n.x);
        by0 = @min(by0, n.y);
        bx1 = @max(bx1, n.x + n.w);
        by1 = @max(by1, n.y + n.h);
    }
    const m: f32 = 40;
    var nz = @min((st.rect.w - 2 * m) / @max(1, bx1 - bx0), (st.rect.h - 2 * m) / @max(1, by1 - by0));
    nz = std.math.clamp(@min(nz, 1), st.min_zoom, st.max_zoom);
    st.view.zoom = nz;
    st.z = nz;
    st.view.x = st.rect.w * 0.5 - (bx0 + bx1) * 0.5 * nz;
    st.view.y = st.rect.h * 0.5 - (by0 + by1) * 0.5 * nz;
    st.ox = st.rect.x + st.view.x;
    st.oy = st.rect.y + st.view.y;
}

// ---------------------------------------------------------------- 绘制

fn drawGrid(ui: *core.Context, st: *const State) void {
    if (!st.grid) return;
    var step = GRID * st.z;
    if (step < 8) step = 8;
    // 点数预算：密集就放大步距（每点一个矩形，属于 MAX_COMMANDS 的预算）
    while (step < 480) {
        const cols = st.rect.w / step;
        const rows = st.rect.h / step;
        if (cols * rows <= GRID_DOTS) break;
        step *= 1.5;
    }
    const a: u8 = if (theme.isDark()) 120 else 90;
    const dot = theme.withAlpha(theme.secondary, a);
    var y = st.oy + @ceil((st.rect.y - st.oy) / step) * step;
    while (y < st.rect.y + st.rect.h) : (y += step) {
        var x = st.ox + @ceil((st.rect.x - st.ox) / step) * step;
        while (x < st.rect.x + st.rect.w) : (x += step) {
            // 2×2 而不是 1×1：软件光栅不做抗锯齿，亚像素小点会整颗消失
            ui.addBox(.{ .x = x - 1, .y = y - 1, .w = 2, .h = 2 }, .{ .fill = dot });
        }
    }
}

fn drawWirePath(ui: *core.Context, st: *const State, a: t.Point, d: t.Point, thick: f32, c: t.Color, budget: *usize) void {
    var pts: [36]t.Point = undefined;
    const n = wirePoints(a, d, st.z, pts[0..]);
    var i: usize = 0;
    while (i + 1 < n and budget.* > 0) : (i += 1) {
        ui.addOverlayLine(pts[i], pts[i + 1], thick, c);
        budget.* -= 1;
    }
}

fn drawWires(ui: *core.Context, st: *const State) void {
    var budget: usize = MAX_WIRE_SEGS;
    const th = wireThickness(st.z);
    for (st.cur.links[0..st.cur.link_n]) |l| {
        if (st.mode == .wire and st.wire_detached and l.id == st.wire_link) continue;
        const pa = findPin(&st.cur, l.from) orelse continue;
        const pd = findPin(&st.cur, l.to) orelse continue;
        const sel = st.link_selected and st.sel_link == l.id;
        const c = if (sel) theme.accent else theme.withAlpha(typeColor(pa.type), 220);
        drawWirePath(ui, st, .{ .x = sx(st, pa.x), .y = sy(st, pa.y) }, .{ .x = sx(st, pd.x), .y = sy(st, pd.y) }, if (sel) th + 0.5 else th, c, &budget);
    }
}

fn drawMinimap(ui: *core.Context, st: *State) void {
    const r = st.rect;
    const k = std.math.clamp(r.w * 0.28 / 168.0, 0.5, 1.0);
    const mw = 168 * k;
    const mh = 108 * k;
    const mm = t.Rect{ .x = r.x + r.w - mw - 12, .y = r.y + r.h - mh - 12, .w = mw, .h = mh };
    if (mm.x <= r.x + 12 or mm.y <= r.y + 12) return;
    var bx0: f32 = 1e9;
    var by0: f32 = 1e9;
    var bx1: f32 = -1e9;
    var by1: f32 = -1e9;
    for (st.cur.nodes[0..st.cur.node_n]) |n| {
        bx0 = @min(bx0, n.x);
        by0 = @min(by0, n.y);
        bx1 = @max(bx1, n.x + n.w);
        by1 = @max(by1, n.y + n.h);
    }
    const vx0 = canvasX(st, r.x);
    const vy0 = canvasY(st, r.y);
    const vx1 = vx0 + r.w / st.z;
    const vy1 = vy0 + r.h / st.z;
    bx0 = @min(bx0, vx0);
    by0 = @min(by0, vy0);
    bx1 = @max(bx1, vx1);
    by1 = @max(by1, vy1);
    const pad: f32 = 8;
    const s = @min((mw - 2 * pad) / @max(1, bx1 - bx0), (mh - 2 * pad) / @max(1, by1 - by0));
    const offx = mm.x + pad + ((mw - 2 * pad) - (bx1 - bx0) * s) * 0.5;
    const offy = mm.y + pad + ((mh - 2 * pad) - (by1 - by0) * s) * 0.5;
    st.mm = .{ .valid = true, .rect = mm, .s = s, .x = offx, .y = offy, .bx = bx0, .by = by0 };

    ui.addOverlayBox(mm, .{ .fill = theme.surface, .border = theme.border, .radius = 6 });
    for (st.cur.nodes[0..st.cur.node_n]) |n| {
        const q = t.Rect{
            .x = offx + (n.x - bx0) * s,
            .y = offy + (n.y - by0) * s,
            .w = @max(2, n.w * s),
            .h = @max(2, n.h * s),
        };
        ui.addOverlayBox(q, .{
            .fill = if (selHas(st, n.id)) theme.withAlpha(theme.accent, 180) else theme.withAlpha(theme.secondary, 110),
            .radius = 1.5,
        });
    }
    const vr = t.Rect{
        .x = offx + (vx0 - bx0) * s,
        .y = offy + (vy0 - by0) * s,
        .w = (vx1 - vx0) * s,
        .h = (vy1 - vy0) * s,
    };
    ui.addOverlayBox(vr, .{ .fill = theme.withAlpha(theme.text, 8), .border = theme.withAlpha(theme.text, 80), .radius = 2 });
}

// ---------------------------------------------------------------- 编辑器

/// 开始一个编辑器（与 `editorEnd` 成对；不嵌套）。
pub fn editorBegin(ui: *core.Context, id: []const u8, st: *State, view: *View, opts: EditorOpts) bool {
    if (st.editing) return false; // 不允许嵌套
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 640;
    const h = if (opts.height > 0) opts.height else 440;
    const rect = ui.reserve(w, h, opts.width <= 0);
    ui.addBox(rect, .{
        .fill = if (theme.isDark()) theme.withAlpha(theme.surface, 210) else theme.track,
        .radius = 10,
        .border = theme.border,
    });

    st.editing = true;
    st.rect = rect;
    st.min_zoom = if (opts.min_zoom > 0) opts.min_zoom else 0.25;
    st.max_zoom = if (opts.max_zoom > st.min_zoom) opts.max_zoom else @max(2.0, st.min_zoom);
    st.grid = opts.grid;
    st.minimap = opts.minimap;
    if (view.zoom <= 0) view.zoom = 1;
    view.zoom = std.math.clamp(view.zoom, st.min_zoom, st.max_zoom);
    st.view = view.*;
    st.z = view.zoom;
    st.ox = rect.x + view.x;
    st.oy = rect.y + view.y;
    st.saved_clip = ui.clip;
    ui.clip = .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 };

    // 本帧缓冲与事件清零
    st.cur.node_n = 0;
    st.cur.pin_n = 0;
    st.cur.link_n = 0;
    st.ev_new_n = 0;
    st.ev_new_read = 0;
    st.ev_rm_n = 0;
    st.ev_rm_read = 0;
    st.ev_del_n = 0;
    st.ev_del_read = 0;
    st.move_dx = 0;
    st.move_dy = 0;

    // 输入快照（手势函数只读这些）
    st.down = ui.input.down;
    st.pressed = ui.input.pressed;
    st.add_mod = ui.input.mods.shift or ui.input.mods.ctrl;
    st.pan_mod = ui.input.mods.alt;
    st.consumed = false;

    const panel_id = core.Context.idOf(id) ^ 0x4E0D;
    const hit = ui.interactEx(panel_id, rect, true);
    const mx = ui.input.mouse.x;
    const my = ui.input.mouse.y;
    const over = rect.contains(mx, my);

    // 滚轮：以指针为中心缩放；Shift 或横向滚轮平移
    if (over and ui.input.wheel != 0) {
        if (ui.input.mods.shift) {
            st.view.x += ui.input.wheel * 40;
            st.ox = rect.x + st.view.x;
        } else {
            zoomAt(st, st.z * std.math.pow(f32, 1.12, ui.input.wheel), mx, my);
        }
        ui.requestFrame();
    }

    // 键盘（编辑器获得焦点时）
    if (hit.focused) {
        const prim = ui.input.mods.ctrl;
        if (ui.input.keyPressed(.delete) or ui.input.keyPressed(.backspace)) deleteSelection(st);
        if (ui.input.keyPressed(.F) and !prim) st.frame_all = true;
        if (prim and ui.input.keyPressed(.A)) {
            st.sel_n = 0;
            for (st.prev.nodes[0..st.prev.node_n]) |n| selAdd(st, n.id);
        }
        if (ui.input.keyPressed(.escape)) {
            if (st.mode == .wire or st.mode == .marquee) {
                st.mode = .idle;
            } else {
                st.sel_n = 0;
                st.link_selected = false;
            }
        }
        if (st.sel_n > 0) {
            const step: f32 = if (ui.input.mods.shift) 1 else 10;
            if (ui.input.keyPressed(.left)) st.move_dx -= step;
            if (ui.input.keyPressed(.right)) st.move_dx += step;
            if (ui.input.keyPressed(.up)) st.move_dy -= step;
            if (ui.input.keyPressed(.down)) st.move_dy += step;
        }
        const cx = rect.x + rect.w * 0.5;
        const cy = rect.y + rect.h * 0.5;
        if (ui.input.keyPressed(.equal)) zoomAt(st, st.z * 1.25, cx, cy);
        if (ui.input.keyPressed(.minus)) zoomAt(st, st.z / 1.25, cx, cy);
        if (ui.input.keyPressed(.digit0)) zoomAt(st, 1.0, cx, cy);
    }
    if (st.frame_all) {
        st.frame_all = false;
        frameAll(st);
    }

    gesture(st, mx, my, over);
    // 手势可能改了平移 / 缩放，写回调用方的 view
    view.* = st.view;
    st.ox = rect.x + st.view.x;
    st.oy = rect.y + st.view.y;

    drawGrid(ui, st);
    return true;
}

/// 结束编辑器：画连线与浮层（拖动中的线 / 框选 / 最小地图），swap 快照。
pub fn editorEnd(ui: *core.Context, st: *State) void {
    if (!st.editing) return;
    st.editing = false;
    if (st.in_node) nodeEnd(ui, st);
    if (st.in_content) contentEnd(ui, st);

    // 连线（浮层通道：画在卡片之上）
    drawWires(ui, st);

    // 拖动中的线
    if (st.mode == .wire) {
        if (findPin(&st.cur, st.wire_pin)) |src| {
            const a = t.Point{ .x = sx(st, src.x), .y = sy(st, src.y) };
            var m = t.Point{ .x = ui.input.mouse.x, .y = ui.input.mouse.y };
            var has = false;
            if (st.has_target) {
                if (findPin(&st.cur, st.target_pin)) |tp| {
                    m = .{ .x = sx(st, tp.x), .y = sy(st, tp.y) };
                    has = true;
                }
            }
            var budget: usize = 30;
            const th = wireThickness(st.z);
            if (src.kind == .out) {
                drawWirePath(ui, st, a, m, th, theme.accent, &budget);
            } else {
                drawWirePath(ui, st, m, a, th, theme.accent, &budget);
            }
            if (!has) ui.addOverlayBox(.{ .x = m.x - 3, .y = m.y - 3, .w = 6, .h = 6 }, .{ .fill = theme.accent, .radius = 3 });
        }
    }
    // 框选
    if (st.mode == .marquee) {
        const x0 = sx(st, @min(st.mq_x0, st.mq_x1));
        const y0 = sy(st, @min(st.mq_y0, st.mq_y1));
        const x1 = sx(st, @max(st.mq_x0, st.mq_x1));
        const y1 = sy(st, @max(st.mq_y0, st.mq_y1));
        ui.addOverlayBox(.{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 }, .{
            .fill = theme.withAlpha(theme.accent, 26),
            .border = theme.withAlpha(theme.accent, 140),
            .radius = 2,
        });
    }
    // 最小地图（本帧重画一遍，映射留给下一帧命中）
    st.mm = .{};
    if (st.minimap and st.cur.node_n > 0) drawMinimap(ui, st);

    // 还原裁剪
    const saved = st.saved_clip;
    st.saved_clip = null;
    ui.clip = saved;

    // swap：本帧快照成为下一帧的「上一帧」
    st.prev = st.cur;
    // 丢掉已经不存在的选中项与选中连线
    var i: usize = st.sel_n;
    while (i > 0) {
        i -= 1;
        if (!hasNode(&st.prev, st.sel[i])) {
            st.sel[i] = st.sel[st.sel_n - 1];
            st.sel_n -= 1;
        }
    }
    if (st.link_selected) {
        var found = false;
        for (st.prev.links[0..st.prev.link_n]) |l| {
            if (l.id == st.sel_link) found = true;
        }
        if (!found) st.link_selected = false;
    }
    if (st.mode == .wire and findPin(&st.prev, st.wire_pin) == null) st.mode = .idle;
}

// ---------------------------------------------------------------- 节点

/// 开始一张节点卡片。返回该节点本帧是否被选中。
pub fn nodeBegin(ui: *core.Context, st: *State, node_id: i32, x: *f32, y: *f32, title: []const u8, opts: NodeOpts) bool {
    if (!st.editing or st.in_node) return false;
    var selected = selHas(st, node_id);
    if (selected and (st.move_dx != 0 or st.move_dy != 0)) {
        x.* += st.move_dx;
        y.* += st.move_dy;
    }
    const w = if (opts.width > 0) opts.width else NODE_W;
    const prev_size = ui.knownSize(nodeKey(0x51, node_id));
    const est_h = if (prev_size) |s| s.h else HEAD_H + 2;

    const card_rect = t.Rect{ .x = sx(st, x.*), .y = sy(st, y.*), .w = w * st.z, .h = est_h * st.z };
    const cid = nodeKey(0x71, node_id);
    const hit = ui.interactEx(cid, card_rect, true);

    if (hit.hover and ui.input.pressed and !st.consumed and st.mode == .idle and
        !pinAtPrev(st, node_id, ui.input.mouse.x, ui.input.mouse.y))
    {
        st.consumed = true;
        const toggle = ui.input.mods.ctrl;
        const add = ui.input.mods.shift;
        st.press_was_sel = selected;
        st.press_mod = toggle or add;
        if (toggle and selected) {
            selRemove(st, node_id);
        } else if ((toggle or add) and !selected) {
            selAdd(st, node_id);
        } else if (!selected) {
            selOnly(st, node_id);
        }
        st.link_selected = false;
        selected = selHas(st, node_id);
        if (selected) {
            st.mode = .pend_drag;
            st.press_node = node_id;
            st.press_x = ui.input.mouse.x;
            st.press_y = ui.input.mouse.y;
            st.last_x = st.press_x;
            st.last_y = st.press_y;
        }
    }
    if (hit.focused and !selected) {
        selOnly(st, node_id);
        selected = true;
    }

    // 卡片背景 + 标题
    ui.addBox(card_rect, .{
        .fill = if (theme.isDark()) theme.raised else theme.surface,
        .radius = theme.radius_control * st.z,
        .border = if (selected) theme.accent else if (hit.hover) theme.withAlpha(theme.secondary, 160) else theme.border,
        .border_width = if (selected) 1.5 else 1,
    });
    const ts = theme.font_body * st.z;
    if (ts >= 4) {
        ui.addText(.{
            .x = card_rect.x + 12 * st.z,
            .y = card_rect.y + (HEAD_H * st.z - ts * 1.4) * 0.5,
            .w = @max(8, card_rect.w - 24 * st.z),
            .h = ts * 1.6,
        }, clipText(ui, title, ts, card_rect.w - 24 * st.z), ts, theme.text);
    }
    if (HEAD_H * st.z > 2) {
        ui.addBox(.{ .x = card_rect.x + 1, .y = card_rect.y + HEAD_H * st.z, .w = @max(0, card_rect.w - 2), .h = 1 }, .{ .fill = theme.border });
    }

    st.in_node = true;
    st.node_id = node_id;
    st.node_x = x.*;
    st.node_y = y.*;
    st.node_w = w;
    st.row_y = HEAD_H + PAD_TOP;
    st.row_n_card = 0;
    st.card_sx = card_rect.x;
    st.card_sy = card_rect.y;
    return selected;
}

pub fn nodeEnd(ui: *core.Context, st: *State) void {
    if (!st.in_node) return;
    if (st.in_content) contentEnd(ui, st);
    st.in_node = false;
    const h = if (st.row_n_card == 0) HEAD_H + 2 else st.row_y + PAD_BOT;
    ui.rememberSize(nodeKey(0x51, st.node_id), st.node_w, h);
    if (st.cur.node_n < st.cur.nodes.len) {
        st.cur.nodes[st.cur.node_n] = .{ .id = st.node_id, .x = st.node_x, .y = st.node_y, .w = st.node_w, .h = h };
        st.cur.node_n += 1;
    }
}

fn pinRow(ui: *core.Context, st: *State, pin: i32, label: []const u8, opts: PinOpts, kind: Kind) bool {
    if (!st.in_node or st.in_content) return false;
    var connected = false;
    for (st.prev.links[0..st.prev.link_n]) |l| {
        const side = if (kind == .in) l.to else l.from;
        if (side == pin and !(st.mode == .wire and st.wire_detached and l.id == st.wire_link)) connected = true;
    }
    const cy_canvas = st.row_y + ROW_H * 0.5;
    const cx_canvas: f32 = if (kind == .in) 0 else st.node_w;
    const pin_canvas = t.Point{ .x = st.node_x + cx_canvas, .y = st.node_y + cy_canvas };
    const dot = t.Point{ .x = sx(st, pin_canvas.x), .y = sy(st, pin_canvas.y) };

    const pid = nodeKey(0x91, pin);
    const hs = @max(14, 18 * st.z);
    const hit_rect = t.Rect{ .x = dot.x - hs * 0.5, .y = dot.y - hs * 0.5, .w = hs, .h = hs };
    const hit = ui.interact(pid, hit_rect);
    if (hit.hover and ui.input.pressed and !st.consumed and st.mode == .idle) {
        st.consumed = true;
        st.wire_detached = false;
        st.wire_orig = pin;
        st.wire_pin = pin;
        st.wire_kind = kind;
        st.wire_type = opts.type;
        st.wire_node = st.node_id;
        if (kind == .in) {
            // 抓住已连的输入引脚 = 把线从它上面摘下来
            for (st.prev.links[0..st.prev.link_n]) |l| {
                if (l.to != pin) continue;
                const src = findPin(&st.prev, l.from) orelse continue;
                st.wire_detached = true;
                st.wire_link = l.id;
                st.wire_pin = src.pin;
                st.wire_kind = .out;
                st.wire_type = src.type;
                st.wire_node = src.node;
                break;
            }
        }
        st.mode = .wire;
        st.has_target = false;
        st.press_x = ui.input.mouse.x;
        st.press_y = ui.input.mouse.y;
        st.last_x = st.press_x;
        st.last_y = st.press_y;
    }

    // 标签
    const ls = theme.font_small * st.z;
    const row_screen_y = sy(st, st.node_y + st.row_y);
    if (ls >= 4 and label.len > 0) {
        const maxw = st.node_w * st.z - 2 * INSET * st.z;
        const tw = ui.measureText(label, ls).w;
        const tx: f32 = if (kind == .in)
            st.card_sx + INSET * st.z
        else
            st.card_sx + st.node_w * st.z - INSET * st.z - @min(maxw, tw);
        ui.addText(.{
            .x = tx,
            .y = row_screen_y + (ROW_H * st.z - ls * 1.4) * 0.5,
            .w = @max(8, maxw),
            .h = ls * 1.6,
        }, clipText(ui, label, ls, maxw), ls, theme.secondary);
    }

    // 引脚点
    const tc = typeColor(opts.type);
    var pr = @max(2.5, PIN_R * st.z);
    const target = st.mode == .wire and st.has_target and st.target_pin == pin;
    const source = st.mode == .wire and st.wire_pin == pin;
    if (hit.hover and st.mode == .idle) pr *= 1.22;
    if (target) {
        ui.addBox(.{ .x = dot.x - pr * 1.6, .y = dot.y - pr * 1.6, .w = pr * 3.2, .h = pr * 3.2 }, .{ .fill = theme.withAlpha(theme.accent, 46), .radius = pr * 1.6 });
        ui.addBox(.{ .x = dot.x - pr * 1.3, .y = dot.y - pr * 1.3, .w = pr * 2.6, .h = pr * 2.6 }, .{ .fill = theme.accent, .radius = pr * 1.3 });
    } else {
        const filled = connected or source;
        ui.addBox(.{ .x = dot.x - pr, .y = dot.y - pr, .w = pr * 2, .h = pr * 2 }, .{
            .fill = if (filled) (if (source) theme.accent else tc) else (if (theme.isDark()) theme.raised else theme.surface),
            .radius = pr,
            .border = if (filled) null else tc,
            .border_width = @max(1, 1.5 * st.z),
        });
    }

    st.row_y += ROW_H;
    st.row_n_card += 1;
    if (st.cur.pin_n < st.cur.pins.len) {
        st.cur.pins[st.cur.pin_n] = .{ .pin = pin, .node = st.node_id, .kind = kind, .type = opts.type, .x = pin_canvas.x, .y = pin_canvas.y };
        st.cur.pin_n += 1;
    }
    return connected;
}

pub fn nodeInput(ui: *core.Context, st: *State, pin: i32, label: []const u8, opts: PinOpts) bool {
    return pinRow(ui, st, pin, label, opts, .in);
}

pub fn nodeOutput(ui: *core.Context, st: *State, pin: i32, label: []const u8, opts: PinOpts) bool {
    return pinRow(ui, st, pin, label, opts, .out);
}

/// 内容宿主的起点：`natural_h` 是内容自己的高度（100% 时的点数）。
pub fn contentBegin(ui: *core.Context, st: *State, natural_h: f32) void {
    if (!st.in_node or st.in_content) return;
    const inner = st.node_w - 2 * INSET;
    const rect = t.Rect{
        .x = st.card_sx + INSET * st.z,
        .y = sy(st, st.node_y + st.row_y + 3),
        .w = inner,
        .h = natural_h,
    };
    st.content_scope = ui.panel(rect, .{ .pad = 0, .gap = 6 });
    st.saved_mx = ui.input.mouse.x;
    st.saved_my = ui.input.mouse.y;
    // 内容按 100% 布局：把指针映射进它的空间
    ui.input.mouse = .{
        .x = rect.x + (ui.input.mouse.x - rect.x) / st.z,
        .y = rect.y + (ui.input.mouse.y - rect.y) / st.z,
    };
    st.in_content = true;
    st.row_y += natural_h / st.z + 6;
    st.row_n_card += 1;
}

/// 内容宿主的终点（指针位置还原）。
pub fn contentEnd(ui: *core.Context, st: *State) void {
    if (!st.in_content) return;
    st.content_scope.end();
    ui.input.mouse = .{ .x = st.saved_mx, .y = st.saved_my };
    st.in_content = false;
}

/// 声明一条连线。返回它本帧是否被选中。
pub fn nodeLink(ui: *core.Context, st: *State, link_id: i32, from_pin: i32, to_pin: i32) bool {
    _ = ui;
    if (!st.editing) return false;
    if (st.cur.link_n < st.cur.links.len) {
        st.cur.links[st.cur.link_n] = .{ .id = link_id, .from = from_pin, .to = to_pin };
        st.cur.link_n += 1;
    }
    return st.link_selected and st.sel_link == link_id;
}

// ---------------------------------------------------------------- 事件

pub fn linkCreated(st: *State, from_pin: *i32, to_pin: *i32) bool {
    if (st.ev_new_read + 2 > st.ev_new_n) return false;
    from_pin.* = st.ev_new[st.ev_new_read];
    to_pin.* = st.ev_new[st.ev_new_read + 1];
    st.ev_new_read += 2;
    return true;
}

pub fn linkRemoved(st: *State, link_id: *i32) bool {
    if (st.ev_rm_read >= st.ev_rm_n) return false;
    link_id.* = st.ev_rm[st.ev_rm_read];
    st.ev_rm_read += 1;
    return true;
}

pub fn nodeDeleted(st: *State, node_id: *i32) bool {
    if (st.ev_del_read >= st.ev_del_n) return false;
    node_id.* = st.ev_del[st.ev_del_read];
    st.ev_del_read += 1;
    return true;
}

/// 当前选中了几个节点。
pub fn selectedCount(st: *const State) usize {
    return st.sel_n;
}

/// 某个节点是否被选中。
pub fn isSelected(st: *const State, node_id: i32) bool {
    return selHas(st, node_id);
}
