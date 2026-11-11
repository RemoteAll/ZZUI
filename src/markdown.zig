//! Markdown 视图（对位 CUI 的 `cui_markdown.c`）：每帧重新解析，**不保留文本副本**。
//!
//! 支持：ATX 标题（`#`..`######`）、段落（段内单换行是软换行）、`**粗体**`、
//! `*斜体*`/`_斜体_`、`~~删除线~~`、`` `行内代码` ``、`[链接](url)`、
//! `![图片](url)`（显示为图片链接）、`<自动链接>`、裸 `https://` / `www.` 链接、
//! 无序（`- * +`）/ 有序（`1.` `1)`）列表（含缩进与任务框）、引用、围栏代码块
//! （``` 或 ~~~，复用 `codeview.codeBlock`）、缩进代码、分隔线、管道表格。
//! 其余（内嵌 HTML、引用式链接、脚注、数学公式）按纯文本显示。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次有人当成 bug）：
//! - 行内标记**不做嵌套合并**（`***x***` 按「粗体 + 斜体片段」显示）；
//! - 引用内部只按段落/列表渲染，不再递归块级（`> # 标题` 显示成文本）；
//! - 图片不加载，只当链接（框架不解码图片格式，见 `image.zig`）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const codeview = @import("codeview.zig");
const num = @import("num.zig");

pub const MarkdownOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 正文字号（标题按级别放大）。
    size: f32 = theme.font_body,
    /// null = 跟随主题。
    color: ?t.Color = null,
    /// 紧凑排版（聊天气泡）：标题更小、段间距收紧。
    compact: bool = false,
};

pub const MarkdownResult = struct {
    /// 本帧被点击/回车激活的链接 URL（帧内存，指向 `Context.text_pool`）。
    link: ?[]const u8 = null,
    /// 指针下的链接 URL。
    hovered_link: ?[]const u8 = null,
    /// 任务框被切换：`text` 里方括号之间那个字符的字节偏移，否则 -1。
    task_offset: i32 = -1,
    /// 该任务项在 `text` 里的 1 基行号（0 = 无）。
    task_line: usize = 0,
    /// 切换后的状态。
    task_checked: bool = false,
    /// 本帧渲染出来的高度。
    height: f32 = 0,
};

const Style = enum { normal, bold, italic, bold_italic, strike, code, link };

const Span = struct {
    text: []const u8,
    style: Style = .normal,
    url: []const u8 = "",
};

/// 任务框：`offset` 是原文中 `[ ]` 方括号内那个字符的字节偏移。
const TaskBox = struct { checked: bool, offset: i32, line: usize };

const MAX_SPANS = 64;
const MAX_TABLE_COLS = 8;

fn isBlank(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

fn trimRight(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and (s[n - 1] == '\r' or s[n - 1] == ' ' or s[n - 1] == '\t')) n -= 1;
    return s[0..n];
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn indentOf(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and s[i] == ' ') i += 1;
    return i;
}

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn startsWith(s: []const u8, p: []const u8) bool {
    return s.len >= p.len and std.mem.eql(u8, s[0..p.len], p);
}

fn eqChar(s: []const u8, c: u8) bool {
    return s.len > 0 and s[0] == c;
}

/// 标题级别（`#`..`######` + 空格）；0 = 不是标题。
fn headingLevel(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == '#') n += 1;
    if (n == 0 or n > 6) return 0;
    if (n < s.len and s[n] != ' ' and s[n] != '\t') return 0;
    return n;
}

/// 分隔线：`---` / `***` / `___`（同一种字符 >= 3，允许中间夹空格）。
fn isRule(s: []const u8) bool {
    const c = if (s.len > 0) s[0] else return false;
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (s) |ch| {
        if (ch == c) {
            n += 1;
        } else if (ch != ' ' and ch != '\t' and ch != '\r') return false;
    }
    return n >= 3;
}

/// 围栏代码块起始：返回语言标签；`null` = 不是围栏。
fn fenceOpen(s: []const u8) ?[]const u8 {
    const tl = trimLeft(s);
    if (tl.len < 3) return null;
    if (!(startsWith(tl, "```") or startsWith(tl, "~~~"))) return null;
    const ch = tl[0];
    var n: usize = 0;
    while (n < tl.len and tl[n] == ch) n += 1;
    if (n < 3) return null;
    return trimRight(tl[n..]);
}

