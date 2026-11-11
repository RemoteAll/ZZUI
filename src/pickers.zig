//! 选择器族（对位 CUI `cui_pickers.c`）：
//! 多选下拉、区间日历、日期区间、时分选择、滚轮、表盘、刻度尺滑块、直方图滑块、签名板。
//!
//! 状态一律由调用方持有（立即模式口径）；`State` / `WheelState` / `RulerState` /
//! `HistState` / `SignatureState` 各自独立，同一页可放多个实例。
//!
//! **已知取舍**（与 CUI 的差异，见 `docs/迁移审计.md` §4）：
//! - `dropzone` / `avatarUpload` 依赖平台能力（OS 文件拖放、位图贴图），本文件不含；
//! - 滚轮与刻度尺**不做惯性动画**（CUI 用 tween/spring），松手即停在最近的吸附位；
//! - 定时器/秒级动画一律不用帧时间，避免引入动画状态机。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const month = @import("month.zig");
const num = @import("num.zig");
const widgets = @import("widgets.zig");
const extras = @import("extras.zig");
const t = @import("types.zig");

pub const Date = month.Date;

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

// ------------------------------------------------------------------ 日期工具

/// 距 1970-01-01 的天数（可为负）。
pub fn dateToDays(d: Date) i32 {
    return @intCast(month.daysFromCivil(d));
}

