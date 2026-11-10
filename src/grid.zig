//! 数据网格 / 树表 / 面包屑 / 筛选条（对位 CUI `cui_grid.c` + `cui_treetable.c`）。
//!
//! 与 `table.zig` 的分工：`table` 是**只读**流式表格（列头排序 + 行选中）；
//! 这里是可以**编辑**的网格（列宽拖拽、列优先级隐藏、多选、单元格内联编辑）、
//! 树表（扁平节点数组 + 展开折叠 + 层级排序）、面包屑与筛选条。
//!
//! 容量纪律：树表只把**可见行**放进 `rows` 缓冲（`MAX_ROWS`），10 万节点的成本与一屏一致。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const overlay = @import("overlay.zig");
const table = @import("table.zig");
const num = @import("num.zig");
const t = @import("types.zig");

pub const MAX_COLS = 12;
pub const MAX_ROWS = 64;
pub const MAX_OPTIONS = 8;

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

pub const Align = table.Align;

pub const GridColumn = struct {
    title: []const u8,
    /// 初始宽（0 = 弹性列）。
    width: f32 = 150,
    text_align: Align = .start,
    sortable: bool = false,
    /// 不可拖拽改宽。
    fixed: bool = false,
    /// > 0 时窗口变窄会先隐藏（数值大的先消失）。
    priority: i32 = 0,
};

pub const GridSort = struct {
    column: ?usize = null,
    desc: bool = false,
};

pub const GridOpts = struct {
    row_h: f32 = 36,
    header_h: f32 = 34,
    /// > 0 时正文滚动（表头固定）。
    height: f32 = 0,
    striped: bool = true,
    pad: f32 = 10,
    /// 显示勾选列（行选择）。
    checkboxes: bool = false,
    sort: ?*GridSort = null,
    /// 空表占位文案。
    empty: []const u8 = "No rows",
};

/// 网格的跨帧状态：列宽、隐藏、拖拽、光标与编辑。
pub const GridState = struct {
    widths: [MAX_COLS]f32 = @splat(0),
    visible: [MAX_COLS]bool = @splat(true),
    drag_col: i32 = -1,
    drag_x: f32 = 0,
    drag_w: f32 = 0,
    /// 键盘行（也是单选的行）。
    cursor: i32 = -1,
    /// Shift 区间起点。
    anchor: i32 = -1,
    editing_row: i32 = -1,
    editing_col: i32 = -1,
    edit_buf: [64]u8 = @splat(0),
    edit_len: usize = 0,
    edit_caret: usize = 0,
    /// 本次渲染覆盖的行区间（虚拟化用）。
    first: usize = 0,
    last: usize = 0,
};

const GridCtx = struct {
    ui: *core.Context,
    id: []const u8,
    columns: []const GridColumn,
    state: *GridState,
    opts: GridOpts,
    selected: ?[]bool,
    row_count: usize,
    width: f32,
    col_x: [MAX_COLS]f32 = @splat(0),
    col_w: [MAX_COLS]f32 = @splat(0),
    scroll: ?core.ScrollScope = null,
    header_rect: t.Rect = .{},
};

var g: GridCtx = undefined;
var active = false;

/// 计算可见列与列宽（含拖拽结果与 priority 隐藏）。
fn layoutColumns(c: *GridCtx) void {
    var i: usize = 0;
    while (i < c.columns.len and i < MAX_COLS) : (i += 1) {
        const col = c.columns[i];
        c.state.visible[i] = true;
        if (c.state.widths[i] <= 0) c.state.widths[i] = if (col.width > 0) col.width else 0;
    }
    // priority 隐藏：从高到低隐藏，直到总宽装得下
    const avail = c.width;
    while (true) {
        var total: f32 = if (c.opts.checkboxes) 32 else 0;
        var flex: usize = 0;
        i = 0;
        while (i < c.columns.len and i < MAX_COLS) : (i += 1) {
            if (!c.state.visible[i]) continue;
            if (c.state.widths[i] > 0) total += c.state.widths[i] else flex += 1;
        }
        if (flex > 0) total += 60 * @as(f32, @floatFromInt(flex));
        if (total <= avail or total <= 0) break;
        // 找优先级最高且还可隐藏的列
        var worst: i32 = -1;
        var worst_pri: i32 = 0;
        i = 0;
        while (i < c.columns.len and i < MAX_COLS) : (i += 1) {
            if (!c.state.visible[i] or c.columns[i].priority <= 0) continue;
            if (c.columns[i].priority > worst_pri) {
                worst_pri = c.columns[i].priority;
                worst = @intCast(i);
            }
        }
        if (worst < 0) break;
        c.state.visible[@intCast(worst)] = false;
    }
    // 位置与最终宽度（弹性列吃剩余）
    var fixed_total: f32 = if (c.opts.checkboxes) 32 else 0;
    var flex: usize = 0;
    i = 0;
    while (i < c.columns.len and i < MAX_COLS) : (i += 1) {
        if (!c.state.visible[i]) continue;
        if (c.state.widths[i] > 0) fixed_total += c.state.widths[i] else flex += 1;
    }
    const flex_w = if (flex > 0) @max((c.width - fixed_total) / @as(f32, @floatFromInt(flex)), 60) else 0;
    var x: f32 = if (c.opts.checkboxes) 32 else 0;
    i = 0;
    while (i < c.columns.len and i < MAX_COLS) : (i += 1) {
        c.col_x[i] = x;
        if (!c.state.visible[i]) {
            c.col_w[i] = 0;
            continue;
        }
        c.col_w[i] = if (c.state.widths[i] > 0) c.state.widths[i] else flex_w;
        x += c.col_w[i];
    }
}