fn isFenceClose(s: []const u8, ch: u8) bool {
    const tl = trimLeft(s);
    if (tl.len < 3 or tl[0] != ch) return false;
    var n: usize = 0;
    while (n < tl.len and tl[n] == ch) n += 1;
    return n >= 3 and isBlank(tl[n..]);
}

const ListMark = struct {
    /// 项目符号宽度（含空格），用于算内容起点与嵌套层级。
    indent: usize,
    /// 有序列表的序号；0 = 无序。
    number: usize,
};

/// 列表项 / 引用前缀识别。
fn listMark(s: []const u8) ?ListMark {
    const ind = indentOf(s);
    const body = s[ind..];
    if (body.len < 2) return null;
    if ((body[0] == '-' or body[0] == '*' or body[0] == '+') and (body[1] == ' ' or body[1] == '\t')) {
        return .{ .indent = ind, .number = 0 };
    }
    // 有序：1. / 1) —— 最多 9 位数字
    var i: usize = 0;
    while (i < body.len and body[i] >= '0' and body[i] <= '9' and i < 9) i += 1;
    if (i == 0 or i + 1 >= body.len) return null;
    if ((body[i] == '.' or body[i] == ')') and (body[i + 1] == ' ' or body[i + 1] == '\t')) {
        const n = std.fmt.parseInt(usize, body[0..i], 10) catch return null;
        return .{ .indent = ind, .number = n };
    }
    return null;
}

/// 任务框：`[ ] ` / `[x] `；返回 `[` 的位置与是否勾选。
fn taskMark(s: []const u8) ?struct { box: usize, checked: bool } {
    if (s.len < 3 or s[0] != '[') return null;
    if (s[2] != ']') return null;
    const c = s[1];
    if (c != ' ' and c != 'x' and c != 'X') return null;
    if (s.len > 3 and s[3] != ' ' and s[3] != '\t') return null;
    return .{ .box = 1, .checked = c != ' ' };
}

fn isQuote(s: []const u8) bool {
    const tl = trimLeft(s);
    return eqChar(tl, '>');
}

fn stripQuote(s: []const u8) []const u8 {
    var tl = trimLeft(s);
    if (eqChar(tl, '>')) tl = tl[1..];
    return if (tl.len > 0 and tl[0] == ' ') tl[1..] else tl;
}

fn isUrlSafe(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '<', '>', '"', '\'', ')', ']' => false,
        else => true,
    };
}

fn cjkAt(s: []const u8, i: usize) bool {
    return i < s.len and s[i] >= 0xE0;
}

// ---------------------------------------------------------------- 内联解析

