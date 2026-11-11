//! 代码编辑器（对位 CUI `cui_editor.c` 的 4 个 API：`code_editor_ex` / `goto` / `select` / `find`）。
//!
//! 文本由调用方持有：`buf: []u8` + `len: *usize`，组件就地编辑、**装不下就整笔拒绝**
//! （`insertBytes` 返回 false 时什么都不改）。光标/选区/滚动/查找栏这些跨帧状态放在调用方
//! 持有的 `EditorState` 里 —— 与 `curves` / `trace` / `files` 同一口径，不在 `Context` 上加字段。
//!
//! 已实现：行号槽 + 等宽网格、长行横向滚动（行号槽固定）、只画视口内的行、光标与选区、
//! 点击定位、拖选、双击选词、点行号选整行、方向键 / Home / End / PageUp / PageDown /
//! Ctrl+Home / Ctrl+End、Shift 扩展选区、Ctrl+A、输入 / 退格 / Delete（有选区先替换）、
//! Enter 保持缩进（行尾是开括号或冒号再加一级）、Tab / Shift+Tab 缩进整行、括号配对、
//! 行内语法着色、`marks` 高亮区间（供正则测试器用）、查找栏（Ctrl+F；Enter / Shift+Enter 前后跳、Esc 关闭）。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **不做撤销/重做**（CUI 有快照栈）：要撤销请调用方自己留副本；
//! - **不接系统剪贴板**（Ctrl+C/X/V 未做）：剪贴板属平台能力，等 X11/Cocoa 一起补；
//! - **Ctrl+左右按词移动**、三击选段未做；
//! - 语法着色是**逐行**的（块注释不跨行跟踪）；每行最多 `MAX_RUNS` 个色块，超出并进最后一块
//!   —— 一屏几十行 × 10 个文本节点，再多彩块就会打爆 `MAX_NODES`(256)；
//! - 网格按**字节**对齐（制表符展开成空格；CJK 等宽字符会略微错位，与 CUI 的等宽网格同口径）；
//! - 查找是**大小写不敏感的子串**匹配（CUI 同口径），不是正则。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const widgets = @import("widgets.zig");

/// 每行最多切多少个色块（含首尾）。一屏约 18 行 × 10 = 180 个文本节点。
const MAX_RUNS = 10;
/// 查找关键词上限。
pub const MAX_QUERY = 48;
/// 一行展开制表符后的缓冲上限（超出的部分不显示，不影响编辑）。
const MAX_DISP = 512;

pub const TextMark = struct {
    start: i32 = 0,
    end: i32 = 0,
    /// 0 = 强调色，1..6 = 系列色（与 CUI 的 `cui_text_mark` 同口径）。
    color: u8 = 0,
};

pub const Opts = struct {
    /// "c" / "cpp" / "js" / "ts" / "rust" / "go" / "python" / "shell" / "json" / "text"
    lang: []const u8 = "text",
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 默认 320。
    height: f32 = 320,
    size: f32 = 13,
    tab_size: u8 = 4,
    use_tabs: bool = false,
    read_only: bool = false,
    no_line_numbers: bool = false,
    placeholder: []const u8 = "",
    /// 要加深底色的区间（搜索命中、正则匹配），按 start 升序。
    marks: []const TextMark = &.{},
};

pub const Result = struct {
    changed: bool = false,
    focused: bool = false,
    /// 光标与选区另一端（字节偏移；相等 = 没有选区）。
    cursor: u32 = 0,
    anchor: u32 = 0,
    /// 光标位置（1 起；列按制表位展开）。
    line: u32 = 1,
    column: u32 = 1,
    line_count: u32 = 1,
    length: u32 = 0,
    /// 光标旁的括号与它的配对（字节偏移，-1 = 无）。
    bracket: i32 = -1,
    bracket_match: i32 = -1,
    find_matches: u32 = 0,
    /// 当前命中序号（1 起；0 = 没有）。
    find_index: u32 = 0,
};

pub const EditorState = struct {
    cursor: usize = 0,
    anchor: usize = 0,
    /// 顶部行号（纵向滚动）。
    scroll_line: usize = 0,
    /// 横向滚动（点）。
    scroll_x: f32 = 0,
    find_open: bool = false,
    find_query: [MAX_QUERY]u8 = @splat(0),
    find_len: usize = 0,
    find_caret: usize = 0,
    // ---- 下一次调用生效的定位请求（对位 goto / select）
    goto_line: u32 = 0,
    goto_col: u32 = 1,
    sel_anchor: i64 = -1,
    sel_cursor: i64 = 0,
};

/// 下一次 `codeEditor` 把光标放到第 `line` 行第 `column` 列（1 起）并滚动过去。
pub fn gotoLine(st: *EditorState, line: u32, column: u32) void {
    st.goto_line = if (line == 0) 1 else line;
    st.goto_col = if (column == 0) 1 else column;
}

/// 下一次 `codeEditor` 选中 `anchor..cursor`（字节偏移）并滚动到光标。
pub fn select(st: *EditorState, anchor: u32, cursor: u32) void {
    st.sel_anchor = @intCast(anchor);
    st.sel_cursor = @intCast(cursor);
}

/// 打开查找栏并填入关键词；`null` 关闭。
pub fn find(st: *EditorState, query: ?[]const u8) void {
    if (query) |q| {
        const n = @min(q.len, st.find_query.len);
        @memcpy(st.find_query[0..n], q[0..n]);
        st.find_len = n;
        st.find_caret = n;
        st.find_open = true;
    } else {
        st.find_open = false;
        st.find_len = 0;
        st.find_caret = 0;
    }
}