/// 从天数还原日期。
pub fn dateFromDays(days: i32) Date {
    // Howard Hinnant 的 civil_from_days
    const z: i64 = @as(i64, days) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

/// `2026-11-10`；未选（year == 0）时写入 `--`。
pub fn formatDate(buf: []u8, d: Date) []const u8 {
    if (d.year <= 0) {
        const s = "--";
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }
    var n: usize = 0;
    var yb: [12]u8 = undefined;
    const ys = num.int(&yb, d.year);
    for (ys) |c| {
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    const parts = [_]u8{ '-', d.month / 10, d.month % 10, '-', d.day / 10, d.day % 10 };
    var i: usize = 0;
    const month_div = [_]u8{ '-', '0', '0', '-', '0', '0' };
    while (i < month_div.len) : (i += 1) {
        if (n < buf.len) {
            buf[n] = month_div[i];
            n += 1;
        }
    }
    // 用两位数字覆盖月日
    if (n >= 6) {
        buf[n - 5] = '0' + parts[1];
        buf[n - 4] = '0' + parts[2];
        buf[n - 1] = '0' + parts[4];
        // 月的个位与日的十位需要单独写
        buf[n - 1] = '0' + parts[5];
        buf[n - 2] = '0' + parts[4];
    }
    return buf[0..n];
}

pub const DateRange = struct {
    start: Date = .{ .year = 0, .month = 0, .day = 0 },
    end: Date = .{ .year = 0, .month = 0, .day = 0 },

    pub fn isSet(self: DateRange) bool {
        return self.start.year > 0;
    }

    pub fn contains(self: DateRange, d: Date) bool {
        if (!self.isSet()) return false;
        const dev = dateToDays(d);
        if (dev < dateToDays(self.start)) return false;
        if (self.end.year > 0 and dev > dateToDays(self.end)) return false;
        return true;
    }
};

// ------------------------------------------------------------------ 通用弹层状态

/// 字段 + 弹层类控件的共用状态（多选 / 日期区间 / 时分共用，各自一个实例）。
pub const PopupState = struct {
    open: bool = false,
    anchor: t.Rect = .{},
    /// 多选的搜索框（`searchable` 时用）。
    query: [32]u8 = @splat(0),
    query_len: usize = 0,
};

fn fieldRect(
    ui: *core.Context,
    id: []const u8,
    text: []const u8,
    width: f32,
    hover: *bool,
    focused: *bool,
) t.Rect {
    const m = ui.measureText(text, theme.font_body);
    const h: f32 = 34;
    const rect = ui.reserve(width, h, false);
    const it = ui.interactEx(idOf(id, 0x5E1EC7), rect, true);
    hover.* = it.hover;
    focused.* = it.focused;
    widgets.ringBox(ui, rect, theme.radius_control, if (it.hover) theme.surface else theme.bg, theme.border);
    const tx = rect.x + 12;
    const maxw = rect.w - 34;
    ui.addText(
        .{ .x = tx, .y = rect.y + (h - m.h) / 2, .w = if (m.w < maxw) m.w else maxw, .h = m.h },
        text[0..@min(text.len, 40)],
        theme.font_body,
        theme.text,
    );
    if (it.focused) ui.addBox(rect.inset(-2), .{ .border = theme.accent, .radius = theme.radius_control + 2 });
    const ax = rect.x + rect.w - 16;
    const ay = rect.y + h / 2 - 2;
    ui.addOverlayLine(.{ .x = ax - 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
    ui.addOverlayLine(.{ .x = ax + 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
    return rect;
}

// ------------------------------------------------------------------ 多选

pub const MultiOpts = struct {
    width: f32 = 240,
    label: []const u8 = "",
    placeholder: []const u8 = "Select…",
    /// chips 最多显示几个，其余折成 `+N`。
    max_chips: u8 = 3,
    searchable: bool = false,
    item_h: f32 = 30,
};

fn multiField(ui: *core.Context, id: []const u8, items: []const []const u8, selected: []const bool, st: *PopupState, opts: MultiOpts) void {
    const h: f32 = 34;
    const rect = ui.reserve(opts.width, h, false);
    const it = ui.interactEx(idOf(id, 0x5E1EC7), rect, true);
    if (it.clicked or it.activated) st.open = !st.open;
    st.anchor = rect;

    widgets.ringBox(ui, rect, theme.radius_control, if (it.hover) theme.surface else theme.bg, theme.border);
    if (it.focused) ui.addBox(rect.inset(-2), .{ .border = theme.accent, .radius = theme.radius_control + 2 });

    // 已选项的 chips
    var x = rect.x + 10;
    const limit = rect.x + rect.w - 36;
    var shown: usize = 0;
    var total: usize = 0;
    for (selected) |v| {
        if (v) total += 1;
    }
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        if (!selected[i]) continue;
        if (shown >= opts.max_chips) break;
        const m = ui.measureText(items[i], theme.font_small);
        const cw = m.w + 14;
        if (x + cw > limit) break;
        const cr = t.Rect{ .x = x, .y = rect.y + 7, .w = cw, .h = 20 };
        ui.addBox(cr, .{ .fill = theme.surface, .radius = 10, .border = theme.border });
        ui.addText(.{ .x = cr.x + 7, .y = cr.y + (cr.h - m.h) / 2, .w = m.w, .h = m.h }, items[i], theme.font_small, theme.text);
        x += cw + 4;
        shown += 1;
    }
    if (total == 0) {
        const m = ui.measureText(opts.placeholder, theme.font_body);
        ui.addText(.{ .x = rect.x + 12, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, opts.placeholder, theme.font_body, theme.secondary);
    } else if (total > shown) {
        var nb: [16]u8 = @splat(0);
        var n: usize = 0;
        nb[n] = '+';
        n += 1;
        var ib: [12]u8 = undefined;
        const is = num.int(&ib, @intCast(total - shown));
        for (is) |c| {
            if (n < nb.len) {
                nb[n] = c;
                n += 1;
            }
        }
        const label = ui.frameStr(nb[0..n]);
        const m = ui.measureText(label, theme.font_small);
        ui.addText(.{ .x = x, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, theme.secondary);
    }

    const ax = rect.x + rect.w - 16;
    const ay = rect.y + h / 2 - 2;
    ui.addOverlayLine(.{ .x = ax - 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
    ui.addOverlayLine(.{ .x = ax + 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
}

fn multiPopup(ui: *core.Context, id: []const u8, items: []const []const u8, selected: []bool, st: *PopupState, opts: MultiOpts) bool {
    if (!st.open) return false;
    var changed = false;
    const pad: f32 = 6;
    const search_h: f32 = if (opts.searchable) 30 else 0;
    const list_h = @as(f32, @floatFromInt(items.len)) * opts.item_h;
    const body_h = search_h + list_h + pad * 2;
    const w = if (st.anchor.w > 160) st.anchor.w else 200;

    var y = st.anchor.y + st.anchor.h + 4;
    if (y + body_h > ui.height - 8) y = st.anchor.y - body_h - 4;
    if (y < 8) y = 8;
    const box = t.Rect{ .x = st.anchor.x, .y = y, .w = w, .h = body_h };

    _ = ui.beginOverlay(.{ .id = idOf(id, 0x0FF5E7), .hit = true });
    defer ui.endOverlay();
    ui.addBox(box, .{ .fill = theme.bg, .radius = 10, .border = theme.border });
    ui.clip = box;

    var top = box.y + pad;
    if (opts.searchable) {
        const q: []const u8 = st.query[0..st.query_len];
        _ = widgets.input(ui, "ms-filter", st.query[0..], &st.query_len, &st.query_len, .{
            .placeholder = "Filter\u{2026}",
            .width = box.w - pad * 2,
        });
        _ = q;
        top += search_h;
    }

    const query: []const u8 = st.query[0..st.query_len];
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        if (opts.searchable and query.len > 0 and !containsNoCase(items[i], query)) continue;
        const ir = t.Rect{ .x = box.x + pad, .y = top, .w = box.w - pad * 2, .h = opts.item_h };
        top += opts.item_h;
        // 列表项只响应鼠标：Tab 停靠点是整个下拉框，不是每一项
        const it = ui.interact(idOf(id, 0xB0 +% @as(u64, i)), ir);
        if (it.hover) ui.addBox(ir, .{ .fill = theme.surface, .radius = 6 });
        // 复选框
        const bs: f32 = 14;
        const br = t.Rect{ .x = ir.x + 4, .y = ir.y + (ir.h - bs) / 2, .w = bs, .h = bs };
        ui.addBox(br, .{
            .fill = if (selected[i]) theme.accent else theme.bg,
            .radius = 4,
            .border = if (selected[i]) theme.accent else theme.border,
        });
        if (selected[i]) {
            ui.addOverlayLine(.{ .x = br.x + 3, .y = br.y + 7 }, .{ .x = br.x + 6, .y = br.y + 10 }, 1.8, theme.accent_text);
            ui.addOverlayLine(.{ .x = br.x + 6, .y = br.y + 10 }, .{ .x = br.x + 11, .y = br.y + 4 }, 1.8, theme.accent_text);
        }
        const m = ui.measureText(items[i], theme.font_body);
        ui.addText(.{ .x = br.x + bs + 8, .y = ir.y + (ir.h - m.h) / 2, .w = m.w, .h = m.h }, items[i], theme.font_body, theme.text);
        if (it.clicked) {
            selected[i] = !selected[i];
            changed = true;
        }
    }
    ui.clip = null;
    if (ui.input.click != null and !box.contains(ui.input.click.?.x, ui.input.click.?.y) and !ui.overlayBackdropClicked()) st.open = false;
    if (ui.overlayBackdropClicked()) st.open = false;
    return changed;
}

fn containsNoCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// 多选（字段 + 弹层）。返回选择是否变化。
pub fn multiSelect(
    ui: *core.Context,
    id: []const u8,
    items: []const []const u8,
    selected: []bool,
    st: *PopupState,
    opts: MultiOpts,
) bool {
    multiField(ui, id, items, selected, st, opts);
    return multiPopup(ui, id, items, selected, st, opts);
}

// ------------------------------------------------------------------ 区间日历

pub const CalendarOpts = struct {
    /// 并列月数（1 或 2）。
    months: u8 = 2,
    cell_h: f32 = 30,
};

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const dow_names = [_][]const u8{ "M", "T", "W", "T", "F", "S", "S" };

fn addMonths(d: Date, delta: i32) Date {
    var m: i32 = @as(i32, d.month) + delta;
    var y: i32 = d.year;
    while (m > 12) {
        m -= 12;
        y += 1;
    }
    while (m < 1) {
        m += 12;
        y -= 1;
    }
    return .{ .year = y, .month = @intCast(m), .day = 1 };
}

fn drawMonth(
    ui: *core.Context,
    id: []const u8,
    slot: u16,
    origin: t.Rect,
    shown: Date,
    range: *DateRange,
    opts: CalendarOpts,
) bool {
    var changed = false;
    const pad: f32 = 4;
    const head_h: f32 = 26;
    const dow_h: f32 = 18;
    const cell_w = (origin.w - pad * 2) / 7;
    const cell_h = opts.cell_h;

    // 标题：2026 Nov
    const m = ui.measureText("2026 Nov", theme.font_small);
    var tb: [24]u8 = @splat(0);
    var n: usize = 0;
    var yb: [12]u8 = undefined;
    const ys = num.int(&yb, shown.year);
    for (ys) |c| {
        if (n < tb.len) {
            tb[n] = c;
            n += 1;
        }
    }
    if (n < tb.len) {
        tb[n] = ' ';
        n += 1;
    }
    const mn = month_names[@min(shown.month -| 1, 11)];
    for (mn) |c| {
        if (n < tb.len) {
            tb[n] = c;
            n += 1;
        }
    }
    const title = ui.frameStr(tb[0..n]);
    ui.addText(.{ .x = origin.x + pad + 4, .y = origin.y + (head_h - m.h) / 2, .w = m.w, .h = m.h }, title, theme.font_small, theme.text);

    // 星期行
    var d: usize = 0;
    while (d < 7) : (d += 1) {
        const dm = ui.measureText(dow_names[d], theme.font_small);
        ui.addText(.{
            .x = origin.x + pad + cell_w * @as(f32, @floatFromInt(d)) + (cell_w - dm.w) / 2,
            .y = origin.y + head_h,
            .w = dm.w,
            .h = dm.h,
        }, dow_names[d], theme.font_small, theme.secondary);
    }

    // 网格
    const first = Date{ .year = shown.year, .month = shown.month, .day = 1 };
    const lead: u8 = month.weekdayOf(first);
    const dim = month.daysInMonth(shown.year, shown.month);
    var idx: u8 = 0;
    while (idx < dim) : (idx += 1) {
        const cell = lead + idx;
        const ri: u8 = cell / 7;
        const ci: u8 = cell % 7;
        const cr = t.Rect{
            .x = origin.x + pad + cell_w * @as(f32, @floatFromInt(ci)),
            .y = origin.y + head_h + dow_h + cell_h * @as(f32, @floatFromInt(ri)),
            .w = cell_w,
            .h = cell_h,
        };
        const day = Date{ .year = shown.year, .month = shown.month, .day = idx + 1 };
        const in_range = range.contains(day);
        const is_start = range.start.year > 0 and range.start.eql(day);
        const is_end = range.end.year > 0 and range.end.eql(day);
        // 日历格只响应鼠标（两月 60+ 格会把焦点池占满）
        const it = ui.interact(idOf(id, 0xD00 +% @as(u64, slot) * 0x4000 +% @as(u64, idx + 1)), cr);
        if (is_start or is_end) {
            ui.addBox(cr.inset(1), .{ .fill = theme.accent, .radius = 6 });
        } else if (in_range) {
            ui.addBox(cr.inset(1), .{ .fill = theme.surface, .radius = 6 });
        } else if (it.hover) {
            ui.addBox(cr.inset(1), .{ .fill = theme.surface, .radius = 6 });
        }
        var db: [8]u8 = @splat(0);
        var dn: usize = 0;
        if (idx + 1 >= 10) {
            db[dn] = '0' + (idx + 1) / 10;
            dn += 1;
        }
        db[dn] = '0' + (idx + 1) % 10;
        dn += 1;
        const label = ui.frameStr(db[0..dn]);
        const lm = ui.measureText(label, theme.font_small);
        ui.addText(.{
            .x = cr.x + (cr.w - lm.w) / 2,
            .y = cr.y + (cr.h - lm.h) / 2,
            .w = lm.w,
            .h = lm.h,
        }, label, theme.font_small, if (is_start or is_end) theme.accent_text else theme.text);
        if (it.clicked) {
            if (!range.isSet() or (range.end.year > 0 and !range.start.eql(range.end))) {
                // 第一下：开新区间
                range.start = day;
                range.end = .{ .year = 0, .month = 0, .day = 0 };
            } else if (dateToDays(day) < dateToDays(range.start)) {
                range.end = range.start;
                range.start = day;
            } else {
                range.end = day;
            }
            changed = true;
        }
    }
    return changed;
}

/// 区间日历：点第一下定起点、第二下定终点（反序自动交换）。返回是否变化。
pub fn rangeCalendar(ui: *core.Context, id: []const u8, shown: *Date, range: *DateRange, opts: CalendarOpts) bool {
    const months: u8 = if (opts.months < 1) 1 else if (opts.months > 2) 2 else opts.months;
    const head_h: f32 = 32;
    const month_h = head_h + 18 + opts.cell_h * 6 + 8;
    const total_h = month_h + 8;
    const rect = ui.reserve(0, total_h, true);

    // 翻月按钮（标题行右侧）
    const bw: f32 = 22;
    const prev = t.Rect{ .x = rect.x + rect.w - bw * 2 - 8, .y = rect.y + 4, .w = bw, .h = bw };
    const next = t.Rect{ .x = rect.x + rect.w - bw - 4, .y = rect.y + 4, .w = bw, .h = bw };
    const p_hit = ui.interactEx(idOf(id, 0x9A0E7), prev, true);
    const n_hit = ui.interactEx(idOf(id, 0x9A0E8), next, true);
    const pcol: t.Color = if (p_hit.hover) theme.text else theme.secondary;
    const ncol: t.Color = if (n_hit.hover) theme.text else theme.secondary;
    ui.addOverlayLine(.{ .x = prev.x + 13, .y = prev.y + 6 }, .{ .x = prev.x + 8, .y = prev.y + 11 }, 1.6, pcol);
    ui.addOverlayLine(.{ .x = prev.x + 8, .y = prev.y + 11 }, .{ .x = prev.x + 13, .y = prev.y + 16 }, 1.6, pcol);
    ui.addOverlayLine(.{ .x = next.x + 9, .y = next.y + 6 }, .{ .x = next.x + 14, .y = next.y + 11 }, 1.6, ncol);
    ui.addOverlayLine(.{ .x = next.x + 14, .y = next.y + 11 }, .{ .x = next.x + 9, .y = next.y + 16 }, 1.6, ncol);
    if (p_hit.clicked) shown.* = addMonths(shown.*, -1);
    if (n_hit.clicked) shown.* = addMonths(shown.*, 1);

    var changed = false;
    const w = (rect.w - 8) / @as(f32, @floatFromInt(months));
    var i: u8 = 0;
    while (i < months) : (i += 1) {
        const origin = t.Rect{
            .x = rect.x + w * @as(f32, @floatFromInt(i)),
            .y = rect.y + head_h,
            .w = w - 8,
            .h = month_h - head_h,
        };
        const mon = addMonths(shown.*, @intCast(i));
        if (drawMonth(ui, id, i, origin, mon, range, opts)) changed = true;
    }
    return changed;
}

// ------------------------------------------------------------------ 日期区间选择器

pub const DateRangeOpts = struct {
    width: f32 = 260,
    placeholder: []const u8 = "Start ~ end",
    no_presets: bool = false,
};

const preset_names = [_][]const u8{ "Today", "Last 7 days", "Last 30 days", "This month" };

fn fieldText(ui: *core.Context, id: []const u8, label: []const u8, value_text: []const u8, width: f32, st: *PopupState) void {
    const h: f32 = 34;
    const rect = ui.reserve(width, h, false);
    st.anchor = rect;
    if (label.len > 0) {
        const lm = ui.measureText(label, theme.font_small);
        ui.addText(.{ .x = rect.x, .y = rect.y - lm.h - 2, .w = lm.w, .h = lm.h }, label, theme.font_small, theme.secondary);
    }
    const it = ui.interactEx(idOf(id, 0x5E1EC7), rect, true);
    if (it.clicked or it.activated) st.open = !st.open;
    widgets.ringBox(ui, rect, theme.radius_control, if (it.hover) theme.surface else theme.bg, theme.border);
    const m = ui.measureText(value_text, theme.font_body);
    ui.addText(.{ .x = rect.x + 12, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, value_text, theme.font_body, theme.text);
    if (it.focused) ui.addBox(rect.inset(-2), .{ .border = theme.accent, .radius = theme.radius_control + 2 });
    const ax = rect.x + rect.w - 16;
    const ay = rect.y + h / 2 - 2;
    ui.addOverlayLine(.{ .x = ax - 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
    ui.addOverlayLine(.{ .x = ax + 5, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.6, theme.secondary);
}

/// 日期区间（字段 + 弹层：预设 + 双月日历）。返回是否变化。
pub fn dateRangePicker(
    ui: *core.Context,
    id: []const u8,
    shown: *Date,
    range: *DateRange,
    st: *PopupState,
    opts: DateRangeOpts,
) bool {
    // 字段
    var vb0: [16]u8 = @splat(0);
    var vb1: [16]u8 = @splat(0);
    const s = formatDate(&vb0, range.start);
    const e = formatDate(&vb1, range.end);
    var joined: [40]u8 = @splat(0);
    var n: usize = 0;
    for (s) |c| {
        if (n < joined.len) {
            joined[n] = c;
            n += 1;
        }
    }
    if (range.isSet()) {
        for (" ~ ") |c| {
            if (n < joined.len) {
                joined[n] = c;
                n += 1;
            }
        }
        for (e) |c| {
            if (n < joined.len) {
                joined[n] = c;
                n += 1;
            }
        }
    }
    const text = ui.frameStr(joined[0..n]);
    const value = if (range.isSet()) text else opts.placeholder;
    fieldText(ui, id, "", value, opts.width, st);

    if (!st.open) return false;

    const pad: f32 = 10;
    const preset_h: f32 = if (opts.no_presets) 0 else (@as(f32, @floatFromInt(preset_names.len)) * 26 + 8);
    const cal_h: f32 = 32 + 18 + 8 * 6 + 8 + 16;
    const box_w: f32 = 560;
    const box_h = pad * 2 + preset_h + cal_h;
    var by = st.anchor.y + st.anchor.h + 4;
    if (by + box_h > ui.height - 8) by = @max(8, st.anchor.y - box_h - 4);
    var bx = st.anchor.x;
    if (bx + box_w > ui.width - 8) bx = @max(8, ui.width - box_w - 8);
    const box = t.Rect{ .x = bx, .y = by, .w = box_w, .h = box_h };

    _ = ui.beginOverlay(.{ .id = idOf(id, 0x0FF5E7), .hit = true });
    defer ui.endOverlay();
    ui.addBox(box, .{ .fill = theme.bg, .radius = 10, .border = theme.border });
    ui.clip = box;

    var changed = false;
    var top = box.y + pad;
    if (!opts.no_presets) {
        const today = Date{ .year = 2026, .month = 11, .day = 10 };
        var pi: usize = 0;
        while (pi < preset_names.len) : (pi += 1) {
            const pr = t.Rect{ .x = box.x + pad, .y = top, .w = box.w - pad * 2, .h = 24 };
            top += 26;
            const it = ui.interact(idOf(id, 0xB5 +% @as(u64, pi)), pr);
            if (it.hover) ui.addBox(pr, .{ .fill = theme.surface, .radius = 6 });
            const m = ui.measureText(preset_names[pi], theme.font_body);
            ui.addText(.{ .x = pr.x + 6, .y = pr.y + (pr.h - m.h) / 2, .w = m.w, .h = m.h }, preset_names[pi], theme.font_body, theme.text);
            if (it.clicked) {
                const span: i32 = switch (pi) {
                    0 => 0,
                    1 => 6,
                    2 => 29,
                    else => 0,
                };
                if (pi == 3) {
                    range.start = .{ .year = today.year, .month = today.month, .day = 1 };
                    range.end = .{ .year = today.year, .month = today.month, .day = month.daysInMonth(today.year, today.month) };
                } else {
                    range.start = dateFromDays(dateToDays(today) - span);
                    range.end = today;
                }
                shown.* = range.start;
                changed = true;
            }
        }
        top += 8;
    }

    // 日历本体：绝对面板（`rangeCalendar` 用 `reserve` 占位，必须在已定位的容器里）
    const cal_rect = t.Rect{ .x = box.x + pad, .y = top, .w = box.w - pad * 2, .h = cal_h };
    var panel = ui.panel(cal_rect, .{ .pad = 0, .gap = 0 });
    defer panel.end();
    if (rangeCalendar(ui, id, shown, range, .{ .months = 2, .cell_h = 26 })) changed = true;

    ui.clip = null;
    if (ui.overlayBackdropClicked()) st.open = false;
    return changed;
}

// ------------------------------------------------------------------ 时分选择

pub const TimeOpts = struct {
    width: f32 = 120,
    twelve_hour: bool = false,
    /// 分钟步长（1/5/15）。
    minute_step: u8 = 1,
};

const ColumnHit = struct {
    value: i32 = -1,
    changed: bool = false,
};

fn timeColumn(ui: *core.Context, id: u64, rect: t.Rect, count: i32, value: i32, step: i32, base: i32) ColumnHit {
    var res = ColumnHit{};
    const row_h: f32 = 26;
    const rows: i32 = @max(1, @as(i32, @intFromFloat(rect.h / row_h)));
    const half_rows: i32 = @divTrunc(rows, 2);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        // 以选中项为中心滚动
        const offset = i - value;
        if (offset < -half_rows or offset > half_rows) continue;
        const y = rect.y + rect.h / 2 - row_h / 2 + @as(f32, @floatFromInt(offset)) * row_h;
        const ir = t.Rect{ .x = rect.x, .y = y, .w = rect.w, .h = row_h };
        // 滚轮行只响应鼠标：方向键交给整个滚轮（外层 focusable）
        const it = ui.interact(id ^ (0x7C0 +% @as(u64, @intCast(i))), ir);
        var vb: [8]u8 = @splat(0);
        var n: usize = 0;
        const v = base + i * step;
        if (v >= 10) {
            vb[n] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 10), 10)));
            n += 1;
        }
        vb[n] = '0' + @as(u8, @intCast(@mod(v, 10)));
        n += 1;
        const label = ui.frameStr(vb[0..n]);
        const m = ui.measureText(label, theme.font_body);
        if (offset == 0) ui.addBox(ir.inset(2), .{ .fill = theme.surface, .radius = 6 });
        ui.addText(.{
            .x = ir.x + (ir.w - m.w) / 2,
            .y = y + (row_h - m.h) / 2,
            .w = m.w,
            .h = m.h,
        }, label, theme.font_body, if (offset == 0) theme.text else theme.secondary);
        if (it.clicked) {
            res.value = i;
            res.changed = true;
        }
    }
    return res;
}

/// 时分选择（字段 + 弹层：时列 + 分列）。返回是否变化。
pub fn timePicker(ui: *core.Context, id: []const u8, hour: *i32, minute: *i32, st: *PopupState, opts: TimeOpts) bool {
    var tb: [8]u8 = @splat(0);
    var n: usize = 0;
    const hh: i32 = if (opts.twelve_hour and hour.* > 12) hour.* - 12 else hour.*;
    if (hh >= 10) {
        tb[n] = '0' + @as(u8, @intCast(@divTrunc(hh, 10)));
        n += 1;
    }
    tb[n] = '0' + @as(u8, @intCast(@mod(hh, 10)));
    n += 1;
    tb[n] = ':';
    n += 1;
    tb[n] = '0' + @as(u8, @intCast(@divTrunc(minute.*, 10)));
    n += 1;
    tb[n] = '0' + @as(u8, @intCast(@mod(minute.*, 10)));
    n += 1;
    const label = ui.frameStr(tb[0..n]);
    fieldText(ui, id, "", label, opts.width, st);

    if (!st.open) return false;

    const step: i32 = if (opts.minute_step < 1) 1 else opts.minute_step;
    const minute_count: i32 = @divTrunc(60, step);
    const box_w: f32 = 150;
    const box_h: f32 = 170;
    var by = st.anchor.y + st.anchor.h + 4;
    if (by + box_h > ui.height - 8) by = @max(8, st.anchor.y - box_h - 4);
    const box = t.Rect{ .x = st.anchor.x, .y = by, .w = box_w, .h = box_h };

    _ = ui.beginOverlay(.{ .id = idOf(id, 0x0FF5E7), .hit = true });
    defer ui.endOverlay();
    ui.addBox(box, .{ .fill = theme.bg, .radius = 10, .border = theme.border });
    ui.clip = box;

    const col_w = (box.w - 12) / 2;
    const hr = t.Rect{ .x = box.x + 4, .y = box.y + 6, .w = col_w, .h = box.h - 12 };
    const mr = t.Rect{ .x = hr.x + col_w + 4, .y = hr.y, .w = col_w, .h = hr.h };
    ui.addBox(t.Rect{ .x = hr.x + col_w + 1, .y = hr.y, .w = 1, .h = hr.h }, .{ .fill = theme.border });

    var changed = false;
    const hi = timeColumn(ui, idOf(id, 0x4000), hr, 24, hour.*, 1, 0);
    if (hi.changed) {
        hour.* = hi.value;
        changed = true;
    }
    const mi = timeColumn(ui, idOf(id, 0x5000), mr, minute_count, @divTrunc(minute.*, step), 1, 0);
    if (mi.changed) {
        minute.* = mi.value * step;
        changed = true;
    }

    ui.clip = null;
    if (ui.overlayBackdropClicked()) st.open = false;
    return changed;
}

// ------------------------------------------------------------------ 滚轮选择器

pub const WheelOpts = struct {
    /// 可见行数（奇数，默认 5）。
    rows: u8 = 5,
    width: f32 = 90,
    row_h: f32 = 28,
    /// 首尾相连（越过末尾回到开头）。
    loop: bool = false,
    /// 与相邻滚轮拼成一条连续的选中带：左侧/右侧不画圆角。
    join_left: bool = false,
    join_right: bool = false,
};

pub const WheelState = struct {
    /// 平滑滚动位置（以「项」为单位的小数）。
    pos: f32 = 0,
    /// 正在拖拽。
    dragging: bool = false,
    /// 拖拽起点（像素）。
    drag_from: f32 = 0,
    /// 拖拽开始时的 pos。
    drag_pos: f32 = 0,
};

fn wrapIndex(i: i32, count: i32, loop: bool) i32 {
    if (count <= 0) return 0;
    if (!loop) return if (i < 0) 0 else if (i >= count) count - 1 else i;
    const m = @mod(i, count);
    return if (m < 0) m + count else m;
}

/// 滚轮选择器（拖动 / 滚轮 / 上下键）。返回选中项是否变化。
pub fn wheelPicker(
    ui: *core.Context,
    id: []const u8,
    items: []const []const u8,
    index: *usize,
    st: *WheelState,
    opts: WheelOpts,
) bool {
    const rows: u8 = if (opts.rows < 3) 3 else if (opts.rows > 9) 9 else opts.rows;
    const visible: i32 = if (@mod(rows, 2) == 0) rows - 1 else rows;
    const h = opts.row_h * @as(f32, @floatFromInt(visible));
    const rect = ui.reserve(opts.width, h, false);
    const id_base = idOf(id, 0x7EE1);
    const it = ui.interact(id_base, rect);

    // 拖动 / 滚轮 / 键盘
    // 注意：`Interaction.pressed` 在拖动期间**每帧都是 true**（"active 且按下"），
    // 所以起点只能用 `!st.dragging` 锁一次，不能无条件重写。
    if (it.pressed and !st.dragging) {
        st.dragging = true;
        st.drag_from = ui.input.mouse.y;
        st.drag_pos = st.pos;
    }
    if (st.dragging) {
        if (ui.input.down) {
            const dy = ui.input.mouse.y - st.drag_from;
            st.pos = st.drag_pos - dy / opts.row_h;
        } else {
            st.dragging = false;
            // 松手吸附（无惯性）
            st.pos = @round(st.pos);
        }
    }
    if (it.hover and ui.input.wheel != 0 and !st.dragging) {
        st.pos -= ui.input.wheel;
    }
    if (it.focused) {
        var k: usize = 0;
        const keys = ui.input.keys[0..ui.input.key_count];
        while (k < keys.len) : (k += 1) {
            switch (keys[k]) {
                .up => st.pos -= 1,
                .down => st.pos += 1,
                .home => st.pos = 0,
                .end => st.pos = @floatFromInt(items.len -| 1),
                else => {},
            }
        }
    }

    const count: i32 = @intCast(items.len);
    if (count > 0) {
        const maxp: f32 = @floatFromInt(count - 1);
        if (st.pos < 0) st.pos = 0;
        if (st.pos > maxp) st.pos = maxp;
    }
    const snapped: usize = if (count > 0) @intCast(@max(0, @min(count - 1, @as(i32, @intFromFloat(@round(st.pos)))))) else 0;
    const changed = snapped != index.*;
    index.* = snapped;

    // 选中带
    const band_y = rect.y + rect.h / 2 - opts.row_h / 2;
    ui.addBox(.{ .x = rect.x, .y = band_y, .w = rect.w, .h = opts.row_h }, .{
        .fill = theme.surface,
        .radius = if (opts.join_left or opts.join_right) 0 else 8,
        .border = theme.border,
    });
    ui.clip = rect;
    defer ui.clip = null;

    // 行：以 pos 为基准上下各铺
    const half: i32 = @divTrunc(visible, 2);
    var d: i32 = -half - 1;
    while (d <= half + 1) : (d += 1) {
        if (items.len == 0) break;
        const item_f: f32 = st.pos + @as(f32, @floatFromInt(d));
        var idx: i32 = @intFromFloat(@round(item_f));
        if (opts.loop) {
            idx = wrapIndex(idx, count, true);
        } else if (idx < 0 or idx >= count) {
            continue;
        }
        const off: f32 = @as(f32, @floatFromInt(d)) - (st.pos - @round(st.pos));
        const y = rect.y + rect.h / 2 + off * opts.row_h - opts.row_h / 2;
        const dist = @abs(off);
        const col: t.Color = if (dist < 0.5) theme.text else if (dist < 1.5) theme.secondary else theme.border;
        const label = items[@intCast(idx)];
        const m = ui.measureText(label, theme.font_body);
        ui.addText(.{
            .x = rect.x + (rect.w - m.w) / 2,
            .y = y + (opts.row_h - m.h) / 2,
            .w = m.w,
            .h = m.h,
        }, label, theme.font_body, col);
    }
    return changed;
}

// ------------------------------------------------------------------ 表盘

/// 时钟表盘：拖指针设小时（外圈），再点内圈设分钟。返回是否变化。
pub fn timeDial(ui: *core.Context, id: []const u8, hour: *i32, minute: *i32, size: f32) bool {
    const rect = ui.reserve(size, size, false);
    const cx = rect.x + rect.w / 2;
    const cy = rect.y + rect.h / 2;
    const radius = @min(rect.w, rect.h) / 2 - 6;
    const it = ui.interactEx(idOf(id, 0x71A1), rect, true);
    const inner_r = radius * 0.62;

    // 拖拽：距圆心近 = 分钟，远 = 小时
    var changed = false;
    const dragging = it.dragging or it.pressed;
    if (dragging) {
        const dx = ui.input.mouse.x - cx;
        const dy = ui.input.mouse.y - cy;
        const dist = @sqrt(dx * dx + dy * dy);
        // 角度：12 点方向为 0，顺时针
        var ang = std.math.atan2(dx, -dy);
        if (ang < 0) ang += 2 * std.math.pi;
        const frac = ang / (2 * std.math.pi);
        if (dist >= inner_r) {
            const v: i32 = @intFromFloat(@round(frac * 12));
            const hh: i32 = if (v == 0) 12 else v;
            if (hh != hour.*) {
                hour.* = hh;
                changed = true;
            }
        } else {
            const v: i32 = @intFromFloat(@round(frac * 60));
            const mm: i32 = @mod(v, 60);
            if (mm != minute.*) {
                minute.* = mm;
                changed = true;
            }
        }
    }

    // 盘面
    ui.addBox(rect, .{ .fill = theme.bg, .radius = radius, .border = theme.border });
    // 小时刻度
    var i: i32 = 0;
    while (i < 12) : (i += 1) {
        const ang: f32 = @as(f32, @floatFromInt(i)) / 12.0 * 2 * std.math.pi;
        const sx = cx + @sin(ang) * (radius - 14);
        const sy = cy - @cos(ang) * (radius - 14);
        const ex = cx + @sin(ang) * (radius - 6);
        const ey = cy - @cos(ang) * (radius - 6);
        ui.addOverlayLine(.{ .x = sx, .y = sy }, .{ .x = ex, .y = ey }, 2, theme.track);
    }
    // 刻度数字（12/3/6/9 之外省略，控制文本量）
    const marks = [_]struct { v: i32, dx: f32, dy: f32 }{
        .{ .v = 12, .dx = 0, .dy = -1 },
        .{ .v = 3, .dx = 1, .dy = 0 },
        .{ .v = 6, .dx = 0, .dy = 1 },
        .{ .v = 9, .dx = -1, .dy = 0 },
    };
    for (marks) |mk| {
        var vb: [4]u8 = @splat(0);
        var n: usize = 0;
        if (mk.v >= 10) {
            vb[n] = '0' + @as(u8, @intCast(@divTrunc(mk.v, 10)));
            n += 1;
        }
        vb[n] = '0' + @as(u8, @intCast(@mod(mk.v, 10)));
        n += 1;
        const label = ui.frameStr(vb[0..n]);
        const m = ui.measureText(label, theme.font_small);
        const tx = cx + mk.dx * (radius - 26) - m.w / 2;
        const ty = cy + mk.dy * (radius - 26) - m.h / 2;
        ui.addText(.{ .x = tx, .y = ty, .w = m.w, .h = m.h }, label, theme.font_small, theme.secondary);
    }
    // 时针（小时）
    const h_ang: f32 = @as(f32, @floatFromInt(@mod(hour.*, 12))) / 12.0 * 2 * std.math.pi;
    ui.addOverlayLine(
        .{ .x = cx, .y = cy },
        .{ .x = cx + @sin(h_ang) * inner_r, .y = cy - @cos(h_ang) * inner_r },
        3,
        theme.accent,
    );
    // 分针
    const m_ang: f32 = @as(f32, @floatFromInt(minute.*)) / 60.0 * 2 * std.math.pi;
    ui.addOverlayLine(
        .{ .x = cx, .y = cy },
        .{ .x = cx + @sin(m_ang) * (radius - 16), .y = cy - @cos(m_ang) * (radius - 16) },
        1.6,
        theme.text,
    );
    ui.addBox(.{ .x = cx - 3, .y = cy - 3, .w = 6, .h = 6 }, .{ .fill = theme.accent, .radius = 3 });
    return changed;
}

// ------------------------------------------------------------------ 刻度尺滑块

pub const RulerOpts = struct {
    step: f32 = 1,
    /// 每几个刻度标一个数字。
    major_every: u8 = 5,
    /// 相邻刻度间距（像素）。
    spacing: f32 = 10,
    unit: []const u8 = "",
    width: f32 = 0,
};

pub const RulerState = struct {
    dragging: bool = false,
    drag_from: f32 = 0,
    drag_value: f32 = 0,
};

/// 刻度尺滑块：拖动尺带、固定指针对准读数，松手吸附到 `step`。返回是否变化。
pub fn rulerSlider(
    ui: *core.Context,
    label: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    st: *RulerState,
    opts: RulerOpts,
) bool {
    const h: f32 = 58;
    const rect = ui.reserve(opts.width, h, true);
    const it = ui.interactEx(idOf(label, 0x810E), rect, true);
    const step = if (opts.step > 0) opts.step else 1;
    const span = max - min;
    const spacing = if (opts.spacing > 2) opts.spacing else 10;

    if (value.* < min) value.* = min;
    if (value.* > max) value.* = max;

    var changed = false;
    // `pressed` 拖动期间恒为 true → 起点只能锁一次
    if (it.pressed and !st.dragging) {
        st.dragging = true;
        st.drag_from = ui.input.mouse.x;
        st.drag_value = value.*;
    }
    if (st.dragging) {
        if (ui.input.down) {
            const dx = ui.input.mouse.x - st.drag_from;
            // 拖右 = 值增大（与普通滑块同直觉）
            var v = st.drag_value + dx / spacing * step;
            if (v < min) v = min;
            if (v > max) v = max;
            if (v != value.*) {
                value.* = v;
                changed = true;
            }
        } else {
            st.dragging = false;
            // 吸附
            const snapped = @round(value.* / step) * step;
            if (snapped != value.*) {
                value.* = @max(min, @min(max, snapped));
                changed = true;
            }
        }
    }
    if (it.hover and ui.input.wheel != 0 and !st.dragging) {
        var v = value.* + ui.input.wheel * step;
        if (v < min) v = min;
        if (v > max) v = max;
        if (v != value.*) {
            value.* = v;
            changed = true;
        }
    }

    // 尺面
    ui.addBox(.{ .x = rect.x, .y = rect.y + 20, .w = rect.w, .h = h - 24 }, .{ .fill = theme.surface, .radius = 6 });
    // 标签
    const lm = ui.measureText(label, theme.font_small);
    ui.addText(.{ .x = rect.x + 2, .y = rect.y, .w = lm.w, .h = lm.h }, label, theme.font_small, theme.secondary);
    // 当前值（右上）
    var vb: [24]u8 = undefined;
    const vs = num.fixed(&vb, value.*, if (step < 1) 1 else 0);
    const unit_owned = ui.frameStr(opts.unit);
    const value_label = ui.frameStr(vs);
    const vm = ui.measureText(value_label, theme.font_body);
    ui.addText(.{ .x = rect.x + rect.w - vm.w - 2, .y = rect.y, .w = vm.w, .h = vm.h }, value_label, theme.font_body, theme.text);
    if (unit_owned.len > 0) {
        const um = ui.measureText(unit_owned, theme.font_small);
        const ux = rect.x + rect.w - um.w - 2;
        const uy = rect.y + vm.h + 2;
        if (uy + um.h <= rect.y + 20) ui.addText(.{ .x = ux, .y = uy, .w = um.w, .h = um.h }, unit_owned, theme.font_small, theme.secondary);
    }

    // 刻度
    const axis_y = rect.y + 20;
    const base_y = axis_y + (h - 24);
    const center_x = rect.x + rect.w / 2;
    const px_per_value = spacing / step;
    const major = if (opts.major_every < 1) 5 else opts.major_every;
    // 可见值范围
    const half_span = (rect.w / 2) / px_per_value;
    var v0 = value.* - half_span;
    var v1 = value.* + half_span;
    if (v0 < min) v0 = min;
    if (v1 > max) v1 = max;
    // 对齐到 step
    var tick_index: i32 = @intFromFloat(@ceil(v0 / step));
    ui.clip = t.Rect{ .x = rect.x + 2, .y = axis_y, .w = rect.w - 4, .h = h - 24 };
    while (true) {
        const tv = @as(f32, @floatFromInt(tick_index)) * step;
        if (tv > v1) break;
        if (tv >= min and tv <= max) {
            const tx = center_x + (tv - value.*) * px_per_value;
            const is_major = @mod(tick_index, @as(i32, major)) == 0;
            ui.addBox(.{ .x = tx, .y = base_y - (if (is_major) @as(f32, 14) else 7), .w = 1, .h = if (is_major) @as(f32, 14) else 7 }, .{ .fill = if (is_major) theme.secondary else theme.track });
            if (is_major) {
                var tb: [16]u8 = undefined;
                const ts = num.fixed(&tb, tv, if (step < 1) 1 else 0);
                const owned = ui.frameStr(ts);
                const tm = ui.measureText(owned, theme.font_small);
                ui.addText(.{ .x = tx - tm.w / 2, .y = base_y - 14 - tm.h - 1, .w = tm.w, .h = tm.h }, owned, theme.font_small, theme.secondary);
            }
        }
        tick_index += 1;
        if (@as(f32, @floatFromInt(tick_index)) * step > max + step) break;
        _ = &span;
    }
    ui.clip = null;
    // 固定指针
    ui.addBox(.{ .x = center_x - 1, .y = axis_y, .w = 2, .h = h - 24 }, .{ .fill = theme.accent });
    ui.addBox(.{ .x = center_x - 5, .y = axis_y - 2, .w = 10, .h = 6 }, .{ .fill = theme.accent, .radius = 3 });
    return changed;
}

// ------------------------------------------------------------------ 直方图滑块

pub const HistOpts = struct {
    height: f32 = 64,
    /// 直方图的 bin 值对应的定义域（数据范围）。
    format_decimals: u8 = 0,
};

/// 直方图 + 双滑块（区间筛选）。返回 lo/hi 是否变化。
pub fn histogramSlider(
    ui: *core.Context,
    label: []const u8,
    bins: []const f32,
    lo: *f32,
    hi: *f32,
    min: f32,
    max: f32,
    opts: HistOpts,
) bool {
    var changed = false;
    const bar_h = if (opts.height > 20) opts.height else 64;
    const total_h = bar_h + 30;
    const rect = ui.reserve(0, total_h, true);
    const graphite = t.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = bar_h };

    if (lo.* < min) lo.* = min;
    if (hi.* > max) hi.* = max;
    if (lo.* > hi.*) lo.* = hi.*;

    // 最大值（用于归一化）
    var peak: f32 = 0;
    for (bins) |b| {
        if (b > peak) peak = b;
    }
    if (peak <= 0) peak = 1;

    const n: usize = bins.len;
    if (n > 0) {
        const bw = graphite.w / @as(f32, @floatFromInt(n));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            // 该 bin 对应值区间
            const b0 = min + (max - min) * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const b1 = min + (max - min) * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(n));
            const inside = (b1 > lo.* and b0 < hi.*) or (n == 1);
            const bh = graphite.h * (bins[i] / peak);
            const y = graphite.y + graphite.h - bh;
            if (bh <= 0) continue;
            ui.addBox(
                .{ .x = graphite.x + bw * @as(f32, @floatFromInt(i)) + 1, .y = y, .w = if (bw > 3) bw - 2 else bw, .h = bh },
                .{ .fill = if (inside) theme.accent else theme.track, .radius = if (bw > 6) 2 else 0 },
            );
        }
    }

    // 双滑块（复用 controls 的轨道逻辑，几何在本控件内）
    const track_y = rect.y + bar_h + 6;
    const track_h: f32 = 6;
    const track = t.Rect{ .x = rect.x, .y = track_y, .w = rect.w, .h = track_h };
    const thumb: f32 = 16;
    const lo_ratio: f32 = if (max > min) (lo.* - min) / (max - min) else 0;
    const hi_ratio: f32 = if (max > min) (hi.* - min) / (max - min) else 1;
    const lo_x = track.x + track.w * lo_ratio;
    const hi_x = track.x + track.w * hi_ratio;

    if (track.w > 0) {
        const lo_hit = t.Rect{ .x = lo_x - thumb / 2 - 2, .y = track_y - 6, .w = thumb + 4, .h = thumb + 12 };
        const hi_hit = t.Rect{ .x = hi_x - thumb / 2 - 2, .y = track_y - 6, .w = thumb + 4, .h = thumb + 12 };
        const it_lo = ui.interactEx(idOf(label, 0x1001), lo_hit, true);
        const it_hi = ui.interactEx(idOf(label, 0x1002), hi_hit, true);
        if (it_lo.dragging) {
            var v = min + (max - min) * ((ui.input.mouse.x - track.x) / track.w);
            if (v < min) v = min;
            if (v > hi.*) v = hi.*;
            if (v != lo.*) {
                lo.* = v;
                changed = true;
            }
        }
        if (it_hi.dragging) {
            var v = min + (max - min) * ((ui.input.mouse.x - track.x) / track.w);
            if (v > max) v = max;
            if (v < lo.*) v = lo.*;
            if (v != hi.*) {
                hi.* = v;
                changed = true;
            }
        }
        ui.addBox(track, .{ .fill = theme.track, .radius = track_h / 2 });
        const from = track.x + track.w * (if (max > min) (lo.* - min) / (max - min) else 0);
        const to = track.x + track.w * (if (max > min) (hi.* - min) / (max - min) else 1);
        if (to > from) ui.addBox(.{ .x = from, .y = track.y, .w = to - from, .h = track_h }, .{ .fill = theme.accent, .radius = track_h / 2 });
        const ty = track_y - thumb / 2 + track_h / 2;
        ui.addBox(.{ .x = from - thumb / 2, .y = ty, .w = thumb, .h = thumb }, .{ .fill = theme.bg, .radius = thumb / 2, .border = theme.accent });
        ui.addBox(.{ .x = to - thumb / 2, .y = ty, .w = thumb, .h = thumb }, .{ .fill = theme.bg, .radius = thumb / 2, .border = theme.accent });
    }

    // 读数
    var lb: [16]u8 = undefined;
    var hb: [16]u8 = undefined;
    const ls = ui.frameStr(num.fixed(&lb, lo.*, opts.format_decimals));
    const hs = ui.frameStr(num.fixed(&hb, hi.*, opts.format_decimals));
    if (label.len > 0) {
        const lm = ui.measureText(label, theme.font_small);
        ui.addText(.{ .x = rect.x, .y = rect.y + bar_h + 18, .w = lm.w, .h = lm.h }, label, theme.font_small, theme.secondary);
    }
    var join_buf: [40]u8 = @splat(0);
    var jn: usize = 0;
    for (ls) |c| {
        if (jn < join_buf.len) {
            join_buf[jn] = c;
            jn += 1;
        }
    }
    for (" ~ ") |c| {
        if (jn < join_buf.len) {
            join_buf[jn] = c;
            jn += 1;
        }
    }
    for (hs) |c| {
        if (jn < join_buf.len) {
            join_buf[jn] = c;
            jn += 1;
        }
    }
    const joined = ui.frameStr(join_buf[0..jn]);
    const jm = ui.measureText(joined, theme.font_small);
    ui.addText(.{ .x = rect.x + rect.w - jm.w, .y = rect.y + bar_h + 18, .w = jm.w, .h = jm.h }, joined, theme.font_small, theme.text);
    return changed;
}

// ------------------------------------------------------------------ 签名板

pub const MAX_SIG_POINTS = 1024;
pub const MAX_SIG_STROKES = 32;

pub const SignatureState = struct {
    pts: [MAX_SIG_POINTS]t.Point = @splat(.{}),
    n_pts: usize = 0,
    /// `ends[i]` 是第 i 条笔画的**最后一点下标 + 1**。
    ends: [MAX_SIG_STROKES]u16 = @splat(0),
    n_strokes: usize = 0,
    drawing: bool = false,
    /// 笔画线宽。
    ink_w: f32 = 2,

    pub fn clear(self: *SignatureState) void {
        self.n_pts = 0;
        self.n_strokes = 0;
        self.drawing = false;
    }

    pub fn isEmpty(self: *const SignatureState) bool {
        return self.n_pts == 0;
    }
};

pub const SignatureOpts = struct {
    width: f32 = 0,
    height: f32 = 140,
    placeholder: []const u8 = "Sign here",
};

/// 签名板：按住拖动记录笔画。返回是否有新的笔画点写入。
pub fn signaturePad(ui: *core.Context, id: []const u8, st: *SignatureState, opts: SignatureOpts) bool {
    const h = if (opts.height > 40) opts.height else 140;
    const rect = ui.reserve(opts.width, h, true);
    const it = ui.interactEx(idOf(id, 0x5167), rect, true);
    var changed = false;

    ui.addBox(rect, .{ .fill = theme.bg, .radius = 8, .border = theme.border });

    if (it.pressed and !st.drawing and st.n_strokes < MAX_SIG_STROKES and st.n_pts < MAX_SIG_POINTS) {
        st.drawing = true;
        st.pts[st.n_pts] = .{ .x = ui.input.mouse.x - rect.x, .y = ui.input.mouse.y - rect.y };
        st.n_pts += 1;
        changed = true;
    } else if (st.drawing and ui.input.down) {
        if (st.n_pts < MAX_SIG_POINTS) {
            const last = st.pts[st.n_pts - 1];
            const nx = ui.input.mouse.x - rect.x;
            const ny = ui.input.mouse.y - rect.y;
            // 至少移动 2px 才记点，避免点数暴涨
            if (@abs(nx - last.x) + @abs(ny - last.y) >= 2) {
                st.pts[st.n_pts] = .{ .x = nx, .y = ny };
                st.n_pts += 1;
                changed = true;
            }
        }
    }
    if (st.drawing and !ui.input.down) {
        st.drawing = false;
        if (st.n_pts > 0 and st.n_strokes < MAX_SIG_STROKES) {
            st.ends[st.n_strokes] = @intCast(st.n_pts);
            st.n_strokes += 1;
        }
    }

    // 绘笔画
    ui.clip = rect;
    var s: usize = 0;
    var start: usize = 0;
    while (s < st.n_strokes) : (s += 1) {
        const end: usize = st.ends[s];
        var i: usize = start + 1;
        while (i < end and i < st.n_pts) : (i += 1) {
            const a = st.pts[i - 1];
            const b = st.pts[i];
            ui.addOverlayLine(
                .{ .x = rect.x + a.x, .y = rect.y + a.y },
                .{ .x = rect.x + b.x, .y = rect.y + b.y },
                st.ink_w,
                theme.text,
            );
        }
        start = end;
    }
    // 正在画的这条
    if (st.drawing and st.n_pts > 1) {
        var i: usize = if (start > 0) start + 1 else 1;
        while (i < st.n_pts) : (i += 1) {
            const a = st.pts[i - 1];
            const b = st.pts[i];
            ui.addOverlayLine(
                .{ .x = rect.x + a.x, .y = rect.y + a.y },
                .{ .x = rect.x + b.x, .y = rect.y + b.y },
                st.ink_w,
                theme.text,
            );
        }
    }
    ui.clip = null;

    if (st.isEmpty()) {
        const m = ui.measureText(opts.placeholder, theme.font_body);
        ui.addText(.{
            .x = rect.x + (rect.w - m.w) / 2,
            .y = rect.y + (rect.h - m.h) / 2,
            .w = m.w,
            .h = m.h,
        }, opts.placeholder, theme.font_body, theme.border);
    }
    return changed;
}

/// 读取点与笔画边界（对位 `cui_signature_points`）：返回点数，`ends` 指向笔画末尾表。
pub fn signaturePoints(st: *SignatureState) struct { points: []const t.Point, ends: []const u16, strokes: usize } {
    return .{ .points = st.pts[0..st.n_pts], .ends = st.ends[0..st.n_strokes], .strokes = st.n_strokes };
}

/// 清空笔画（对位 `cui_signature_clear`）。
pub fn signatureClear(st: *SignatureState) void {
    st.clear();
}