/// 把一行文本解析成带样式的片段。返回写入的片段数。
fn parseInline(s: []const u8, out: []Span) usize {
    var n: usize = 0;
    var plain_start: usize = 0;
    var i: usize = 0;

    const pushPlain = struct {
        fn f(list: []Span, idx: *usize, txt: []const u8) void {
            if (txt.len == 0 or idx.* >= list.len) return;
            list[idx.*] = .{ .text = txt };
            idx.* += 1;
        }
    }.f;

    while (i < s.len) {
        const c = s[i];
        var handled = false;

        // 行内代码
        if (c == '`') {
            if (std.mem.indexOfPos(u8, s, i + 1, "`")) |e| {
                if (n + 2 <= out.len) {
                    pushPlain(out, &n, s[plain_start..i]);
                    if (e > i + 1) {
                        out[n] = .{ .text = s[i + 1 .. e], .style = .code };
                        n += 1;
                    }
                    i = e + 1;
                    plain_start = i;
                    handled = true;
                }
            }
        } else if (c == '*' or c == '_' or c == '~') {
            // **粗体** / ~~删除线~~ / *斜体*
            const double = i + 1 < s.len and s[i + 1] == c and c != '_';
            const marker: []const u8 = if (double) s[i .. i + 2] else s[i .. i + 1];
            if (double or c != '~') {
                if (std.mem.indexOfPos(u8, s, i + marker.len, marker)) |e| {
                    if (e > i + marker.len and n + 2 <= out.len) {
                        pushPlain(out, &n, s[plain_start..i]);
                        const inner = s[i + marker.len .. e];
                        out[n] = .{ .text = inner, .style = if (double) .bold else .italic };
                        n += 1;
                        i = e + marker.len;
                        plain_start = i;
                        handled = true;
                    }
                }
            }
        } else if (c == '[' or (c == '!' and i + 1 < s.len and s[i + 1] == '[')) {
            // [链接](url) / ![图片](url)
            const open = if (c == '!') i + 1 else i;
            if (std.mem.indexOfPos(u8, s, open + 1, "](")) |mid| {
                if (std.mem.indexOfPos(u8, s, mid + 2, ")")) |close| {
                    if (n + 2 <= out.len) {
                        pushPlain(out, &n, s[plain_start..if (c == '!') i else open]);
                        out[n] = .{
                            .text = s[open + 1 .. mid],
                            .style = .link,
                            .url = s[mid + 2 .. close],
                        };
                        n += 1;
                        i = close + 1;
                        plain_start = i;
                        handled = true;
                    }
                }
            }
        } else if (c == '<') {
            // <https://autolink>
            if (std.mem.indexOfPos(u8, s, i + 1, ">")) |e| {
                const inner = s[i + 1 .. e];
                if (inner.len > 0 and std.mem.indexOf(u8, inner, "://") != null and n + 2 <= out.len) {
                    pushPlain(out, &n, s[plain_start..i]);
                    out[n] = .{ .text = inner, .style = .link, .url = inner };
                    n += 1;
                    i = e + 1;
                    plain_start = i;
                    handled = true;
                }
            }
        } else if ((c == 'h' or c == 'w') and (i == 0 or isSpaceByte(s[i - 1]))) {
            // 裸链接：https://... / http://... / www....
            const rest = s[i..];
            const is_http = startsWith(rest, "https://") or startsWith(rest, "http://");
            const is_www = startsWith(rest, "www.");
            if (is_http or is_www) {
                var e = i;
                while (e < s.len and isUrlSafe(s[e])) e += 1;
                const min_len: usize = if (is_www) 4 else 8;
                if (e > i + min_len and n + 2 <= out.len) {
                    pushPlain(out, &n, s[plain_start..i]);
                    out[n] = .{ .text = s[i..e], .style = .link, .url = s[i..e] };
                    n += 1;
                    i = e;
                    plain_start = i;
                    handled = true;
                }
            }
        }

        if (!handled) i += 1;
    }
    pushPlain(out, &n, s[plain_start..]);
    return n;
}

fn styleColor(st: Style, base: t.Color) t.Color {
    return switch (st) {
        .link => theme.accent,
        .code => base,
        else => base,
    };
}

// ---------------------------------------------------------------- 排版