// ------------------------------------------------------------------ 文本工具

fn utf8Step(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    return @min(i + n, s.len);
}

fn prevCharStart(s: []const u8, i: usize) usize {
    var k = i;
    while (k > 0) {
        k -= 1;
        if ((s[k] & 0xC0) != 0x80) return k;
    }
    return 0;
}

/// 插入：装不下就整笔拒绝（不留半截）。
fn insertBytes(buf: []u8, len: *usize, at: usize, bytes: []const u8) bool {
    if (at > len.* or len.* + bytes.len > buf.len) return false;
    var k = len.*;
    while (k > at) : (k -= 1) buf[k - 1 + bytes.len] = buf[k - 1];
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) buf[at + i] = bytes[i];
    len.* += bytes.len;
    return true;
}

fn removeRange(buf: []u8, len: *usize, from: usize, to: usize) void {
    if (from >= to or to > len.*) return;
    const n = to - from;
    var k = from;
    while (k + n < len.*) : (k += 1) buf[k] = buf[k + n];
    len.* -= n;
}

fn lineEndAt(s: []const u8, start: usize) usize {
    if (start >= s.len) return s.len;
    if (std.mem.indexOfScalar(u8, s[start..], '\n')) |p| return start + p;
    return s.len;
}

fn lineStartAt(s: []const u8, line_no: usize) usize {
    var line: usize = 0;
    var i: usize = 0;
    while (line < line_no) : (line += 1) {
        if (i >= s.len) return s.len;
        if (std.mem.indexOfScalar(u8, s[i..], '\n')) |p| i += p + 1 else return s.len;
    }
    return i;
}

fn countLines(s: []const u8, upto: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    const end = @min(upto, s.len);
    while (i < end) : (i += 1) {
        if (s[i] == '\n') n += 1;
    }
    return n;
}

const Scan = struct {
    lines: usize = 1,
    caret_line: usize = 0,
    caret_col: usize = 0,
};

/// 一次扫描拿齐：总行数 + 光标的行列（列按制表位展开，0 起）。
fn scan(s: []const u8, cursor: usize, tab_size: u8) Scan {
    var out = Scan{};
    var line: usize = 0;
    var col: usize = 0;
    var i: usize = 0;
    var found = false;
    const ts: usize = if (tab_size > 0) tab_size else 4;
    while (i <= s.len) {
        if (!found and i >= cursor) {
            out.caret_line = line;
            out.caret_col = col;
            found = true;
        }
        if (i == s.len) break;
        const c = s[i];
        if (c == '\n') {
            line += 1;
            col = 0;
        } else if (c == '\t') {
            col += ts - (col % ts);
        } else if ((c & 0xC0) != 0x80) {
            col += 1;
        }
        i += 1;
    }
    if (!found) {
        out.caret_line = line;
        out.caret_col = col;
    }
    out.lines = line + 1;
    return out;
}

/// 第 `line` 行第 `col` 列（1 起）→ 字节偏移。
fn offsetOfLineCol(s: []const u8, line: u32, col: u32, tab_size: u8) usize {
    var off = lineStartAt(s, if (line > 0) line - 1 else 0);
    const ts: usize = if (tab_size > 0) tab_size else 4;
    var cur: usize = 1;
    const want: usize = if (col > 0) col else 1;
    while (off < s.len and s[off] != '\n' and cur < want) {
        if (s[off] == '\t') {
            const before = cur - 1;
            cur += ts - (before % ts);
        } else {
            cur += 1;
        }
        off = utf8Step(s, off);
    }
    return off;
}

fn firstNonSpace(s: []const u8, start: usize, end: usize) usize {
    var i = start;
    while (i < end and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return if (i < end) i else start;
}

fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn wordBounds(s: []const u8, at: usize) struct { start: usize, end: usize } {
    var a = @min(at, s.len);
    var b = @min(at, s.len);
    while (a > 0 and isWordByte(s[a - 1])) a -= 1;
    while (b < s.len and isWordByte(s[b])) b += 1;
    if (a == b and b < s.len) b = utf8Step(s, b);
    return .{ .start = a, .end = b };
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn matchesAt(hay: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > hay.len) return false;
    var i: usize = 0;
    while (i < needle.len) : (i += 1) {
        if (toLower(hay[at + i]) != toLower(needle[i])) return false;
    }
    return true;
}

// ------------------------------------------------------------------ 着色

const Lang = enum { c_like, python, shell, json, plain };

fn langOf(name: []const u8) Lang {
    if (std.mem.eql(u8, name, "python") or std.mem.eql(u8, name, "py")) return .python;
    if (std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "bash")) return .shell;
    if (std.mem.eql(u8, name, "json")) return .json;
    if (name.len == 0 or std.mem.eql(u8, name, "text")) return .plain;
    return .c_like;
}

/// C 系关键字（c/cpp/js/ts/rust/go/zig 共用一份，体积优先；多认几个不碍事）。
const kw_c =
    "auto break case catch char class const constexpr continue default do double else enum " ++
    "export extern false float fn for func function go goto if impl import in int interface let " ++
    "long match mod mut namespace new nil null nullptr package private protected pub public ref " ++
    "return self short signed sizeof static struct switch template this throw trait true try " ++
    "type typedef typename union unsafe unsigned use using var virtual void volatile where while";
