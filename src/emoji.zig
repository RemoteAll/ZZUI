//! Emoji（对位 CUI `cui_emoji.c`）：把 emoji 当文本交给平台字体画 + 一个 emoji 选择器。
//!
//! **为什么没有字体解析**：CUI 自己解析 sbix / CBDT / COLR 字体才能画出彩色 emoji；
//! ZZUI 的文本一律走**平台字体**（Win32 GDI，带系统字体回退），彩色 emoji 由系统直接画出来。
//! 于是这里：
//! - `fontLoadSystem()` 恒成功（平台本来就画得了）、`fontLoadFile()` / `fontLoadMemory()`
//!   返回 false —— **不做字体解析**（真做要 60 KB 级字体解析器 + 几十 KB 字形缓存，与
//!   「产物尽可能小」的硬约束冲突）；
//! - `supported()` 恒 true（拿不到逐字形覆盖信息；GDI 会回退到能画它的字体）。
//!
//! **目录是内置子集**：CUI 带 1914 个 emoji 的 deflate 数据（16.4 KB 压缩 / 41 KB 原文 + 解压器）。
//! 这里是手写目录（九个分组、约 130 个常用 emoji、名字为英文），选择器的**交互全部保留**
//! （搜索、分组页签、最近使用、肤色、预览与名字、键盘导航），只是目录小了一档。
//!
//! 交互：滚轮滚网格、上下左右移动光标、回车/点击选中、Esc 清搜索、肤色按钮循环 0..5。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

pub const Group = enum(u8) {
    smileys = 0,
    people = 1,
    nature = 2,
    food = 3,
    travel = 4,
    activities = 5,
    objects = 6,
    symbols = 7,
    flags = 8,
};

pub const GROUP_COUNT = 9;

pub const groupNames = [GROUP_COUNT][]const u8{
    "Smileys & emotion",
    "People & body",
    "Animals & nature",
    "Food & drink",
    "Travel & places",
    "Activities",
    "Objects",
    "Symbols",
    "Flags",
};

/// 分组页签上显示的图标（每个分组一个代表 emoji）。
pub const groupIcons = [GROUP_COUNT][]const u8{
    "\u{1F600}",
    "\u{1F44B}",
    "\u{1F43B}",
    "\u{1F354}",
    "\u{2708}\u{FE0F}",
    "\u{26BD}",
    "\u{1F4F1}",
    "\u{2764}\u{FE0F}",
    "\u{1F3C1}",
};

pub const Entry = struct {
    text: []const u8,
    name: []const u8,
    group: Group,
    /// 支持肤色修饰（单一码位的手/人）。
    tonable: bool = false,
};

