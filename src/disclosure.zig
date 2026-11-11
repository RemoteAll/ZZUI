//! 披露族（对位 CUI `cui_disclosure.c`）：把次要信息「收起来/晚点说」的一批控件 ——
//! 横幅、倒计时、上手清单、确认气泡、可展开文本/卡片、悬停卡片。
//!
//! 状态与 `overlay.zig` 同口径：展开与否由调用方持有，浮层用 `beginOverlay`/`panel`。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const extras = @import("extras.zig");
const num = @import("num.zig");
const t = @import("types.zig");

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

// ------------------------------------------------------------------ 横幅
pub const BannerOpts = struct {
    tone: extras.Tone = .accent,
    /// 右侧动作按钮文案（空 = 没有动作）。
    action: []const u8 = "",
    dismissible: bool = true,
};

pub const BannerResult = struct {
    /// 本帧点击了右侧动作。
    action_clicked: bool = false,
    /// 本帧点击了关闭（`open` 已被写成 false）。
    dismissed: bool = false,
};

/// 顶部横幅（CUI `cui_banner`）：左侧色条 + 文本（自动换行）+ 动作 + 关闭。
pub fn banner(
    ui: *core.Context,
    id: []const u8,
    text: []const u8,
    open: *bool,
    opts: BannerOpts,
) BannerResult {
    var res = BannerResult{};
    if (!open.*) return res;

    const c = extras.toneColors(opts.tone);
    const pad: f32 = 12;
    const inner_w = ui.width - pad * 2;
    const close_w: f32 = if (opts.dismissible) 26 else 0;
    var act_w: f32 = 0;
    if (opts.action.len > 0) act_w = ui.measureText(opts.action, theme.font_small).w + 20;
    const text_w = inner_w - 18 - close_w - act_w - 8;

    var lines: [core.MAX_LINES][]const u8 = undefined;
    const n = core.wrapText(ui, text, theme.font_body, if (text_w > 40) text_w else 40, &lines);
    var line_h: f32 = 20;
    if (n > 0) line_h = ui.measureText(text, theme.font_body).h + 3;
    const h = @max(48, line_h * @as(f32, @floatFromInt(if (n > 0) n else 1)) + pad * 2);

    const rect = ui.reserve(0, h, true);
    ui.addBox(rect, .{ .fill = c.bg, .radius = 10 });
    ui.addBox(.{ .x = rect.x, .y = rect.y, .w = 4, .h = rect.h }, .{ .fill = c.fg, .radius = 2 });

    var ty = rect.y + pad;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const lm = ui.measureText(lines[i], theme.font_body);
        ui.addText(
            .{ .x = rect.x + 18, .y = ty, .w = lm.w, .h = lm.h },
            lines[i],
            theme.font_body,
            theme.text,
        );
        ty += line_h;
    }

    if (act_w > 0) {
        const br = t.Rect{
            .x = rect.x + rect.w - close_w - act_w - 8,
            .y = rect.y + (rect.h - 28) / 2,
            .w = act_w,
            .h = 28,
        };
        const hit = ui.interactEx(idOf(id, 0x8A11E7), br, true);
        widgets.ringBox(ui, br, 6, theme.bg, c.fg);
        const am = ui.measureText(opts.action, theme.font_small);
        ui.addText(
            .{ .x = br.x + (br.w - am.w) / 2, .y = br.y + (br.h - am.h) / 2, .w = am.w, .h = am.h },
            opts.action,
            theme.font_small,
            c.fg,
        );
        if (hit.clicked or hit.activated) res.action_clicked = true;
    }

    if (opts.dismissible) {
        const xr = t.Rect{
            .x = rect.x + rect.w - close_w - 4,
            .y = rect.y + (rect.h - 24) / 2,
            .w = 24,
            .h = 24,
        };
        const hit = ui.interactEx(idOf(id, 0xD155155), xr, true);
        if (hit.hover) ui.addBox(xr, .{ .fill = c.fg, .radius = 12, .border = null });
        const color: t.Color = if (hit.hover) c.bg else c.fg;
        ui.addOverlayLine(.{ .x = xr.x + 8, .y = xr.y + 8 }, .{ .x = xr.x + 16, .y = xr.y + 16 }, 1.5, color);
        ui.addOverlayLine(.{ .x = xr.x + 16, .y = xr.y + 8 }, .{ .x = xr.x + 8, .y = xr.y + 16 }, 1.5, color);
        if (hit.clicked or hit.activated) {
            open.* = false;
            res.dismissed = true;
        }
    }
    return res;
}

