//! 正则测试器（对位 CUI `cui_devpanels.c` 里的 `cui_regex_tester_ex`，属于 `cui_regex.c` 族）。
//!
//! 形态：模式输入框（错误显示在下方）+ i/m/s 三个开关 + 可编辑的样本文本（命中与每个捕获分组
//! 各自上色）+ 摘要 + 命中列表（最多 6 条，带字节区间与分组）。
//!
//! 状态全在调用方持有的 `TesterState` 里（与 `editor` / `trace` / `curves` 同口径，不用堆）：
//! 命中上限 `MAX_HITS = 16`、标记上限 `MAX_MARKS = 96`，超出时摘要显示 `16+`。
//! **只在模式 / 开关 / 文本变化时重算**（FNV-1a 签名比对），不是每帧跑正则。
//!
//! 与 CUI 的差异（有意为之）：命中上限 2000 → 16（不用堆）；`i/m/s` 三个开关用
//! `controls.chip`（它的 id 由标签哈希决定，同页放两个测试器会撞 id）；列表不换行排版（窄面板会挤）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const widgets = @import("widgets.zig");
const controls = @import("controls.zig");
const regex = @import("regex.zig");
const editor = @import("editor.zig");

/// 记录多少个命中（CUI 是 2000，我们不用堆）。
pub const MAX_HITS = 16;
/// 标记上限：每个命中 1 条（整体）+ 每个分组 1 条。
pub const MAX_MARKS = 96;
/// 列表里最多列几条。
const LISTED = 6;

pub const Hit = struct {
    start: i32 = -1,
    end: i32 = -1,
    group_start: [regex.CAP]i32 = @splat(-1),
    group_end: [regex.CAP]i32 = @splat(-1),
};

pub const TesterState = struct {
    flags: u32 = 0,
    /// 上一次结果的签名（模式 + 开关 + 文本）；`key_valid == false` 时强制重算。
    key: u64 = 0,
    key_valid: bool = false,
    /// 0 = 正常、-1 = 模式非法、-2 = 回溯过多。
    status: i32 = 0,
    error_len: usize = 0,
    err_msg: [64]u8 = @splat(0),
    count: usize = 0,
    /// 命中数超过 `MAX_HITS`。
    more: bool = false,
    groups: usize = 0,
    names: [regex.CAP][24]u8 = @splat(@splat(0)),
    hits: [MAX_HITS]Hit = @splat(.{}),
    marks: [MAX_MARKS]editor.TextMark = @splat(.{}),
    n_marks: usize = 0,
    /// 样本文本的编辑器状态（光标 / 滚动 / 查找栏）。
    text_state: editor.EditorState = .{},
};

pub const Opts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 样本文本编辑器的高度，默认 180。
    height: f32 = 180,
    /// 外部持有的开关（`regex.ICASE | MULTILINE | DOTALL`）；null = 用状态里的。
    flags: ?*u32 = null,
    placeholder: []const u8 = "Text to test the pattern on",
};

pub const Result = struct {
    valid: bool = false,
    /// 命中数（上限 `MAX_HITS`）。
    matches: u32 = 0,
    /// 命中数被上限截断（`matches` 只是「至少这么多」）。
    more: bool = false,
    err: ?[]const u8 = null,
};