/// 内置目录（按分组连续排列，便于按组过滤）。
pub const catalog = [_]Entry{
    // ---- Smileys & emotion
    .{ .text = "\u{1F600}", .name = "grinning face", .group = .smileys },
    .{ .text = "\u{1F603}", .name = "smiling face big eyes", .group = .smileys },
    .{ .text = "\u{1F604}", .name = "grinning face smiling eyes", .group = .smileys },
    .{ .text = "\u{1F601}", .name = "beaming face", .group = .smileys },
    .{ .text = "\u{1F606}", .name = "grinning squinting face", .group = .smileys },
    .{ .text = "\u{1F605}", .name = "grinning face sweat", .group = .smileys },
    .{ .text = "\u{1F602}", .name = "face with tears of joy", .group = .smileys },
    .{ .text = "\u{1F642}", .name = "slightly smiling face", .group = .smileys },
    .{ .text = "\u{1F643}", .name = "upside down face", .group = .smileys },
    .{ .text = "\u{1F609}", .name = "winking face", .group = .smileys },
    .{ .text = "\u{1F60A}", .name = "smiling face smiling eyes", .group = .smileys },
    .{ .text = "\u{1F60D}", .name = "smiling face heart eyes", .group = .smileys },
    .{ .text = "\u{1F618}", .name = "face blowing a kiss", .group = .smileys },
    .{ .text = "\u{1F61C}", .name = "winking face tongue", .group = .smileys },
    .{ .text = "\u{1F914}", .name = "thinking face", .group = .smileys },
    .{ .text = "\u{1F634}", .name = "sleeping face", .group = .smileys },
    .{ .text = "\u{1F622}", .name = "crying face", .group = .smileys },
    .{ .text = "\u{1F621}", .name = "enraged face", .group = .smileys },
    // ---- People & body
    .{ .text = "\u{1F44B}", .name = "waving hand", .group = .people, .tonable = true },
    .{ .text = "\u{1F590}", .name = "hand with fingers splayed", .group = .people, .tonable = true },
    .{ .text = "\u{270B}", .name = "raised hand", .group = .people, .tonable = true },
    .{ .text = "\u{1F44C}", .name = "ok hand", .group = .people, .tonable = true },
    .{ .text = "\u{270C}", .name = "victory hand", .group = .people, .tonable = true },
    .{ .text = "\u{1F91E}", .name = "crossed fingers", .group = .people, .tonable = true },
    .{ .text = "\u{1F44D}", .name = "thumbs up", .group = .people, .tonable = true },
    .{ .text = "\u{1F44E}", .name = "thumbs down", .group = .people, .tonable = true },
    .{ .text = "\u{270A}", .name = "raised fist", .group = .people, .tonable = true },
    .{ .text = "\u{1F44F}", .name = "clapping hands", .group = .people, .tonable = true },
    .{ .text = "\u{1F64F}", .name = "folded hands", .group = .people, .tonable = true },
    .{ .text = "\u{1F4AA}", .name = "flexed biceps", .group = .people, .tonable = true },
    .{ .text = "\u{1F9E0}", .name = "brain", .group = .people },
    .{ .text = "\u{1F463}", .name = "footprints", .group = .people },
    .{ .text = "\u{1F440}", .name = "eyes", .group = .people },
    .{ .text = "\u{1F464}", .name = "bust in silhouette", .group = .people },
    // ---- Animals & nature
    .{ .text = "\u{1F436}", .name = "dog face", .group = .nature },
    .{ .text = "\u{1F431}", .name = "cat face", .group = .nature },
    .{ .text = "\u{1F42D}", .name = "mouse face", .group = .nature },
    .{ .text = "\u{1F439}", .name = "hamster", .group = .nature },
    .{ .text = "\u{1F430}", .name = "rabbit face", .group = .nature },
    .{ .text = "\u{1F98A}", .name = "fox", .group = .nature },
    .{ .text = "\u{1F43B}", .name = "bear", .group = .nature },
    .{ .text = "\u{1F43C}", .name = "panda", .group = .nature },
    .{ .text = "\u{1F428}", .name = "koala", .group = .nature },
    .{ .text = "\u{1F42F}", .name = "tiger face", .group = .nature },
    .{ .text = "\u{1F981}", .name = "lion", .group = .nature },
    .{ .text = "\u{1F437}", .name = "pig face", .group = .nature },
    .{ .text = "\u{1F438}", .name = "frog", .group = .nature },
    .{ .text = "\u{1F333}", .name = "deciduous tree", .group = .nature },
    .{ .text = "\u{1F334}", .name = "palm tree", .group = .nature },
    .{ .text = "\u{1F335}", .name = "cactus", .group = .nature },
    // ---- Food & drink
    .{ .text = "\u{1F34E}", .name = "red apple", .group = .food },
    .{ .text = "\u{1F350}", .name = "pear", .group = .food },
    .{ .text = "\u{1F34A}", .name = "tangerine", .group = .food },
    .{ .text = "\u{1F34B}", .name = "lemon", .group = .food },
    .{ .text = "\u{1F34C}", .name = "banana", .group = .food },
    .{ .text = "\u{1F349}", .name = "watermelon", .group = .food },
    .{ .text = "\u{1F347}", .name = "grapes", .group = .food },
    .{ .text = "\u{1F353}", .name = "strawberry", .group = .food },
    .{ .text = "\u{1F352}", .name = "cherries", .group = .food },
    .{ .text = "\u{1F351}", .name = "peach", .group = .food },
    .{ .text = "\u{1F35E}", .name = "bread", .group = .food },
    .{ .text = "\u{1F355}", .name = "pizza", .group = .food },
    .{ .text = "\u{1F354}", .name = "hamburger", .group = .food },
    .{ .text = "\u{2615}", .name = "hot beverage", .group = .food },
    .{ .text = "\u{1F37A}", .name = "beer mug", .group = .food },
    .{ .text = "\u{1F382}", .name = "birthday cake", .group = .food },
    // ---- Travel & places
    .{ .text = "\u{1F697}", .name = "automobile", .group = .travel },
    .{ .text = "\u{1F695}", .name = "taxi", .group = .travel },
    .{ .text = "\u{1F699}", .name = "sport utility vehicle", .group = .travel },
    .{ .text = "\u{1F68C}", .name = "bus", .group = .travel },
    .{ .text = "\u{1F693}", .name = "police car", .group = .travel },
    .{ .text = "\u{1F691}", .name = "ambulance", .group = .travel },
    .{ .text = "\u{1F6B2}", .name = "bicycle", .group = .travel },
    .{ .text = "\u{2708}", .name = "airplane", .group = .travel },
    .{ .text = "\u{1F680}", .name = "rocket", .group = .travel },
    .{ .text = "\u{1F681}", .name = "helicopter", .group = .travel },
    .{ .text = "\u{1F682}", .name = "locomotive", .group = .travel },
    .{ .text = "\u{26F5}", .name = "sailboat", .group = .travel },
    .{ .text = "\u{1F5FA}", .name = "world map", .group = .travel },
    .{ .text = "\u{1F3D4}", .name = "snow capped mountain", .group = .travel },
    .{ .text = "\u{1F3E0}", .name = "house", .group = .travel },
    .{ .text = "\u{1F3D6}", .name = "beach with umbrella", .group = .travel },
    // ---- Activities
    .{ .text = "\u{26BD}", .name = "soccer ball", .group = .activities },
    .{ .text = "\u{1F3C0}", .name = "basketball", .group = .activities },
    .{ .text = "\u{1F3C8}", .name = "american football", .group = .activities },
    .{ .text = "\u{26BE}", .name = "baseball", .group = .activities },
    .{ .text = "\u{1F3BE}", .name = "tennis", .group = .activities },
    .{ .text = "\u{1F3D0}", .name = "volleyball", .group = .activities },
    .{ .text = "\u{1F3B1}", .name = "pool 8 ball", .group = .activities },
    .{ .text = "\u{1F3AF}", .name = "direct hit", .group = .activities },
    .{ .text = "\u{1F3AE}", .name = "video game", .group = .activities },
    .{ .text = "\u{1F3B2}", .name = "game die", .group = .activities },
    .{ .text = "\u{1F3B8}", .name = "guitar", .group = .activities },
    .{ .text = "\u{1F3B9}", .name = "musical keyboard", .group = .activities },
    .{ .text = "\u{1F3BA}", .name = "trumpet", .group = .activities },
    .{ .text = "\u{1F3C6}", .name = "trophy", .group = .activities },
    .{ .text = "\u{1F3AD}", .name = "performing arts", .group = .activities },
    .{ .text = "\u{1F3A8}", .name = "artist palette", .group = .activities },
    // ---- Objects
    .{ .text = "\u{231A}", .name = "watch", .group = .objects },
    .{ .text = "\u{1F4F1}", .name = "mobile phone", .group = .objects },
    .{ .text = "\u{1F4BB}", .name = "laptop", .group = .objects },
    .{ .text = "\u{2328}", .name = "keyboard", .group = .objects },
    .{ .text = "\u{1F5A5}", .name = "desktop computer", .group = .objects },
    .{ .text = "\u{1F5A8}", .name = "printer", .group = .objects },
    .{ .text = "\u{1F5B1}", .name = "computer mouse", .group = .objects },
    .{ .text = "\u{1F4A1}", .name = "light bulb", .group = .objects },
    .{ .text = "\u{1F526}", .name = "flashlight", .group = .objects },
    .{ .text = "\u{1F4F7}", .name = "camera", .group = .objects },
    .{ .text = "\u{1F4FA}", .name = "television", .group = .objects },
    .{ .text = "\u{1F4FB}", .name = "radio", .group = .objects },
    .{ .text = "\u{23F0}", .name = "alarm clock", .group = .objects },
    .{ .text = "\u{1F511}", .name = "key", .group = .objects },
    .{ .text = "\u{1F4E6}", .name = "package", .group = .objects },
    .{ .text = "\u{1F4DA}", .name = "books", .group = .objects },
    // ---- Symbols
    .{ .text = "\u{2764}", .name = "red heart", .group = .symbols },
    .{ .text = "\u{1F9E1}", .name = "orange heart", .group = .symbols },
    .{ .text = "\u{1F49B}", .name = "yellow heart", .group = .symbols },
    .{ .text = "\u{1F49A}", .name = "green heart", .group = .symbols },
    .{ .text = "\u{1F499}", .name = "blue heart", .group = .symbols },
    .{ .text = "\u{1F49C}", .name = "purple heart", .group = .symbols },
    .{ .text = "\u{1F525}", .name = "fire", .group = .symbols },
    .{ .text = "\u{2728}", .name = "sparkles", .group = .symbols },
    .{ .text = "\u{2B50}", .name = "star", .group = .symbols },
    .{ .text = "\u{2705}", .name = "check mark button", .group = .symbols },
    .{ .text = "\u{274C}", .name = "cross mark", .group = .symbols },
    .{ .text = "\u{26A0}", .name = "warning", .group = .symbols },
    .{ .text = "\u{2753}", .name = "question mark", .group = .symbols },
    .{ .text = "\u{2757}", .name = "exclamation mark", .group = .symbols },
    .{ .text = "\u{1F6A7}", .name = "construction", .group = .symbols },
    .{ .text = "\u{267B}", .name = "recycling symbol", .group = .symbols },
    // ---- Flags
    .{ .text = "\u{1F3C1}", .name = "chequered flag", .group = .flags },
    .{ .text = "\u{1F6A9}", .name = "triangular flag", .group = .flags },
    .{ .text = "\u{1F38C}", .name = "crossed flags", .group = .flags },
    .{ .text = "\u{1F3F3}", .name = "white flag", .group = .flags },
    .{ .text = "\u{1F3F4}", .name = "black flag", .group = .flags },
    .{ .text = "\u{1F1E8}\u{1F1F3}", .name = "flag china", .group = .flags },
    .{ .text = "\u{1F1FA}\u{1F1F8}", .name = "flag united states", .group = .flags },
    .{ .text = "\u{1F1EF}\u{1F1F5}", .name = "flag japan", .group = .flags },
    .{ .text = "\u{1F1EC}\u{1F1E7}", .name = "flag united kingdom", .group = .flags },
    .{ .text = "\u{1F1E9}\u{1F1EA}", .name = "flag germany", .group = .flags },
    .{ .text = "\u{1F1EB}\u{1F1F7}", .name = "flag france", .group = .flags },
    .{ .text = "\u{1F1EE}\u{1F1F9}", .name = "flag italy", .group = .flags },
    .{ .text = "\u{1F1F0}\u{1F1F7}", .name = "flag south korea", .group = .flags },
    .{ .text = "\u{1F1F7}\u{1F1FA}", .name = "flag russia", .group = .flags },
    .{ .text = "\u{1F1EA}\u{1F1F8}", .name = "flag spain", .group = .flags },
    .{ .text = "\u{1F1E7}\u{1F1F7}", .name = "flag brazil", .group = .flags },
};

