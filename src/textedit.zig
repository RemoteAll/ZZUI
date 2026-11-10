//! 文本编辑族（对位 CUI 的 `cui_textedit.c` 公开件）：多行文本域 / 搜索框 / 数字输入。
//! 与 `widgets.input` 同一口径：缓冲、长度、光标都由调用方保存，按字节计。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const t = @import("types.zig");

const MAX_LINES = 64;

fn utf8Step(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    const e = i + n;
    return if (e > s.len) s.len else e;
}

fn prevCharStart(s: []const u8, i: usize) usize {
    var k = i;
    while (k > 0) {
        k -= 1;
        if ((s[k] & 0xC0) != 0x80) return k;
    }
    return 0;
}

fn sliceId(id: []const u8, salt: u64) u64 {
    return core.Context.idOf(id) ^ salt;
}

fn lineCircle(ui: *core.Context, cx: f32, cy: f32, r: f32, color: t.Color) void {
    // 8 段折线近似圆（不引入曲线渲染器）
    const segs: usize = 8;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const a0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)) * 2 * std.math.pi;
        const a1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs)) * 2 * std.math.pi;
        ui.addOverlayLine(
            .{ .x = cx + @cos(a0) * r, .y = cy + @sin(a0) * r },
            .{ .x = cx + @cos(a1) * r, .y = cy + @sin(a1) * r },
            1.4,
            color,
        );
    }
}

fn crossIcon(ui: *core.Context, rect: t.Rect, color: t.Color) void {
    const p: f32 = 4;
    const cx = rect.x + rect.w / 2;
    const cy = rect.y + rect.h / 2;
    ui.addOverlayLine(.{ .x = cx - p, .y = cy - p }, .{ .x = cx + p, .y = cy + p }, 1.4, color);
    ui.addOverlayLine(.{ .x = cx + p, .y = cy - p }, .{ .x = cx - p, .y = cy + p }, 1.4, color);
}

// ------------------------------------------------------------------ textarea

pub const TextareaOpts = struct {
    /// 0 表示撑满内容宽。
    width: f32 = 0,
    /// 可视行数（超出的行通过跟随光标滚动显示）。
    rows: usize = 4,
    line_h: f32 = 20,
    pad: f32 = 8,
    placeholder: []const u8 = "",
};

