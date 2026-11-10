//! 程序坞（对位 CUI `cui_dock.c`）：一排图标，指针经过时放大，运行中的应用下方带点，可带徽标。
//!
//! 与 `dockspace.zig` 的区别：这里是 **macOS 风格的应用坞**（图标行，悬停放大），
//! 不是可拖拽分割的面板停靠布局（那个在 `dockspace.zig`）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const num = @import("num.zig");
const t = @import("types.zig");

pub const DockOpts = struct {
    /// 基础图标尺寸。
    size: f32 = 40,
    /// 悬停时的放大倍数（1.0 = 不放大）。
    magnify: f32 = 1.35,
    /// 图标之间的间距。
    gap: f32 = 8,
};

pub const DockItemOpts = struct {
    /// 图标底色（null = 按序号取调色板）。
    color: ?t.Color = null,
    /// 正在运行（底部画一个小点）。
    running: bool = false,
    /// > 0 时右上角显示数字徽标。
    badge: u32 = 0,
};

pub const DockState = struct {
    /// 本帧已放置的图标数（`dockItem` 自增，用于定位与配色）。
    at: usize = 0,
    /// 分隔符额外占用的宽度。
    extra: f32 = 0,
    base: t.Rect = .{},
    opts: DockOpts = .{},
    opened: bool = false,
};

var st: DockState = .{};

const palette = [_]t.Color{
    t.Color.hex(0x2563EB, 255),
    t.Color.hex(0x0891B2, 255),
    t.Color.hex(0x15803D, 255),
    t.Color.hex(0xB45309, 255),
    t.Color.hex(0x7C3AED, 255),
    t.Color.hex(0xB91C1C, 255),
};

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

/// 开始程序坞：占一整行（高度 = size * magnify + 标签余量）。
pub fn dockBegin(ui: *core.Context, id: []const u8, state: *DockState, opts: DockOpts) void {
    state.at = 0;
    state.extra = 0;
    state.opts = opts;
    const h = opts.size * @max(opts.magnify, 1.0) + 22;
    state.base = ui.reserve(0, h, true);
    state.opened = true;
    st = state.*;
    // 底座
    ui.addBox(
        .{ .x = state.base.x, .y = state.base.y + 4, .w = state.base.w, .h = h - 8 },
        .{ .fill = t.Color.hex(0xF7F8FA, 255), .radius = 14, .border = theme.border },
    );
    _ = id;
}

/// 一个图标项。返回 true 表示本帧被点击。
pub fn dockItem(ui: *core.Context, id: []const u8, icon: []const u8, label: []const u8, opts: DockItemOpts) bool {
    if (!st.opened) return false;
    const size = st.opts.size;
    const gap = st.opts.gap;
    const base_y = st.base.y + 8;
    // 先算水平位置（从左开始排，含分隔符占用）
    var x = st.base.x + 12 + st.extra;
    var i: usize = 0;
    while (i < st.at) : (i += 1) x += size * st.opts.magnify + gap;
    const hit_zone = t.Rect{ .x = x, .y = base_y, .w = size * st.opts.magnify, .h = size * st.opts.magnify };
    const hit = ui.interactEx(idOf(id, 0xD0C0 +% @as(u64, @intCast(st.at))), hit_zone, true);

    // 放大：悬停时按 magnify 缩放，其余保持原尺寸并底部对齐
    const scale: f32 = if (hit.hover) st.opts.magnify else 1.0;
    const s = size * scale;
    const icon_rect = t.Rect{
        .x = hit_zone.x + (hit_zone.w - s) / 2,
        .y = base_y + (st.opts.magnify * size - s),
        .w = s,
        .h = s,
    };
    const c = opts.color orelse palette[st.at % palette.len];
    ui.addBox(icon_rect, .{ .fill = c, .radius = s * 0.24 });
    // 图标本体：用首字母当占位图形（ZZUI 没有图标字体）
    const label_ch = if (icon.len > 0) icon[0..1] else "?";
    const m = ui.measureText(label_ch, theme.font_heading);
    ui.addText(
        .{ .x = icon_rect.x + (icon_rect.w - m.w) / 2, .y = icon_rect.y + (icon_rect.h - m.h) / 2, .w = m.w, .h = m.h },
        label_ch,
        theme.font_heading,
        theme.accent_text,
    );

    if (opts.running) {
        ui.addBox(
            .{ .x = hit_zone.x + hit_zone.w / 2 - 2, .y = base_y + st.opts.magnify * size + 2, .w = 4, .h = 4 },
            .{ .fill = theme.text, .radius = 2 },
        );
    }
    if (opts.badge > 0) {
        var b: [12]u8 = undefined;
        const bs = ui.frameStr(num.int(&b, @intCast(opts.badge)));
        const bm = ui.measureText(bs, theme.font_small);
        const bw = @max(bm.w + 8, 16);
        const br = t.Rect{ .x = icon_rect.x + icon_rect.w - bw * 0.7, .y = icon_rect.y - 4, .w = bw, .h = 16 };
        ui.addBox(br, .{ .fill = theme.danger, .radius = 8 });
        ui.addText(
            .{ .x = br.x + (br.w - bm.w) / 2, .y = br.y + (br.h - bm.h) / 2, .w = bm.w, .h = bm.h },
            bs,
            theme.font_small,
            theme.accent_text,
        );
    }
    // 悬停时在图标上方显示名称
    if (hit.hover and label.len > 0) {
        const lm = ui.measureText(label, theme.font_small);
        const lr = t.Rect{ .x = hit_zone.x + hit_zone.w / 2 - lm.w / 2 - 6, .y = base_y - 20, .w = lm.w + 12, .h = 18 };
        ui.addBox(lr, .{ .fill = theme.text, .radius = 5 });
        ui.addText(
            .{ .x = lr.x + 6, .y = lr.y + (lr.h - lm.h) / 2, .w = lm.w, .h = lm.h },
            label,
            theme.font_small,
            theme.accent_text,
        );
    }
    st.at += 1;
    return hit.clicked or hit.activated;
}

/// 分隔线（不占图标位，只推后后续图标的水平位置）。
pub fn dockSeparator(ui: *core.Context) void {
    if (!st.opened) return;
    const size = st.opts.size;
    const gap = st.opts.gap;
    var x = st.base.x + 12 + st.extra;
    var i: usize = 0;
    while (i < st.at) : (i += 1) x += size * st.opts.magnify + gap;
    const y = st.base.y + 8 + st.opts.magnify * size / 2;
    ui.addBox(.{ .x = x + 4, .y = y - 14, .w = 1, .h = 28 }, .{ .fill = theme.border });
    st.extra += 12;
}

/// 结束程序坞。
pub fn dockEnd(ui: *core.Context) void {
    _ = ui;
    st.opened = false;
}
