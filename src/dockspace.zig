//! 面板停靠（对位 CUI `cui_panels.c` 的 `cui_dockspace_*` 系列）：
//! 可拖拽分割的面板布局 + 每个叶子的 tab 组 + 布局保存/加载。
//!
//! 布局是一棵二叉树：`h` 左右分割、`v` 上下分割、`leaf` 一组 tab。
//! 分割线上拖动改 `ratio`；点 tab 切换；tab 上的 × 关闭面板（`open` 写回调用方）。
//!
//! **已知取舍**（与 CUI 的差异，写在 `docs/迁移审计.md` §4）：
//! 不支持「把 tab 拖到另一个 leaf 里」（跨叶子拖拽合并/分割）；面板重开时插回根叶子。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const num = @import("num.zig");
const t = @import("types.zig");

pub const MAX_NODES = 32;
pub const MAX_PANELS = 16;
pub const MAX_TABS = 4;
pub const TITLE_MAX = 48;

pub const Kind = enum(u8) { leaf = 0, h_split = 1, v_split = 2 };

pub const LayoutNode = struct {
    kind: Kind = .leaf,
    /// 分割时第一个子节点占的比例。
    ratio: f32 = 0.5,
    a: i32 = -1,
    b: i32 = -1,
    /// 叶子里的面板索引。
    tabs: [MAX_TABS]u16 = @splat(0xFFFF),
    n_tabs: u8 = 0,
    selected: u8 = 0,
};

pub const Panel = struct {
    title: [TITLE_MAX]u8 = @splat(0),
    title_len: u8 = 0,
    used: bool = false,
    /// 当前是否打开（与调用方的 `*bool` 同步）。
    open: bool = true,
    /// 所在叶子（-1 = 不在布局里）。
    leaf: i32 = -1,
    /// 调用方这一帧是否请求了内容。
    built: bool = false,
    /// 本帧在 tab 上被点了关闭（下一帧 `panelBegin` 时写回调用方的 `*bool`）。
    request_close: bool = false,

    pub fn name(self: *const Panel) []const u8 {
        return self.title[0..@min(self.title_len, TITLE_MAX)];
    }
};

pub const DockspaceOpts = struct {
    /// 固定高度。
    height: f32 = 420,
    /// 分割线最小面板宽/高。
    min_w: f32 = 120,
    min_h: f32 = 96,
    tab_h: f32 = 28,
    /// 首次构建时使用的布局串（空 = 内置「左 1/4 + 右侧上下」）。
    layout: []const u8 = "",
};

pub const DockspaceState = struct {
    nodes: [MAX_NODES]LayoutNode = @splat(.{}),
    n_nodes: usize = 0,
    root: i32 = -1,
    panels: [MAX_PANELS]Panel = @splat(.{}),
    n_panels: usize = 0,
    /// 正在拖拽的分割节点（-1 = 无）。
    drag_split: i32 = -1,
    drag_pos: f32 = 0,
    drag_ratio: f32 = 0,

    fn node(self: *DockspaceState, i: i32) *LayoutNode {
        return &self.nodes[@intCast(i)];
    }
};

const LeafFrame = struct {
    rect: t.Rect = .{},
    panel: i16 = -1,
};

var ds: *DockspaceState = undefined;
var d_opts: DockspaceOpts = .{};
var d_id: []const u8 = "";
var d_active = false;
var d_leaves: [MAX_NODES]LeafFrame = @splat(.{});
var d_leaf_count: usize = 0;
var d_content: t.Rect = .{};
var d_in_panel = false;
var d_saved_clip: ?t.Rect = null;

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

fn newLeaf(state: *DockspaceState) i32 {
    if (state.n_nodes >= MAX_NODES) return -1;
    const i = state.n_nodes;
    state.nodes[i] = .{};
    state.n_nodes += 1;
    return @intCast(i);
}

fn newSplit(state: *DockspaceState, kind: Kind, a: i32, b: i32, ratio: f32) i32 {
    if (state.n_nodes >= MAX_NODES) return -1;
    const i = state.n_nodes;
    state.nodes[i] = .{ .kind = kind, .a = a, .b = b, .ratio = ratio };
    state.n_nodes += 1;
    return @intCast(i);
}