pub const TONE_COUNT = 6;
/// 肤色调色（按钮上画的小圆点）。
const tone_colors = [6]t.Color{
    .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    .{ .r = 0xF7, .g = 0xD7, .b = 0xB5, .a = 255 },
    .{ .r = 0xE0, .g = 0xB4, .b = 0x8D, .a = 255 },
    .{ .r = 0xC6, .g = 0x8E, .b = 0x63, .a = 255 },
    .{ .r = 0x9C, .g = 0x5F, .b = 0x38, .a = 255 },
    .{ .r = 0x5C, .g = 0x3B, .b = 0x28, .a = 255 },
};

// ---------------------------------------------------------------- 字体（平台代劳）

/// 系统 emoji 字体：平台字体本就带系统回退，恒成功。
pub fn fontLoadSystem() bool {
    return true;
}

/// 不做字体解析（见文件头）。
pub fn fontLoadFile(_: []const u8) bool {
    return false;
}

/// 不做字体解析（见文件头）。
pub fn fontLoadMemory(_: []const u8) bool {
    return false;
}

/// 平台能画就交给它画：拿不到逐字形覆盖信息，恒 true。
pub fn supported(_: []const u8) bool {
    return true;
}

/// 在一个矩形里居中画一个 emoji（字号按矩形高）。
pub fn drawEmoji(ui: *core.Context, text: []const u8, r: t.Rect) void {
    if (text.len == 0 or r.w <= 0 or r.h <= 0) return;
    const size = r.h;
    // emoji 字体的前移宽约 1.28em（比正文宽）；量不到就不量，直接居中摆
    const adv = size * 1.28;
    ui.addEmojiText(.{
        .x = r.x + (r.w - adv) * 0.5,
        .y = r.y + (r.h - size * 1.35) * 0.5,
        .w = adv + 2,
        .h = size * 1.4,
    }, text, size, theme.text);
}