/// 正则测试器。`pattern` / `text` 都由调用方持有并就地编辑。
pub fn tester(
    ui: *core.Context,
    id: []const u8,
    pattern: []u8,
    pattern_len: *usize,
    pattern_caret: *usize,
    text: []u8,
    text_len: *usize,
    st: *TesterState,
    opts: Opts,
) Result {
    var res = Result{};
    if (pattern_len.* > pattern.len) pattern_len.* = pattern.len;
    if (text_len.* > text.len) text_len.* = text.len;
    const flags = opts.flags orelse &st.flags;

    var col = ui.column(.{ .pad = 0, .gap = 8 });
    defer col.end();

    // ---- 模式输入
    _ = widgets.input(ui, id, pattern, pattern_len, pattern_caret, .{
        .placeholder = "Pattern",
        .width = opts.width,
    });

    // ---- 开关：i / m / s
    {
        var row = ui.row(.{ .gap = 6 });
        defer row.end();
        var i_on = flags.* & regex.ICASE != 0;
        var m_on = flags.* & regex.MULTILINE != 0;
        var s_on = flags.* & regex.DOTALL != 0;
        const ci = controls.chip(ui, "i", &i_on);
        const cm = controls.chip(ui, "m", &m_on);
        const cs = controls.chip(ui, "s", &s_on);
        if (ci or cm or cs) {
            flags.* = (if (i_on) regex.ICASE else 0) |
                (if (m_on) regex.MULTILINE else 0) |
                (if (s_on) regex.DOTALL else 0);
        }
    }

    // ---- 重算（只在模式 / 开关 / 文本变化时）
    run(pattern[0..pattern_len.*], flags.*, text[0..text_len.*], st);

    // ---- 样本文本：可编辑 + 命中/分组高亮（编辑器 id 与模式框区分开）
    {
        var idbuf: [160]u8 = undefined;
        const n = @min(id.len, idbuf.len - 2);
        @memcpy(idbuf[0..n], id[0..n]);
        idbuf[n] = '~';
        const ed = editor.codeEditor(ui, idbuf[0 .. n + 1], text, text_len, &st.text_state, .{
            .lang = "text",
            .width = opts.width,
            .height = if (opts.height > 0) opts.height else 180,
            .size = 12,
            .no_line_numbers = true,
            .placeholder = opts.placeholder,
            .marks = st.marks[0..st.n_marks],
        });
        // 编辑器在本帧改了文本 → 立刻重算，让下面的摘要与列表拿到新结果。
        // 高亮块是画在上面的（用的是本帧开头那份标记），因此标记恒滞后一帧：
        // 好处是标记与它当时对应的文本永远一致，不会闪出错位的色块。
        if (ed.changed) run(pattern[0..pattern_len.*], flags.*, text[0..text_len.*], st);
    }

    // ---- 摘要
    const summary = summaryText(ui, st, pattern_len.*);
    _ = ui.textRun(summary, theme.font_small, if (st.status < 0) theme.danger else theme.secondary);
    res.valid = st.status >= 0;
    res.matches = @intCast(st.count);
    res.more = st.more;
    if (st.status < 0) res.err = st.err_msg[0..st.error_len];

    // ---- 命中列表（最多 6 条）
    if (st.status >= 0 and st.count > 0) list(ui, text[0..text_len.*], st);

    return res;
}

fn summaryText(ui: *core.Context, st: *const TesterState, pattern_len: usize) []const u8 {
    if (st.status == -1) return "Invalid pattern";
    if (st.status == -2) return "Too complex to finish";
    if (pattern_len == 0) return "Type a pattern";
    if (st.count == 0) return "No match";
    var buf: [32]u8 = undefined;
    const d = num.int(buf[0..], @intCast(st.count));
    var n = d.len;
    if (st.more) {
        buf[n] = '+';
        n += 1;
    }
    const tail = if (st.count == 1 and !st.more) " match" else " matches";
    @memcpy(buf[n..][0..tail.len], tail);
    n += tail.len;
    return ui.frameStr(buf[0..n]);
}

/// 命中 / 分组的底色：整体用强调色，分组用系列色（都比文字浅一档）。
fn markColor(k: u8) t.Color {
    const base = if (k == 0) theme.accent else seriesColor(k);
    return theme.withAlpha(base, if (theme.isDark()) 96 else 72);
}

fn seriesColor(k: u8) t.Color {
    const hue: f32 = @floatFromInt((@as(u32, k) * 57) % 360);
    const light: f32 = if (theme.isDark()) 0.58 else 0.46;
    return hsl(hue / 360.0, 0.55, light);
}

fn hsl(h: f32, sat: f32, l: f32) t.Color {
    const q = if (l < 0.5) l * (1 + sat) else l + sat - l * sat;
    const p = 2 * l - q;
    return .{
        .r = @intFromFloat(@round(hue2rgb(p, q, h + 1.0 / 3.0) * 255)),
        .g = @intFromFloat(@round(hue2rgb(p, q, h) * 255)),
        .b = @intFromFloat(@round(hue2rgb(p, q, h - 1.0 / 3.0) * 255)),
        .a = 255,
    };
}

