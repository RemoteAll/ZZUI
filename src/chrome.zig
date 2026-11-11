//! 应用外壳（对位 CUI 的 `cui_chrome.c`）：菜单栏 / 工具栏 / 状态栏 / 文档标签。
//!
//! 这些都是「组合件」：内部只调用已有的 `widgets`（button / menu / ringBox）与基础绘制，
//! 不复制控件实现；因此体积增量很小（纯布局 + 线段）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const t = @import("types.zig");

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

// ------------------------------------------------------------------ 菜单栏

pub const MenuDef = struct {
    label: []const u8,
    items: []const widgets.MenuItem,
};

pub const MenuPick = struct {
    menu: usize = 0,
    item: usize = 0,
};

pub const MenuBarOpts = struct {
    pad: f32 = 4,
    gap: f32 = 2,
    item_h: f32 = 28,
    /// 下拉宽度。
    menu_w: f32 = 180,
};

/// 菜单栏：点菜单名展开下拉（只允许一个菜单同时打开），点空白/Esc 关闭。
/// 返回被选中的「哪个菜单的第几项」。
pub fn menuBar(ui: *core.Context, id: []const u8, menus: []const MenuDef, open: *?usize, opts: MenuBarOpts) ?MenuPick {
    var picked: ?MenuPick = null;
    const rect = ui.reserve(0, opts.item_h + opts.pad * 2, true);

    var bar = ui.panel(rect, .{
        .pad = opts.pad,
        .gap = opts.gap,
        .dir = .row,
        .fill = theme.raised,
        .border = theme.border,
    });
    defer bar.end();

    for (menus, 0..) |m, i| {
        const text_m = ui.measureText(m.label, theme.font_body);
        const w = text_m.w + 20;
        const btn = ui.reserve(w, opts.item_h, false);
        const it = ui.interactEx(idOf(id, 0xBA5E + @as(u64, i)), btn, true);
        const is_open = open.* != null and open.*.? == i;
        if (it.clicked or it.activated) {
            open.* = if (is_open) null else i;
        }
        if (is_open) {
            ui.addBox(btn, .{ .fill = theme.surface, .radius = 6 });
        } else if (it.hover) {
            ui.addBox(btn, .{ .fill = theme.hair, .radius = 6 });
        }
        ui.addText(.{
            .x = btn.x + (btn.w - text_m.w) / 2,
            .y = btn.y + (btn.h - text_m.h) / 2,
            .w = text_m.w,
            .h = text_m.h,
        }, m.label, theme.font_body, theme.text);

        if (is_open) {
            var still_open = true;
            if (widgets.menu(ui, id, btn, m.items, &still_open, .{
                .width = opts.menu_w,
                .item_h = 28,
                .pad = 5,
                .gap = 0,
                .id_salt = 0x4D3E + @as(u64, i) * 0x1000,
            })) |idx| {
                picked = .{ .menu = i, .item = idx };
            }
            if (!still_open) open.* = null;
        }
    }
    return picked;
}

// ------------------------------------------------------------------ 工具栏

pub const ToolbarOpts = struct {
    pad: f32 = 6,
    gap: f32 = 4,
    height: f32 = 36,
};

/// 工具栏开始（返回需要配对的 `toolbarEnd`）。
pub fn toolbarBegin(ui: *core.Context, opts: ToolbarOpts) void {
    const rect = ui.reserve(0, opts.height + opts.pad * 2, true);
    _ = ui.panel(rect, .{
        .pad = opts.pad,
        .gap = opts.gap,
        .dir = .row,
        .fill = theme.bg,
        .border = theme.border,
    });
}

pub fn toolbarEnd(ui: *core.Context) void {
    ui.endPanel();
}

