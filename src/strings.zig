//! 界面文案表（对位 CUI `cui_strings.c`）：月名 / 星期名 / 「今天」等，
//! 供月历、日期选择器、范围日历、日历热力图、文件浏览器共用。
//!
//! 调用方**持有表**，框架只存指针（表必须活得比使用期长），每帧读取 ——
//! 换语言就是一次调用。某一条留空（`len == 0`）则回退英文，所以只翻译一部分也行。
//! `set(ui, null)` 恢复全英文。周一开头的惯例与 CUI 一致。
const core = @import("core.zig");

pub const month_en = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};
pub const month_short_en = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
pub const weekday_en = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
pub const weekday_short_en = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
pub const weekday_min_en = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };

/// 文案表。留空（`len == 0`）的条目回退英文。
pub const Strings = struct {
    /// "January" … "December"
    month: [12][]const u8 = month_en,
    /// "Jan" …
    month_short: [12][]const u8 = month_short_en,
    /// "Monday" … "Sunday"（周一开头）
    weekday: [7][]const u8 = weekday_en,
    /// "Mon" …
    weekday_short: [7][]const u8 = weekday_short_en,
    /// "Mo" …
    weekday_min: [7][]const u8 = weekday_min_en,
    today: []const u8 = "Today",
};

/// 设置文案表；`null` 恢复英文。
pub fn set(ui: *core.Context, s: ?*const Strings) void {
    ui.strings = s;
}

/// 当前文案表（未设置则为 null = 英文）。
pub fn get(ui: *core.Context) ?*const Strings {
    return ui.strings;
}

fn pick(table: []const []const u8, i: usize, fallback: []const []const u8) []const u8 {
    if (i < table.len and table[i].len > 0) return table[i];
    return fallback[i];
}

/// 月名（1..=12）。
pub fn monthName(ui: *core.Context, m: u8) []const u8 {
    const idx: usize = if (m >= 1 and m <= 12) m - 1 else 0;
    if (ui.strings) |s| return pick(s.month[0..], idx, month_en[0..]);
    return month_en[idx];
}

/// 简写月名（1..=12）。
pub fn monthShort(ui: *core.Context, m: u8) []const u8 {
    const idx: usize = if (m >= 1 and m <= 12) m - 1 else 0;
    if (ui.strings) |s| return pick(s.month_short[0..], idx, month_short_en[0..]);
    return month_short_en[idx];
}

/// 星期名（0 = 周一）。
pub fn weekdayName(ui: *core.Context, i: usize) []const u8 {
    const idx = i % 7;
    if (ui.strings) |s| return pick(s.weekday[0..], idx, weekday_en[0..]);
    return weekday_en[idx];
}

/// 简写星期名（0 = 周一）。
pub fn weekdayShort(ui: *core.Context, i: usize) []const u8 {
    const idx = i % 7;
    if (ui.strings) |s| return pick(s.weekday_short[0..], idx, weekday_short_en[0..]);
    return weekday_short_en[idx];
}

/// 两字母星期名（0 = 周一）。
pub fn weekdayMin(ui: *core.Context, i: usize) []const u8 {
    const idx = i % 7;
    if (ui.strings) |s| return pick(s.weekday_min[0..], idx, weekday_min_en[0..]);
    return weekday_min_en[idx];
}

/// 「今天」按钮的文案。
pub fn todayLabel(ui: *core.Context) []const u8 {
    if (ui.strings) |s| {
        if (s.today.len > 0) return s.today;
    }
    return "Today";
}