fn hue2rgb(p: f32, q: f32, tt: f32) f32 {
    var x = tt;
    if (x < 0) x += 1;
    if (x > 1) x -= 1;
    if (x < 1.0 / 6.0) return p + (q - p) * 6 * x;
    if (x < 0.5) return q;
    if (x < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - x) * 6;
    return p;
}

/// 签名：模式 + 开关 + 文本（FNV-1a 64）。
fn signature(pattern: []const u8, flags: u32, text: []const u8) u64 {
    var h: u64 = 0xCBF29CE484222325;
    for (pattern) |c| {
        h = (h ^ c) *% 0x100000001B3;
    }
    h = (h ^ (flags & 0xFF)) *% 0x100000001B3;
    for (text) |c| {
        h = (h ^ c) *% 0x100000001B3;
    }
    return h;
}

/// 重新收集全部命中与标记；签名没变就什么都不做。
fn run(pattern: []const u8, flags: u32, text: []const u8, st: *TesterState) void {
    const key = signature(pattern, flags, text);
    if (st.key_valid and st.key == key) return;
    st.key = key;
    st.key_valid = true;
    st.count = 0;
    st.more = false;
    st.groups = 0;
    st.n_marks = 0;
    st.status = 0;
    st.error_len = 0;
    if (pattern.len == 0) return;

    var from: usize = 0;
    while (from <= text.len) {
        var m = regex.Match{};
        var err: []const u8 = "";
        switch (regex.search(pattern, flags, text, from, &m, &err)) {
            .invalid_pattern => {
                st.status = -1;
                setError(st, err);
                return;
            },
            .too_slow => {
                st.status = -2;
                setError(st, err);
                return;
            },
            .none => break,
            .found => {},
        }
        if (st.count >= MAX_HITS) {
            st.more = true;
            break;
        }
        st.groups = m.groups;
        st.names = m.group_name;
        const k = st.count;
        st.hits[k] = .{
            .start = m.start,
            .end = m.end,
            .group_start = m.group_start,
            .group_end = m.group_end,
        };
        st.count += 1;
        if (st.n_marks < MAX_MARKS) {
            st.marks[st.n_marks] = .{ .start = m.start, .end = m.end, .color = 0 };
            st.n_marks += 1;
        }
        var g: usize = 1;
        while (g <= m.groups and g < regex.CAP) : (g += 1) {
            // 分组数组是 0 基：第 g 组在 g-1
            const gs = m.group_start[g - 1];
            const ge = m.group_end[g - 1];
            if (gs >= 0 and ge > gs and st.n_marks < MAX_MARKS) {
                st.marks[st.n_marks] = .{
                    .start = gs,
                    .end = ge,
                    .color = @intCast(1 + (g - 1) % 6),
                };
                st.n_marks += 1;
            }
        }
        // 空匹配也要往前走一个字符，否则原地打转
        var next: usize = if (m.end > m.start) @intCast(m.end) else @as(usize, @intCast(m.start)) + 1;
        while (next < text.len and (text[next] & 0xC0) == 0x80) next += 1;
        from = next;
    }
    sortMarks(st.marks[0..st.n_marks]);
}

fn setError(st: *TesterState, err: []const u8) void {
    const n = @min(err.len, st.err_msg.len);
    @memcpy(st.err_msg[0..n], err[0..n]);
    st.error_len = n;
}

/// 标记按起点升序（插入排序：命中本来就有序，最坏也只是分组内部小规模移动）。
fn sortMarks(marks: []editor.TextMark) void {
    var i: usize = 1;
    while (i < marks.len) : (i += 1) {
        const x = marks[i];
        var j = i;
        while (j > 0 and marks[j - 1].start > x.start) : (j -= 1) marks[j] = marks[j - 1];
        marks[j] = x;
    }
}