/// 把面板挂到一个叶子：选 tab 数最少的那个（均衡分到三个默认叶子）。
fn assignLeaf(state: *DockspaceState, pi: usize) void {
    if (state.root < 0) state.root = newLeaf(state);
    var best: i32 = -1;
    var best_n: i16 = 99;
    var i: usize = 0;
    while (i < state.n_nodes) : (i += 1) {
        const n = &state.nodes[i];
        if (n.kind != .leaf) continue;
        if (n.n_tabs >= MAX_TABS) continue;
        if (@as(i16, @intCast(n.n_tabs)) < best_n) {
            best_n = @intCast(n.n_tabs);
            best = @intCast(i);
        }
    }
    if (best < 0) return;
    const ln = state.node(best);
    ln.tabs[ln.n_tabs] = @intCast(pi);
    ln.n_tabs += 1;
    state.panels[pi].leaf = best;
}

/// 查找面板（按标题）；不存在则注册。
fn findPanel(state: *DockspaceState, title: []const u8) ?usize {
    var i: usize = 0;
    while (i < state.n_panels) : (i += 1) {
        if (state.panels[i].used and std.mem.eql(u8, state.panels[i].name(), title)) return i;
    }
    if (state.n_panels >= MAX_PANELS) return null;
    const idx = state.n_panels;
    state.panels[idx] = .{ .used = true };
    const n = @min(title.len, TITLE_MAX);
    @memcpy(state.panels[idx].title[0..n], title[0..n]);
    state.panels[idx].title_len = @intCast(n);
    state.n_panels += 1;
    assignLeaf(state, idx);
    return idx;
}

/// 默认布局：左（1/4）一个叶子，右（3/4）再上下分割。
fn initLayout(state: *DockspaceState) void {
    state.n_nodes = 0;
    state.root = -1;
    const left = newLeaf(state);
    const right_top = newLeaf(state);
    const right_bottom = newLeaf(state);
    if (left < 0 or right_top < 0 or right_bottom < 0) return;
    const right = newSplit(state, .v_split, right_top, right_bottom, 0.68);
    state.root = newSplit(state, .h_split, left, right, 0.24);
}

fn layoutNode(ui: *core.Context, state: *DockspaceState, ni: i32, rect: t.Rect) void {
    if (ni < 0) return;
    const n = state.node(ni);
    switch (n.kind) {
        .leaf => {
            d_leaves[d_leaf_count] = .{ .rect = rect, .panel = 0 };
            const slot = d_leaf_count;
            d_leaf_count += 1;
            drawLeaf(ui, state, ni, rect, slot);
        },
        .h_split, .v_split => {
            const horizontal = n.kind == .h_split;
            const avail = if (horizontal) rect.w else rect.h;
            const min0 = if (horizontal) d_opts.min_w else d_opts.min_h;
            var first = avail * n.ratio;
            if (first < min0) first = @min(min0, avail / 2);
            if (avail - first < min0) first = avail - @min(min0, avail / 2);

            if (horizontal) {
                layoutNode(ui, state, n.a, .{ .x = rect.x, .y = rect.y, .w = first, .h = rect.h });
                layoutNode(ui, state, n.b, .{ .x = rect.x + first, .y = rect.y, .w = rect.w - first, .h = rect.h });
            } else {
                layoutNode(ui, state, n.a, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first });
                layoutNode(ui, state, n.b, .{ .x = rect.x, .y = rect.y + first, .w = rect.w, .h = rect.h - first });
            }

            // 分隔条：4px 热区
            const bar = if (horizontal)
                t.Rect{ .x = rect.x + first - 2, .y = rect.y, .w = 4, .h = rect.h }
            else
                t.Rect{ .x = rect.x, .y = rect.y + first - 2, .w = rect.w, .h = 4 };
            const hit = ui.interactEx(idOf(d_id, 0x5B117 +% @as(u64, @intCast(ni))), bar, false);
            ui.addBox(bar, .{ .fill = if (hit.hover or state.drag_split == ni) theme.accent else theme.border });
            if (ui.input.pressed and hit.hover) {
                state.drag_split = ni;
                state.drag_pos = if (horizontal) ui.input.mouse.x else ui.input.mouse.y;
                state.drag_ratio = n.ratio;
            }
            if (state.drag_split == ni) {
                if (ui.input.down) {
                    const cur = if (horizontal) ui.input.mouse.x else ui.input.mouse.y;
                    var r = state.drag_ratio + (cur - state.drag_pos) / (if (avail > 0) avail else 1);
                    r = if (r < 0.08) 0.08 else if (r > 0.92) 0.92 else r;
                    if (r != n.ratio) n.ratio = r;
                } else {
                    state.drag_split = -1;
                }
            }
        },
    }
}