/// 数据网格开始。返回 false 表示没有可画的列（调用方不必再开行）。
pub fn dataGridBegin(
    ui: *core.Context,
    id: []const u8,
    columns: []const GridColumn,
    row_count: usize,
    selected: ?[]bool,
    state: *GridState,
    opts: GridOpts,
) bool {
    if (columns.len == 0) return false;
    g = .{
        .ui = ui,
        .id = id,
        .columns = columns,
        .state = state,
        .opts = opts,
        .selected = selected,
        .row_count = row_count,
        .width = ui.width - 24,
    };
    active = true;

    const header = ui.reserve(0, opts.header_h, true);
    g.header_rect = header;
    g.width = header.w;
    layoutColumns(&g);

    // 表头背景
    ui.addBox(header, .{ .fill = theme.surface });

    // 勾选列的全选
    if (opts.checkboxes) {
        const cb = t.Rect{ .x = header.x + 8, .y = header.y + (opts.header_h - 16) / 2, .w = 16, .h = 16 };
        const hit = ui.interactEx(idOf(id, 0xC401), cb, true);
        const all = blk: {
            if (selected) |sel| {
                if (sel.len == 0) break :blk false;
                for (sel[0..@min(sel.len, row_count)]) |v| {
                    if (!v) break :blk false;
                }
                break :blk true;
            }
            break :blk false;
        };
        widgets.ringBox(ui, cb, 3, if (all) theme.accent else theme.bg, if (hit.hover) theme.accent else theme.border);
        if (all) {
            ui.addOverlayLine(.{ .x = cb.x + 4, .y = cb.y + 8 }, .{ .x = cb.x + 7, .y = cb.y + 11 }, 1.6, theme.accent_text);
            ui.addOverlayLine(.{ .x = cb.x + 7, .y = cb.y + 11 }, .{ .x = cb.x + 12, .y = cb.y + 5 }, 1.6, theme.accent_text);
        }
        if (hit.clicked) {
            if (selected) |sel| {
                var i: usize = 0;
                while (i < @min(sel.len, row_count)) : (i += 1) sel[i] = !all;
            }
        }
    }

    // 列头 + 排序 + 拖拽手柄
    var i: usize = 0;
    while (i < columns.len and i < MAX_COLS) : (i += 1) {
        if (!state.visible[i]) continue;
        const col = columns[i];
        const cr = t.Rect{ .x = header.x + g.col_x[i], .y = header.y, .w = g.col_w[i], .h = opts.header_h };
        const hit = ui.interactEx(idOf(id, 0x1EAD +% i), cr, col.sortable);
        const m = ui.measureText(col.title, theme.font_small);
        const tx = switch (col.text_align) {
            .start => cr.x + opts.pad,
            .center => cr.x + (cr.w - m.w) / 2,
            .end => cr.x + cr.w - m.w - opts.pad,
        };
        ui.addText(.{ .x = tx, .y = cr.y + (cr.h - m.h) / 2, .w = m.w, .h = m.h }, col.title, theme.font_small, theme.secondary);
        if (col.sortable) {
            ui.addText(.{ .x = tx - m.w - 10, .y = cr.y + (cr.h - m.h) / 2, .w = m.w, .h = m.h }, "", theme.font_small, theme.secondary);
            const ax = tx + m.w + 4;
            const ay = cr.y + cr.h / 2 - 2;
            if (opts.sort) |s| {
                if (s.column != null and s.column.? == i) {
                    if (s.desc) {
                        ui.addOverlayLine(.{ .x = ax, .y = ay - 1 }, .{ .x = ax + 4, .y = ay + 3 }, 1.2, theme.accent);
                        ui.addOverlayLine(.{ .x = ax + 4, .y = ay + 3 }, .{ .x = ax + 8, .y = ay - 1 }, 1.2, theme.accent);
                    } else {
                        ui.addOverlayLine(.{ .x = ax, .y = ay + 3 }, .{ .x = ax + 4, .y = ay - 1 }, 1.2, theme.accent);
                        ui.addOverlayLine(.{ .x = ax + 4, .y = ay - 1 }, .{ .x = ax + 8, .y = ay + 3 }, 1.2, theme.accent);
                    }
                }
            }
        }
        if (hit.clicked and col.sortable) {
            if (opts.sort) |s| {
                if (s.column != null and s.column.? == i) {
                    s.desc = !s.desc;
                } else {
                    s.column = i;
                    s.desc = false;
                }
            }
        }
        // 列宽拖拽手柄（右边缘 8px）
        if (!col.fixed) {
            const grip = t.Rect{ .x = cr.x + cr.w - 4, .y = cr.y, .w = 8, .h = cr.h };
            const ghit = ui.interactEx(idOf(id, 0x6B1B +% i), grip, false);
            if (ghit.hover or state.drag_col == @as(i32, @intCast(i))) {
                ui.addBox(.{ .x = grip.x + 3, .y = grip.y + 6, .w = 1.5, .h = cr.h - 12 }, .{ .fill = theme.accent });
            }
            if (ui.input.pressed and ghit.hover) {
                state.drag_col = @intCast(i);
                state.drag_x = ui.input.mouse.x;
                state.drag_w = state.widths[i];
            }
        }
        // 分隔线
        ui.addBox(.{ .x = cr.x + cr.w - 1, .y = cr.y + 6, .w = 1, .h = cr.h - 12 }, .{ .fill = theme.border });
    }
    if (state.drag_col >= 0) {
        const ci: usize = @intCast(state.drag_col);
        if (ui.input.down and ci < MAX_COLS) {
            const nw = @max(state.drag_w + (ui.input.mouse.x - state.drag_x), 48);
            if (state.widths[ci] != nw) {
                state.widths[ci] = nw;
                layoutColumns(&g);
            }
        } else {
            state.drag_col = -1;
        }
    }
    ui.addBox(.{ .x = header.x, .y = header.y + header.h - 1, .w = header.w, .h = 1 }, .{ .fill = theme.border });

    if (opts.height > 0) {
        g.scroll = ui.scroll(.{ .id = id, .height = opts.height, .pad = 0, .gap = 0 });
    }
    if (row_count == 0) {
        const m = ui.measureText(opts.empty, theme.font_body);
        const er = ui.reserve(0, 60, true);
        ui.addText(.{ .x = er.x + (er.w - m.w) / 2, .y = er.y + 20, .w = m.w, .h = m.h }, opts.empty, theme.font_body, theme.secondary);
    }
    return true;
}