/// 多行文本域：按宽换行、Enter 换行、上下左右/Home/End、点击定位、
/// 行数超过 `rows` 时窗口跟随光标。
pub fn textarea(
    ui: *core.Context,
    id: []const u8,
    buf: []u8,
    len: *usize,
    caret: *usize,
    opts: TextareaOpts,
) bool {
    const rows_f: f32 = @floatFromInt(@max(opts.rows, 1));
    const h = opts.line_h * rows_f + opts.pad * 2;
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const it = ui.interactEx(sliceId(id, 0x7A47E), rect, true);
    const inner_x = rect.x + opts.pad;
    const inner_w = rect.w - opts.pad * 2;

    var changed = false;
    if (caret.* > len.*) caret.* = len.*;

    // 布局：按 '\n' 分段，段内按宽换行
    var lines: [MAX_LINES][]const u8 = @splat("");
    var starts: [MAX_LINES]usize = @splat(0);
    const n = layoutLines(ui, buf[0..len.*], inner_w, &lines, &starts);

    // 光标所在行
    var caret_line: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (caret.* >= starts[i]) caret_line = i;
    }

    // 点击定位
    if (it.clicked and inner_w > 0) {
        const top_now = topLine(caret_line, opts.rows);
        var row_i: usize = 0;
        if (ui.input.mouse.y > rect.y + opts.pad) {
            row_i = @intFromFloat((ui.input.mouse.y - rect.y - opts.pad) / opts.line_h);
        }
        const target = @min(top_now + row_i, n - 1);
        caret.* = caretFromX(ui, lines[target], starts[target], inner_x, ui.input.mouse.x);
        caret_line = target;
    }

    // 键盘编辑
    if (it.focused) {
        if (ui.input.keyPressed(.backspace) and caret.* > 0) {
            const prev = prevCharStart(buf[0..len.*], caret.*);
            removeRange(buf, len, prev, caret.*);
            caret.* = prev;
            changed = true;
        }
        if (ui.input.keyPressed(.delete) and caret.* < len.*) {
            removeRange(buf, len, caret.*, utf8Step(buf[0..len.*], caret.*));
            changed = true;
        }
        if (ui.input.keyPressed(.left) and caret.* > 0) caret.* = prevCharStart(buf[0..len.*], caret.*);
        if (ui.input.keyPressed(.right) and caret.* < len.*) caret.* = utf8Step(buf[0..len.*], caret.*);
        if (ui.input.keyPressed(.home)) caret.* = starts[caret_line];
        if (ui.input.keyPressed(.end)) {
            const e = starts[caret_line] + lines[caret_line].len;
            caret.* = e;
        }
        if (ui.input.keyPressed(.up) and caret_line > 0) {
            const col_w = ui.measureText(buf[starts[caret_line]..caret.*], theme.font_body).w;
            caret.* = caretFromX(ui, lines[caret_line - 1], starts[caret_line - 1], inner_x, inner_x + col_w);
        }
        if (ui.input.keyPressed(.down) and caret_line + 1 < n) {
            const col_w = ui.measureText(buf[starts[caret_line]..caret.*], theme.font_body).w;
            caret.* = caretFromX(ui, lines[caret_line + 1], starts[caret_line + 1], inner_x, inner_x + col_w);
        }
        if (ui.input.keyPressed(.enter)) {
            insertBytes(buf, len, caret.*, "\n");
            caret.* += 1;
            changed = true;
        }
        const chars = ui.input.charsSlice();
        var ci: usize = 0;
        while (ci < chars.len) {
            const clen = std.unicode.utf8ByteSequenceLength(chars[ci]) catch 1;
            if (ci + clen > chars.len) break;
            insertBytes(buf, len, caret.*, chars[ci .. ci + clen]);
            caret.* += clen;
            changed = true;
            ci += clen;
        }
    }

    widgets.ringBox(ui, rect, theme.radius_control, t.Color.hex(0xFFFFFF, 255), if (it.focused) theme.accent else theme.border);

    var lines2: [MAX_LINES][]const u8 = @splat("");
    var starts2: [MAX_LINES]usize = @splat(0);
    const n2 = if (changed) layoutLines(ui, buf[0..len.*], inner_w, &lines2, &starts2) else blk: {
        lines2 = lines;
        starts2 = starts;
        break :blk n;
    };
    var caret_line2: usize = 0;
    i = 0;
    while (i < n2) : (i += 1) {
        if (caret.* >= starts2[i]) caret_line2 = i;
    }
    const top = topLine(caret_line2, opts.rows);

    if (len.* == 0 and opts.placeholder.len > 0) {
        const pm = ui.measureText(opts.placeholder, theme.font_body);
        ui.addText(.{ .x = inner_x, .y = rect.y + opts.pad, .w = pm.w, .h = pm.h }, opts.placeholder, theme.font_body, theme.secondary);
    } else {
        var r: usize = 0;
        while (r < opts.rows and top + r < n2) : (r += 1) {
            const line = lines2[top + r];
            if (line.len == 0) continue;
            const lm = ui.measureText(line, theme.font_body);
            ui.addText(.{
                .x = inner_x,
                .y = rect.y + opts.pad + opts.line_h * @as(f32, @floatFromInt(r)),
                .w = lm.w,
                .h = lm.h,
            }, line, theme.font_body, theme.text);
        }
    }

    if (it.focused) {
        const row_in_view = caret_line2 - top;
        const prefix_w = ui.measureText(buf[starts2[caret_line2]..caret.*], theme.font_body).w;
        var cx = inner_x + prefix_w;
        if (cx > rect.x + rect.w - opts.pad) cx = rect.x + rect.w - opts.pad;
        const cy = rect.y + opts.pad + opts.line_h * @as(f32, @floatFromInt(row_in_view));
        ui.addOverlayLine(.{ .x = cx, .y = cy + 1 }, .{ .x = cx, .y = cy + opts.line_h - 3 }, 1.5, theme.text);
    }
    return changed;
}