fn drawLeaf(ui: *core.Context, state: *DockspaceState, ni: i32, rect: t.Rect, slot: usize) void {
    const n = state.node(ni);
    ui.addBox(rect, .{ .fill = theme.bg });
    // tab 条
    const tab_rect = t.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = d_opts.tab_h };
    ui.addBox(tab_rect, .{ .fill = theme.surface });
    ui.addBox(.{ .x = tab_rect.x, .y = tab_rect.y + tab_rect.h - 1, .w = tab_rect.w, .h = 1 }, .{ .fill = theme.border });

    var x = rect.x + 4;
    var i: usize = 0;
    var selected_panel: i16 = -1;
    while (i < n.n_tabs) : (i += 1) {
        const pi: usize = n.tabs[i];
        if (pi >= MAX_PANELS or !state.panels[pi].used) continue;
        const p = &state.panels[pi];
        const m = ui.measureText(p.name(), theme.font_small);
        const w = m.w + 34;
        const tr = t.Rect{ .x = x, .y = rect.y + 2, .w = w, .h = d_opts.tab_h - 4 };
        const hit = ui.interactEx(idOf(d_id, 0x7AB0 +% (@as(u64, @intCast(ni)) * 8 + i)), tr, true);
        const on = n.selected == @as(u8, @intCast(i));
        if (on) {
            ui.addBox(tr, .{ .fill = theme.bg, .radius = 6, .border = theme.border });
        } else if (hit.hover) {
            ui.addBox(tr, .{ .fill = theme.track, .radius = 6 });
        }
        ui.addText(
            .{ .x = tr.x + 8, .y = tr.y + (tr.h - m.h) / 2, .w = m.w, .h = m.h },
            p.name(),
            theme.font_small,
            if (on) theme.text else theme.secondary,
        );
        // 关闭 ×
        const xr = t.Rect{ .x = tr.x + tr.w - 16, .y = tr.y + (tr.h - 12) / 2, .w = 12, .h = 12 };
        const xhit = ui.interactEx(idOf(d_id, 0xC105 +% (@as(u64, @intCast(ni)) * 8 + i)), xr, true);
        // 关闭 ×：仅悬停或选中时显示（未悬停时保持干净）
        if (xhit.hover or on) {
            const xc: t.Color = if (xhit.hover) theme.danger else theme.secondary;
            const xm = ui.measureText("\u{00d7}", theme.font_small);
            ui.addText(
                .{ .x = xr.x + (xr.w - xm.w) / 2, .y = xr.y + (xr.h - xm.h) / 2, .w = xm.w, .h = xm.h },
                "\u{00d7}",
                theme.font_small,
                xc,
            );
        }
        if (xhit.clicked) {
            p.open = false;
            p.request_close = true;
            p.leaf = -1;
        } else if (hit.clicked) {
            state.node(ni).selected = @intCast(i);
        }
        if (state.node(ni).selected == @as(u8, @intCast(i)) and p.open) selected_panel = @intCast(pi);
        x += w + 2;
    }
    if (slot < d_leaves.len) d_leaves[slot].panel = selected_panel;
}

/// 开始停靠区（与 `end` 配对）。
pub fn begin(ui: *core.Context, id: []const u8, state: *DockspaceState, opts: DockspaceOpts) void {
    ds = state;
    d_opts = opts;
    d_id = id;
    d_active = true;
    d_leaf_count = 0;
    d_in_panel = false;

    if (state.root < 0) {
        if (opts.layout.len > 0 and load(state, opts.layout)) {
            // 已按调用方给的串建立布局
        } else {
            initLayout(state);
        }
    }
    const rect = ui.reserve(0, opts.height, true);
    ui.addBox(rect, .{ .fill = theme.bg, .border = theme.border });
    ui.clip = rect;
    layoutNode(ui, state, state.root, rect);
    ui.clip = null;
}

