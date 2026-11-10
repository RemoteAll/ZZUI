//! 表格族（对位 CUI 的 `cui_grid.c` / `cui_treetable.c` 公开件）：
//! 数据表格（列头排序、行选中、斑马纹、可选滚动）与树形表格（缩进 + 展开折叠）。
//!
//! 形状是**流式**的（`begin` → `row` → `cell` → `end`），与 CUI 一致：
//! 行矩形一次占位、单元格按列宽切片，因此单元格里可以放任意绘制内容。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

pub const Align = enum { start, center, end };

pub const Column = struct {
    label: []const u8,
    /// 0 表示弹性列（吃掉剩余宽度，多个弹性列平均分）。
    width: f32 = 0,
    /// 文本对齐（`align` 是 Zig 关键字，故加前缀）
    text_align: Align = .start,
    sortable: bool = false,
};

pub const SortState = struct {
    column: ?usize = null,
    desc: bool = false,
};

pub const TableOpts = struct {
    row_h: f32 = 32,
    header_h: f32 = 34,
    /// > 0 时正文区滚动（表头固定）。
    height: f32 = 0,
    striped: bool = true,
    /// 单元格左右内边距。
    pad: f32 = 10,
    font: f32 = theme.font_body,
};

pub const Table = struct {
    ui: *core.Context,
    id: u64,
    columns: []const Column,
    sort: *SortState,
    opts: TableOpts,
    width: f32,
    /// 正文区滚动作用域（仅 `opts.height > 0` 时存在）。
    scroll: ?core.ScrollScope = null,

    /// 结束表格（关闭滚动区）。
    pub fn end(self: *Table) void {
        if (self.scroll) |*s| s.end();
        self.scroll = null;
    }

    fn columnWidth(self: *const Table, idx: usize) f32 {
        if (idx >= self.columns.len) return 0;
        const c = self.columns[idx];
        if (c.width > 0) return c.width;
        var fixed: f32 = 0;
        var flex: usize = 0;
        for (self.columns) |col| {
            if (col.width > 0) fixed += col.width else flex += 1;
        }
        if (flex == 0) return 0;
        const rem = self.width - fixed;
        return if (rem > 40) rem / @as(f32, @floatFromInt(flex)) else 60;
    }

    /// 开始一行：整行占位、画背景、登记点击。返回行句柄。
    pub fn row(self: *Table, index: usize, selected: bool) Row {
        const ui = self.ui;
        const rect = ui.reserve(0, self.opts.row_h, true);
        const row_id = self.id ^ (0x1200 + @as(u64, @intCast(index)));
        const it = ui.interactEx(row_id, rect, true);

        if (selected) {
            ui.addBox(rect, .{ .fill = t.Color.hex(0xE8EFFD, 255) });
        } else if (it.hover) {
            ui.addBox(rect, .{ .fill = theme.surface });
        } else if (self.opts.striped and (index % 2) == 1) {
            ui.addBox(rect, .{ .fill = t.Color.hex(0xFAFBFC, 255) });
        }
        // 行分隔线
        ui.addBox(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, .{ .fill = t.Color.hex(0xEDF0F3, 255) });

        return .{ .table = self, .rect = rect, .clicked = it.clicked };
    }
};