pub const GridRow = struct {
    rect: t.Rect,
    index: usize,
    clicked: bool = false,

    /// 第 `idx` 列的矩形（纯计算）。
    pub fn cell(self: GridRow, idx: usize) t.Rect {
        if (idx >= MAX_COLS) return .{};
        return .{ .x = g.header_rect.x + g.col_x[idx], .y = self.rect.y, .w = g.col_w[idx], .h = self.rect.h };
    }

    /// 在单元格里画文本（按列对齐、超宽截断）。
    pub fn text(self: GridRow, idx: usize, s: []const u8, color: t.Color) void {
        const ui = g.ui;
        const r = self.cell(idx);
        if (r.w <= 0) return;
        const col = if (idx < g.columns.len) g.columns[idx] else GridColumn{ .title = "" };
        const inner = r.w - g.opts.pad * 2;
        var shown = s;
        const m = ui.measureText(s, theme.font_body);
        if (m.w > inner and s.len > 0) {
            var end: usize = 0;
            while (end < s.len) {
                const n = std.unicode.utf8ByteSequenceLength(s[end]) catch 1;
                const next = @min(end + n, s.len);
                if (ui.measureText(s[0..next], theme.font_body).w > inner - 8) break;
                end = next;
            }
            shown = s[0..end];
        }
        const sm = ui.measureText(shown, theme.font_body);
        const tx = switch (col.text_align) {
            .start => r.x + g.opts.pad,
            .center => r.x + (r.w - sm.w) / 2,
            .end => r.x + r.w - sm.w - g.opts.pad,
        };
        ui.addText(.{ .x = tx, .y = r.y + (r.h - sm.h) / 2, .w = sm.w, .h = sm.h }, shown, theme.font_body, color);
    }

    /// 单元格内联编辑：点击进入（Shift+点击也可），Enter 提交，Esc 取消。
    /// 返回 true 表示本帧提交了新值（`buf` 已更新）。
    pub fn edit(self: GridRow, idx: usize, buf: []u8, len: *usize) bool {
        const ui = g.ui;
        const st = g.state;
        if (idx >= MAX_COLS) return false;
        const r = self.cell(idx);
        if (r.w <= 0) return false;
        const cell_hit = ui.interactEx(idOf(g.id, 0xE0D0 +% (self.index * MAX_COLS + idx)), r, false);
        const editing = st.editing_row == @as(i32, @intCast(self.index)) and st.editing_col == @as(i32, @intCast(idx));

        if (!editing) {
            if (cell_hit.clicked and (ui.input.mods.shift or ui.input.mods.ctrl)) {
                // 进入编辑：把当前内容拷进编辑缓冲（调用方在 text() 里画过原值）
                st.editing_row = @intCast(self.index);
                st.editing_col = @intCast(idx);
                st.edit_len = @min(len.*, st.edit_buf.len);
                @memcpy(st.edit_buf[0..st.edit_len], buf[0..st.edit_len]);
                st.edit_caret = st.edit_len;
            }
            return false;
        }

        // 编辑态
        if (cell_hit.clicked) st.edit_caret = @min(st.edit_len, st.edit_buf.len);
        widgets.ringBox(ui, r, 0, t.Color.hex(0xFFFFFF, 255), theme.accent);
        if (cell_hit.hover or ui.input.down) {
            // 同一时刻只应有一个编辑框获得按键：用 focus 判定
        }
        var changed = false;
        widgets.editKeys(ui, &st.edit_buf, &st.edit_len, &st.edit_caret, &changed);
        const cur = st.edit_buf[0..@min(st.edit_len, st.edit_buf.len)];
        const m = ui.measureText(cur, theme.font_body);
        ui.addText(.{ .x = r.x + g.opts.pad, .y = r.y + (r.h - m.h) / 2, .w = m.w, .h = m.h }, cur, theme.font_body, theme.text);
        const careted = ui.measureText(st.edit_buf[0..@min(st.edit_caret, cur.len)], theme.font_body);
        var cx = r.x + g.opts.pad + careted.w;
        if (cx > r.x + r.w - g.opts.pad) cx = r.x + r.w - g.opts.pad;
        ui.addOverlayLine(.{ .x = cx, .y = r.y + 8 }, .{ .x = cx, .y = r.y + r.h - 8 }, 1.5, theme.text);

        if (ui.input.keyPressed(.enter)) {
            const nb = @min(st.edit_len, buf.len);
            @memcpy(buf[0..nb], st.edit_buf[0..nb]);
            len.* = nb;
            st.editing_row = -1;
            st.editing_col = -1;
            return true;
        }
        if (ui.input.keyPressed(.escape)) {
            st.editing_row = -1;
            st.editing_col = -1;
        }
        return false;
    }
};