const kw_python =
    "and as assert async await break class continue def del elif else except False finally for from " ++
    "global if import in is lambda None nonlocal not or pass raise return True try while with yield";
const kw_shell =
    "case do done elif else esac fi for function if in local return select then until while";

fn inWords(list: []const u8, w: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |k| {
        if (std.mem.eql(u8, k, w)) return true;
    }
    return false;
}

fn isKeyword(lang: Lang, w: []const u8) bool {
    return switch (lang) {
        .c_like => inWords(kw_c, w),
        .python => inWords(kw_python, w),
        .shell => inWords(kw_shell, w),
        else => false,
    };
}

/// 色块：`kind` 0 = 默认、1 = 关键字、2 = 字符串、3 = 数字、4 = 注释。
const Run = struct { start: usize, end: usize, kind: u8 };

fn pushRun(out: *[MAX_RUNS]Run, n: *usize, start: usize, end: usize, kind: u8) void {
    if (end <= start) return;
    if (n.* > 0 and out[n.* - 1].kind == kind and out[n.* - 1].end == start) {
        out[n.* - 1].end = end;
        return;
    }
    if (n.* >= MAX_RUNS) {
        // 到上限：并进最后一块（颜色以最后一块为准，覆盖到行尾）
        out[MAX_RUNS - 1].end = end;
        return;
    }
    out[n.*] = .{ .start = start, .end = end, .kind = kind };
    n.* += 1;
}

fn tokenize(lang: Lang, line: []const u8, out: *[MAX_RUNS]Run) usize {
    var n: usize = 0;
    var i: usize = 0;
    // 纯文本：整行一个 run，不认关键字/字符串/数字（正则测试器这类“任意文本”场景）
    if (lang == .plain) {
        if (line.len == 0) return 0;
        out[0] = .{ .start = 0, .end = line.len, .kind = 0 };
        return 1;
    }
    const lc: []const u8 = switch (lang) {
        .python, .shell => "#",
        .json => "",
        else => "//",
    };
    while (i < line.len) {
        const c = line[i];
        if (lc.len > 0 and std.mem.startsWith(u8, line[i..], lc)) {
            pushRun(out, &n, i, line.len, 4);
            break;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '*' and lang != .python and lang != .shell) {
            const close = std.mem.indexOfPos(u8, line, i + 2, "*/");
            const end = if (close) |p| p + 2 else line.len;
            pushRun(out, &n, i, end, 4);
            i = end;
            continue;
        }
        if (c == '"' or c == '\'' or (c == '`' and lang == .c_like)) {
            var j = i + 1;
            while (j < line.len) {
                if (line[j] == '\\' and j + 1 < line.len) {
                    j += 2;
                    continue;
                }
                if (line[j] == c) {
                    j += 1;
                    break;
                }
                j += 1;
            }
            pushRun(out, &n, i, j, 2);
            i = j;
            continue;
        }
        if (c >= '0' and c <= '9') {
            var j = i;
            const hex = c == '0' and i + 1 < line.len and (line[i + 1] == 'x' or line[i + 1] == 'X');
            while (j < line.len) : (j += 1) {
                const d = line[j];
                const ok = (d >= '0' and d <= '9') or (d >= 'a' and d <= 'f') or (d >= 'A' and d <= 'F') or
                    d == '.' or d == '_' or (hex and (d == 'x' or d == 'X'));
                if (!ok) break;
            }
            pushRun(out, &n, i, j, 3);
            i = j;
            continue;
        }
        if (isWordByte(c)) {
            var j = i;
            while (j < line.len and isWordByte(line[j])) j += 1;
            pushRun(out, &n, i, j, if (isKeyword(lang, line[i..j])) @as(u8, 1) else 0);
            i = j;
            continue;
        }
        pushRun(out, &n, i, i + 1, 0);
        i += 1;
    }
    return n;
}

fn runColor(kind: u8) t.Color {
    return switch (kind) {
        1 => theme.accent,
        2 => if (theme.isDark()) theme.success else t.Color.hex(0x116329, 255),
        3 => if (theme.isDark()) theme.warn else t.Color.hex(0x953800, 255),
        4 => theme.secondary,
        else => theme.text,
    };
}

/// 单行语法着色（只读视图复用，如 `devviews.blame`）：把一行切成色块后逐段画出来。
/// 与 `codeEditor` 同口径（逐行、块注释不跨行），`lang_name` 取 `Opts.lang` 的写法。
pub fn highlightLine(ui: *core.Context, lang_name: []const u8, s: []const u8, x: f32, y: f32, size: f32, max_w: f32) void {
    if (s.len == 0 or max_w <= 2) return;
    var runs: [MAX_RUNS]Run = @splat(.{ .start = 0, .end = 0, .kind = 0 });
    const n = tokenize(langOf(lang_name), s, &runs);
    if (n == 0) return;
    const limit = x + max_w;
    var cx = x;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = runs[i];
        const end = @min(r.end, s.len);
        if (end <= r.start) continue;
        const piece = s[r.start..end];
        const w = ui.measureText(piece, size).w;
        if (cx >= limit) break;
        ui.addMonoText(.{ .x = cx, .y = y, .w = @min(w + 1, limit - cx), .h = size * 1.5 }, piece, size, runColor(r.kind));
        cx += w;
    }
}