/// 行内排版器：逐词累加到「样式相同的行内片段」，样式变化或换行时输出一个文本节点。
/// `commit == false` 时只走排版（算高度/行数），不建任何节点 —— 段落要先知道多高才能占位。
const Layout = struct {
    ui: *core.Context,
    res: *MarkdownResult,
    id_hash: u64,
    size: f32,
    line_h: f32,
    base: t.Color,
    commit: bool,
    base_x: f32 = 0,
    line_y: f32 = 0,
    buf: [512]u8 = undefined,
    len: usize = 0,
    style: Style = .normal,
    url: []const u8 = "",
    seg_x: f32 = 0,
    seg_w: f32 = 0,

    fn flushSeg(self: *Layout) void {
        if (self.len == 0) return;
        if (self.commit) {
            const txt = self.ui.frameStr(self.buf[0..self.len]);
            const rect = t.Rect{ .x = self.seg_x, .y = self.line_y, .w = self.seg_w, .h = self.line_h };
            if (self.style == .code) {
                self.ui.addBox(rect.inset(2), .{ .fill = theme.track, .radius = 4 });
            }
            const bold = self.style == .bold or self.style == .bold_italic;
            const italic = self.style == .italic or self.style == .bold_italic;
            self.ui.addRichText(rect, txt, self.size, styleColor(self.style, self.base), bold, italic);
            if (self.style == .link) {
                const uy = self.line_y + self.line_h * 0.94;
                self.ui.addOverlayLine(.{ .x = rect.x, .y = uy }, .{ .x = rect.x + rect.w, .y = uy }, 1, theme.accent);
                const lid = self.id_hash ^ core.Context.idOf(self.url) ^
                    @as(u64, @intFromFloat(@max(self.line_y, 0) * 4));
                const it = self.ui.interact(lid, rect);
                if (it.hover) self.res.hovered_link = self.ui.frameStr(self.url);
                if (it.clicked or it.activated) self.res.link = self.ui.frameStr(self.url);
            } else if (self.style == .strike) {
                const my = self.line_y + self.line_h * 0.52;
                self.ui.addOverlayLine(.{ .x = rect.x, .y = my }, .{ .x = rect.x + rect.w, .y = my }, 1, self.base);
            }
        }
        self.len = 0;
        self.seg_w = 0;
    }

    /// 追加一个词；超宽先换行，样式变化另起一段。
    fn addWord(self: *Layout, word: []const u8, st: Style, url: []const u8, pen: *f32, max_w: f32) void {
        const bold = st == .bold or st == .bold_italic;
        const w = self.ui.measureTextStyled(word, self.size, bold).w;
        if (pen.* + w > max_w and pen.* > 0) {
            self.flushSeg();
            self.line_y += self.line_h;
            pen.* = 0;
        }
        if (self.len == 0 or st != self.style or !std.mem.eql(u8, url, self.url)) {
            self.flushSeg();
            self.style = st;
            self.url = url;
            self.seg_x = self.base_x + pen.*;
        }
        const room = self.buf.len - self.len;
        const take = if (word.len < room) word.len else room;
        @memcpy(self.buf[self.len..][0..take], word[0..take]);
        self.len += take;
        self.seg_w += w;
        pen.* += w;
    }
};

/// 把一组 span 排成多行；返回渲染后的总高度。
fn layoutInline(
    ui: *core.Context,
    id_hash: u64,
    spans: []const Span,
    x: f32,
    y: f32,
    max_w: f32,
    size: f32,
    base: t.Color,
    res: *MarkdownResult,
    commit: bool,
) f32 {
    const prob = ui.measureText("Ag", size);
    const line_h = if (prob.h > 0) prob.h else size * 1.35;
    var L = Layout{
        .ui = ui,
        .res = res,
        .id_hash = id_hash,
        .size = size,
        .line_h = line_h,
        .base = base,
        .commit = commit,
        .base_x = x,
        .line_y = y,
    };
    const wrap_w = if (max_w > 0) max_w else 1e9;
    var pen: f32 = 0;
    for (spans) |sp| {
        var i: usize = 0;
        while (i < sp.text.len) {
            const start = i;
            if (isSpaceByte(sp.text[i])) {
                while (i < sp.text.len and isSpaceByte(sp.text[i])) i += 1;
                // 行首空格丢掉（换行后不缩进）
                if (pen > 0) L.addWord(sp.text[start..i], sp.style, sp.url, &pen, wrap_w);
                continue;
            }
            // 词：CJK 逐字断行，西文按空格断
            if (cjkAt(sp.text, i)) {
                const l = std.unicode.utf8ByteSequenceLength(sp.text[i]) catch 1;
                i += @min(l, sp.text.len - i);
            } else {
                while (i < sp.text.len and !isSpaceByte(sp.text[i]) and !cjkAt(sp.text, i)) i += 1;
            }
            L.addWord(sp.text[start..i], sp.style, sp.url, &pen, wrap_w);
        }
    }
    L.flushSeg();
    return (L.line_y - y) + line_h;
}

// ---------------------------------------------------------------- 块渲染

