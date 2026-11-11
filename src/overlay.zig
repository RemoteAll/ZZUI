//! 浮层族（对位 CUI 的 `cui_overlay.c` 公开件）：提示条 / 锚定浮层 / 下拉选择 /
//! 上下文菜单 / 命令面板。
//!
//! 与 `widgets.menu`、`widgets.dialog` 同一口径：状态由调用方保存，输入对上一帧矩形判定。
//! 浮层栈可嵌套（`beginOverlay` 每层 +1），但一次只应打开一层交互浮层。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const extras = @import("extras.zig");
const t = @import("types.zig");

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ------------------------------------------------------------------ toast

pub const ToastKind = enum { info, success, warn, danger };

pub const ToastOpts = struct {
    kind: ToastKind = .info,
    /// 显示时长（秒）；<= 0 表示不自动消失。
    ttl: f64 = 3.0,
    /// 堆叠槽位：0 在最下面，往上叠。
    slot: usize = 0,
    width: f32 = 280,
    margin: f32 = 16,
};

/// 右下角提示条。`since` 由调用方保存（**初始值写 -1**表示尚未开始显示），
/// 超过 `ttl` 自动把 `open` 置为 false 并返回 false。
pub fn toast(ui: *core.Context, id: []const u8, label: []const u8, open: *bool, since: *f64, opts: ToastOpts) bool {
    _ = id;
    if (!open.*) {
        since.* = -1;
        return false;
    }
    if (since.* < 0) since.* = ui.time;
    // 有 ttl 就要持续出帧，否则空闲节流后它永远不会自己消失
    if (opts.ttl > 0) ui.requestFrame();
    if (opts.ttl > 0 and ui.time - since.* >= opts.ttl) {
        open.* = false;
        since.* = -1;
        return false;
    }

    const m = ui.measureText(label, theme.font_body);
    const h: f32 = m.h + 20;
    const w = @max(opts.width, m.w + 40);
    const x = ui.width - opts.margin - w;
    const y = ui.height - opts.margin - (h + 8) * (@as(f32, @floatFromInt(opts.slot)) + 1);

    var ov = ui.beginOverlay(.{ .dim = null, .hit = false });
    defer ov.end();

    const tone: extras.Tone = switch (opts.kind) {
        .info => .accent,
        .success => .success,
        .warn => .warn,
        .danger => .danger,
    };
    const c = extras.toneColors(tone);
    // toast 是**反色浮层**：底与文字必须成对取令牌（拿 `theme.text` 当底，深色模式下就会变成浅底浅字）
    ui.addBox(.{ .x = x, .y = y, .w = w, .h = h }, .{ .fill = theme.overlay_bg, .radius = 10 });
    ui.addBox(.{ .x = x, .y = y, .w = 4, .h = h }, .{ .fill = c.bg, .radius = 2 });
    ui.addText(.{ .x = x + 14, .y = y + (h - m.h) / 2, .w = m.w + 4, .h = m.h }, label, theme.font_body, theme.overlay_fg);
    return true;
}

// ------------------------------------------------------------------ popover

pub const PopoverOpts = struct {
    width: f32 = 240,
    pad: f32 = 12,
    gap: f32 = 6,
    radius: f32 = 12,
    /// null = 跟随主题。
    fill: ?t.Color = null,
    /// 打开时是否压暗页面（默认不压暗，只拦外部点击）。
    dim: ?t.Color = null,
    /// 向上弹出（需要 `estimate_h` 才能定位）。
    above: bool = false,
    estimate_h: f32 = 180,
};

/// 锚定浮层开始：返回 true 时必须配对调用 `popoverEnd`。
/// 点外部会关闭浮层并把 `open` 写成 false。
pub fn popoverBegin(ui: *core.Context, id: []const u8, anchor: t.Rect, open: *bool, opts: PopoverOpts) bool {
    if (!open.*) return false;
    _ = ui.beginOverlay(.{ .dim = opts.dim, .hit = true, .id = idOf(id, 0xB0B0B0) });
    if (ui.overlayBackdropClicked()) {
        ui.endOverlay();
        open.* = false;
        return false;
    }

    const w = opts.width;
    var x = anchor.x;
    var y = anchor.y + anchor.h + opts.gap;
    if (opts.above) y = anchor.y - opts.estimate_h - opts.gap;
    if (y + opts.estimate_h > ui.height - 8 and !opts.above) y = anchor.y - opts.estimate_h - opts.gap;
    if (x + w > ui.width - 8) x = ui.width - w - 8;
    if (x < 8) x = 8;
    // 锚点可能在滚动视口之外：定位结果必须夹回窗口，否则面板会画到屏幕外
    const max_y = ui.height - 8 - opts.estimate_h;
    if (y > max_y) y = max_y;
    if (y < 8) y = 8;

    _ = ui.panel(.{ .x = x, .y = y, .w = w, .h = 0 }, .{
        .pad = opts.pad,
        .gap = 8,
        .fill = opts.fill orelse theme.bg,
        .radius = opts.radius,
        .border = theme.border,
        .auto_height = true,
    });
    return true;
}

/// 结束锚定浮层（与 `popoverBegin` 配对）。
pub fn popoverEnd(ui: *core.Context) void {
    ui.endPanel();
    ui.endOverlay();
}

// ------------------------------------------------------------------ select

pub const SelectOpts = struct {
    width: f32 = 220,
    item_h: f32 = 30,
    item_pad: f32 = 6,
};