/// 画一行：背景、勾选、点击选区（单选 / Shift 区间 / Ctrl 切换）。
pub fn dataGridRow(ui: *core.Context, index: usize) ?GridRow {
    if (!active) return null;
    const st = g.state;
    if (index < st.first) st.first = index;
    if (index + 1 > st.last) st.last = index + 1;

    const rect = ui.reserve(0, g.opts.row_h, true);
    const row_id = idOf(g.id, 0x1200 +% @as(u64, @intCast(index)));
    const it = ui.interactEx(row_id, rect, true);
    const is_sel = if (g.selected) |sel| (index < sel.len and sel[index]) else false;

    if (is_sel) {
        ui.addBox(rect, .{ .fill = t.Color.hex(0xE8EFFD, 255) });
    } else if (it.hover) {
        ui.addBox(rect, .{ .fill = theme.surface });
    } else if (g.opts.striped and (index % 2) == 1) {
        ui.addBox(rect, .{ .fill = t.Color.hex(0xFAFBFC, 255) });
    }
    ui.addBox(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, .{ .fill = t.Color.hex(0xEDF0F3, 255) });

    // 勾选列
    if (g.opts.checkboxes) {
        const cb = t.Rect{ .x = rect.x + 8, .y = rect.y + (rect.h - 16) / 2, .w = 16, .h = 16 };
        const chit = ui.interactEx(idOf(g.id, 0xC410 +% @as(u64, @intCast(index))), cb, true);
        widgets.ringBox(ui, cb, 3, if (is_sel) theme.accent else theme.bg, if (chit.hover) theme.accent else theme.border);
        if (is_sel) {
            ui.addOverlayLine(.{ .x = cb.x + 4, .y = cb.y + 8 }, .{ .x = cb.x + 7, .y = cb.y + 11 }, 1.6, theme.accent_text);
            ui.addOverlayLine(.{ .x = cb.x + 7, .y = cb.y + 11 }, .{ .x = cb.x + 12, .y = cb.y + 5 }, 1.6, theme.accent_text);
        }
        if (chit.clicked) {
            if (g.selected) |sel| {
                if (index < sel.len) sel[index] = !sel[index];
            }
        }
    }

    if (it.clicked) {
        if (g.selected) |sel| {
            if (index < sel.len) {
                if (ui.input.mods.shift and st.anchor >= 0) {
                    const a: usize = @intCast(@max(st.anchor, 0));
                    const lo = @min(a, index);
                    const hi = @max(a, index);
                    var i: usize = lo;
                    while (i <= hi and i < sel.len) : (i += 1) sel[i] = true;
                } else if (ui.input.mods.ctrl) {
                    sel[index] = !sel[index];
                    st.anchor = @intCast(index);
                } else {
                    var i: usize = 0;
                    while (i < sel.len) : (i += 1) sel[i] = false;
                    sel[index] = true;
                    st.anchor = @intCast(index);
                }
            }
        }
        st.cursor = @intCast(index);
    }
    return .{ .rect = rect, .index = index, .clicked = it.clicked };
}

/// 结束网格（关闭滚动区、复位隐式上下文）。
pub fn dataGridEnd(ui: *core.Context) void {
    if (!active) return;
    if (g.scroll) |*s| s.end();
    g.scroll = null;
    active = false;
    _ = ui;
}

// ------------------------------------------------------------------ 树表
pub const TreeFlag = struct {
    pub const expanded: u32 = 1 << 0;
    pub const selected: u32 = 1 << 2;
    pub const loading: u32 = 1 << 3;
};