const MdCtx = struct {
    ui: *core.Context,
    id_hash: u64,
    opts: MarkdownOpts,
    base: t.Color,
    res: *MarkdownResult,

    fn gap(self: *MdCtx) f32 {
        return if (self.opts.compact) self.opts.size * 0.35 else self.opts.size * 0.7;
    }

    fn contentW(self: *MdCtx) f32 {
        if (self.opts.width > 0) return self.opts.width;
        const f = &self.ui.stack[self.ui.depth - 1];
        return if (f.width > 0) f.width else 0;
    }

    fn spacing(self: *MdCtx, h: f32) void {
        _ = self.ui.reserve(0, h, true);
    }

    fn heading(self: *MdCtx, level: usize, text: []const u8) void {
        const scale: f32 = switch (level) {
            1 => 1.7,
            2 => 1.45,
            3 => 1.25,
            4 => 1.12,
            5 => 1.03,
            else => 0.96,
        };
        const size = self.opts.size * (if (self.opts.compact) 1.0 + (scale - 1.0) * 0.6 else scale);
        var spans: [MAX_SPANS]Span = undefined;
        const n = parseInline(text, &spans);
        // 标题整体加粗：内联片段一律提到粗体（链接保留强调色）
        for (spans[0..n]) |*sp| {
            if (sp.style == .normal) sp.style = .bold;
        }
        const w = self.contentW();
        const h = layoutInline(self.ui, self.id_hash, spans[0..n], 0, 0, w, size, self.base, self.res, false);
        const rect = self.ui.reserve(0, h + size * 0.25, true);
        _ = layoutInline(self.ui, self.id_hash, spans[0..n], rect.x, rect.y, w, size, self.base, self.res, true);
        self.spacing(self.gap() * 0.5);
    }

    fn para(self: *MdCtx, lines: []const []const u8) void {
        if (lines.len == 0) return;
        var spans: [MAX_SPANS]Span = undefined;
        var n: usize = 0;
        for (lines, 0..) |ln, k| {
            if (n >= MAX_SPANS) break;
            if (k > 0) {
                spans[n] = .{ .text = " " }; // 软换行
                n += 1;
            }
            if (n >= MAX_SPANS) break;
            n += parseInline(ln, spans[n..]);
        }
        const w = self.contentW();
        const size = self.opts.size;
        const h = layoutInline(self.ui, self.id_hash, spans[0..n], 0, 0, w, size, self.base, self.res, false);
        const rect = self.ui.reserve(0, h, true);
        _ = layoutInline(self.ui, self.id_hash, spans[0..n], rect.x, rect.y, w, size, self.base, self.res, true);
        self.spacing(self.gap());
    }

    fn bullet(
        self: *MdCtx,
        depth: usize,
        marker: []const u8,
        text: []const u8,
        box: ?TaskBox,
    ) void {
        const indent: f32 = 14 + @as(f32, @floatFromInt(depth)) * 16;
        const size = self.opts.size;
        const prob = self.ui.measureText("Ag", size);
        const line_h = if (prob.h > 0) prob.h else size * 1.35;
        const w = self.contentW();
        const glyph_w: f32 = 18;
        const avail = if (w > 0) w - indent - glyph_w else 0;
        var spans: [MAX_SPANS]Span = undefined;
        const n = parseInline(text, &spans);
        const h = layoutInline(self.ui, self.id_hash, spans[0..n], 0, 0, avail, size, self.base, self.res, false);
        const row = self.ui.reserve(0, @max(h, line_h), true);

        if (box) |b| {
            const bs: f32 = 14;
            const bx = row.x + indent;
            const by = row.y + (line_h - bs) / 2;
            const bid = self.id_hash ^ 0xC4EC ^ @as(u64, @intCast(@max(b.offset, 0)));
            const it = self.ui.interact(bid, .{ .x = bx, .y = by, .w = bs, .h = bs });
            self.ui.addBox(.{ .x = bx, .y = by, .w = bs, .h = bs }, .{
                .fill = if (b.checked) theme.accent else theme.bg,
                .border = if (b.checked) theme.accent else theme.border,
                .radius = 3,
            });
            if (b.checked) {
                self.ui.addOverlayLine(.{ .x = bx + 3.5, .y = by + 7 }, .{ .x = bx + 6, .y = by + 10 }, 1.8, theme.accent_text);
                self.ui.addOverlayLine(.{ .x = bx + 6, .y = by + 10 }, .{ .x = bx + 10.5, .y = by + 4 }, 1.8, theme.accent_text);
            }
            if (it.clicked or it.activated) {
                self.res.task_offset = b.offset;
                self.res.task_line = b.line;
                self.res.task_checked = !b.checked;
            }
        } else if (marker.len > 0) {
            const mw = self.ui.measureText(marker, size).w;
            self.ui.addText(.{ .x = row.x + indent, .y = row.y, .w = mw, .h = line_h }, marker, size, theme.secondary);
        }

        const text_x = row.x + indent + glyph_w;
        _ = layoutInline(self.ui, self.id_hash, spans[0..n], text_x, row.y, avail, size, self.base, self.res, true);
    }

    fn rule(self: *MdCtx) void {
        const row = self.ui.reserve(0, 9, true);
        const y = row.y + 4;
        self.ui.addOverlayLine(.{ .x = row.x, .y = y }, .{ .x = row.x + row.w, .y = y }, 1, theme.border);
        self.spacing(self.gap() * 0.5);
    }

    fn codeFence(self: *MdCtx, lang: []const u8, body: []const u8) void {
        codeview.codeBlock(self.ui, "", body, .{ .lang = lang, .size = self.opts.size - 2, .line_numbers = false });
        self.spacing(self.gap() * 0.6);
    }

    fn quoteLine(self: *MdCtx, text: []const u8) void {
        const size = self.opts.size;
        const prob = self.ui.measureText("Ag", size);
        const line_h = if (prob.h > 0) prob.h else size * 1.35;
        const w = self.contentW();
        const inset: f32 = 14;
        const avail = if (w > 0) w - inset else 0;
        var spans: [MAX_SPANS]Span = undefined;
        const n = parseInline(text, &spans);
        const h = layoutInline(self.ui, self.id_hash, spans[0..n], 0, 0, avail, size, self.base, self.res, false);
        const row = self.ui.reserve(0, @max(h, line_h), true);
        self.ui.addBox(.{ .x = row.x + 2, .y = row.y, .w = 3, .h = @max(h, line_h) }, .{ .fill = theme.border, .radius = 1.5 });
        _ = layoutInline(self.ui, self.id_hash, spans[0..n], row.x + inset, row.y, avail, size, theme.secondary, self.res, true);
    }
};