fn topLine(caret_line: usize, rows: usize) usize {
    const r = @max(rows, 1);
    return if (caret_line + 1 > r) caret_line + 1 - r else 0;
}

fn removeRange(buf: []u8, len: *usize, from: usize, to: usize) void {
    if (to <= from or to > len.*) return;
    const n = to - from;
    var k = to;
    while (k < len.*) : (k += 1) buf[k - n] = buf[k];
    len.* -= n;
}

fn insertBytes(buf: []u8, len: *usize, at: usize, bytes: []const u8) void {
    if (at > len.*) return;
    if (len.* + bytes.len > buf.len) return;
    var k = len.*;
    while (k > at) : (k -= 1) buf[k + bytes.len - 1] = buf[k - 1];
    @memcpy(buf[at .. at + bytes.len], bytes);
    len.* += bytes.len;
}

fn caretFromX(ui: *core.Context, line: []const u8, base: usize, x0: f32, mx: f32) usize {
    var i: usize = 0;
    while (i < line.len) {
        const e = utf8Step(line, i);
        if (x0 + ui.measureText(line[0..e], theme.font_body).w > mx) return base + i;
        i = e;
    }
    return base + line.len;
}

/// 把文本排成可视行，`starts` 记录每行在缓冲区里的起始偏移。
fn layoutLines(
    ui: *core.Context,
    s: []const u8,
    max_w: f32,
    lines: *[MAX_LINES][]const u8,
    starts: *[MAX_LINES]usize,
) usize {
    var n: usize = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '\n') {
            n = wrapSegment(ui, s, seg_start, i, max_w, lines, starts, n);
            seg_start = i + 1;
        }
    }
    if (n == 0) {
        lines[0] = "";
        starts[0] = 0;
        n = 1;
    }
    return n;
}

fn wrapSegment(
    ui: *core.Context,
    s: []const u8,
    from: usize,
    to: usize,
    max_w: f32,
    lines: *[MAX_LINES][]const u8,
    starts: *[MAX_LINES]usize,
    n0: usize,
) usize {
    var n = n0;
    var a = from;
    var last_space: ?usize = null;
    var i = from;
    while (i < to) {
        const e = utf8Step(s, i);
        if (max_w > 0 and i > a and ui.measureText(s[a..e], theme.font_body).w > max_w) {
            var cut = i;
            if (last_space) |sp| {
                if (sp > a) cut = sp + 1;
            }
            if (n < lines.len) {
                lines[n] = s[a..cut];
                starts[n] = a;
                n += 1;
            }
            a = cut;
            last_space = null;
            continue;
        }
        if (s[i] == ' ') last_space = i;
        i = e;
    }
    if (n < lines.len) {
        lines[n] = s[a..to];
        starts[n] = a;
        n += 1;
    }
    return n;
}

// ------------------------------------------------------------------ search

pub const SearchOpts = struct {
    width: f32 = 260,
    placeholder: []const u8 = "Search",
};

pub const SearchResult = struct {
    /// 内容发生了变化（输入/删除/清除）。
    changed: bool = false,
    /// 本帧按了 Enter。
    submitted: bool = false,
};