/// 工具栏按钮（小号 ghost）。
pub fn toolbarButton(ui: *core.Context, label: []const u8) bool {
    const m = ui.measureText(label, theme.font_body);
    const h: f32 = 28;
    const w = m.w + 18;
    const r = ui.reserve(w, h, false);
    return widgets.buttonRect(ui, r, label, .{ .variant = .ghost, .width = w });
}

/// 工具栏分隔线。
pub fn toolbarSeparator(ui: *core.Context) void {
    const r = ui.reserve(9, 28, false);
    ui.addBox(.{ .x = r.x + 4, .y = r.y + 5, .w = 1, .h = r.h - 10 }, .{ .fill = theme.border });
}

/// 工具栏弹性间隔（把后续项推远一点；固定宽度，不做「推到最右」）。
pub fn toolbarSpacer(ui: *core.Context, width: f32) void {
    _ = ui.reserve(@max(width, 4), 28, false);
}

// ------------------------------------------------------------------ 状态栏

pub const StatusKind = enum { text, accent, success, warn, danger };

pub const StatusItem = struct {
    label: []const u8,
    kind: StatusKind = .text,
    /// 可点击（返回下标）。
    clickable: bool = false,
};

pub const StatusPick = struct {
    /// true = 右侧分组。
    right: bool = false,
    index: usize = 0,
};

pub const StatusBarOpts = struct {
    height: f32 = 26,
    pad: f32 = 10,
    gap: f32 = 14,
};

fn statusColor(kind: StatusKind) t.Color {
    return switch (kind) {
        .text => theme.secondary,
        .accent => theme.accent,
        .success => theme.success,
        .warn => theme.warn,
        .danger => theme.danger,
    };
}

/// 状态栏：左侧项从左排、右侧项右对齐（一次布局，支持点击）。
pub fn statusBar(
    ui: *core.Context,
    id: []const u8,
    left: []const StatusItem,
    right: []const StatusItem,
    opts: StatusBarOpts,
) ?StatusPick {
    const rect = ui.reserve(0, opts.height, true);
    ui.addBox(rect, .{ .fill = theme.raised });
    ui.addBox(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, .{ .fill = theme.border });

    var picked: ?StatusPick = null;

    // 右侧：从右往左排（先量宽再定 x）
    var rx = rect.x + rect.w - opts.pad;
    var i = right.len;
    while (i > 0) {
        i -= 1;
        const item = right[i];
        const m = ui.measureText(item.label, theme.font_small);
        rx -= m.w;
        const r = t.Rect{ .x = rx, .y = rect.y + 1, .w = m.w, .h = rect.h - 1 };
        if (item.clickable) {
            const it = ui.interactEx(idOf(id, 0x5BAD + @as(u64, i)), r, true);
            if (it.clicked or it.activated) picked = .{ .right = true, .index = i };
            if (it.hover) ui.addBox(r.inset(-2), .{ .fill = theme.track, .radius = 4 });
        }
        ui.addText(.{ .x = r.x, .y = r.y + (r.h - m.h) / 2, .w = m.w, .h = m.h }, item.label, theme.font_small, statusColor(item.kind));
        rx -= opts.gap;
    }

    // 左侧：从左往右
    var lx = rect.x + opts.pad;
    for (left, 0..) |item, li| {
        const m = ui.measureText(item.label, theme.font_small);
        const r = t.Rect{ .x = lx, .y = rect.y + 1, .w = m.w, .h = rect.h - 1 };
        if (item.clickable) {
            const it = ui.interactEx(idOf(id, 0x51EF + @as(u64, li)), r, true);
            if (it.clicked or it.activated) picked = .{ .right = false, .index = li };
            if (it.hover) ui.addBox(r.inset(-2), .{ .fill = theme.track, .radius = 4 });
        }
        ui.addText(.{ .x = r.x, .y = r.y + (r.h - m.h) / 2, .w = m.w, .h = m.h }, item.label, theme.font_small, statusColor(item.kind));
        lx += m.w + opts.gap;
    }
    return picked;
}

