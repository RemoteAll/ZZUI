//! 文本编辑族（对位 CUI 的 `cui_textedit.c` 公开件）：多行文本域 / 搜索框 / 数字输入。
//! 与 `widgets.input` 同一口径：缓冲、长度、光标都由调用方保存，按字节计。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const num = @import("num.zig");
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
    /// 剪贴板（Ctrl+C/X/V）。null = 不碰剪贴板，其余编辑行为不变。
    clipboard: ?*const core.Clipboard = null,
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
    const pid = sliceId(id, 0x7A47E);
    const it = ui.interactEx(pid, rect, true);
    const inner_x = rect.x + opts.pad;
    const inner_w = rect.w - opts.pad * 2;

    var changed = false;
    if (caret.* > len.*) caret.* = len.*;
    // 选区锚点 / 连击：与 `widgets.input` 共用同一套「按 id 的编辑状态池」
    const st = ui.editState(pid);
    if (st.anchor > len.*) st.anchor = len.*;

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

    // 按下定位 + 连击（双击选词、三击全选），按住拖动扩选（与 `widgets.input` 同口径）
    if (inner_w > 0 and (it.pressed or it.dragging)) {
        if (it.pressed) {
            const top_now = topLine(caret_line, opts.rows);
            var row_i: usize = 0;
            if (ui.input.mouse.y > rect.y + opts.pad) {
                row_i = @intFromFloat((ui.input.mouse.y - rect.y - opts.pad) / opts.line_h);
            }
            const target = @min(top_now + row_i, n - 1);
            caret.* = caretFromX(ui, lines[target], starts[target], inner_x, ui.input.mouse.x);
            caret_line = target;
            const now = ui.time;
            st.clicks = if (st.clicks > 0 and now - st.last_click <= 0.42) st.clicks +| 1 else 1;
            st.last_click = now;
            if (st.clicks == 2) {
                const w = widgets.wordRange(buf[0..len.*], caret.*);
                st.anchor = w.start;
                caret.* = w.end;
            } else if (st.clicks >= 3) {
                st.anchor = 0;
                caret.* = len.*;
                st.clicks = 0;
            } else {
                st.anchor = caret.*;
            }
        } else {
            // 按住拖动：锚点不动，插入符跟着鼠标走
            const top_now = topLine(caret_line, opts.rows);
            var row_i: usize = 0;
            if (ui.input.mouse.y > rect.y + opts.pad) {
                row_i = @intFromFloat((ui.input.mouse.y - rect.y - opts.pad) / opts.line_h);
            }
            const target = @min(top_now + row_i, n - 1);
            caret.* = caretFromX(ui, lines[target], starts[target], inner_x, ui.input.mouse.x);
            caret_line = target;
        }
        // 选中后光标可能跨行了，重算一次
        i = 0;
        while (i < n) : (i += 1) {
            if (caret.* >= starts[i]) caret_line = i;
        }
    }

    // 键盘编辑（有选区时先按选区语义处理）
    if (it.focused) {
        const shift = ui.input.mods.shift;
        const ctrl = ui.input.mods.ctrl;
        const a0 = @min(st.anchor, caret.*);
        const b0 = @max(st.anchor, caret.*);
        const has_sel = b0 > a0;

        if (ctrl and ui.input.keyPressed(.A)) {
            st.anchor = 0;
            caret.* = len.*;
        } else if (ctrl and opts.clipboard != null and
            (ui.input.keyPressed(.C) or ui.input.keyPressed(.X) or ui.input.keyPressed(.V)))
        {
            const cb = opts.clipboard.?;
            if (ui.input.keyPressed(.C)) {
                if (has_sel) {
                    if (cb.set) |set| set(cb.ctx, buf[a0..b0]);
                }
            } else if (ui.input.keyPressed(.X)) {
                if (has_sel) {
                    if (cb.set) |set| set(cb.ctx, buf[a0..b0]);
                    removeRange(buf, len, a0, b0);
                    caret.* = a0;
                    changed = true;
                }
            } else if (cb.get) |get| {
                var tmp: [1024]u8 = undefined;
                const cn = get(cb.ctx, tmp[0..]);
                if (cn > 0 and cn <= tmp.len and len.* - (b0 - a0) + cn <= buf.len) {
                    removeRange(buf, len, a0, b0);
                    insertBytes(buf, len, a0, tmp[0..cn]);
                    caret.* = a0 + cn;
                    changed = true;
                }
            }
        } else {
            if (has_sel and (ui.input.keyPressed(.backspace) or ui.input.keyPressed(.delete))) {
                removeRange(buf, len, a0, b0);
                caret.* = a0;
                changed = true;
            } else if (!has_sel) {
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
            }
            // 方向键 / Home / End / 上下：Shift = 只挪插入符（扩选），否则塌缩到选区边界
            if (ui.input.keyPressed(.left)) {
                caret.* = if (has_sel and !shift) a0 else prevCharStart(buf[0..len.*], caret.*);
            }
            if (ui.input.keyPressed(.right)) {
                if (has_sel and !shift) {
                    caret.* = b0;
                } else if (caret.* < len.*) {
                    // utf8Step 会读 s[i]：必须自己守上界（光标在末尾时右移就是不动）
                    caret.* = utf8Step(buf[0..len.*], caret.*);
                }
            }
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
                if (has_sel) {
                    const s0 = @min(st.anchor, caret.*);
                    const s1 = @max(st.anchor, caret.*);
                    removeRange(buf, len, s0, s1);
                    caret.* = s0;
                }
                insertBytes(buf, len, caret.*, "\n");
                caret.* += 1;
                changed = true;
            }
            const chars = ui.input.charsSlice();
            if (chars.len > 0) {
                if (has_sel) {
                    const s0 = @min(st.anchor, caret.*);
                    const s1 = @max(st.anchor, caret.*);
                    removeRange(buf, len, s0, s1);
                    caret.* = s0;
                    changed = true;
                }
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
            // Shift 扩选时保留锚点；其余情况锚点跟着插入符走
            // （注意：这一行只能留在本分支里 —— 放到 if/else 外面会把 Ctrl+A 刚建好的选区立刻塌缩）
            if (!shift or changed) st.anchor = caret.*;
        }
    }

    widgets.ringBox(ui, rect, theme.radius_control, theme.bg, if (it.focused) theme.accent else theme.border);

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

    // 选区底色：按可视行分段画（跨行、整行选中、含换行符都连续）
    const sa = @min(st.anchor, caret.*);
    const sb = @max(st.anchor, caret.*);
    if (it.focused and sb > sa) {
        var r: usize = 0;
        while (r < opts.rows and top + r < n2) : (r += 1) {
            const li = top + r;
            const ls = starts2[li];
            const le = ls + lines2[li].len;
            if (le < sa or ls > sb) continue;
            const from = @max(ls, sa);
            const to = @min(le, sb);
            var x0 = inner_x + ui.measureText(buf[ls..from], theme.font_body).w;
            var x1 = inner_x + ui.measureText(buf[ls..to], theme.font_body).w;
            // 选区含这行的换行符时给 4px 宽度，否则跨行看着断开
            if (to == le and sb > le) x1 += 4;
            if (x0 < inner_x) x0 = inner_x;
            const max_x = rect.x + rect.w - opts.pad;
            if (x1 > max_x) x1 = max_x;
            if (x1 <= x0) continue;
            ui.addBox(.{
                .x = x0,
                .y = rect.y + opts.pad + opts.line_h * @as(f32, @floatFromInt(r)) + 2,
                .w = x1 - x0,
                .h = opts.line_h - 4,
            }, .{ .fill = theme.withAlpha(theme.accent, 64), .radius = 2 });
        }
    }

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
        const bar = t.Rect{ .x = cx, .y = cy + 1, .w = 1.5, .h = opts.line_h - 4 };
        ui.addOverlayLine(.{ .x = bar.x, .y = bar.y }, .{ .x = bar.x, .y = bar.y + bar.h }, 1.5, theme.text);
        ui.noteCaret(bar);
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
    /// 剪贴板（Ctrl+C/X/V）。null = 不碰剪贴板，其余编辑行为不变。
    clipboard: ?*const core.Clipboard = null,
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
    const pid = sliceId(id, 0x5EA4C4);
    const it = ui.interactEx(pid, rect, true);
    const pad_x: f32 = 32;
    const right_pad: f32 = if (len.* > 0) 30 else 10;

    var changed = false;
    if (len.* > buf.len) len.* = buf.len;
    if (caret.* > len.*) caret.* = len.*;
    // 选区状态与 `widgets.input` 同一套（按 id 的编辑状态池）
    const st = ui.editState(pid);
    if (st.anchor > len.*) st.anchor = len.*;

    // 按下定位 + 连击（双击选词、三击全选），按住拖动扩选
    if (it.pressed) {
        caret.* = caretFromXAt(ui, buf[0..len.*], rect.x + pad_x, ui.input.mouse.x);
        const now = ui.time;
        st.clicks = if (st.clicks > 0 and now - st.last_click <= 0.42) st.clicks +| 1 else 1;
        st.last_click = now;
        if (st.clicks == 2) {
            const w = widgets.wordRange(buf[0..len.*], caret.*);
            st.anchor = w.start;
            caret.* = w.end;
        } else if (st.clicks >= 3) {
            st.anchor = 0;
            caret.* = len.*;
            st.clicks = 0;
        } else {
            st.anchor = caret.*;
        }
    } else if (it.dragging) {
        caret.* = caretFromXAt(ui, buf[0..len.*], rect.x + pad_x, ui.input.mouse.x);
    }

    if (it.clicked) {
        const clr = t.Rect{ .x = rect.x + rect.w - 26, .y = rect.y + (h - 20) / 2, .w = 20, .h = 20 };
        if (len.* > 0 and clr.contains(ui.input.mouse.x, ui.input.mouse.y)) {
            len.* = 0;
            caret.* = 0;
            st.anchor = 0;
            changed = true;
        }
    }

    if (it.focused) {
        if (widgets.editKeysSel(ui, st, buf, len, caret, opts.clipboard)) changed = true;
    }

    const border = if (it.focused) theme.accent else theme.border;
    widgets.ringBox(ui, rect, theme.radius_control, theme.bg, border);

    // 放大镜：圆 + 手柄
    const gx = rect.x + 15;
    const gy = rect.y + h / 2 - 1;
    lineCircle(ui, gx, gy, 5, theme.secondary);
    ui.addOverlayLine(.{ .x = gx + 3.6, .y = gy + 3.6 }, .{ .x = gx + 7.5, .y = gy + 7.5 }, 1.4, theme.secondary);

    const content = buf[0..len.*];
    const tx = rect.x + pad_x;

    // 选区底色：压在文字下面（节点顺序即绘制顺序）
    const sa = @min(st.anchor, caret.*);
    const sb = @max(st.anchor, caret.*);
    if (it.focused and sb > sa) {
        const limit = rect.x + rect.w - right_pad;
        const x0 = @min(tx + ui.measureText(buf[0..sa], theme.font_body).w, limit);
        const x1 = @min(tx + ui.measureText(buf[0..sb], theme.font_body).w, limit);
        if (x1 > x0) ui.addBox(
            .{ .x = x0, .y = rect.y + 7, .w = x1 - x0, .h = h - 14 },
            .{ .fill = theme.withAlpha(theme.accent, 64), .radius = 3 },
        );
    }

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

    widgets.ringBox(ui, rect, theme.radius_control, theme.bg, if (it.focused) theme.accent else theme.border);
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
    return num.fixed(buf, v, decimals);
}