/// 一个 emoji 组件（占 `size` 见方）。
pub fn emoji(ui: *core.Context, text: []const u8, size: f32) void {
    const box = ui.reserve(size, size, false);
    drawEmoji(ui, text, box);
}

// ---------------------------------------------------------------- 肤色

/// 给一个「可调肤色」的 emoji 加上 U+1F3FB+tone-1（单码位基字符；复合序列不调）。
/// 返回写进 `buf` 的切片，或原串。
pub fn toned(entry: Entry, tone: u8, buf: []u8) []const u8 {
    if (!entry.tonable or tone == 0 or tone >= TONE_COUNT) return entry.text;
    // 取第一个码位（emoji 的基字符都是 4 字节或 3 字节 UTF-8）
    const n: usize = if (entry.text.len >= 4 and entry.text[0] >= 0xF0) 4 else 3;
    if (entry.text.len < n or buf.len < n + 4) return entry.text;
    @memcpy(buf[0..n], entry.text[0..n]);
    const cp: u21 = @intCast(@as(u32, 0x1F3FB) + tone - 1);
    var tmp: [4]u8 = undefined;
    const k = std.unicode.utf8Encode(cp, &tmp) catch return entry.text;
    @memcpy(buf[n .. n + k], tmp[0..k]);
    return buf[0 .. n + k];
}

