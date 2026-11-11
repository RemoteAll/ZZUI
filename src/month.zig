//! 月历族（对位 CUI `cui_month.c`）：月份网格 + 事件条 + 选中/翻月。
//!
//! 日期只用三个整数（年/月/日），不引入时间库：月份长度与星期都由 `daysFromCivil`
//! 推算（Howard Hinnant 的民用历算法），Zig 侧不需要任何平台时间 API。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const extras = @import("extras.zig");
const num = @import("num.zig");
const t = @import("types.zig");

pub const Date = struct {
    year: i32 = 1970,
    month: u8 = 1,
    day: u8 = 1,

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    pub fn less(a: Date, b: Date) bool {
        if (a.year != b.year) return a.year < b.year;
        if (a.month != b.month) return a.month < b.month;
        return a.day < b.day;
    }
};

pub fn isLeap(y: i32) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) @as(u8, 29) else 28,
        else => 30,
    };
}

/// 距 1970-01-01 的天数（可为负）。
pub fn daysFromCivil(d: Date) i64 {
    var y: i64 = d.year;
    if (d.month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, d.month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d.day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// 星期（0 = 周一 … 6 = 周日）。
pub fn weekdayOf(d: Date) u8 {
    const days = daysFromCivil(d);
    return @intCast(@mod(days + 3, 7));
}

const month_names_en = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
const weekday_names_en = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };

pub const MonthEvent = struct {
    title: []const u8,
    start: Date,
    /// 早于 start 或未设置（同年月日 = 单日事件）。
    end: Date = .{ .year = 0, .month = 1, .day = 1 },
    /// 有具体时刻时的小时数（9.5 = 9:30）；`all_day` 为 true 时忽略。
    time: f32 = 0,
    all_day: bool = true,
    tone: extras.Tone = .accent,
};

pub const MonthOpts = struct {
    /// 当前选中日（调用方可读写）。
    selected: ?*Date = null,
    /// 0 = 周一 … 6 = 周日。
    first_weekday: u8 = 0,
    cell_height: f32 = 76,
    /// 12 个月名（本地化）。
    month_names: ?[]const []const u8 = null,
    /// 7 个星期名（周一开头）。
    day_names: ?[]const []const u8 = null,
    /// 覆盖「今天」（跨时区/测试）。
    today: ?Date = null,
};

pub const MonthResult = struct {
    /// 点了某个事件（`events` 下标），否则 -1。
    event: i32 = -1,
    /// 点了日期格。
    day_clicked: bool = false,
    /// 箭头 / 方向键 / Today 改了 `month`。
    month_changed: bool = false,
};

fn monthName(opts: MonthOpts, m: u8) []const u8 {
    if (opts.month_names) |names| {
        if (m >= 1 and m <= 12 and m <= names.len) return names[m - 1];
    }
    return month_names_en[(if (m >= 1 and m <= 12) m - 1 else 0)];
}

fn dayName(opts: MonthOpts, i: usize) []const u8 {
    if (opts.day_names) |names| {
        if (i < names.len) return names[i];
    }
    return weekday_names_en[i];
}

/// 月历（CUI `cui_month_calendar`）：标题 + 星期行 + 6×7 网格 + 事件条。
pub fn monthCalendar(
    ui: *core.Context,
    id: []const u8,
    month: *Date,
    events: []const MonthEvent,
    opts: MonthOpts,
) MonthResult {
    var res = MonthResult{};
    const cell_h = if (opts.cell_height > 40) opts.cell_height else 76;
    const gap: f32 = 2;
    const header_h: f32 = 28;
    const weekday_h: f32 = 20;
    const total_h = header_h + weekday_h + (cell_h + gap) * 6;
    const rect = ui.reserve(0, total_h, true);
    const cell_w = (rect.w - gap * 6) / 7;

    // ---- 标题行：全部绝对定位（若用 `ui.row()` 会从已推进的父游标开始，标题会掉到网格下方）
    const title = blk: {
        var b: [40]u8 = @splat(0);
        var n: usize = 0;
        var yb: [12]u8 = undefined;
        const ys = num.int(&yb, @intCast(month.year));
        for (ys) |c| {
            if (n < b.len) {
                b[n] = c;
                n += 1;
            }
        }
        if (n < b.len) {
            b[n] = ' ';
            n += 1;
        }
        for (monthName(opts, month.month)) |c| {
            if (n < b.len) {
                b[n] = c;
                n += 1;
            }
        }
        break :blk ui.frameStr(b[0..n]);
    };
    const tm = ui.measureText(title, theme.font_body);
    const prev = t.Rect{ .x = rect.x, .y = rect.y, .w = 26, .h = header_h };
    const title_rect = t.Rect{ .x = prev.x + prev.w + 8, .y = rect.y, .w = tm.w + 4, .h = header_h };
    const next = t.Rect{ .x = title_rect.x + title_rect.w + 10, .y = rect.y, .w = 26, .h = header_h };
    const prev_hit = ui.interactEx(core.Context.idOf(id) ^ 0x60D7, prev, true);
    const next_hit = ui.interactEx(core.Context.idOf(id) ^ 0x60D8, next, true);
    ui.addText(
        .{ .x = title_rect.x, .y = rect.y + (header_h - tm.h) / 2, .w = tm.w, .h = tm.h },
        title,
        theme.font_body,
        theme.text,
    );

    // 箭头外观（‹ › 用两段短线画，避免依赖字体里的符号）
    const py = prev.y + prev.h / 2;
    const pcolor: t.Color = if (prev_hit.hover) theme.accent else theme.secondary;
    ui.addOverlayLine(.{ .x = prev.x + 16, .y = py - 5 }, .{ .x = prev.x + 10, .y = py }, 1.6, pcolor);
    ui.addOverlayLine(.{ .x = prev.x + 10, .y = py }, .{ .x = prev.x + 16, .y = py + 5 }, 1.6, pcolor);
    const ny = next.y + next.h / 2;
    const ncolor: t.Color = if (next_hit.hover) theme.accent else theme.secondary;
    ui.addOverlayLine(.{ .x = next.x + 6, .y = ny - 5 }, .{ .x = next.x + 12, .y = ny }, 1.6, ncolor);
    ui.addOverlayLine(.{ .x = next.x + 12, .y = ny }, .{ .x = next.x + 6, .y = ny + 5 }, 1.6, ncolor);

    var month_delta: i32 = 0;
    if (prev_hit.clicked or prev_hit.activated) month_delta = -1;
    if (next_hit.clicked or next_hit.activated) month_delta = 1;
    if (month_delta != 0) {
        var m: i32 = @as(i32, month.month) + month_delta;
        var y = month.year;
        if (m < 1) {
            m = 12;
            y -= 1;
        } else if (m > 12) {
            m = 1;
            y += 1;
        }
        month.year = y;
        month.month = @intCast(m);
        res.month_changed = true;
    }
    // 方向键翻月（聚焦在月历上时）；Home 回到今天所在月
    if (prev_hit.focused or next_hit.focused) {
        if (ui.input.keyPressed(.page_up) or ui.input.keyPressed(.left)) {
            const m2: i32 = if (month.month == 1) 12 else @as(i32, month.month) - 1;
            if (month.month == 1) month.year -= 1;
            month.month = @intCast(m2);
            res.month_changed = true;
        }
        if (ui.input.keyPressed(.page_down) or ui.input.keyPressed(.right)) {
            const m2: i32 = if (month.month == 12) 1 else @as(i32, month.month) + 1;
            if (month.month == 12) month.year += 1;
            month.month = @intCast(m2);
            res.month_changed = true;
        }
        if (ui.input.keyPressed(.home)) {
            if (opts.today) |td| {
                month.year = td.year;
                month.month = td.month;
                res.month_changed = true;
            }
        }
    }

    // ---- 星期行
    var wi: usize = 0;
    while (wi < 7) : (wi += 1) {
        const idx = (@as(usize, opts.first_weekday) + wi) % 7;
        const x = rect.x + @as(f32, @floatFromInt(wi)) * (cell_w + gap);
        const y = rect.y + header_h;
        const dm = ui.measureText(dayName(opts, idx), theme.font_small);
        ui.addText(
            .{ .x = x + (cell_w - dm.w) / 2, .y = y + (weekday_h - dm.h) / 2, .w = dm.w, .h = dm.h },
            dayName(opts, idx),
            theme.font_small,
            theme.secondary,
        );
    }

    // ---- 网格
    const first = Date{ .year = month.year, .month = month.month, .day = 1 };
    const lead: usize = (@as(usize, weekdayOf(first)) + 7 - @as(usize, opts.first_weekday)) % 7;
    const dim: usize = daysInMonth(month.year, month.month);
    const today = opts.today;

    const grid_y = rect.y + header_h + weekday_h;
    var row: usize = 0;
    while (row < 6) : (row += 1) {
        var col: usize = 0;
        while (col < 7) : (col += 1) {
            const cell_index = row * 7 + col;
            const day_num = if (cell_index >= lead) cell_index - lead + 1 else 0;
            const x = rect.x + @as(f32, @floatFromInt(col)) * (cell_w + gap);
            const y = grid_y + @as(f32, @floatFromInt(row)) * (cell_h + gap);
            const cell = t.Rect{ .x = x, .y = y, .w = cell_w, .h = cell_h };
            if (day_num == 0 or day_num > dim) {
                ui.addBox(cell, .{ .fill = theme.surface, .radius = 6 });
                continue;
            }
            const this_day = Date{ .year = month.year, .month = month.month, .day = @intCast(day_num) };
            const is_today = if (today) |td| td.eql(this_day) else false;
            const is_sel = if (opts.selected) |sel| sel.eql(this_day) else false;
            // 格子只响应鼠标：不做 Tab 停靠点（否则一个月 42 格会把焦点池占满）
            const hit = ui.interact(core.Context.idOf(id) ^ (0xD00 + cell_index), cell);

            const bg: t.Color = if (is_sel)
                theme.accent_bg
            else if (hit.hover)
                theme.surface
            else
                theme.bg;
            ui.addBox(cell, .{
                .fill = bg,
                .radius = 6,
                .border = if (is_today) theme.accent else theme.border,
            });
            var db: [4]u8 = undefined;
            const ds = ui.frameStr(num.int(&db, @intCast(day_num)));
            ui.addText(
                .{ .x = x + 6, .y = y + 4, .w = 18, .h = 16 },
                ds,
                theme.font_small,
                if (is_sel) theme.accent else theme.text,
            );

            // 事件条（当日最多 2 条 + 「+N」）
            var shown: usize = 0;
            var extra_count: usize = 0;
            for (events, 0..) |ev, ei| {
                const e_start = if (ev.end.less(ev.start)) ev.start else ev.start;
                const e_end = if (ev.end.less(ev.start)) ev.start else ev.end;
                if (this_day.less(e_start) or e_end.less(this_day)) continue;
                if (shown < 2) {
                    const bar = t.Rect{ .x = x + 4, .y = y + 22 + @as(f32, @floatFromInt(shown)) * 15, .w = cell_w - 8, .h = 13 };
                    const c = extras.toneColors(ev.tone);
                    const bhit = ui.interact(core.Context.idOf(id) ^ (0xE00 + ei), bar);
                    ui.addBox(bar, .{ .fill = c.bg, .radius = 3 });
                    ui.addBox(.{ .x = bar.x, .y = bar.y, .w = 3, .h = bar.h }, .{ .fill = c.fg, .radius = 2 });
                    const em = ui.measureText(ev.title, theme.font_small);
                    // 事件标题按格宽硬截断
                    var cut: usize = ev.title.len;
                    while (cut > 0 and ui.measureText(ev.title[0..cut], theme.font_small).w > cell_w - 16) : (cut -= 1) {}
                    const etxt = ev.title[0..cut];
                    _ = em;
                    ui.addText(
                        .{ .x = bar.x + 6, .y = bar.y + 1, .w = cell_w - 14, .h = 12 },
                        etxt,
                        theme.font_small,
                        c.fg,
                    );
                    if (bhit.clicked or bhit.activated) res.event = @intCast(ei);
                    shown += 1;
                } else {
                    extra_count += 1;
                }
            }
            if (extra_count > 0) {
                var xb: [16]u8 = undefined;
                var n: usize = 0;
                xb[0] = '+';
                n = 1;
                var nb: [8]u8 = undefined;
                const ns = ui.frameStr(num.int(&nb, @intCast(extra_count)));
                for (ns) |c| {
                    if (n < xb.len) {
                        xb[n] = c;
                        n += 1;
                    }
                }
                ui.addText(
                    .{ .x = x + 6, .y = y + cell_h - 16, .w = cell_w - 12, .h = 14 },
                    ui.frameStr(xb[0..n]),
                    theme.font_small,
                    theme.secondary,
                );
            }

            if (hit.clicked) {
                if (opts.selected) |sel| sel.* = this_day;
                res.day_clicked = true;
            }
        }
    }

    // ---- 箭头与翻月的效果已在上面写回 `month` / `res`
    return res;
}