/// 搜索框：前置放大镜 + 有内容时的清除按钮。返回内容变化与才考提交标志。
pub fn search(
    ui: *core.Context,
    id: []const u8,
    buf: []u8,
    len: *usize,
    caret: *usize,
    opts: SearchOpts,
) SearchResult {
    const h: f32 = 34;
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const it = ui.interactEx(sliceId(id, 0x5EA4C4), rect, true);
    const pad_x: f32 = 32;
    const right_pad: f32 = if (len.* > 0) 30 else 10;

    var changed = false;
    if (it.clicked) {
        const clr = t.Rect{ .x = rect.x + rect.w - 26, .y = rect.y + (h - 20) / 2, .w = 20, .h = 20 };
        if (len.* > 0 and clr.contains(ui.input.mouse.x, ui.input.mouse.y)) {
            len.* = 0;
            caret.* = 0;
            changed = true;
        } else {
            caret.* = caretFromXAt(ui, buf[0..len.*], rect.x + pad_x, ui.input.mouse.x);
        }
    }

    if (it.focused) {
        widgets.editKeys(ui, buf, len, caret, &changed);
    }

    const border = if (it.focused) theme.accent else theme.border;
    widgets.ringBox(ui, rect, theme.radius_control, t.Color.hex(0xFFFFFF, 255), border);

    // 放大镜：圆 + 手柄
    const gx = rect.x + 15;
    const gy = rect.y + h / 2 - 1;
    lineCircle(ui, gx, gy, 5, theme.secondary);
    ui.addOverlayLine(.{ .x = gx + 3.6, .y = gy + 3.6 }, .{ .x = gx + 7.5, .y = gy + 7.5 }, 1.4, theme.secondary);

    const content = buf[0..len.*];
    const tx = rect.x + pad_x;
    const m = ui.measureText(content, theme.font_body);
    const ty = rect.y + (h - m.h) / 2;
    if (len.* == 0) {
        const pm = ui.measureText(opts.placeholder, theme.font_body);
        ui.addText(.{ .x = tx, .y = rect.y + (h - pm.h) / 2, .w = pm.w, .h = pm.h }, opts.placeholder, theme.font_body, theme.secondary);
    } else {
        var shown = content;
        const inner_w = rect.w - pad_x - right_pad;
        if (m.w > inner_w) {
            var start: usize = content.len;
            while (start > 0) {
                const prev = prevCharStart(content, start);
                if (ui.measureText(content[prev..], theme.font_body).w > inner_w) break;
                start = prev;
            }
            shown = content[start..];
        }
        const sm = ui.measureText(shown, theme.font_body);
        ui.addText(.{ .x = tx, .y = ty, .w = sm.w, .h = sm.h }, shown, theme.font_body, theme.text);
        const clr = t.Rect{ .x = rect.x + rect.w - 26, .y = rect.y + (h - 20) / 2, .w = 20, .h = 20 };
        if (clr.contains(ui.input.mouse.x, ui.input.mouse.y)) {
            ui.addBox(clr, .{ .fill = theme.surface, .radius = 5 });
        }
        crossIcon(ui, clr, theme.secondary);
    }

    if (it.focused) {
        const cm = ui.measureText(buf[0..caret.*], theme.font_body);
        var cx = tx + cm.w;
        const limit = rect.x + rect.w - right_pad;
        if (cx > limit) cx = limit;
        ui.addOverlayLine(.{ .x = cx, .y = rect.y + 8 }, .{ .x = cx, .y = rect.y + h - 8 }, 1.5, theme.text);
    }
    return .{ .changed = changed, .submitted = ui.input.keyPressed(.enter) and it.focused };
}

fn caretFromXAt(ui: *core.Context, s: []const u8, x0: f32, mx: f32) usize {
    var i: usize = 0;
    while (i < s.len) {
        const e = utf8Step(s, i);
        if (x0 + ui.measureText(s[0..e], theme.font_body).w > mx) return i;
        i = e;
    }
    return s.len;
}

// ------------------------------------------------------------------ number

pub const NumberOpts = struct {
    width: f32 = 160,
    min: f32 = 0,
    max: f32 = 100,
    step: f32 = 1,
    decimals: u8 = 0,
    suffix: []const u8 = "",
    label: []const u8 = "",
};