fn expandTabs(line: []const u8, tab_size: u8, out: []u8) []const u8 {    const ts: usize = if (tab_size > 0) tab_size else 4;
    var n: usize = 0;
    for (line) |c| {
        if (n >= out.len) break;
        if (c == '\t') {
            const spaces = ts - (n % ts);
            var k: usize = 0;
            while (k < spaces and n < out.len) : (k += 1) {
                out[n] = ' ';
                n += 1;
            }
        } else {
            out[n] = c;
            n += 1;
        }
    }
    return out[0..n];
}

fn intersect(a: ?t.Rect, b: t.Rect) ?t.Rect {
    if (a) |ra| {
        const x0 = @max(ra.x, b.x);
        const y0 = @max(ra.y, b.y);
        const x1 = @min(ra.x + ra.w, b.x + b.w);
        const y1 = @min(ra.y + ra.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
    return b;
}

// ------------------------------------------------------------------ 括号配对

fn isBracket(c: u8) bool {
    return c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}';
}

const Bracket = struct { a: i32 = -1, b: i32 = -1 };

fn bracketMatch(s: []const u8, cursor: usize) Bracket {
    if (s.len == 0) return .{};
    var at: ?usize = null;
    if (cursor < s.len and isBracket(s[cursor])) {
        at = cursor;
    } else if (cursor > 0 and isBracket(s[cursor - 1])) {
        at = cursor - 1;
    }
    const i = at orelse return .{};
    const c = s[i];
    const open = c == '(' or c == '[' or c == '{';
    const pair: u8 = switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        ')' => '(',
        ']' => '[',
        else => '{',
    };
    var depth: i32 = 0;
    var steps: usize = 0;
    if (open) {
        var j = i;
        while (j < s.len and steps < 8000) : (steps += 1) {
            if (s[j] == c) depth += 1;
            if (s[j] == pair) {
                depth -= 1;
                if (depth == 0) return .{ .a = @intCast(i), .b = @intCast(j) };
            }
            j += 1;
        }
    } else {
        var j = i;
        while (j > 0 and steps < 8000) : (steps += 1) {
            j -= 1;
            if (s[j] == c) depth += 1;
            if (s[j] == pair) {
                depth -= 1;
                if (depth == 0) return .{ .a = @intCast(i), .b = @intCast(j) };
            }
        }
    }
    return .{ .a = @intCast(i), .b = -1 };
}

// ------------------------------------------------------------------ 查找

const FindMatches = struct { count: usize = 0, index: usize = 0 };

fn countMatches(s: []const u8, q: []const u8, cursor: usize) FindMatches {
    var m = FindMatches{};
    if (q.len == 0) return m;
    var i: usize = 0;
    while (i + q.len <= s.len) {
        if (!matchesAt(s, i, q)) {
            i += 1;
            continue;
        }
        m.count += 1;
        if (m.index == 0 and i >= cursor) m.index = m.count;
        i += q.len;
    }
    if (m.index == 0 and m.count > 0) m.index = m.count; // 光标之后没有 → 回绕
    return m;
}

/// 从 `from` 起第一个命中；到尾部没有则回绕到开头。
fn nextMatch(s: []const u8, q: []const u8, from: usize) ?usize {
    if (q.len == 0) return null;
    var i = @min(from, s.len);
    while (i + q.len <= s.len) : (i += 1) {
        if (matchesAt(s, i, q)) return i;
    }
    i = 0;
    while (i < @min(from, s.len)) : (i += 1) {
        if (matchesAt(s, i, q)) return i;
    }
    return null;
}

/// `from` 之前最后一个命中；没有则回绕到最后一个。
fn prevMatch(s: []const u8, q: []const u8, from: usize) ?usize {
    if (q.len == 0) return null;
    var best: ?usize = null;
    var i: usize = 0;
    while (i + q.len <= s.len) {
        if (matchesAt(s, i, q)) {
            if (i + q.len <= from) best = i else break;
            i += q.len;
        } else {
            i += 1;
        }
    }
    if (best) |b| return b;
    i = 0;
    while (i + q.len <= s.len) : (i += 1) {
        if (matchesAt(s, i, q)) best = i;
    }
    return best;
}

// ------------------------------------------------------------------ 键盘

fn moveCaret(s: []const u8, st: *EditorState, to: usize, extend: bool) void {
    st.cursor = @min(to, s.len);
    if (!extend) st.anchor = st.cursor;
}

/// 行首缩进占的字节数（一个制表符或最多 tab_size 个空格）。
fn indentWidth(s: []const u8, line_start: usize, tab_size: u8) usize {
    if (line_start >= s.len) return 0;
    if (s[line_start] == '\t') return 1;
    const max: usize = if (tab_size > 0) tab_size else 4;
    var n: usize = 0;
    while (n < max and line_start + n < s.len and s[line_start + n] == ' ') n += 1;
    return n;
}