fn splitCells(line: []const u8, out: *[MAX_TABLE_COLS][]const u8) usize {
    var tl = trimLeft(line);
    tl = trimRight(tl);
    if (tl.len > 0 and tl[0] == '|') tl = tl[1..];
    if (tl.len > 0 and tl[tl.len - 1] == '|') tl = tl[0 .. tl.len - 1];
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= tl.len and n < MAX_TABLE_COLS) : (i += 1) {
        if (i == tl.len or tl[i] == '|') {
            out[n] = trimRight(trimLeft(tl[start..i]));
            n += 1;
            start = i + 1;
        }
    }
    return n;
}

/// 表格对齐行：`|---|:--:|`（每格只含 `-` 与 `:`，至少一个 `-`）。
fn isTableAlign(line: []const u8) bool {
    var tl = trimLeft(line);
    tl = trimRight(tl);
    if (tl.len < 3) return false;
    if (tl[0] != '|' and tl[0] != ':') return false;
    var dashes: usize = 0;
    for (tl) |c| {
        switch (c) {
            '-' => dashes += 1,
            ':', '|', ' ', '\t' => {},
            else => return false,
        }
    }
    return dashes > 0;
}

fn isTableRow(line: []const u8) bool {
    const tl = trimLeft(line);
    return tl.len > 0 and tl[0] == '|' and std.mem.indexOfScalar(u8, tl, '|') != null;
}

// ---------------------------------------------------------------- 入口