/// 面板开始：`title` 必须在同一个 dockspace 内唯一。
/// 返回 true 时必须配对 `panelEnd`（内容区已开成 `ui.panel` 作用域）。
pub fn panelBegin(ui: *core.Context, state: *DockspaceState, title: []const u8, open: *bool) bool {
    if (!d_active) return false;
    const pi = findPanel(state, title) orelse return false;
    const p = &state.panels[pi];
    // tab 上的关闭是**用户动作**：写回调用方的 `*bool`，避免下一帧又被打开
    if (p.request_close) {
        open.* = false;
        p.request_close = false;
        p.open = false;
        return false;
    }
    p.open = open.*;
    if (!open.*) return false;

    // 找到它所在的叶子，并确认它是该叶子当前选中的 tab
    var slot: usize = 0;
    var found = false;
    while (slot < d_leaf_count) : (slot += 1) {
        if (d_leaves[slot].panel == @as(i16, @intCast(pi))) {
            found = true;
            break;
        }
    }
    if (!found) return false;

    const leaf_rect = d_leaves[slot].rect;
    d_content = .{
        .x = leaf_rect.x + 1,
        .y = leaf_rect.y + d_opts.tab_h,
        .w = leaf_rect.w - 2,
        .h = leaf_rect.h - d_opts.tab_h - 1,
    };
    // 内容裁到面板内容区：超出叶子高度的控件不能画到别的面板上
    d_saved_clip = ui.clip;
    ui.clip = d_content;
    _ = ui.panel(d_content, .{ .pad = 10, .gap = 8 });
    d_in_panel = true;
    p.built = true;
    return true;
}

/// 结束面板（与 `panelBegin` 配对）。
pub fn panelEnd(ui: *core.Context) void {
    if (!d_in_panel) return;
    ui.endPanel();
    ui.clip = d_saved_clip;
    d_in_panel = false;
}

/// 结束停靠区。
pub fn end(ui: *core.Context) void {
    _ = ui;
    d_active = false;
    d_in_panel = false;
}

// ------------------------------------------------------------------ 保存 / 加载
fn appendEscaped(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |c| {
        if (c == ',' or c == '[' or c == ']' or c == '(' or c == ')' or c == '\\') {
            if (n.* < buf.len) {
                buf[n.*] = '\\';
                n.* += 1;
            }
        }
        if (n.* < buf.len) {
            buf[n.*] = c;
            n.* += 1;
        }
    }
}

fn saveNode(state: *DockspaceState, ni: i32, buf: []u8, n: *usize) void {
    if (ni < 0) return;
    const node = state.node(ni);
    switch (node.kind) {
        .leaf => {
            if (n.* < buf.len) {
                buf[n.*] = '[';
                n.* += 1;
            }
            var i: usize = 0;
            while (i < node.n_tabs) : (i += 1) {
                const pi: usize = node.tabs[i];
                if (pi >= MAX_PANELS or !state.panels[pi].used) continue;
                if (i > 0 and n.* < buf.len) {
                    buf[n.*] = ',';
                    n.* += 1;
                }
                if (node.selected == @as(u8, @intCast(i)) and n.* < buf.len) {
                    buf[n.*] = '*';
                    n.* += 1;
                }
                appendEscaped(buf, n, state.panels[pi].name());
            }
            if (n.* < buf.len) {
                buf[n.*] = ']';
                n.* += 1;
            }
        },
        .h_split, .v_split => {
            if (n.* < buf.len) {
                buf[n.*] = if (node.kind == .h_split) 'h' else 'v';
                n.* += 1;
            }
            // ratio 写成三位小数（整数定点，不引浮点格式化）
            var rb: [8]u8 = undefined;
            const rs = num.fixed(&rb, node.ratio, 3);
            for (rs) |c| {
                if (n.* < buf.len) {
                    buf[n.*] = c;
                    n.* += 1;
                }
            }
            if (n.* < buf.len) {
                buf[n.*] = '(';
                n.* += 1;
            }
            saveNode(state, node.a, buf, n);
            if (n.* < buf.len) {
                buf[n.*] = ',';
                n.* += 1;
            }
            saveNode(state, node.b, buf, n);
            if (n.* < buf.len) {
                buf[n.*] = ')';
                n.* += 1;
            }
        },
    }
}

/// 输出布局字符串（`h0.240([*A,B],v0.680([*C],[*D]))`）。返回写出的长度。
pub fn save(state: *DockspaceState, buf: []u8) usize {
    var n: usize = 0;
    saveNode(state, state.root, buf, &n);
    return n;
}