pub const TreeNode = struct {
    parent: i32 = -1,
    first_child: i32 = -1,
    next_sibling: i32 = -1,
    flags: u32 = 0,
};

pub const TreeTableOpts = struct {
    row_h: f32 = 32,
    header_h: f32 = 34,
    height: f32 = 0,
    root: i32 = 0,
    indent: f32 = 16,
    /// 节点的显示文本（由调用方提供，避免把字符串塞进节点结构）。
    labelFn: ?*const fn (nodes: []const TreeNode, index: usize) []const u8 = null,
};

pub const TreeTableState = struct {
    cursor: i32 = -1,
    /// 本帧展开后的可见节点（供调用方取行）。
    rows: [MAX_ROWS]i32 = @splat(-1),
    row_count: usize = 0,
    /// 本帧正在画第几行（`treeTableRow` 自增）。
    at: usize = 0,
};

var tg: GridCtx = undefined;
var t_active = false;
var t_nodes: []TreeNode = &.{};
var t_state: *TreeTableState = undefined;
var t_opts: TreeTableOpts = .{};
/// 树表的列宽/拖拽状态（与数据网格分开，两者不共用同一份运行时状态）。
var t_grid: GridState = .{};

/// 把展开的那部分树按先序展平成 `rows`。
fn flatten(nodes: []const TreeNode, start: i32, depth: usize, max_depth: usize) void {
    var idx = start;
    while (idx >= 0) {
        const i: usize = @intCast(idx);
        if (i >= nodes.len or t_state.row_count >= MAX_ROWS) return;
        t_state.rows[t_state.row_count] = idx;
        t_state.row_count += 1;
        const n = nodes[i];
        if ((n.flags & TreeFlag.expanded) != 0 and n.first_child >= 0 and depth < max_depth) {
            flatten(nodes, n.first_child, depth + 1, max_depth);
        }
        idx = n.next_sibling;
    }
}

/// 树表开始（与 `dataGrid` 共用列/列宽逻辑）。
pub fn treeTableBegin(
    ui: *core.Context,
    id: []const u8,
    columns: []const GridColumn,
    nodes: []TreeNode,
    state: *TreeTableState,
    opts: TreeTableOpts,
) bool {
    if (columns.len == 0 or nodes.len == 0) return false;
    t_nodes = nodes;
    t_state = state;
    t_opts = opts;
    state.row_count = 0;
    state.at = 0;
    flatten(nodes, if (opts.root >= 0) opts.root else 0, 0, 32);

    const grid_opts = GridOpts{ .row_h = opts.row_h, .header_h = opts.header_h, .height = opts.height };
    if (!dataGridBegin(ui, id, columns, state.row_count, null, &t_grid, grid_opts)) return false;
    t_active = true;
    return true;
}

/// 画下一行（返回该行对应的节点下标）。
pub fn treeTableRow(ui: *core.Context, state: *TreeTableState) ?usize {
    if (!t_active) return null;
    if (state.at >= state.row_count) return null;
    const node_idx = state.rows[state.at];
    const row = dataGridRow(ui, state.at) orelse return null;
    const ni: usize = @intCast(node_idx);
    state.at += 1;

    // 层级缩进 + 展开箭头（画在第一列）
    var depth: usize = 0;
    var p = t_nodes[ni].parent;
    while (p >= 0 and depth < 32) : (p = t_nodes[@intCast(p)].parent) depth += 1;
    const cr = row.cell(0);
    const has_child = t_nodes[ni].first_child >= 0;
    const ex = cr.x + 8 + @as(f32, @floatFromInt(depth)) * t_opts.indent;
    const arrow = t.Rect{ .x = ex, .y = cr.y + (cr.h - 14) / 2, .w = 14, .h = 14 };
    if (has_child) {
        const hit = ui.interactEx(idOf("tree", 0xA000 +% @as(u64, @intCast(state.at))), arrow, true);
        const cy = arrow.y + 7;
        if ((t_nodes[ni].flags & TreeFlag.expanded) != 0) {
            ui.addOverlayLine(.{ .x = arrow.x + 3, .y = cy + 2 }, .{ .x = arrow.x + 7, .y = cy - 2 }, 1.4, theme.secondary);
            ui.addOverlayLine(.{ .x = arrow.x + 7, .y = cy - 2 }, .{ .x = arrow.x + 11, .y = cy + 2 }, 1.4, theme.secondary);
        } else {
            ui.addOverlayLine(.{ .x = arrow.x + 5, .y = cy - 3 }, .{ .x = arrow.x + 9, .y = cy }, 1.4, theme.secondary);
            ui.addOverlayLine(.{ .x = arrow.x + 9, .y = cy }, .{ .x = arrow.x + 5, .y = cy + 3 }, 1.4, theme.secondary);
        }
        if (hit.clicked) t_nodes[ni].flags ^= TreeFlag.expanded;
    }
    if (t_opts.labelFn) |lf| {
        const label = lf(t_nodes, ni);
        const m = ui.measureText(label, theme.font_body);
        ui.addText(
            .{ .x = ex + 18, .y = cr.y + (cr.h - m.h) / 2, .w = m.w, .h = m.h },
            label,
            theme.font_body,
            if ((t_nodes[ni].flags & TreeFlag.selected) != 0) theme.accent else theme.text,
        );
    }
    return ni;
}