// ------------------------------------------------------------------ 文档标签

pub const DocTab = struct {
    label: []const u8,
    /// 未保存标记（右侧圆点）。
    dirty: bool = false,
};

pub const DocTabsOpts = struct {
    height: f32 = 32,
    pad: f32 = 0,
    gap: f32 = 2,
    /// 是否显示关闭按钮。
    closable: bool = true,
};

pub const DocTabsResult = struct {
    /// 本帧点中的标签下标。
    clicked: ?usize = null,
    /// 本帧点了关闭按钮的标签下标（点关闭也视为 clicked）。
    closed: ?usize = null,
};

/// 文档标签条：横向标签 + 关闭按钮（×），选中项高亮并与内容区连成一体。
pub fn docTabs(
    ui: *core.Context,
    id: []const u8,
    tabs: []const DocTab,
    selected: *usize,
    opts: DocTabsOpts,
) DocTabsResult {
    var result = DocTabsResult{};

    const rect = ui.reserve(0, opts.height, true);
    var bar = ui.panel(rect, .{
        .pad = opts.pad,
        .gap = opts.gap,
        .dir = .row,
        .fill = theme.bg,
        .border = theme.border,
    });
    defer bar.end();

    for (tabs, 0..) |tab, i| {
        const m = ui.measureText(tab.label, theme.font_small);
        const close_w: f32 = if (opts.closable) 18 else 0;
        const w = m.w + 22 + close_w;
        const r = ui.reserve(w, opts.height, false);
        const it = ui.interactEx(idOf(id, 0x0C7A + @as(u64, i)), r, true);
        const on = selected.* == i;

        if (on) {
            ui.addBox(r, .{ .fill = theme.bg, .radius = 0 });
            // 顶部强调线
            ui.addBox(.{ .x = r.x, .y = r.y, .w = r.w, .h = 2 }, .{ .fill = theme.accent });
            ui.addBox(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, .{ .fill = theme.border });
        } else if (it.hover) {
            ui.addBox(r, .{ .fill = theme.surface, .radius = 0 });
        }
        ui.addText(.{
            .x = r.x + 10,
            .y = r.y + (r.h - m.h) / 2,
            .w = m.w,
            .h = m.h,
        }, tab.label, theme.font_small, if (on) theme.text else theme.secondary);

        // 未保存圆点 / 关闭叉
        if (opts.closable) {
            const cr = t.Rect{ .x = r.x + r.w - 18, .y = r.y + (r.h - 16) / 2, .w = 16, .h = 16 };
            const cit = ui.interactEx(idOf(id, 0x0C10 + @as(u64, i)), cr, false);
            if (cit.clicked) {
                result.closed = i;
                result.clicked = i;
            } else if (cit.hover) {
                ui.addBox(cr, .{ .fill = theme.track, .radius = 4 });
            }
            if (tab.dirty) {
                ui.addBox(.{ .x = cr.x + 5, .y = cr.y + 5, .w = 6, .h = 6 }, .{ .fill = theme.secondary, .radius = 3 });
            } else {
                const cx = cr.x + cr.w / 2;
                const cy = cr.y + cr.h / 2;
                ui.addOverlayLine(.{ .x = cx - 3, .y = cy - 3 }, .{ .x = cx + 3, .y = cy + 3 }, 1.2, theme.secondary);
                ui.addOverlayLine(.{ .x = cx + 3, .y = cy - 3 }, .{ .x = cx - 3, .y = cy + 3 }, 1.2, theme.secondary);
            }
        } else if (tab.dirty) {
            ui.addBox(.{ .x = r.x + r.w - 12, .y = r.y + r.h / 2 - 3, .w = 6, .h = 6 }, .{ .fill = theme.secondary, .radius = 3 });
        }

        if (it.clicked or it.activated) {
            selected.* = i;
            if (result.clicked == null) result.clicked = i;
        }
    }
    return result;
}