/// 写进 `buf`（长度 8）并返回切片：没有肤色就是目录里的常量串。
fn tonedTo(entry: Entry, tone: u8, buf: *[8]u8) []const u8 {
    if (!entry.tonable or tone == 0 or tone >= TONE_COUNT) return entry.text;
    const n: usize = if (entry.text.len >= 4 and entry.text[0] >= 0xF0) 4 else 3;
    if (entry.text.len < n) return entry.text;
    @memcpy(buf[0..n], entry.text[0..n]);
    const cp: u21 = @intCast(@as(u32, 0x1F3FB) + tone - 1);
    var tmp: [4]u8 = undefined;
    const k = std.unicode.utf8Encode(cp, &tmp) catch return entry.text;
    @memcpy(buf[n .. n + k], tmp[0..k]);
    return buf[0 .. n + k];
}

// ---------------------------------------------------------------- 选择器

pub const MAX_FILTER = 160;
pub const MAX_RECENT = 16;

pub const PickerOpts = struct {
    width: f32 = 360,
    /// 网格视口高。
    height: f32 = 280,
    /// 单个 emoji 的字号。
    size: f32 = 26,
    /// 最近使用（空格分隔、最新的在前）；控件会把选中的写回（`recent_cap` 是容量）。
    recent: []u8 = &.{},
    recent_len: ?*usize = null,
    /// 肤色 0..5（调用方持有）。
    tone: ?*u8 = null,
    placeholder: []const u8 = "Search emoji",
    empty_text: []const u8 = "No emoji found",
    hint: []const u8 = "Pick an emoji",
    search: bool = true,
    preview: bool = true,
    tone_button: bool = true,
};

pub const State = struct {
    query: [32]u8 = @splat(0),
    query_len: usize = 0,
    caret: usize = 0,
    tab: u8 = 0, // 0 = 最近，1..9 = 分组
    sel: i32 = -1,
    scroll: f32 = 0,
    /// 过滤后的目录下标（每次输入/页签变化重算）
    filter: [MAX_FILTER]u8 = @splat(0),
    filter_n: usize = 0,
    key: u64 = 1,
    key_valid: bool = false,
    hover: i32 = -1,
    /// 回调出去的 emoji（带肤色时写在这里，保证返回的切片下一帧仍有效）
    out_buf: [8]u8 = @splat(0),
};

fn filterKey(st: *const State, tab: u8) u64 {
    var h: u64 = 0xCBF29CE484222325;
    for (st.query[0..st.query_len]) |c| {
        h = (h ^ (c | 0x20)) *% 0x100000001B3;
    }
    return (h ^ @as(u64, tab)) *% 0x100000001B3;
}

/// 子串匹配（ASCII 大小写不敏感）。
fn nameMatch(name: []const u8, q: []const u8) bool {
    if (q.len == 0) return true;
    if (q.len > name.len) return false;
    var i: usize = 0;
    while (i + q.len <= name.len) : (i += 1) {
        var k: usize = 0;
        while (k < q.len) : (k += 1) {
            const a = name[i + k] | 0x20;
            const b = q[k] | 0x20;
            if (a != b) break;
        }
        if (k == q.len) return true;
    }
    return false;
}

fn rebuild(st: *State) void {
    st.filter_n = 0;
    const searching = st.query_len > 0;
    for (catalog, 0..) |e, i| {
        if (st.filter_n >= MAX_FILTER) break;
        if (searching) {
            if (!nameMatch(e.name, st.query[0..st.query_len])) continue;
        } else if (st.tab != 0) {
            if (@backingInt(e.group) != st.tab - 1) continue;
        }
        st.filter[st.filter_n] = @intCast(i);
        st.filter_n += 1;
    }
    const n: i32 = @intCast(st.filter_n);
    if (st.sel >= n) st.sel = if (n > 0) n - 1 else -1;
}

fn recentList(opts: PickerOpts) []const u8 {
    if (opts.recent_len) |p| return opts.recent[0..@min(p.*, opts.recent.len)];
    return &.{};
}