const Parser = struct {
    text: []const u8,
    at: usize = 0,
    state: *DockspaceState,
    ok: bool = true,

    fn peek(self: *Parser) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.at < self.text.len and self.text[self.at] == ' ') self.at += 1;
    }

    fn parseName(self: *Parser, out: []u8) []const u8 {
        var n: usize = 0;
        var esc = false;
        while (self.at < self.text.len) {
            const c = self.text[self.at];
            if (esc) {
                if (n < out.len) {
                    out[n] = c;
                    n += 1;
                }
                esc = false;
                self.at += 1;
                continue;
            }
            if (c == '\\') {
                esc = true;
                self.at += 1;
                continue;
            }
            if (c == ',' or c == ']' or c == ')' or c == '[' or c == '(') break;
            if (n < out.len) {
                out[n] = c;
                n += 1;
            }
            self.at += 1;
        }
        return out[0..n];
    }

    fn parseRatio(self: *Parser) f32 {
        var v: f32 = 0;
        var seen = false;
        while (self.at < self.text.len) {
            const c = self.text[self.at];
            if (c >= '0' and c <= '9') {
                v = v * 10 + @as(f32, @floatFromInt(c - '0'));
                seen = true;
                self.at += 1;
            } else if (c == '.') {
                self.at += 1;
                var scale: f32 = 1;
                while (self.at < self.text.len and self.text[self.at] >= '0' and self.text[self.at] <= '9') {
                    scale *= 10;
                    v += @as(f32, @floatFromInt(self.text[self.at] - '0')) / scale;
                    self.at += 1;
                }
                return v;
            } else break;
        }
        if (!seen) self.ok = false;
        return v / 1000.0;
    }

    fn parseNode(self: *Parser) i32 {
        self.skipSpaces();
        const c = self.peek();
        if (c == 0) {
            self.ok = false;
            return -1;
        }
        if (c == '[') {
            self.at += 1;
            const leaf = newLeaf(self.state);
            if (leaf < 0) return -1;
            const ln = self.state.node(leaf);
            while (self.at < self.text.len and self.peek() != ']') {
                self.skipSpaces();
                var star = false;
                if (self.peek() == '*') {
                    star = true;
                    self.at += 1;
                }
                var tmp: [TITLE_MAX]u8 = @splat(0);
                const name = self.parseName(&tmp);
                if (name.len > 0 and ln.n_tabs < MAX_TABS) {
                    if (findPanel(self.state, name)) |pi| {
                        if (star) ln.selected = @intCast(ln.n_tabs);
                        ln.tabs[ln.n_tabs] = @intCast(pi);
                        ln.n_tabs += 1;
                        self.state.panels[pi].leaf = leaf;
                    }
                }
                self.skipSpaces();
                if (self.peek() == ',') self.at += 1;
            }
            if (self.peek() == ']') self.at += 1 else self.ok = false;
            return leaf;
        }
        if (c == 'h' or c == 'v') {
            self.at += 1;
            const ratio = self.parseRatio();
            if (self.peek() != '(') {
                self.ok = false;
                return -1;
            }
            self.at += 1;
            const a = self.parseNode();
            self.skipSpaces();
            if (self.peek() == ',') self.at += 1 else self.ok = false;
            const b = self.parseNode();
            self.skipSpaces();
            if (self.peek() == ')') self.at += 1 else self.ok = false;
            return newSplit(self.state, if (c == 'h') .h_split else .v_split, a, b, ratio);
        }
        self.ok = false;
        return -1;
    }
};

/// 从字符串恢复布局。格式错误时返回 false 且不改动现有布局。
pub fn load(state: *DockspaceState, text: []const u8) bool {
    var probe = DockspaceState{};
    probe.n_panels = state.n_panels;
    probe.panels = state.panels;
    var p = Parser{ .text = text, .state = &probe };
    const root = p.parseNode();
    if (!p.ok or root < 0) return false;
    probe.root = root;
    // 未出现在新布局里的面板：关闭（与 CUI 的 `-name` 语义一致）
    var i: usize = 0;
    while (i < probe.n_panels) : (i += 1) {
        if (!probe.panels[i].used) continue;
        if (probe.panels[i].leaf < 0) probe.panels[i].open = false;
    }
    state.nodes = probe.nodes;
    state.n_nodes = probe.n_nodes;
    state.root = probe.root;
    state.panels = probe.panels;
    return true;
}