/// 数字输入：值 + 内嵌 −/+ 按钮；聚焦时上下键按 step 步进，越界夹取。返回是否变化。
pub fn number(ui: *core.Context, id: []const u8, value: *f32, opts: NumberOpts) bool {
    if (opts.label.len > 0) {
        const lm = ui.measureText(opts.label, theme.font_small);
        const lr = ui.reserve(lm.w, lm.h + 2, false);
        ui.addText(.{ .x = lr.x, .y = lr.y, .w = lm.w, .h = lm.h }, opts.label, theme.font_small, theme.secondary);
    }
    const h: f32 = 34;
    const rect = ui.reserve(opts.width, h, false);
    const it = ui.interactEx(sliceId(id, 0x4E554D), rect, true);
    const old = value.*;

    var txt: [48]u8 = @splat(0);
    const s = fmtNumber(&txt, value.*, opts.decimals);
    const sm = ui.measureText(s, theme.font_body);

    const btn: f32 = 24;
    const dec_rect = t.Rect{ .x = rect.x + rect.w - btn * 2 - 6, .y = rect.y + (h - btn) / 2, .w = btn, .h = btn };
    const inc_rect = t.Rect{ .x = rect.x + rect.w - btn - 4, .y = rect.y + (h - btn) / 2, .w = btn, .h = btn };
    const hit_dec = ui.interactEx(sliceId(id, 0x4E5541), dec_rect, false).clicked;
    const hit_inc = ui.interactEx(sliceId(id, 0x4E5542), inc_rect, false).clicked;
    if (hit_dec) value.* -= opts.step;
    if (hit_inc) value.* += opts.step;
    if (it.focused) {
        if (ui.input.keyPressed(.up)) value.* += opts.step;
        if (ui.input.keyPressed(.down)) value.* -= opts.step;
    }
    if (value.* < opts.min) value.* = opts.min;
    if (value.* > opts.max) value.* = opts.max;

    widgets.ringBox(ui, rect, theme.radius_control, t.Color.hex(0xFFFFFF, 255), if (it.focused) theme.accent else theme.border);
    ui.addText(.{ .x = rect.x + 10, .y = rect.y + (h - sm.h) / 2, .w = sm.w, .h = sm.h }, ui.frameStr(s), theme.font_body, theme.text);
    if (opts.suffix.len > 0) {
        const um = ui.measureText(opts.suffix, theme.font_small);
        ui.addText(.{ .x = rect.x + 12 + sm.w, .y = rect.y + (h - um.h) / 2, .w = um.w, .h = um.h }, opts.suffix, theme.font_small, theme.secondary);
    }

    // 内嵌 +/−（按下态反馈）
    for ([_]t.Rect{ dec_rect, inc_rect }) |b| {
        if (b.contains(ui.input.mouse.x, ui.input.mouse.y)) ui.addBox(b, .{ .fill = theme.track, .radius = 6 });
    }
    ui.addOverlayLine(.{ .x = dec_rect.x + 6, .y = dec_rect.y + btn / 2 }, .{ .x = dec_rect.x + btn - 6, .y = dec_rect.y + btn / 2 }, 1.6, theme.text);
    const icy = inc_rect.y + btn / 2;
    const icx = inc_rect.x + btn / 2;
    ui.addOverlayLine(.{ .x = icx - 6, .y = icy }, .{ .x = icx + 6, .y = icy }, 1.6, theme.text);
    ui.addOverlayLine(.{ .x = icx, .y = icy - 6 }, .{ .x = icx, .y = icy + 6 }, 1.6, theme.text);

    return value.* != old;
}

fn fmtNumber(buf: []u8, v: f32, decimals: u8) []const u8 {
    return switch (decimals) {
        0 => std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(@round(v)))}) catch "",
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{v}) catch "",
        2 => std.fmt.bufPrint(buf, "{d:.2}", .{v}) catch "",
        else => std.fmt.bufPrint(buf, "{d:.3}", .{v}) catch "",
    };
}