fn pushRecent(opts: PickerOpts, src: []const u8) void {
    const cap = opts.recent.len;
    if (cap == 0 or src.len == 0) return;
    // 新的放最前，重复的剔掉，最多 MAX_RECENT 项
    var tmp: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(tmp[0..src.len], src);
    n += src.len;
    var count: usize = 1;
    var it = std.mem.splitScalar(u8, recentList(opts), ' ');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        if (count >= MAX_RECENT) break;
        if (std.mem.eql(u8, item, src)) continue;
        if (n + 1 + item.len > tmp.len) break;
        tmp[n] = ' ';
        n += 1;
        @memcpy(tmp[n .. n + item.len], item);
        n += item.len;
        count += 1;
    }
    const copy = @min(n, cap);
    @memcpy(opts.recent[0..copy], tmp[0..copy]);
    if (opts.recent_len) |p| p.* = copy;
}

/// emoji 选择器。返回本帧选中的 emoji（UTF-8，指向内置目录或内部缓冲，下一帧仍有效），否则 null。
pub fn picker(ui: *core.Context, id: []const u8, st: *State, opts: PickerOpts) ?[]const u8 {
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 360;
    const header_h: f32 = if (opts.search) 34 else 0;
    const tabs_h: f32 = 30;
    const preview_h: f32 = if (opts.preview) 30 else 0;
    const h = header_h + tabs_h + opts.height + preview_h + 12;
    const rect = ui.reserve(w, h, false);
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 10, .border = theme.border });

    var y = rect.y + 8;
    const inner_x = rect.x + 10;
    const inner_w = rect.w - 20;

    // ---- 搜索框 + 肤色按钮
    if (opts.search) {
        const tone_w: f32 = if (opts.tone_button and opts.tone != null) 34.0 else 0.0;
        const field_w = inner_w - tone_w - (if (tone_w > 0) @as(f32, 6) else @as(f32, 0));
        const id_s = core.Context.idOf(id) ^ 0x5EA2;
        const changed = textField(ui, id_s, .{ .x = inner_x, .y = y, .w = field_w, .h = 28 }, st, opts.placeholder);
        if (changed) st.key_valid = false;
        if (tone_w > 0) {
            const tone = opts.tone.?;
            const btn = t.Rect{ .x = inner_x + field_w + 6, .y = y, .w = tone_w, .h = 28 };
            const hit = ui.interact(core.Context.idOf(id) ^ 0x70E1, btn);
            ui.addBox(btn, .{
                .fill = if (hit.hover) theme.track else theme.bg,
                .radius = 6,
                .border = theme.border,
            });
            if (tone.* == 0) {
                drawEmoji(ui, "\u{270B}", .{ .x = btn.x + 4, .y = btn.y + 2, .w = 24, .h = 24 });
            } else {
                ui.addBox(.{ .x = btn.x + 8, .y = btn.y + 9, .w = 16, .h = 16 }, .{
                    .fill = tone_colors[tone.* % TONE_COUNT],
                    .radius = 8,
                    .border = theme.border,
                });
            }
            if (hit.clicked) {
                tone.* = @intCast((tone.* + 1) % TONE_COUNT);
                ui.requestFrame();
            }
        }
        y += 34;
    }

    // ---- 分组页签（0 = 最近）
    {
        const tab_w = @min(34.0, inner_w / @as(f32, GROUP_COUNT + 1));
        var k: usize = 0;
        while (k <= GROUP_COUNT) : (k += 1) {
            const tb = t.Rect{ .x = inner_x + @as(f32, @floatFromInt(k)) * tab_w, .y = y, .w = tab_w, .h = 26 };
            const hit = ui.interact(core.Context.idOf(id) ^ (0x7A00 + k), tb);
            const active = st.tab == k;
            if (active) {
                ui.addBox(.{ .x = tb.x + 2, .y = tb.y + 22, .w = tb.w - 4, .h = 2 }, .{ .fill = theme.accent });
            } else if (hit.hover) {
                ui.addBox(tb.inset(2), .{ .fill = theme.track, .radius = 5 });
            }
            const icon: []const u8 = if (k == 0) "\u{1F551}" else groupIcons[k - 1];
            drawEmoji(ui, icon, .{ .x = tb.x + 5, .y = tb.y + 1, .w = 24, .h = 24 });
            if (hit.clicked and st.tab != k) {
                st.tab = @intCast(k);
                st.sel = -1;
                st.scroll = 0;
                rebuild(st);
            }
        }
        y += tabs_h;
    }

    // ---- 网格
    if (!st.key_valid or st.key != filterKey(st, st.tab)) {
        st.key = filterKey(st, st.tab);
        st.key_valid = true;
        rebuild(st);
    }
    const grid = t.Rect{ .x = inner_x, .y = y, .w = inner_w, .h = opts.height };
    const cell = opts.size + 14;
    const cols: usize = @max(1, @as(usize, @intFromFloat(@max(1, inner_w / cell))));
    const rows = if (st.filter_n == 0) 0 else (st.filter_n + cols - 1) / cols;
    const content_h = @as(f32, @floatFromInt(rows)) * cell;
    const max_scroll = @max(0, content_h - grid.h);
    const grid_hit = ui.interactEx(core.Context.idOf(id) ^ 0x9911, grid, true);
    if (grid_hit.hover and ui.input.wheel != 0) {
        st.scroll = std.math.clamp(st.scroll - ui.input.wheel * cell * 2, 0, max_scroll);
    }
    // 键盘
    if (grid_hit.focused and st.query_len == 0) {
        const kleft = ui.input.keyPressed(.left);
        const kright = ui.input.keyPressed(.right);
        const kup = ui.input.keyPressed(.up);
        const kdown = ui.input.keyPressed(.down);
        if (kleft or kright or kup or kdown) {
            var sel = st.sel;
            if (kright) sel += 1;
            if (kleft) sel -= 1;
            if (kdown) sel += @as(i32, @intCast(cols));
            if (kup) sel -= @as(i32, @intCast(cols));
            if (sel < 0) sel = 0;
            if (sel >= @as(i32, @intCast(st.filter_n))) sel = @as(i32, @intCast(st.filter_n)) - 1;
            if (sel != st.sel and st.filter_n > 0) {
                st.sel = sel;
                // 滚进视口
                const row = @as(usize, @intCast(@divTrunc(sel, @as(i32, @intCast(cols)))));
                const top = @as(f32, @floatFromInt(row)) * cell;
                if (top < st.scroll) st.scroll = top;
                if (top + cell > st.scroll + grid.h) st.scroll = top + cell - grid.h;
                st.scroll = std.math.clamp(st.scroll, 0, max_scroll);
            }
        }
    }
    st.scroll = std.math.clamp(st.scroll, 0, max_scroll);

    const saved = ui.clip;
    ui.clip = .{ .x = grid.x, .y = grid.y, .w = grid.w, .h = grid.h };
    st.hover = -1;
    var picked: ?[]const u8 = null;
    if (st.filter_n == 0) {
        const m = ui.measureText(opts.empty_text, theme.font_small);
        ui.addText(.{
            .x = grid.x + (grid.w - m.w) * 0.5,
            .y = grid.y + grid.h * 0.5 - 8,
            .w = m.w + 2,
            .h = 16,
        }, opts.empty_text, theme.font_small, theme.secondary);
    } else {
        const first_row: usize = @intFromFloat(@max(0, @floor(st.scroll / cell)));
        const first = first_row * cols;
        const last = @min(st.filter_n, first + (cols * (@as(usize, @intFromFloat(@max(1, grid.h / cell))) + 2)));
        var i = first;
        while (i < last) : (i += 1) {
            const col = i % cols;
            const row = i / cols;
            const cr = t.Rect{
                .x = grid.x + @as(f32, @floatFromInt(col)) * cell,
                .y = grid.y + @as(f32, @floatFromInt(row)) * cell - st.scroll,
                .w = cell,
                .h = cell,
            };
            if (cr.y + cr.h < grid.y or cr.y > grid.y + grid.h) continue;
            const hit = ui.interact(core.Context.idOf(id) ^ (0x2200 + i), cr);
            const entry = catalog[st.filter[i]];
            const chosen = st.sel == @as(i32, @intCast(i));
            if (chosen or hit.hover) {
                ui.addBox(cr.inset(1), .{
                    .fill = if (chosen) theme.accent_bg else theme.track,
                    .radius = 6,
                    .border = if (chosen) theme.accent else null,
                });
            }
            const buf8: [8]u8 = undefined;
            _ = buf8;
            var tone_buf: [8]u8 = undefined;
            const tone_v: u8 = if (opts.tone) |tp| tp.* else 0;
            drawEmoji(ui, toned(entry, tone_v, tone_buf[0..]), .{ .x = cr.x + 7, .y = cr.y + 7, .w = opts.size, .h = opts.size });
            if (hit.hover) st.hover = @intCast(i);
            if (hit.clicked) {
                st.sel = @intCast(i);
                picked = tonedTo(entry, tone_v, &st.out_buf);
            }
        }
    }
    ui.clip = saved;
    // 滚动条
    if (max_scroll > 0.5) {
        const th = @max(20, grid.h * grid.h / content_h);
        ui.addBox(.{ .x = grid.x + grid.w - 3, .y = grid.y + (grid.h - th) * (st.scroll / max_scroll), .w = 3, .h = th }, .{
            .fill = theme.withAlpha(theme.secondary, 120),
            .radius = 1.5,
        });
    }
    y += opts.height;

    // ---- 预览（名字 + 大图）
    if (opts.preview) {
        const show_i: i32 = if (st.hover >= 0) st.hover else st.sel;
        var name: []const u8 = opts.hint;
        var show: []const u8 = "";
        if (show_i >= 0 and show_i < @as(i32, @intCast(st.filter_n))) {
            const entry = catalog[st.filter[@intCast(show_i)]];
            name = entry.name;
            var tone_buf: [8]u8 = undefined;
            const tone_v: u8 = if (opts.tone) |tp| tp.* else 0;
            show = toned(entry, tone_v, tone_buf[0..]);
        }
        const pr = t.Rect{ .x = inner_x, .y = y + 4, .w = inner_w, .h = 24 };
        ui.addBox(.{ .x = pr.x, .y = pr.y, .w = pr.w, .h = 1 }, .{ .fill = theme.border });
        if (show.len > 0) drawEmoji(ui, show, .{ .x = pr.x, .y = pr.y, .w = 24, .h = 24 });
        const name_x = pr.x + (if (show.len > 0) @as(f32, 28) else @as(f32, 0));
        ui.addText(.{
            .x = name_x,
            .y = pr.y + 4,
            .w = @max(8, pr.x + pr.w - name_x),
            .h = 18,
        }, name, theme.font_small, if (show.len > 0) theme.text else theme.secondary);
    }

    // 回车选中当前光标项（网格有焦点时）
    if (grid_hit.focused and ui.input.keyPressed(.enter) and st.sel >= 0 and
        st.sel < @as(i32, @intCast(st.filter_n)))
    {
        const entry = catalog[st.filter[@intCast(st.sel)]];
        const tone_v: u8 = if (opts.tone) |tp| tp.* else 0;
        picked = tonedTo(entry, tone_v, &st.out_buf);
    }
    if (picked) |p| {
        if (p.len > 0) {
            pushRecent(opts, p);
            ui.requestFrame();
            return p;
        }
    }
    return null;
}