/// 导航键（不改文本）。返回 true 表示 Tab/Shift+Tab 改了文本（缩进）。
fn navKeys(ui: *core.Context, buf: []u8, len: *usize, st: *EditorState, sc: Scan, rows: usize, opts: Opts) bool {
    var s = buf[0..len.*];
    const shift = ui.input.mods.shift;
    const ctrl = ui.input.mods.ctrl;
    const cur = st.cursor;
    const has_sel = st.anchor != st.cursor;

    if (ctrl and ui.input.keyPressed(.A)) {
        st.anchor = 0;
        st.cursor = len.*;
        return false;
    }
    if (ui.input.keyPressed(.left)) {
        if (has_sel and !shift) {
            moveCaret(s, st, @min(st.anchor, cur), false);
        } else if (cur > 0) {
            moveCaret(s, st, prevCharStart(s, cur), shift);
        }
    }
    if (ui.input.keyPressed(.right)) {
        if (has_sel and !shift) {
            moveCaret(s, st, @max(st.anchor, cur), false);
        } else if (cur < len.*) {
            moveCaret(s, st, utf8Step(s, cur), shift);
        }
    }
    if (ui.input.keyPressed(.up) and sc.caret_line > 0) {
        moveCaret(s, st, offsetOfLineCol(s, @intCast(sc.caret_line), @intCast(sc.caret_col + 1), opts.tab_size), shift);
    }
    if (ui.input.keyPressed(.down) and sc.caret_line + 1 < sc.lines) {
        moveCaret(s, st, offsetOfLineCol(s, @intCast(sc.caret_line + 2), @intCast(sc.caret_col + 1), opts.tab_size), shift);
    }
    if (ui.input.keyPressed(.page_up)) {
        const target = if (sc.caret_line > rows - 1) sc.caret_line - (rows - 1) else 0;
        moveCaret(s, st, offsetOfLineCol(s, @intCast(target + 1), @intCast(sc.caret_col + 1), opts.tab_size), shift);
    }
    if (ui.input.keyPressed(.page_down)) {
        const target = @min(sc.caret_line + rows - 1, sc.lines - 1);
        moveCaret(s, st, offsetOfLineCol(s, @intCast(target + 1), @intCast(sc.caret_col + 1), opts.tab_size), shift);
    }
    if (ui.input.keyPressed(.home)) {
        if (ctrl) {
            moveCaret(s, st, 0, shift);
        } else {
            const ls = lineStartAt(s, sc.caret_line);
            const le = lineEndAt(s, ls);
            const fnsp = firstNonSpace(s, ls, le);
            moveCaret(s, st, if (cur != fnsp) fnsp else ls, shift);
        }
    }
    if (ui.input.keyPressed(.end)) {
        if (ctrl) {
            moveCaret(s, st, len.*, shift);
        } else {
            moveCaret(s, st, lineEndAt(s, lineStartAt(s, sc.caret_line)), shift);
        }
    }

    // Tab：有选区就缩进整段，否则插入一级缩进；Shift+Tab 反缩进
    if (ui.input.keyPressed(.tab) and !opts.read_only) {
        const n_spaces: usize = if (opts.use_tabs) 1 else (if (opts.tab_size > 0) opts.tab_size else 4);
        const unit = if (opts.use_tabs) @as([]const u8, "\t") else "        ";
        if (has_sel or shift) {
            const first_line = countLines(s, @min(st.anchor, st.cursor));
            const last_sel = @max(st.anchor, st.cursor);
            var last_line = countLines(s, last_sel);
            // 选区恰好结束在行首（如 Ctrl+A 选中 "a\nb\n"）：那一行不绠进去
            if (last_sel > 0 and s[last_sel - 1] == '\n' and last_line > first_line) last_line -= 1;
            var changed = false;
            if (shift) {
                var ln = last_line + 1;
                while (ln > first_line) {
                    ln -= 1;
                    s = buf[0..len.*];
                    const ls = lineStartAt(s, ln);
                    const w = indentWidth(s, ls, opts.tab_size);
                    if (w > 0) {
                        removeRange(buf, len, ls, ls + w);
                        changed = true;
                    }
                }
            } else {
                var ln = first_line;
                while (ln <= last_line) : (ln += 1) {
                    s = buf[0..len.*];
                    const ls = lineStartAt(s, ln);
                    if (insertBytes(buf, len, ls, unit[0..n_spaces])) changed = true;
                }
            }
            if (changed) {
                s = buf[0..len.*];
                const total = countLines(s, len.*);
                st.anchor = lineStartAt(s, @min(first_line, total));
                st.cursor = @min(lineEndAt(s, lineStartAt(s, @min(last_line, total))), len.*);
            }
            return changed;
        }
        if (insertBytes(buf, len, st.cursor, unit[0..n_spaces])) {
            st.cursor += n_spaces;
            st.anchor = st.cursor;
            return true;
        }
    }
    return false;
}