/// 渲染 markdown（每帧重新解析）。在 column 容器里调用。
pub fn markdown(ui: *core.Context, id: []const u8, text: []const u8, opts: MarkdownOpts) MarkdownResult {
    var res = MarkdownResult{};
    const id_hash = core.Context.idOf(id);
    var ctx = MdCtx{
        .ui = ui,
        .id_hash = id_hash,
        .opts = opts,
        .base = opts.color orelse theme.text,
        .res = &res,
    };
    const start_y = ui.stack[ui.depth - 1].content_y;
    if (text.len == 0) {
        res.height = 0;
        return res;
    }

    var lines: [core.MAX_LINES][]const u8 = undefined;
    var nlines: usize = 0;
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |ln| {
            if (nlines >= lines.len) break;
            lines[nlines] = trimRight(ln);
            nlines += 1;
        }
    }

    // 段落缓冲：连续的非块行
    var para: [core.MAX_LINES][]const u8 = undefined;
    var para_n: usize = 0;

    var i: usize = 0;
    while (i < nlines) {
        const line = lines[i];
        const line_no = i + 1;

        if (isBlank(line)) {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            i += 1;
            continue;
        }

        // 围栏代码块
        if (fenceOpen(line)) |lang| {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            const ch = trimLeft(line)[0];
            const body_start = i + 1;
            var j = body_start;
            var closed = false;
            while (j < nlines) : (j += 1) {
                if (isFenceClose(lines[j], ch)) {
                    closed = true;
                    break;
                }
            }
            const body = if (closed)
                joinRange(ui, lines[body_start..j])
            else
                joinRange(ui, lines[body_start..nlines]);
            ctx.codeFence(lang, body);
            i = if (closed) j + 1 else nlines;
            continue;
        }

        // 标题
        const hlevel = headingLevel(line);
        if (hlevel > 0) {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            ctx.spacing(ctx.gap() * 0.4);
            ctx.heading(hlevel, trimLeft(line[hlevel..]));
            i += 1;
            continue;
        }

        // 分隔线
        if (isRule(line)) {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            ctx.rule();
            i += 1;
            continue;
        }

        // 表格：本行是 |...| 且下一行是对齐行
        if (isTableRow(line) and i + 1 < nlines and isTableAlign(lines[i + 1])) {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            var cols: [MAX_TABLE_COLS][]const u8 = undefined;
            const ncols = splitCells(line, &cols);
            const size = opts.size;
            const prob = ui.measureText("Ag", size);
            const line_h = if (prob.h > 0) prob.h else size * 1.35;
            const w = ctx.contentW();
            const col_w = if (w > 0 and ncols > 0) w / @as(f32, @floatFromInt(ncols)) else 120;
            // 表头
            const hrow = ui.reserve(0, line_h + 8, true);
            var k: usize = 0;
            while (k < ncols) : (k += 1) {
                const cx = hrow.x + col_w * @as(f32, @floatFromInt(k));
                ui.addText(.{ .x = cx + 8, .y = hrow.y + 4, .w = col_w - 16, .h = line_h }, cols[k], size, theme.text);
            }
            ui.addOverlayLine(.{ .x = hrow.x, .y = hrow.y + hrow.h - 1 }, .{ .x = hrow.x + hrow.w, .y = hrow.y + hrow.h - 1 }, 1, theme.border);
            // 数据行
            var r = i + 2;
            while (r < nlines and isTableRow(lines[r])) : (r += 1) {
                var rc: [MAX_TABLE_COLS][]const u8 = undefined;
                const rn = splitCells(lines[r], &rc);
                const rrow = ui.reserve(0, line_h + 6, true);
                k = 0;
                while (k < rn and k < ncols) : (k += 1) {
                    const cx = rrow.x + col_w * @as(f32, @floatFromInt(k));
                    ui.addText(.{ .x = cx + 8, .y = rrow.y + 3, .w = col_w - 16, .h = line_h }, rc[k], size, theme.text);
                }
                ui.addOverlayLine(.{ .x = rrow.x, .y = rrow.y + rrow.h - 1 }, .{ .x = rrow.x + rrow.w, .y = rrow.y + rrow.h - 1 }, 1, theme.hair);
            }
            ctx.spacing(ctx.gap());
            i = r;
            continue;
        }

        // 引用
        if (isQuote(line)) {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            while (i < nlines and isQuote(lines[i])) : (i += 1) {
                ctx.quoteLine(stripQuote(lines[i]));
            }
            ctx.spacing(ctx.gap() * 0.6);
            continue;
        }

        // 列表项
        if (listMark(line)) |lm| {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            const depth = @min(lm.indent / 2, 5);
            const body_start = lm.indent + (if (lm.number > 0) digitsOf(lm.number) + 2 else 2);
            const body = if (body_start <= line.len) line[body_start..] else "";
            var marker_buf: [16]u8 = undefined;
            var marker: []const u8 = undefined;
            var box: ?TaskBox = null;
            if (lm.number > 0) {
                const ms = num.int(&marker_buf, @intCast(lm.number));
                const tail = marker_buf[ms.len..];
                tail[0] = '.';
                marker = ui.frameStr(marker_buf[0 .. ms.len + 1]);
            } else {
                marker = "•";
                if (taskMark(body)) |tm| {
                    box = .{
                        .checked = tm.checked,
                        .offset = @intCast(offsetOfLine(text, line_no) + body_start + tm.box),
                        .line = line_no,
                    };
                    marker = "";
                }
            }
            const content = if (box != null) trimLeft(body[3..]) else body;
            ctx.bullet(depth, marker, content, box);
            i += 1;
            continue;
        }

        // 缩进代码（4 空格）
        if (indentOf(line) >= 4) {
            if (para_n > 0) {
                ctx.para(para[0..para_n]);
                para_n = 0;
            }
            var j = i;
            while (j < nlines and (isBlank(lines[j]) or indentOf(lines[j]) >= 4)) : (j += 1) {}
            const body = joinIndented(ui, lines[i..j]);
            ctx.codeFence("", body);
            i = j;
            continue;
        }

        // 段落行
        if (para_n < para.len) {
            para[para_n] = line;
            para_n += 1;
        }
        i += 1;
    }
    if (para_n > 0) ctx.para(para[0..para_n]);

    const end_y = ui.stack[ui.depth - 1].content_y + ui.stack[ui.depth - 1].cursor;
    res.height = end_y - start_y;
    return res;
}