pub const Row = struct {
    table: *Table,
    rect: t.Rect,
    clicked: bool = false,

    /// 第 `idx` 列的矩形（纯计算，不推进布局）。
    pub fn cell(self: *const Row, idx: usize) t.Rect {
        var x = self.rect.x;
        var i: usize = 0;
        while (i < idx and i < self.table.columns.len) : (i += 1) x += self.table.columnWidth(i);
        return .{ .x = x, .y = self.rect.y, .w = self.table.columnWidth(idx), .h = self.rect.h };
    }

    /// 便捷：在单元格里画一行文本（按列对齐、超宽省略）。
    pub fn text(self: *const Row, idx: usize, s: []const u8, color: t.Color) void {
        const r = self.cell(idx);
        const c = if (idx < self.table.columns.len) self.table.columns[idx] else Column{ .label = "" };
        const m = self.table.ui.measureText(s, self.table.opts.font);
        const pad = self.table.opts.pad;
        const inner = r.w - pad * 2;
        var shown = s;
        if (m.w > inner and s.len > 0) {
            // 超宽：按字符逐步截断（保持 UTF-8 边界）
            var end: usize = 0;
            while (end < s.len) {
                const n = std.unicode.utf8ByteSequenceLength(s[end]) catch 1;
                const next = @min(end + n, s.len);
                if (self.table.ui.measureText(s[0..next], self.table.opts.font).w > inner - 8) break;
                end = next;
            }
            shown = s[0..end];
        }
        const sm = self.table.ui.measureText(shown, self.table.opts.font);
        const tx = switch (c.text_align) {
            .start => r.x + pad,
            .center => r.x + (r.w - sm.w) / 2,
            .end => r.x + r.w - pad - sm.w,
        };
        self.table.ui.addText(.{ .x = tx, .y = r.y + (r.h - sm.h) / 2, .w = sm.w, .h = sm.h }, shown, self.table.opts.font, color);
    }
};

/// 开始表格：画表头（可排序列点击切换排序）、按需打开正文滚动区。
pub fn begin(
    ui: *core.Context,
    id: []const u8,
    columns: []const Column,
    sort: *SortState,
    opts: TableOpts,
) Table {
    const header = ui.reserve(0, opts.header_h, true);
    const width = header.w;
    const id_hash = core.Context.idOf(id);

    // 表头底色
    ui.addBox(header, .{ .fill = t.Color.hex(0xF7F8FA, 255) });
    ui.addBox(.{ .x = header.x, .y = header.y + header.h - 1, .w = header.w, .h = 1 }, .{ .fill = theme.border });

    var x = header.x;
    for (columns, 0..) |c, i| {
        var w = c.width;
        if (w <= 0) {
            // 弹性列：与 Table.columnWidth 同口径
            var fixed: f32 = 0;
            var flex: usize = 0;
            for (columns) |col| {
                if (col.width > 0) fixed += col.width else flex += 1;
            }
            const rem = width - fixed;
            w = if (flex > 0 and rem > 40) rem / @as(f32, @floatFromInt(flex)) else 60;
        }
        const r = t.Rect{ .x = x, .y = header.y, .w = w, .h = header.h };
        x += w;

        const hdr_id = id_hash ^ (0x1100 + @as(u64, i));
        const it = ui.interactEx(hdr_id, r, c.sortable);
        if (c.sortable and (it.clicked or it.activated)) {
            if (sort.column != null and sort.column.? == i) {
                sort.desc = !sort.desc;
            } else {
                sort.column = i;
                sort.desc = false;
            }
        }
        if (c.sortable and it.hover) ui.addBox(r.inset(2), .{ .fill = theme.surface, .radius = 6 });

        const m = ui.measureText(c.label, theme.font_small);
        const tx = switch (c.text_align) {
            .start => r.x + opts.pad,
            .center => r.x + (r.w - m.w) / 2,
            .end => r.x + r.w - opts.pad - m.w,
        };
        ui.addText(.{ .x = tx, .y = r.y + (r.h - m.h) / 2, .w = m.w, .h = m.h }, c.label, theme.font_small, theme.secondary);

        // 排序指示：升序向上三角、降序向下三角
        if (sort.column != null and sort.column.? == i) {
            const ax = tx + m.w + 8;
            const ay = r.y + r.h / 2;
            const col = if (sort.desc) theme.accent else theme.text;
            if (sort.desc) {
                ui.addOverlayLine(.{ .x = ax - 4, .y = ay - 2 }, .{ .x = ax + 4, .y = ay - 2 }, 1.6, col);
                ui.addOverlayLine(.{ .x = ax - 4, .y = ay - 2 }, .{ .x = ax, .y = ay + 4 }, 1.6, col);
                ui.addOverlayLine(.{ .x = ax + 4, .y = ay - 2 }, .{ .x = ax, .y = ay + 4 }, 1.6, col);
            } else {
                ui.addOverlayLine(.{ .x = ax - 4, .y = ay + 2 }, .{ .x = ax + 4, .y = ay + 2 }, 1.6, col);
                ui.addOverlayLine(.{ .x = ax - 4, .y = ay + 2 }, .{ .x = ax, .y = ay - 4 }, 1.6, col);
                ui.addOverlayLine(.{ .x = ax + 4, .y = ay + 2 }, .{ .x = ax, .y = ay - 4 }, 1.6, col);
            }
        }
    }

    var tbl = Table{
        .ui = ui,
        .id = id_hash,
        .columns = columns,
        .sort = sort,
        .opts = opts,
        .width = width,
    };
    if (opts.height > 0) {
        tbl.scroll = ui.scroll(.{ .id = id, .height = opts.height, .gap = 0 });
    }
    return tbl;
}