/// 结束树表。
pub fn treeTableEnd(ui: *core.Context) void {
    if (!t_active) return;
    dataGridEnd(ui);
    t_active = false;
}

/// 按比较函数对某个父节点的子链表排序（节点内容由调用方按 `table` 顺序读）。
/// 返回排序后的首个子节点下标。
pub fn treeSort(
    nodes: []TreeNode,
    parent_index: i32,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), i32, i32) bool,
) i32 {
    // 收集子节点
    var list: [MAX_ROWS]i32 = @splat(-1);
    var n: usize = 0;
    var cur: i32 = if (parent_index < 0) -1 else nodes[@intCast(parent_index)].first_child;
    if (parent_index < 0) {
        // 无父节点时，从「第一个 -1 父的节点」开始（通常是 0）
        cur = if (nodes.len > 0) 0 else -1;
    }
    while (cur >= 0 and n < MAX_ROWS) {
        list[n] = cur;
        n += 1;
        cur = nodes[@intCast(cur)].next_sibling;
    }
    if (n < 2) return if (n == 1) list[0] else -1;
    // 插入排序（n 很小，且稳定）
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const v = list[i];
        var j = i;
        while (j > 0 and lessThan(context, v, list[j - 1])) : (j -= 1) {
            list[j] = list[j - 1];
        }
        list[j] = v;
    }
    // 重接兄弟链
    i = 0;
    while (i < n) : (i += 1) {
        nodes[@intCast(list[i])].next_sibling = if (i + 1 < n) list[i + 1] else -1;
    }
    if (parent_index >= 0) {
        nodes[@intCast(parent_index)].first_child = list[0];
    }
    return list[0];
}

// ------------------------------------------------------------------ 面包屑（path bar）
pub const PathBarOpts = struct {
    icon: []const u8 = "",
    /// 禁止文本编辑（只做点击导航）。
    no_edit: bool = false,
    /// 分段之间是否可打开兄弟菜单。
    menus: bool = true,
    width: f32 = 0,
};

pub const PathBarState = struct {
    editing: bool = false,
    buf: [128]u8 = @splat(0),
    len: usize = 0,
    caret: usize = 0,
    /// 当前展开兄弟菜单的分段下标（-1 = 没打开）。
    menu_segment: i32 = -1,
    menu_anchor: t.Rect = .{},
    /// 菜单是否打开（给 `popoverBegin` 的 `*bool`）。
    menu_open: bool = false,
};

pub const PathBarResult = struct {
    /// 被点的分段下标（-1 = 没点）。
    clicked: i32 = -1,
    /// 文本模式按 Enter 提交的路径（指向 `state.buf`，仅本帧有效）。
    submitted: ?[]const u8 = null,
    editing: bool = false,
};

const SEP: []const u8 = "/";