/// 小型单行输入框（选择器的搜索框：只需 ASCII 子集 + 退格）。
fn textField(ui: *core.Context, id: u64, r: t.Rect, st: *State, placeholder: []const u8) bool {
    const hit = ui.interactEx(id, r, true);
    ui.addBox(r, .{
        .fill = theme.bg,
        .radius = 6,
        .border = if (hit.focused) theme.accent else theme.border,
        .border_width = if (hit.focused) 1.5 else 1,
    });
    var changed = false;
    if (hit.focused) {
        // 输入：本帧字符
        const chars = ui.input.chars[0..ui.input.chars_len];
        for (chars) |c| {
            if (c < 0x20 or c >= 0x7F) continue;
            if (st.query_len >= st.query.len) break;
            const at = @min(st.caret, st.query_len);
            var k = st.query_len;
            while (k > at) : (k -= 1) st.query[k] = st.query[k - 1];
            st.query[at] = c;
            st.query_len += 1;
            st.caret = at + 1;
            changed = true;
        }
        if (ui.input.keyPressed(.backspace) and st.caret > 0) {
            var k = st.caret - 1;
            while (k + 1 < st.query_len) : (k += 1) st.query[k] = st.query[k + 1];
            st.query_len -= 1;
            st.caret -= 1;
            changed = true;
        }
        if (ui.input.keyPressed(.left) and st.caret > 0) st.caret -= 1;
        if (ui.input.keyPressed(.right) and st.caret < st.query_len) st.caret += 1;
        if (ui.input.keyPressed(.escape)) {
            st.query_len = 0;
            st.caret = 0;
            changed = true;
        }
    }
    if (hit.clicked) st.caret = st.query_len;
    const text: []const u8 = if (st.query_len > 0) st.query[0..st.query_len] else placeholder;
    const col = if (st.query_len > 0) theme.text else theme.secondary;
    ui.addText(.{ .x = r.x + 8, .y = r.y + 6, .w = @max(8, r.w - 16), .h = 18 }, text, theme.font_body, col);
    if (hit.focused and ui.time != 0) {
        const cw = ui.measureText(st.query[0..st.caret], theme.font_body).w;
        ui.addBox(.{ .x = r.x + 8 + cw, .y = r.y + 6, .w = 1, .h = 18 }, .{ .fill = theme.accent });
    }
    return changed;
}