// ------------------------------------------------------------------ 树形表格

pub const TreeRow = struct {
    depth: u8 = 0,
    has_children: bool = false,
    expanded: bool = true,
};

/// 每层缩进步长。
pub const tree_indent: f32 = 16;
/// 展开三角的点击区宽度。
pub const tree_twisty_w: f32 = 18;

pub const TreeResult = struct {
    /// 行句柄（可继续用 `row.text()` 画其它列）。
    row: Row,
    /// 本帧点击了展开三角。
    toggled: bool = false,
};

/// 树表的一行：第一列自动带缩进与展开三角（三角点击只切换展开，不触发行点击）。
pub fn treeRow(tbl: *Table, index: usize, row_node: *TreeRow, label: []const u8, selected: bool) TreeResult {
    const r = tbl.row(index, selected);
    const ui = tbl.ui;
    const c0 = r.cell(0);
    const indent = @as(f32, @floatFromInt(row_node.depth)) * tree_indent;
    const tw_x = c0.x + tbl.opts.pad + indent;
    const tw_y = c0.y + c0.h / 2;

    var out = TreeResult{ .row = r };

    if (row_node.has_children) {
        const tw = t.Rect{ .x = tw_x, .y = c0.y + (c0.h - tree_twisty_w) / 2, .w = tree_twisty_w, .h = tree_twisty_w };
        const it = ui.interactEx(tbl.id ^ (0x1300 + @as(u64, @intCast(index))), tw, true);
        if (it.hover) ui.addBox(tw, .{ .fill = theme.track, .radius = 4 });
        if (it.clicked or it.activated) {
            row_node.expanded = !row_node.expanded;
            out.toggled = true;
        }
        const col = theme.secondary;
        if (row_node.expanded) {
            ui.addOverlayLine(.{ .x = tw_x + 4, .y = tw_y - 2 }, .{ .x = tw_x + 12, .y = tw_y - 2 }, 1.5, col);
            ui.addOverlayLine(.{ .x = tw_x + 4, .y = tw_y - 2 }, .{ .x = tw_x + 8, .y = tw_y + 3 }, 1.5, col);
            ui.addOverlayLine(.{ .x = tw_x + 12, .y = tw_y - 2 }, .{ .x = tw_x + 8, .y = tw_y + 3 }, 1.5, col);
        } else {
            ui.addOverlayLine(.{ .x = tw_x + 5, .y = tw_y - 5 }, .{ .x = tw_x + 10, .y = tw_y }, 1.5, col);
            ui.addOverlayLine(.{ .x = tw_x + 5, .y = tw_y + 5 }, .{ .x = tw_x + 10, .y = tw_y }, 1.5, col);
            ui.addOverlayLine(.{ .x = tw_x + 5, .y = tw_y - 5 }, .{ .x = tw_x + 5, .y = tw_y + 5 }, 1.5, col);
        }
    }

    const tx = tw_x + (if (row_node.has_children) tree_twisty_w + 4 else 0);
    const m = ui.measureText(label, tbl.opts.font);
    ui.addText(.{ .x = tx, .y = c0.y + (c0.h - m.h) / 2, .w = m.w, .h = m.h }, label, tbl.opts.font, theme.text);
    return out;
}