/// 编辑键（字符 / 退格 / Delete / Enter）。有选区时先整段替换。
fn editKeys(ui: *core.Context, buf: []u8, len: *usize, st: *EditorState, opts: Opts) bool {
    if (opts.read_only) return false;
    var changed = false;
    var s = buf[0..len.*];

    if (st.anchor != st.cursor) {
        const a = @min(st.anchor, st.cursor);
        const b = @max(st.anchor, st.cursor);
        const typing = ui.input.charsSlice().len > 0;
        if (typing or ui.input.keyPressed(.backspace) or ui.input.keyPressed(.delete) or ui.input.keyPressed(.enter)) {
            removeRange(buf, len, a, b);
            st.cursor = a;
            st.anchor = a;
            s = buf[0..len.*];
            changed = true;
        }
    }

    if (ui.input.keyPressed(.backspace) and st.cursor > 0) {
        const prev = prevCharStart(s, st.cursor);
        removeRange(buf, len, prev, st.cursor);
        st.cursor = prev;
        st.anchor = prev;
        changed = true;
    }
    if (ui.input.keyPressed(.delete) and st.cursor < len.*) {
        removeRange(buf, len, st.cursor, utf8Step(s, st.cursor));
        changed = true;
    }
    if (ui.input.keyPressed(.enter)) {
        // 保持缩进；行尾是开括号或冒号再深一级
        const ls = lineStartAt(s, countLines(s, st.cursor)); // ← 行号，不是偏移
        const le = lineEndAt(s, ls);
        var ind_end = ls;
        while (ind_end < le and (s[ind_end] == ' ' or s[ind_end] == '\t')) ind_end += 1;
        const prefix = s[ls..@min(ind_end, st.cursor)];
        var probe = st.cursor;
        while (probe > ls and (s[probe - 1] == ' ' or s[probe - 1] == '\t')) probe -= 1;
        const deeper = probe > ls and (s[probe - 1] == '{' or s[probe - 1] == '(' or s[probe - 1] == '[' or s[probe - 1] == ':');
        const level: usize = if (opts.use_tabs) 1 else (if (opts.tab_size > 0) opts.tab_size else 4);
        var tmp: [300]u8 = undefined;
        var n: usize = 0;
        tmp[0] = '\n';
        n = 1;
        const take = @min(prefix.len, tmp.len - n - level - 1);
        @memcpy(tmp[n..][0..take], prefix[0..take]);
        n += take;
        if (deeper) {
            if (opts.use_tabs) {
                tmp[n] = '\t';
                n += 1;
            } else {
                var k: usize = 0;
                while (k < level and n < tmp.len) : (k += 1) {
                    tmp[n] = ' ';
                    n += 1;
                }
            }
        }
        if (insertBytes(buf, len, st.cursor, tmp[0..n])) {
            st.cursor += n;
            st.anchor = st.cursor;
            changed = true;
        }
    }
    const chars = ui.input.charsSlice();
    if (chars.len > 0) {
        if (insertBytes(buf, len, st.cursor, chars)) {
            st.cursor += chars.len;
            st.anchor = st.cursor;
            changed = true;
        }
    }
    return changed;
}

// ------------------------------------------------------------------ 主组件