// ------------------------------------------------------------------ 倒计时
pub const CountdownOpts = struct {
    hide_days: bool = false,
    /// 紧凑：只有数字，没有单位标签。
    compact: bool = false,
};

fn pad2(buf: []u8, v: u64) []const u8 {
    var tmp: [20]u8 = undefined;
    const s = num.int(&tmp, @intCast(v));
    var n: usize = 0;
    if (s.len < 2) {
        buf[0] = '0';
        n = 1;
    }
    for (s) |c| {
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

fn tile(ui: *core.Context, digits_in: []const u8, unit: []const u8, compact: bool) void {
    // 缓冲在调用方栈上，必须拷进帧内池，否则帧末绘制时已失效（会渲染成乱码）
    const digits = ui.frameStr(digits_in);
    const dm = ui.measureText(digits, theme.font_heading);
    const uw: f32 = if (compact) 0 else ui.measureText(unit, theme.font_small).w;
    const w = @max(dm.w + 16, 40);
    const h: f32 = if (compact) dm.h + 12 else dm.h + 26;
    const r = ui.reserve(w, h, false);
    ui.addBox(r, .{ .fill = theme.surface, .radius = 8, .border = theme.border });
    ui.addText(
        .{ .x = r.x + (r.w - dm.w) / 2, .y = r.y + 6, .w = dm.w, .h = dm.h },
        digits,
        theme.font_heading,
        theme.text,
    );
    if (!compact) {
        const um = ui.measureText(unit, theme.font_small);
        ui.addText(
            .{ .x = r.x + (r.w - @max(um.w, uw)) / 2, .y = r.y + h - um.h - 5, .w = um.w, .h = um.h },
            unit,
            theme.font_small,
            theme.secondary,
        );
    }
}

/// 倒计时瓦片：天 / 时 / 分 / 秒（CUI `cui_countdown`）。
pub fn countdown(ui: *core.Context, id: []const u8, seconds_left: f64, opts: CountdownOpts) void {
    _ = id;
    const total: u64 = if (seconds_left <= 0) 0 else @intFromFloat(@floor(seconds_left));
    const days = total / 86400;
    const hours = (total % 86400) / 3600;
    const mins = (total % 3600) / 60;
    const secs = total % 60;

    var row = ui.row(.{ .gap = 6 });
    defer row.end();
    var b1: [8]u8 = undefined;
    var b2: [8]u8 = undefined;
    var b3: [8]u8 = undefined;
    var b4: [8]u8 = undefined;
    if (!opts.hide_days and days > 0) tile(ui, pad2(&b1, days), "days", opts.compact);
    tile(ui, pad2(&b2, hours), "hrs", opts.compact);
    tile(ui, pad2(&b3, mins), "min", opts.compact);
    tile(ui, pad2(&b4, secs), "sec", opts.compact);
}

// ------------------------------------------------------------------ 上手清单
pub const CheckStep = struct {
    title: []const u8,
    description: []const u8 = "",
    action: []const u8 = "",
    done: bool = false,
};

pub const ChecklistOpts = struct {
    title: []const u8 = "Getting started",
    description: []const u8 = "",
};

/// 上手清单（CUI `cui_checklist`）：点圆圈切换完成；返回本帧点了「动作」的步骤下标。
pub fn checklist(
    ui: *core.Context,
    id: []const u8,
    steps: []CheckStep,
    opts: ChecklistOpts,
) ?usize {
    var action_picked: ?usize = null;
    const done_count = blk: {
        var n: usize = 0;
        for (steps) |s| {
            if (s.done) n += 1;
        }
        break :blk n;
    };

    var col = ui.column(.{ .pad = 16, .gap = 10, .fill = theme.bg, .radius = 12, .border = theme.border });
    defer col.end();
    _ = id;

    _ = ui.textRun(opts.title, theme.font_body, theme.text);
    if (opts.description.len > 0) _ = ui.textRun(opts.description, theme.font_small, theme.secondary);

    // 进度：一条细条 + 完成数/总数
    const ratio: f32 = if (steps.len == 0) 0 else @as(f32, @floatFromInt(done_count)) / @as(f32, @floatFromInt(steps.len));
    var prow = ui.row(.{ .gap = 8 });
    defer prow.end();
    const bar = ui.reserve(0, 6, true);
    ui.addBox(bar, .{ .fill = theme.track, .radius = 3 });
    if (ratio > 0) ui.addBox(.{ .x = bar.x, .y = bar.y, .w = bar.w * ratio, .h = bar.h }, .{ .fill = theme.success, .radius = 3 });
    {
        var cb: [16]u8 = undefined;
        var cn: usize = 0;
        var nb: [8]u8 = undefined;
        const ds = num.int(&nb, @intCast(done_count));
        for (ds) |c| {
            cb[cn] = c;
            cn += 1;
        }
        cb[cn] = '/';
        cn += 1;
        var nb2: [8]u8 = undefined;
        const ts = num.int(&nb2, @intCast(steps.len));
        for (ts) |c| {
            if (cn < cb.len) {
                cb[cn] = c;
                cn += 1;
            }
        }
        _ = ui.textRun(ui.frameStr(cb[0..cn]), theme.font_small, theme.secondary);
    }

    for (steps, 0..) |*st, i| {
        const salt_title = idOf(st.title, 0x0C4EC);
        var row = ui.row(.{ .gap = 10 });
        defer row.end();

        // 圆圈（点它切换完成）
        const cr = ui.reserve(20, 20, false);
        const chit = ui.interactEx(salt_title ^ 0x11, cr, true);
        if (st.done) {
            ui.addBox(cr, .{ .fill = theme.success, .radius = 10 });
            ui.addOverlayLine(.{ .x = cr.x + 5, .y = cr.y + 10 }, .{ .x = cr.x + 9, .y = cr.y + 14 }, 1.8, theme.accent_text);
            ui.addOverlayLine(.{ .x = cr.x + 9, .y = cr.y + 14 }, .{ .x = cr.x + 15, .y = cr.y + 6 }, 1.8, theme.accent_text);
        } else {
            widgets.ringBox(ui, cr, 10, theme.bg, if (chit.hover) theme.accent else theme.border);
        }
        if (chit.clicked or chit.activated) st.done = !st.done;

        var body = ui.column(.{ .gap = 2 });
        defer body.end();
        var title_row = ui.row(.{ .gap = 8 });
        defer title_row.end();
        const tm = ui.measureText(st.title, theme.font_body);
        const tr = ui.reserve(tm.w, tm.h + 2, false);
        const color: t.Color = if (st.done) theme.secondary else theme.text;
        ui.addText(.{ .x = tr.x, .y = tr.y, .w = tm.w, .h = tm.h }, st.title, theme.font_body, color);
        if (st.description.len > 0) _ = ui.textRun(st.description, theme.font_small, theme.secondary);
        if (st.action.len > 0 and !st.done) {
            const am = ui.measureText(st.action, theme.font_small);
            const ar = ui.reserve(am.w, 18, false);
            const ah = ui.interactEx(salt_title ^ 0xA, ar, true);
            ui.addText(
                .{ .x = ar.x, .y = ar.y, .w = am.w, .h = am.h },
                st.action,
                theme.font_small,
                if (ah.hover) theme.accent_active else theme.accent,
            );
            if (ah.clicked or ah.activated) action_picked = i;
        }
    }
    return action_picked;
}

// ------------------------------------------------------------------ 确认气泡
pub const ConfirmPopoverOpts = struct {
    title: []const u8 = "Are you sure?",
    description: []const u8 = "",
    confirm_label: []const u8 = "Confirm",
    cancel_label: []const u8 = "Cancel",
    danger: bool = false,
    width: f32 = 240,
};

pub const ConfirmPopoverResult = enum { none, confirmed, canceled, dismissed };

/// 锚定在某个控件下方的确认气泡（CUI `cui_confirm_popover`）。
/// `open` 由调用方控制；点外部/取消/确认都会关闭它。
pub fn confirmPopover(
    ui: *core.Context,
    id: []const u8,
    anchor: t.Rect,
    open: *bool,
    opts: ConfirmPopoverOpts,
) ConfirmPopoverResult {
    if (!open.*) return .none;
    _ = ui.beginOverlay(.{ .dim = null, .hit = true, .id = idOf(id, 0xC0F19) });
    if (ui.overlayBackdropClicked()) {
        ui.endOverlay();
        open.* = false;
        return .dismissed;
    }

    const est_h: f32 = 150;
    var x = anchor.x;
    var y = anchor.y + anchor.h + 8;
    if (y + est_h > ui.height - 8) y = anchor.y - est_h - 8;
    if (x + opts.width > ui.width - 8) x = ui.width - opts.width - 8;
    if (x < 8) x = 8;
    if (y > ui.height - 8 - est_h) y = ui.height - 8 - est_h;
    if (y < 8) y = 8;

    var out: ConfirmPopoverResult = .none;
    _ = ui.panel(.{ .x = x, .y = y, .w = opts.width, .h = 0 }, .{
        .pad = 14,
        .gap = 8,
        .fill = theme.bg,
        .radius = 12,
        .border = theme.border,
        .auto_height = true,
    });
    _ = ui.textRun(opts.title, theme.font_body, theme.text);
    if (opts.description.len > 0) _ = ui.textRun(opts.description, theme.font_small, theme.secondary);

    var row = ui.row(.{ .gap = 8 });
    defer row.end();
    const variant: t.Variant = if (opts.danger) .primary else .primary;
    if (widgets.button(ui, opts.confirm_label, .{ .variant = variant, .id_salt = 0xCF1 })) out = .confirmed;
    if (widgets.button(ui, opts.cancel_label, .{ .variant = .secondary, .id_salt = 0xCF2 })) out = .canceled;

    if (ui.input.keyPressed(.escape)) out = .canceled;
    if (ui.input.keyPressed(.enter) and out == .none) out = .confirmed;
    if (out != .none) open.* = false;

    ui.endPanel();
    ui.endOverlay();
    return out;
}

// ------------------------------------------------------------------ 可展开文本
pub const ExpandableTextState = struct {
    expanded: bool = false,
};

pub const ExpandableTextOpts = struct {
    /// 折叠时显示几行。
    lines: usize = 3,
    size: f32 = theme.font_body,
};

/// 折叠多行文本 + 「Show more / Show less」（CUI `cui_expandable_text`）。
pub fn expandableText(
    ui: *core.Context,
    id: []const u8,
    text: []const u8,
    state: *ExpandableTextState,
    opts: ExpandableTextOpts,
) void {
    // 可用宽度：调用方常把控件放在带内边距的容器/滚动区里，按父宽度减内边距估算；
    // 行必须自己算好再逐行 addText —— 交给 `textRun` 会被容器再折一次行（出现双换行）。
    const avail = ui.width - 48;
    var lines: [core.MAX_LINES][]const u8 = undefined;
    const n = core.wrapText(ui, text, opts.size, if (avail > 120) avail else 120, &lines);
    const show = if (state.expanded) n else @min(n, opts.lines);

    const sample = ui.measureText("Ag", opts.size);
    const lh = if (sample.h > 0) sample.h + 3 else opts.size * 1.4;
    var i: usize = 0;
    while (i < show) : (i += 1) {
        const r = ui.reserve(0, lh, true);
        const lm = ui.measureText(lines[i], opts.size);
        ui.addText(.{ .x = r.x, .y = r.y, .w = lm.w, .h = lm.h }, lines[i], opts.size, theme.text);
    }

    if (n > opts.lines) {
        const label = if (state.expanded) "Show less" else "Show more";
        const lw = ui.measureText(label, theme.font_small).w;
        const r = ui.reserve(lw, 20, false);
        const hit = ui.interactEx(idOf(id, 0x5A0E), r, true);
        ui.addText(
            .{ .x = r.x, .y = r.y, .w = lw, .h = 20 },
            label,
            theme.font_small,
            if (hit.hover) theme.accent_active else theme.accent,
        );
        if (hit.clicked or hit.activated) state.expanded = !state.expanded;
    }
}

// ------------------------------------------------------------------ 可展开卡片
pub const ExpandableCardOpts = struct {
    description: []const u8 = "",
    badge: []const u8 = "",
    badge_tone: extras.Tone = .neutral,
};

pub const ExpandableCardState = struct {
    open: bool = false,
};

/// 可展开卡片开始（与 `expandableCardEnd` 配对）：标题行常显，正文展开时可用。
/// 返回值 = 当前是否展开（展开时调用方在 End 之前放正文）。
pub fn expandableCardBegin(
    ui: *core.Context,
    id: []const u8,
    title: []const u8,
    state: *ExpandableCardState,
    opts: ExpandableCardOpts,
) bool {
    _ = ui.column(.{ .pad = 14, .gap = 10, .fill = theme.bg, .radius = 12, .border = theme.border });

    const header_h: f32 = 28;
    var row = ui.row(.{ .gap = 8 });
    defer row.end();

    // 箭头
    const ar = ui.reserve(18, header_h, false);
    const ahit = ui.interactEx(idOf(id, 0xA330), ar, true);
    const cy = ar.y + header_h / 2;
    if (state.open) {
        ui.addOverlayLine(.{ .x = ar.x + 4, .y = cy + 2 }, .{ .x = ar.x + 9, .y = cy - 3 }, 1.6, theme.secondary);
        ui.addOverlayLine(.{ .x = ar.x + 9, .y = cy - 3 }, .{ .x = ar.x + 14, .y = cy + 2 }, 1.6, theme.secondary);
    } else {
        ui.addOverlayLine(.{ .x = ar.x + 6, .y = cy - 4 }, .{ .x = ar.x + 11, .y = cy + 1 }, 1.6, theme.secondary);
        ui.addOverlayLine(.{ .x = ar.x + 11, .y = cy + 1 }, .{ .x = ar.x + 6, .y = cy + 6 }, 1.6, theme.secondary);
    }

    const tm = ui.measureText(title, theme.font_body);
    const tr = ui.reserve(tm.w + 4, header_h, false);
    const thit = ui.interactEx(idOf(id, 0xA331), tr, true);
    ui.addText(
        .{ .x = tr.x, .y = tr.y + (header_h - tm.h) / 2, .w = tm.w, .h = tm.h },
        title,
        theme.font_body,
        theme.text,
    );
    if (opts.badge.len > 0) extras.badge(ui, opts.badge, opts.badge_tone);

    if (opts.description.len > 0 and !state.open) {
        _ = ui.textRun(opts.description, theme.font_small, theme.secondary);
    }
    if (ahit.clicked or ahit.activated or thit.clicked or thit.activated) state.open = !state.open;
    return state.open;
}

/// 结束可展开卡片（与 `expandableCardBegin` 配对）。
pub fn expandableCardEnd(ui: *core.Context) void {
    ui.endPanel();
}

// ------------------------------------------------------------------ 悬停卡片
pub const HoverCardOpts = struct {
    width: f32 = 240,
    pad: f32 = 12,
    /// 悬停多久才出现（秒）。
    delay: f64 = 0.35,
};

pub const HoverCardState = struct {
    start: f64 = -1,
};

/// 悬停卡片开始：`hovered` 为 true 且超过 `delay` 秒才出现。
/// 返回 true 时必须配对调用 `hoverCardEnd`（在浮层里放正文）。
pub fn hoverCardBegin(
    ui: *core.Context,
    id: []const u8,
    anchor: t.Rect,
    hovered: bool,
    state: *HoverCardState,
    opts: HoverCardOpts,
) bool {
    if (!hovered) {
        state.start = -1;
        return false;
    }
    if (state.start < 0) state.start = ui.time;
    if (ui.time - state.start < opts.delay) {
        ui.requestFrame(); // 等延迟：不出帧就永远等不到
        return false;
    }

    _ = ui.beginOverlay(.{ .dim = null, .hit = false });
    const est_h: f32 = 96;
    var x = anchor.x;
    var y = anchor.y + anchor.h + 6;
    if (y + est_h > ui.height - 8) y = anchor.y - est_h - 6;
    if (x + opts.width > ui.width - 8) x = ui.width - opts.width - 8;
    if (x < 8) x = 8;
    if (y < 8) y = 8;
    if (y > ui.height - 8 - est_h) y = ui.height - 8 - est_h;

    _ = ui.panel(.{ .x = x, .y = y, .w = opts.width, .h = 0 }, .{
        .pad = opts.pad,
        .gap = 6,
        .fill = theme.text,
        .radius = 10,
        .auto_height = true,
    });
    _ = id;
    return true;
}

/// 结束悬停卡片（与 `hoverCardBegin` 配对）。
pub fn hoverCardEnd(ui: *core.Context) void {
    ui.endPanel();
    ui.endOverlay();
}