/// 面包屑：`icon / a / b / c`。点击分段返回下标；点最后一段或空白进入文本编辑，
/// 分隔符可打开兄弟菜单（`pathBarMenuBegin`）。
pub fn pathBar(
    ui: *core.Context,
    id: []const u8,
    segments: []const []const u8,
    state: *PathBarState,
    opts: PathBarOpts,
) PathBarResult {
    var res = PathBarResult{ .editing = state.editing };
    const h: f32 = 32;
    const w = if (opts.width > 0) opts.width else ui.width - 24;
    const rect = ui.reserve(if (opts.width > 0) opts.width else 0, h, opts.width <= 0);

    if (state.editing) {
        // 文本模式：整条变成输入框
        _ = widgets.input(ui, id, &state.buf, &state.len, &state.caret, .{ .width = w, .placeholder = "Type a path" });
        if (ui.input.keyPressed(.enter)) {
            state.editing = false;
            res.editing = false;
            res.submitted = state.buf[0..@min(state.len, state.buf.len)];
        } else if (ui.input.keyPressed(.escape)) {
            state.editing = false;
            res.editing = false;
        }
        return res;
    }

    var x = rect.x;
    var budget = rect.w;

    // 图标
    if (opts.icon.len > 0) {
        const m = ui.measureText(opts.icon, theme.font_body);
        ui.addText(.{ .x = x, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, opts.icon, theme.font_body, theme.secondary);
        x += m.w + 6;
        budget -= m.w + 6;
    }

    // 分段宽度；装不下时把中间折叠成 "..."
    var widths: [16]f32 = @splat(0);
    const n = @min(segments.len, 16);
    var total: f32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        widths[i] = ui.measureText(segments[i], theme.font_body).w + 14;
        total += widths[i] + 10;
    }
    var skip_from: usize = 0;
    var skip_to: usize = 0;
    const ell_w: f32 = 22;
    if (total > budget and n > 2) {
        // 从中间丢，保留首尾
        var keep: f32 = widths[0] + widths[n - 1] + ell_w + 20;
        skip_from = 1;
        skip_to = n - 1;
        var k: usize = 1;
        while (k + 1 < n and keep + widths[k] + 10 <= budget) : (k += 1) {
            keep += widths[k] + 10;
            skip_from = k + 1;
        }
        skip_to = n - 1;
    }

    i = 0;
    var ell_drawn = false;
    while (i < n) : (i += 1) {
        if (skip_to > skip_from and i >= skip_from and i < skip_to) {
            if (!ell_drawn) {
                ui.addText(.{ .x = x, .y = rect.y + (h - 16) / 2, .w = ell_w, .h = 16 }, "...", theme.font_body, theme.secondary);
                x += ell_w;
                ell_drawn = true;
            }
            continue;
        }
        const label = segments[i];
        const m = ui.measureText(label, theme.font_body);
        const sr = t.Rect{ .x = x, .y = rect.y + 3, .w = m.w + 8, .h = h - 6 };
        const hit = ui.interactEx(idOf(id, 0x9A00 +% @as(u64, @intCast(i))), sr, true);
        const is_last = i + 1 == n;
        if (hit.hover) ui.addBox(sr, .{ .fill = theme.surface, .radius = 5 });
        ui.addText(
            .{ .x = sr.x + 4, .y = sr.y + (sr.h - m.h) / 2, .w = m.w, .h = m.h },
            label,
            theme.font_body,
            if (is_last) theme.text else theme.accent,
        );
        if (hit.clicked) {
            if (is_last and !opts.no_edit) {
                // 点最后一段 → 进入文本编辑，预填完整路径
                state.editing = true;
                state.len = 0;
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    if (k > 0 and state.len < state.buf.len) {
                        state.buf[state.len] = '/';
                        state.len += 1;
                    }
                    for (segments[k]) |ch| {
                        if (state.len < state.buf.len) {
                            state.buf[state.len] = ch;
                            state.len += 1;
                        }
                    }
                }
                state.caret = state.len;
                res.editing = true;
            } else {
                res.clicked = @intCast(i);
            }
        }
        x += sr.w;

        // 分隔符（点击打开兄弟菜单）
        if (!is_last) {
            const sep = t.Rect{ .x = x, .y = rect.y + 3, .w = 10, .h = h - 6 };
            const shit = ui.interactEx(idOf(id, 0x5E00 +% @as(u64, @intCast(i))), sep, opts.menus);
            ui.addText(.{ .x = x + 3, .y = rect.y + (h - 16) / 2, .w = 8, .h = 16 }, SEP, theme.font_body, theme.secondary);
            if (shit.clicked and opts.menus) {
                state.menu_segment = @intCast(i);
                state.menu_anchor = sep;
            }
            x += sep.w;
        }
    }

    // 空白区域点击 → 编辑
    const rest = t.Rect{ .x = x, .y = rect.y, .w = @max(rect.x + rect.w - x, 8), .h = h };
    if (!opts.no_edit) {
        const rh = ui.interactEx(idOf(id, 0xE017), rest, false);
        if (rh.clicked) {
            state.editing = true;
            res.editing = true;
            if (state.len == 0) {
                var k: usize = 0;
                while (k < n) : (k += 1) {
                    if (k > 0 and state.len < state.buf.len) {
                        state.buf[state.len] = '/';
                        state.len += 1;
                    }
                    for (segments[k]) |ch| {
                        if (state.len < state.buf.len) {
                            state.buf[state.len] = ch;
                            state.len += 1;
                        }
                    }
                }
                state.caret = state.len;
            }
        }
    }
    return res;
}

/// 打开兄弟菜单（返回 true 时必须配对 `pathBarMenuEnd`）。菜单内容由调用方填。
pub fn pathBarMenuBegin(ui: *core.Context, id: []const u8, state: *PathBarState, opts: overlay.PopoverOpts) bool {
    if (state.menu_segment < 0) return false;
    state.menu_open = true;
    const shown = overlay.popoverBegin(ui, id, state.menu_anchor, &state.menu_open, opts);
    if (!shown) state.menu_segment = -1;
    return shown;
}

/// 结束兄弟菜单（与 `pathBarMenuBegin` 配对）。
pub fn pathBarMenuEnd(ui: *core.Context) void {
    overlay.popoverEnd(ui);
}

// ------------------------------------------------------------------ 筛选条
pub const FilterField = struct {
    name: []const u8,
    options: []const []const u8,
};

pub const FilterBarState = struct {
    search_len: usize = 0,
    search_caret: usize = 0,
    /// 当前展开选项的字段（-1 = 无）。
    open_field: i32 = -1,
    open_anchor: t.Rect = .{},
};