pub fn codeEditor(
    ui: *core.Context,
    id: []const u8,
    buf: []u8,
    len: *usize,
    st: *EditorState,
    opts: Opts,
) Result {
    var res = Result{};
    if (len.* > buf.len) len.* = buf.len;
    var s = buf[0..len.*];

    // ---- 上一次调用挂起的定位请求（对位 goto / select）
    if (st.goto_line > 0) {
        st.cursor = offsetOfLineCol(s, st.goto_line, st.goto_col, opts.tab_size);
        st.anchor = st.cursor;
        st.goto_line = 0;
    }
    if (st.sel_anchor >= 0) {
        st.anchor = @min(@as(usize, @intCast(st.sel_anchor)), len.*);
        st.cursor = @min(@as(usize, @intCast(st.sel_cursor)), len.*);
        st.sel_anchor = -1;
    }
    if (st.cursor > len.*) st.cursor = len.*;
    if (st.anchor > len.*) st.anchor = len.*;

    const size = if (opts.size > 0) opts.size else 13;
    // 等宽网格：用一串等宽字符实测再平均（与 codeview 同口径）。
    // 不能用 `size * 0.6` 这种估算 —— 每个色块的 x 都按「列 × 字宽」算，
    // 字宽比真实字形宽一点点，token 之间就会裂开（实测 13px 时 0.6em 偏宽 9%）。
    const probe = "00000000";
    const cw = blk: {
        const mw = ui.measureText(probe, size).w / @as(f32, @floatFromInt(probe.len));
        break :blk if (mw > 0) mw else size * 0.55;
    };
    const lh = @round(size * 1.5);
    const pad: f32 = 6;
    const total_h = if (opts.height > 0) opts.height else 320;
    const pid = core.Context.idOf(id);

    // ---- 查找栏（在编辑区上方占一行；用现成的单行输入）
    var find_focused = false;
    if (st.find_open) {
        const find_id = pid ^ 0x7FEB352D; // 与 widgets.input 内部同一口径
        var qlen = st.find_len;
        var qcaret = st.find_caret;
        _ = widgets.input(ui, id, st.find_query[0..], &qlen, &qcaret, .{ .placeholder = "Find in file", .width = opts.width });
        st.find_len = @min(qlen, st.find_query.len);
        st.find_caret = @min(qcaret, st.find_len);
        find_focused = ui.focus_id == find_id;
        if (ui.input.keyPressed(.escape)) {
            st.find_open = false;
            st.find_len = 0;
            find_focused = false;
        }
    }

    // ---- 编辑区
    const rect = ui.reserve(opts.width, total_h, opts.width <= 0);
    const it = ui.interactEx(pid, rect, true);
    res.focused = it.focused or find_focused;

    var sc = scan(s, st.cursor, opts.tab_size);
    res.length = @intCast(len.*);
    res.line_count = @intCast(sc.lines);

    var gutter_w: f32 = 0;
    if (!opts.no_line_numbers) {
        var nb: [12]u8 = undefined;
        const digits = num.int(nb[0..], @intCast(sc.lines)).len;
        gutter_w = cw * @as(f32, @floatFromInt(digits)) + 14;
    }
    const body = t.Rect{ .x = rect.x + gutter_w, .y = rect.y, .w = @max(1, rect.w - gutter_w), .h = rect.h };
    const rows: usize = @intFromFloat(@max(1, @floor((rect.h - pad) / lh)));
    const view_w = @max(1, body.w - pad * 2);

    // ---- 输入
    var changed = false;
    const cursor_before = st.cursor;
    if (!find_focused) {
        if (it.focused) {
            if (st.find_open) {
                if (ui.input.keyPressed(.F) and ui.input.mods.ctrl) {
                    st.find_open = false;
                } else if (ui.input.keyPressed(.enter)) {
                    const q = st.find_query[0..st.find_len];
                    const at = if (ui.input.mods.shift) prevMatch(s, q, st.cursor) else nextMatch(s, q, st.cursor + 1);
                    if (at) |p| {
                        st.anchor = p;
                        st.cursor = p + q.len;
                    }
                }
            } else if (ui.input.keyPressed(.F) and ui.input.mods.ctrl) {
                st.find_open = true;
                st.find_len = 0;
                st.find_caret = 0;
            } else {
                changed = navKeys(ui, buf, len, st, sc, rows, opts);
                if (editKeys(ui, buf, len, st, opts)) changed = true;
                s = buf[0..len.*];
            }
        }
        // 鼠标：按下定位 / 拖选 / 双击选词 / 点行号选行
        if (it.hover and ui.input.pressed) {
            const mx = ui.input.mouse.x;
            const my = ui.input.mouse.y;
            if (mx < body.x and !opts.no_line_numbers) {
                const row: usize = @intFromFloat(@max(0, @floor((my - rect.y - pad * 0.5) / lh)));
                const ln = @min(st.scroll_line + row, sc.lines - 1);
                const a = lineStartAt(s, ln);
                const b = lineEndAt(s, a);
                st.anchor = a;
                st.cursor = if (b < len.*) b + 1 else b;
            } else {
                const off = caretFromPoint(s, st, sc, body, rect, mx, my, lh, pad, cw);
                st.cursor = off;
                st.anchor = off;
            }
        }
        if (it.dragging and ui.input.mouse.x >= body.x) {
            st.cursor = caretFromPoint(s, st, sc, body, rect, ui.input.mouse.x, ui.input.mouse.y, lh, pad, cw);
        }
        if (it.clicked and ui.input.mouse.x >= body.x) {
            const key = pid ^ 0x5E1D;
            const prev = ui.knownSize(key);
            const dbl = if (prev) |p| ui.time * 1000.0 - @as(f64, p.w) < 420.0 else false;
            ui.rememberSize(key, @as(f32, @floatCast(ui.time * 1000.0)), 0);
            if (dbl) {
                const wb = wordBounds(s, st.cursor);
                st.anchor = wb.start;
                st.cursor = wb.end;
            }
        }
    }

    if (changed) {
        s = buf[0..len.*];
        res.changed = true;
        res.line_count = @intCast(sc.lines);
    }
    // 光标动过也要重扫：`line` / `column` 是拿扫描结果报的，旧值会差一行
    if (changed or st.cursor != cursor_before) {
        sc = scan(s, st.cursor, opts.tab_size);
        res.line_count = @intCast(sc.lines);
    }

    // ---- 查找命中
    if (st.find_len > 0) {
        const fm = countMatches(s, st.find_query[0..st.find_len], st.cursor);
        res.find_matches = @intCast(fm.count);
        res.find_index = @intCast(fm.index);
    }

    // ---- 滚动：保证光标可见
    if (sc.caret_line < st.scroll_line) st.scroll_line = sc.caret_line;
    if (sc.caret_line >= st.scroll_line + rows) st.scroll_line = sc.caret_line + 1 - rows;
    const caret_x = @as(f32, @floatFromInt(sc.caret_col)) * cw;
    if (caret_x - st.scroll_x > view_w) st.scroll_x = caret_x - view_w + cw;
    if (caret_x < st.scroll_x) st.scroll_x = caret_x;
    if (st.scroll_x < 0) st.scroll_x = 0;

    // ---- 绘制
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 8, .border = if (it.focused) theme.accent else theme.border });
    if (gutter_w > 0) {
        ui.addBox(.{ .x = rect.x + 1, .y = rect.y + 1, .w = gutter_w - 1, .h = rect.h - 2 }, .{ .fill = theme.raised });
        ui.addOverlayLine(.{ .x = rect.x + gutter_w, .y = rect.y + 1 }, .{ .x = rect.x + gutter_w, .y = rect.y + rect.h - 1 }, 1, theme.hair);
    }

    const saved_clip = ui.clip;
    ui.clip = intersect(saved_clip, .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 });

    const lang = langOf(opts.lang);
    const sel_lo = @min(st.anchor, st.cursor);
    const sel_hi = @max(st.anchor, st.cursor);

    var off = lineStartAt(s, st.scroll_line);
    var row_i: usize = 0;
    while (row_i < rows and off <= len.*) : (row_i += 1) {
        const line_no = st.scroll_line + row_i;
        if (line_no >= sc.lines) break;
        const e = lineEndAt(s, off);
        const line = s[off..e];
        const y = rect.y + pad * 0.5 + lh * @as(f32, @floatFromInt(row_i));

        if (sel_hi > sel_lo) {
            const a = @max(sel_lo, off);
            const b = @min(sel_hi, e);
            if (b > a) {
                const x0 = body.x + pad + @as(f32, @floatFromInt(a - off)) * cw - st.scroll_x;
                const x1 = body.x + pad + @as(f32, @floatFromInt(b - off)) * cw - st.scroll_x;
                ui.addBox(.{ .x = x0, .y = y, .w = @max(1, x1 - x0), .h = lh }, .{ .fill = theme.accent_bg });
            }
        }
        for (opts.marks) |mk| {
            if (mk.end <= mk.start) continue;
            const a = @max(@as(i64, mk.start), @as(i64, @intCast(off)));
            const b = @min(@as(i64, mk.end), @as(i64, @intCast(e)));
            if (b <= a) continue;
            const x0 = body.x + pad + @as(f32, @floatFromInt(a - @as(i64, @intCast(off)))) * cw - st.scroll_x;
            const x1 = body.x + pad + @as(f32, @floatFromInt(b - @as(i64, @intCast(off)))) * cw - st.scroll_x;
            const col = if (mk.color == 0) theme.accent else seriesColor(mk.color);
            ui.addBox(.{ .x = x0, .y = y, .w = @max(1, x1 - x0), .h = lh }, .{ .fill = theme.withAlpha(col, 60), .radius = 2 });
        }
        if (gutter_w > 0) {
            var nb: [12]u8 = undefined;
            const nt = ui.frameStr(num.int(nb[0..], @intCast(line_no + 1)));
            const nw = cw * @as(f32, @floatFromInt(nt.len));
            ui.addMonoText(.{ .x = rect.x + gutter_w - nw - 8, .y = y, .w = nw + 2, .h = lh }, nt, size, theme.secondary);
        }
        if (line.len > 0) {
            var disp_buf: [MAX_DISP]u8 = undefined;
            const disp = expandTabs(line, opts.tab_size, disp_buf[0..]);
            const owned = ui.frameStr(disp);
            var runs: [MAX_RUNS]Run = undefined;
            // 纯文本（`lang = "text"`）整行一个 run：数字/引号都不该上色
            const rn = tokenize(lang, owned, &runs);
            var k: usize = 0;
            while (k < rn) : (k += 1) {
                const r = runs[k];
                if (r.end <= r.start) continue;
                const x = body.x + pad + @as(f32, @floatFromInt(r.start)) * cw - st.scroll_x;
                const w = @as(f32, @floatFromInt(r.end - r.start)) * cw;
                if (x + w < body.x or x > body.x + body.w) continue;
                ui.addMonoText(.{ .x = x, .y = y, .w = w + 2, .h = lh }, owned[r.start..r.end], size, runColor(r.kind));
            }
        }
        off = if (e < len.*) e + 1 else len.* + 1;
    }

    if (it.focused and sc.caret_line >= st.scroll_line and sc.caret_line < st.scroll_line + rows) {
        const cy = rect.y + pad * 0.5 + lh * @as(f32, @floatFromInt(sc.caret_line - st.scroll_line));
        const cx = body.x + pad + caret_x - st.scroll_x;
        ui.addOverlayLine(.{ .x = cx, .y = cy + 1 }, .{ .x = cx, .y = cy + lh - 2 }, 1.5, theme.text);
    }
    ui.clip = saved_clip;

    if (len.* == 0 and opts.placeholder.len > 0) {
        ui.addText(.{ .x = body.x + pad, .y = rect.y + pad * 0.5, .w = body.w - pad * 2, .h = lh }, opts.placeholder, size, theme.secondary);
    }

    if (sc.lines > rows) {
        const th = @max(16, rect.h * @as(f32, @floatFromInt(rows)) / @as(f32, @floatFromInt(sc.lines)));
        const max_first: f32 = @floatFromInt(sc.lines - rows);
        const ty = rect.y + (rect.h - th) * (@as(f32, @floatFromInt(st.scroll_line)) / max_first);
        ui.addBox(.{ .x = rect.x + rect.w - 5, .y = ty, .w = 3, .h = th }, .{ .fill = theme.withAlpha(theme.secondary, 110), .radius = 1.5 });
    }

    const bm = bracketMatch(s, st.cursor);
    res.bracket = bm.a;
    res.bracket_match = bm.b;
    res.cursor = @intCast(st.cursor);
    res.anchor = @intCast(st.anchor);
    res.line = @intCast(sc.caret_line + 1);
    res.column = @intCast(sc.caret_col + 1);
    return res;
}