fn digitsOf(v: usize) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) n += 1;
    return n;
}

/// 行号（1 基）→ 该行首字节在原文里的偏移。用于把任务框位置映射回调用方的文本。
fn offsetOfLine(text: []const u8, line_no: usize) usize {
    if (line_no <= 1) return 0;
    var n: usize = 1;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            n += 1;
            if (n == line_no) return i + 1;
        }
    }
    return text.len;
}

fn joinRange(ui: *core.Context, lines: []const []const u8) []const u8 {
    var total: usize = 0;
    for (lines) |ln| total += ln.len + 1;
    if (total == 0) return "";
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    for (lines, 0..) |ln, k| {
        const take = @min(ln.len, buf.len - len);
        @memcpy(buf[len..][0..take], ln[0..take]);
        len += take;
        if (k + 1 < lines.len and len < buf.len) {
            buf[len] = '\n';
            len += 1;
        }
    }
    return ui.frameStr(buf[0..len]);
}

fn joinIndented(ui: *core.Context, lines: []const []const u8) []const u8 {
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    for (lines, 0..) |ln, k| {
        const body = if (ln.len >= 4) ln[4..] else trimLeft(ln);
        const take = @min(body.len, buf.len - len);
        @memcpy(buf[len..][0..take], body[0..take]);
        len += take;
        if (k + 1 < lines.len and len < buf.len) {
            buf[len] = '\n';
            len += 1;
        }
    }
    // 去掉尾部空行
    while (len > 0 and buf[len - 1] == '\n') len -= 1;
    return ui.frameStr(buf[0..len]);
}

/// 把报告的任务框切换写回调用方的文本（`[ ]` ↔ `[x]`）。
/// 返回 false 表示没有切换、或 text 里那个位置已经不是任务框。
pub fn applyTask(text: []u8, res: MarkdownResult) bool {
    if (res.task_offset < 0) return false;
    const off: usize = @intCast(res.task_offset);
    if (off >= text.len) return false;
    const c = text[off];
    if (c != ' ' and c != 'x' and c != 'X') return false;
    text[off] = if (res.task_checked) 'x' else ' ';
    return true;
}

/// 正文行的基础测量（示例/测试用）。
pub fn measureHeight(ui: *core.Context, text: []const u8, width: f32, opts: MarkdownOpts) f32 {
    // 用一个隔离的临时 Context 不行（需要真实测量回调）；这里直接渲染一遍再回读高度，
    // 供「高度未知但要先占位」的场景使用（如聊天气泡）。
    var o = opts;
    o.width = width;
    var ui2 = core.Context{};
    ui2.measure_ctx = ui.measure_ctx;
    ui2.measure_fn = ui.measure_fn;
    ui2.begin(width, 10000);
    _ = markdown(&ui2, "measure", text, o);
    return ui2.stack[ui2.depth - 1].cursor;
}