/// 下拉字段（页面阶段）：显示当前项，点击展开。返回字段矩形，作为弹出层的锚点。
pub fn selectField(
    ui: *core.Context,
    id: []const u8,
    items: []const []const u8,
    selected: *usize,
    open: *bool,
    opts: SelectOpts,
) t.Rect {
    const cur = if (selected.* < items.len) items[selected.*] else "";
    const m = ui.measureText(cur, theme.font_body);
    const h: f32 = 34;
    const rect = ui.reserve(opts.width, h, false);
    const it = ui.interactEx(idOf(id, 0x5E1EC7), rect, true);
    if (it.clicked or it.activated) open.* = !open.*;

    widgets.ringBox(ui, rect, theme.radius_control, if (it.hover) theme.surface else theme.bg, theme.border);
    ui.addText(.{ .x = rect.x + 12, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, cur, theme.font_body, theme.text);
    if (it.focused) ui.addBox(rect.inset(-2), .{ .border = theme.accent, .radius = theme.radius_control + 2 });
    const ax = rect.x + rect.w - 16;
    const ay = rect.y + h / 2 - 2;
    ui.addOverlayLine(.{ .x = ax - 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
    ui.addOverlayLine(.{ .x = ax + 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
    return rect;
}

/// 下拉弹层（浮层阶段，在页面内容之后调用）：返回 true 表示选择发生了变化。
pub fn selectPopup(
    ui: *core.Context,
    id: []const u8,
    anchor: t.Rect,
    items: []const []const u8,
    selected: *usize,
    open: *bool,
    opts: SelectOpts,
) bool {
    if (!open.*) return false;

    // 列表项：MenuItem 由标签数组现构造（上限 32 项，够下拉用）
    var buf: [32]widgets.MenuItem = @splat(.{ .label = "" });
    const n = @min(items.len, buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = .{ .label = items[i] };
    const picked = widgets.menu(ui, id, anchor, buf[0..n], open, .{
        .width = opts.width,
        .item_h = opts.item_h,
        .pad = opts.item_pad,
        .gap = 4,
    });
    if (picked) |idx| {
        selected.* = idx;
        return true;
    }
    return false;
}

/// 便捷组合（字段 + 弹层一次性完成）。注意：弹层会紧跟字段建在当前容器里，
/// 页面内容多时请改用 `selectField` + `selectPopup` 分两阶段调用。
pub fn select(
    ui: *core.Context,
    id: []const u8,
    items: []const []const u8,
    selected: *usize,
    open: *bool,
    opts: SelectOpts,
) bool {
    const anchor = selectField(ui, id, items, selected, open, opts);
    return selectPopup(ui, id, anchor, items, selected, open, opts);
}

// ------------------------------------------------------------------ context menu

/// 上下文菜单：`at` 是右键位置。调用方在 `ui.input.right_click` 时置 `open = true` 并记录位置。
pub fn contextMenu(
    ui: *core.Context,
    id: []const u8,
    items: []const widgets.MenuItem,
    open: *bool,
    at: t.Point,
) ?usize {
    if (!open.*) return null;
    const anchor = t.Rect{ .x = at.x, .y = at.y, .w = 0, .h = 0 };
    return widgets.menu(ui, id, anchor, items, open, .{ .gap = 0 });
}

// ------------------------------------------------------------------ command palette

pub const PaletteOpts = struct {
    width: f32 = 440,
    item_h: f32 = 32,
    pad: f32 = 12,
    /// 面板距窗口顶部。
    top: f32 = 72,
    /// 最多显示的匹配项。
    max_items: usize = 6,
};

/// 命令面板：顶部居中，边输入边过滤（大小写不敏感子串），Esc 关闭。
/// 返回被点中的原始下标（`items` 里的位置）。
pub fn commandPalette(
    ui: *core.Context,
    id: []const u8,
    buf: []u8,
    len: *usize,
    caret: *usize,
    items: []const []const u8,
    open: *bool,
    opts: PaletteOpts,
) ?usize {
    if (!open.*) return null;

    var ov = ui.beginOverlay(.{ .dim = t.Color.hex(0x000000, 90), .hit = true });
    defer ov.end();

    if (ui.overlayBackdropClicked() or ui.input.keyPressed(.escape)) {
        open.* = false;
        return null;
    }

    const w = opts.width;
    const x = (ui.width - w) / 2;
    _ = ui.panel(.{ .x = x, .y = opts.top, .w = w, .h = 0 }, .{
        .pad = opts.pad,
        .gap = 8,
        .fill = theme.bg,
        .radius = 14,
        .border = theme.border,
        .auto_height = true,
    });
    defer ui.endPanel();

    _ = widgets.input(ui, "palette-input", buf, len, caret, .{ .placeholder = "Type a command" });

    const query = buf[0..len.*];
    var shown: usize = 0;
    var picked: ?usize = null;
    for (items, 0..) |label, i| {
        if (!containsIgnoreCase(label, query)) continue;
        if (shown >= opts.max_items) break;
        shown += 1;

        const m = ui.measureText(label, theme.font_body);
        const r = ui.reserve(0, opts.item_h, true);
        const it = ui.interactEx(idOf(id, 0xF00D0000 + i), r, true);
        if (it.hover) ui.addBox(r, .{ .fill = theme.surface, .radius = 6 });
        ui.addText(.{ .x = r.x + 8, .y = r.y + (r.h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, theme.text);
        if (it.clicked) picked = i;
    }
    if (shown == 0) extras.muted(ui, "No matching command");
    if (picked != null) open.* = false;
    return picked;
}