fn caretFromPoint(
    s: []const u8,
    st: *EditorState,
    sc: Scan,
    body: t.Rect,
    rect: t.Rect,
    mx: f32,
    my: f32,
    lh: f32,
    pad: f32,
    cw: f32,
) usize {
    const row_f = @floor((my - rect.y - pad * 0.5) / lh);
    const row: usize = @intFromFloat(@max(0, row_f));
    const ln = @min(st.scroll_line + row, sc.lines - 1);
    const start = lineStartAt(s, ln);
    const e = lineEndAt(s, start);
    const want: f32 = @floor((mx - (body.x + pad) + st.scroll_x) / cw);
    var off = start;
    var col: f32 = 0;
    while (off < e and col < want) {
        col += 1;
        off = utf8Step(s, off);
    }
    return off;
}

fn seriesColor(k: u8) t.Color {
    const hue: f32 = @floatFromInt((@as(u32, k) * 57) % 360);
    const light: f32 = if (theme.isDark()) 0.55 else 0.46;
    return hsl(hue / 360.0, 0.55, light);
}

fn hsl(h: f32, sat: f32, l: f32) t.Color {
    const q = if (l < 0.5) l * (1 + sat) else l + sat - l * sat;
    const p = 2 * l - q;
    const r = hue2rgb(p, q, h + 1.0 / 3.0);
    const g = hue2rgb(p, q, h);
    const b = hue2rgb(p, q, h - 1.0 / 3.0);
    return t.Color{
        .r = @intFromFloat(@round(r * 255)),
        .g = @intFromFloat(@round(g * 255)),
        .b = @intFromFloat(@round(b * 255)),
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