/// 筛选条：搜索框 + 已选筛选 chips + 「+ Filter」。
/// `selected[i]` 是第 i 个字段的选项位掩码。返回 true 表示搜索或筛选发生了变化。
pub fn filterBar(
    ui: *core.Context,
    id: []const u8,
    fields: []const FilterField,
    selected: []u32,
    search: []u8,
    state: *FilterBarState,
    width: f32,
) bool {
    var changed = false;
    var row = ui.row(.{ .gap = 8 });
    defer row.end();

    const search_w: f32 = if (width > 200) 180 else @max(width * 0.4, 120);
    if (widgets.input(ui, id, search, &state.search_len, &state.search_caret, .{ .width = search_w, .placeholder = "Search" })) {
        changed = true;
    }

    // 已选筛选的 chips
    for (fields, 0..) |f, fi| {
        if (fi >= selected.len) break;
        const mask = selected[fi];
        if (mask == 0) continue;
        // 拼 "name: opt1, opt2"
        var label_buf: [96]u8 = @splat(0);
        var ln: usize = 0;
        for (f.name) |c| {
            if (ln < label_buf.len) {
                label_buf[ln] = c;
                ln += 1;
            }
        }
        if (ln + 2 < label_buf.len) {
            label_buf[ln] = ':';
            label_buf[ln + 1] = ' ';
            ln += 2;
        }
        var first = true;
        for (f.options, 0..) |opt, oi| {
            if (oi >= 32) break;
            if ((mask & (@as(u32, 1) << @intCast(oi))) == 0) continue;
            if (!first and ln + 2 < label_buf.len) {
                label_buf[ln] = ',';
                label_buf[ln + 1] = ' ';
                ln += 2;
            }
            for (opt) |c| {
                if (ln < label_buf.len) {
                    label_buf[ln] = c;
                    ln += 1;
                }
            }
            first = false;
        }
        const label = ui.frameStr(label_buf[0..ln]);
        const m = ui.measureText(label, theme.font_small);
        const chip = ui.reserve(m.w + 42, 28, false);
        const hit = ui.interactEx(idOf(id, 0xC41C +% @as(u64, @intCast(fi))), chip, true);
        widgets.ringBox(ui, chip, theme.radius_pill, t.Color.hex(0xE8EFFD, 255), theme.accent);
        ui.addText(.{ .x = chip.x + 10, .y = chip.y + (chip.h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, theme.accent);
        // 右侧 × 清除
        const xr = t.Rect{ .x = chip.x + chip.w - 20, .y = chip.y + (chip.h - 14) / 2, .w = 14, .h = 14 };
        ui.addOverlayLine(.{ .x = xr.x + 3, .y = xr.y + 3 }, .{ .x = xr.x + 11, .y = xr.y + 11 }, 1.3, theme.accent);
        ui.addOverlayLine(.{ .x = xr.x + 11, .y = xr.y + 3 }, .{ .x = xr.x + 3, .y = xr.y + 11 }, 1.3, theme.accent);
        if (hit.clicked) {
            // 点 chip 打开该字段的选项下拉；点 × 清空
            if (ui.input.mouse.x >= xr.x - 2) {
                selected[fi] = 0;
            } else {
                state.open_field = @intCast(fi);
                state.open_anchor = chip;
            }
            changed = true;
        }
    }

    // “+ Filter”
    {
        const label = "+ Filter";
        const m = ui.measureText(label, theme.font_small);
        const b = ui.reserve(m.w + 20, 28, false);
        const hit = ui.interactEx(idOf(id, 0xF117), b, true);
        widgets.ringBox(ui, b, theme.radius_pill, theme.bg, if (hit.hover) theme.accent else theme.border);
        ui.addText(
            .{ .x = b.x + (b.w - m.w) / 2, .y = b.y + (b.h - m.h) / 2, .w = m.w, .h = m.h },
            label,
            theme.font_small,
            if (hit.hover) theme.accent else theme.secondary,
        );
        if (hit.clicked) {
            // 打开「有可用选项的字段」列表：用第一个还没选的字段
            for (fields, 0..) |_, fi| {
                if (fi >= selected.len) break;
                if (selected[fi] == 0) {
                    state.open_field = @intCast(fi);
                    state.open_anchor = b;
                    break;
                }
            }
        }
    }

    // 选项下拉（浮层，多选）
    if (state.open_field >= 0 and @as(usize, @intCast(state.open_field)) < fields.len) {
        const fi: usize = @intCast(state.open_field);
        const f = fields[fi];
        var open = true;
        if (overlay.popoverBegin(ui, "filter-menu", state.open_anchor, &open, .{ .width = 200, .estimate_h = 40 + 26 * @as(f32, @floatFromInt(f.options.len)) })) {
            _ = ui.textRun(f.name, theme.font_small, theme.secondary);
            for (f.options, 0..) |opt, oi| {
                if (oi >= 32) break;
                const bit = @as(u32, 1) << @intCast(oi);
                var on = fi < selected.len and (selected[fi] & bit) != 0;
                const before = on;
                widgets.checkbox(ui, opt, &on);
                if (on != before) {
                    if (fi < selected.len) {
                        if (on) selected[fi] |= bit else selected[fi] &= ~bit;
                    }
                    changed = true;
                }
            }
            if (widgets.button(ui, "Clear", .{ .variant = .ghost })) {
                if (fi < selected.len) selected[fi] = 0;
                changed = true;
                open = false;
            }
            overlay.popoverEnd(ui);
        }
        if (!open) state.open_field = -1;
    }
    return changed;
}