/// 命中列表：序号 + 匹配文本块 + 字节区间 + 每个分组的名字与文本块。
fn list(ui: *core.Context, text: []const u8, st: *const TesterState) void {
    const shown = @min(st.count, LISTED);
    var k: usize = 0;
    while (k < shown) : (k += 1) {
        const h = st.hits[k];
        var row = ui.row(.{ .gap = 6 });
        defer row.end();
        var nb: [8]u8 = undefined;
        _ = ui.textRun(ui.frameStr(num.int(nb[0..], @intCast(k + 1))), theme.font_small, theme.secondary);
        chip(ui, text, h.start, h.end, 0);
        var rb: [40]u8 = undefined;
        const d1 = num.int(rb[0..], @intCast(h.start));
        const n1 = d1.len;
        rb[n1] = '-';
        const d2 = num.int(rb[n1 + 1 ..], @intCast(h.end));
        _ = ui.textRun(ui.frameStr(rb[0 .. n1 + 1 + d2.len]), theme.font_small, theme.secondary);
        var g: usize = 1;
        while (g <= st.groups and g < regex.CAP) : (g += 1) {
            _ = ui.textRun(groupName(ui, st, g), theme.font_small, theme.secondary);
            // 分组数组是 0 基：第 g 组在 g-1
            const gs = h.group_start[g - 1];
            const ge = h.group_end[g - 1];
            if (gs >= 0 and ge > gs) {
                chip(ui, text, gs, ge, @intCast(1 + (g - 1) % 6));
            } else {
                _ = ui.textRun("-", theme.font_small, theme.secondary);
            }
        }
    }
    if (st.count > shown) {
        var buf: [40]u8 = undefined;
        const d = num.int(buf[0..], @intCast(st.count - shown));
        const n1 = d.len;
        const tail = if (st.more) "+ more" else " more";
        @memcpy(buf[n1..][0..tail.len], tail);
        _ = ui.textRun(ui.frameStr(buf[0 .. n1 + tail.len]), theme.font_small, theme.secondary);
    }
}

fn groupName(ui: *core.Context, st: *const TesterState, g: usize) []const u8 {
    // `group_name[i]` 是**第 i+1 组**的名字（1 基分组 → 0 基数组）
    const slot = if (g > 0 and g <= regex.CAP) g - 1 else 0;
    var n: usize = 0;
    while (n < st.names[slot].len and st.names[slot][n] != 0) n += 1;
    if (n > 0) return st.names[slot][0..n];
    var nb: [8]u8 = undefined;
    return ui.frameStr(num.int(nb[0..], @intCast(g)));
}

/// 一段文本画成带底色的小块：换行写成 `\n`、制表符写成空格、超过 40 字节加省略号。
fn chip(ui: *core.Context, text: []const u8, start: i32, end: i32, color: u8) void {
    var buf: [48]u8 = undefined;
    var n: usize = 0;
    var i: usize = if (start > 0) @intCast(start) else 0;
    const e: usize = if (end > 0) @min(@as(usize, @intCast(end)), text.len) else 0;
    while (i < e and n + 3 < buf.len) : (i += 1) {
        const c = text[i];
        if (c == '\n') {
            buf[n] = '\\';
            buf[n + 1] = 'n';
            n += 2;
            continue;
        }
        buf[n] = if (c == '\t') ' ' else c;
        n += 1;
        if (n >= 40) break;
    }
    while (n > 0 and (buf[n - 1] & 0xC0) == 0x80) n -= 1; // 别停在半个字符上
    if (i < e) {
        buf[n] = '.';
        buf[n + 1] = '.';
        buf[n + 2] = '.';
        n += 3;
    }
    const empty = n == 0;
    const label = ui.frameStr(if (empty) "(empty)" else buf[0..n]);
    const w = ui.measureText(label, theme.font_small).w + 10;
    const rect = ui.reserve(w, theme.font_small * 1.35 + 4, false);
    ui.addBox(rect, .{ .fill = markColor(color), .radius = 4 });
    if (empty) {
        ui.addText(.{ .x = rect.x + 5, .y = rect.y + 2, .w = w, .h = theme.font_small * 1.35 }, label, theme.font_small, theme.secondary);
    } else {
        ui.addMonoText(.{ .x = rect.x + 5, .y = rect.y + 2, .w = w, .h = theme.font_small * 1.35 }, label, theme.font_small, theme.text);
    }
}
