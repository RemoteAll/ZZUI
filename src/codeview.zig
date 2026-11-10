//! 代码呈现族（对位 CUI `cui_code.c` / `cui_hex.c`）：
//! 代码块（行号 / 高亮行 / 滚动）、JSON 树视图（可逐层展开）、十六进制视图（带选区和 ASCII 列）。
//!
//! 三者都用**等宽字体**（`Context.addMonoText`），因此字符网格可以直接按「单字符宽度 × 序号」定位 ——
//! 这也是十六进制视图能精确选中字节的前提。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const num = @import("num.zig");
const t = @import("types.zig");

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

/// 等宽字符宽度（用一串等宽字符测量再平均，避免单字符 hinting 误差）。
fn charW(ui: *core.Context, size: f32) f32 {
    const probe = "00000000";
    return ui.measureText(probe, size).w / @as(f32, @floatFromInt(probe.len));
}

fn lineH(ui: *core.Context, size: f32) f32 {
    const m = ui.measureText("Ag", size);
    return if (m.h > 0) m.h + 3 else size * 1.4;
}

/// 按 `\n` 切行（返回写入 `out` 的行数；超出容量时截断）。
fn splitLines(text: []const u8, out: *[core.MAX_LINES][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            if (n < out.len) {
                out[n] = text[start..i];
                n += 1;
            } else return n;
            start = i + 1;
        }
    }
    return n;
}

// ------------------------------------------------------------------ 代码块
pub const CodeOpts = struct {
    /// 语言标签（显示在标题栏右侧）。
    lang: []const u8 = "zig",
    /// 标题（通常是文件名）。
    title: []const u8 = "",
    line_numbers: bool = true,
    /// 1 基行号的强调区间。
    highlight_from: usize = 0,
    highlight_to: usize = 0,
    /// > 0 时超出高度出现滚动。
    max_height: f32 = 0,
    size: f32 = 12,
    /// 即使有 lang 也不画标题栏。
    no_header: bool = false,
};

/// 代码块（CUI `cui_code_block`）：标题栏 + 行号 + 等宽正文，可滚动。
pub fn codeBlock(ui: *core.Context, id: []const u8, code: []const u8, opts: CodeOpts) void {
    var lines: [core.MAX_LINES][]const u8 = undefined;
    const n = splitLines(code, &lines);
    const lh = lineH(ui, opts.size);
    const cw = charW(ui, opts.size);
    const header_h: f32 = if (!opts.no_header and (opts.title.len > 0 or opts.lang.len > 0)) 26 else 0;
    const pad: f32 = 10;
    const num_w: f32 = if (opts.line_numbers) cw * 4 + 8 else 0;

    // 正文宽：取最长行
    var max_w: f32 = 0;
    for (lines[0..n]) |ln| {
        const w = cw * @as(f32, @floatFromInt(ln.len));
        if (w > max_w) max_w = w;
    }
    const content_h = lh * @as(f32, @floatFromInt(if (n > 0) n else 1));
    const body_h = if (opts.max_height > 0 and content_h > opts.max_height) opts.max_height else content_h;
    const total_h = header_h + body_h + pad * 2;

    var rect = ui.reserve(0, total_h, true);
    rect.w = if (rect.w > 0) rect.w else max_w + num_w + pad * 2;
    ui.addBox(rect, .{ .fill = t.Color.hex(0x0D1117, 255), .radius = 8 });

    if (header_h > 0) {
        ui.addBox(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = header_h }, .{ .fill = t.Color.hex(0x161B22, 255), .radius = 8 });
        const tm = ui.measureText(opts.title, theme.font_small);
        if (opts.title.len > 0) {
            ui.addText(
                .{ .x = rect.x + pad, .y = rect.y + (header_h - tm.h) / 2, .w = tm.w, .h = tm.h },
                opts.title,
                theme.font_small,
                t.Color.hex(0xC9D1D9, 255),
            );
        }
        if (opts.lang.len > 0) {
            const lm = ui.measureText(opts.lang, theme.font_small);
            ui.addText(
                .{ .x = rect.x + rect.w - lm.w - pad, .y = rect.y + (header_h - lm.h) / 2, .w = lm.w, .h = lm.h },
                opts.lang,
                theme.font_small,
                t.Color.hex(0x8B949E, 255),
            );
        }
    }

    const body_y = rect.y + header_h + pad;
    const body_rect = t.Rect{ .x = rect.x, .y = rect.y + header_h, .w = rect.w, .h = body_h };

    if (opts.max_height > 0 and content_h > opts.max_height) {
        // 滚动区：每行先占位再在自己的矩形里画，行号与高亮跟着走
        var sc = ui.scroll(.{ .id = id, .height = body_h, .pad = pad, .gap = 0 });
        defer sc.end();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const lr = ui.reserve(0, lh, true);
            drawCodeLineAt(ui, lines[i], i + 1, opts, cw, lh, num_w, 0, lr.x, lr.y, lr.w);
        }
    } else {
        ui.clip = body_rect;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const y = body_y + lh * @as(f32, @floatFromInt(i));
            drawCodeLineAt(ui, lines[i], i + 1, opts, cw, lh, num_w, pad, rect.x, y, rect.w);
        }
        ui.clip = null;
    }
}

fn drawCodeLineAt(
    ui: *core.Context,
    ln: []const u8,
    lineno: usize,
    opts: CodeOpts,
    cw: f32,
    lh: f32,
    num_w: f32,
    pad: f32,
    x0: f32,
    y: f32,
    row_w: f32,
) void {
    if (opts.highlight_from > 0 and lineno >= opts.highlight_from and lineno <= opts.highlight_to) {
        ui.addBox(.{ .x = x0, .y = y - 1, .w = row_w, .h = lh + 2 }, .{ .fill = t.Color.hex(0x1F6FEB, 60) });
    }
    if (opts.line_numbers) {
        var nb: [12]u8 = undefined;
        const nt = ui.frameStr(num.int(&nb, @intCast(lineno)));
        const nw = cw * @as(f32, @floatFromInt(nt.len));
        ui.addMonoText(
            .{ .x = x0 + pad + num_w - nw - 8, .y = y, .w = nw, .h = lh },
            nt,
            opts.size,
            t.Color.hex(0x6E7681, 255),
        );
    }
    ui.addMonoText(
        .{ .x = x0 + pad + num_w, .y = y, .w = cw * @as(f32, @floatFromInt(ln.len)), .h = lh },
        ln,
        opts.size,
        t.Color.hex(0xE6EDF3, 255),
    );
}

// ------------------------------------------------------------------ JSON 视图
pub const JsonOpts = struct {
    /// 初始展开到第几层（0 = 只显示根）。
    expand_depth: usize = 1,
    max_height: f32 = 0,
    size: f32 = 12,
};

pub const JsonState = struct {
    /// 位图：第 i 行容器是否展开。
    expanded: u64 = 0,
    /// 首次调用时按 `expand_depth` 初始化（之后尊重用户的展开状态）。
    inited: bool = false,
};

const JsonLine = struct {
    depth: usize,
    /// 行文本（已含缩进前的纯内容）。
    text: []const u8,
    /// 以 `{` / `[` 结尾 → 可作为容器折叠。
    container: bool,
    /// 本行是否是容器的收尾行（`}` / `]` / `},`），不参与折叠三角。
    closer: bool,
};

fn flushLine(ui: *core.Context, b: []const u8, d: usize, dst: *[core.MAX_LINES]JsonLine, cnt: *usize) void {
    var trimmed = b;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == ' ' or trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r' or trimmed[trimmed.len - 1] == '\t')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\n' or trimmed[0] == '\r' or trimmed[0] == '\t')) {
        trimmed = trimmed[1..];
    }
    if (trimmed.len == 0 or cnt.* >= dst.len) return;
    const is_container = trimmed[trimmed.len - 1] == '{' or trimmed[trimmed.len - 1] == '[';
    const is_closer = trimmed[0] == '}' or trimmed[0] == ']';
    dst[cnt.*] = .{
        .depth = d,
        .text = ui.frameStr(trimmed),
        .container = is_container,
        .closer = is_closer,
    };
    cnt.* += 1;
}

/// 把 JSON 压成「行 + 深度」，并标记容器行（不做语义校验，纯排版）。
fn beautify(ui: *core.Context, json: []const u8, out: *[core.MAX_LINES]JsonLine) usize {
    var n: usize = 0;
    var depth: usize = 0;
    var buf: [256]u8 = @splat(0);
    var blen: usize = 0;
    var in_str = false;
    var esc = false;

    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        const ch = json[i];
        if (in_str) {
            if (blen < buf.len) {
                buf[blen] = ch;
                blen += 1;
            }
            if (esc) {
                esc = false;
            } else if (ch == '\\') {
                esc = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        switch (ch) {
            '"' => {
                in_str = true;
                if (blen < buf.len) {
                    buf[blen] = ch;
                    blen += 1;
                }
            },
            '{', '[' => {
                if (blen < buf.len) {
                    buf[blen] = ch;
                    blen += 1;
                }
                flushLine(ui, buf[0..blen], depth, out, &n);
                blen = 0;
                depth += 1;
            },
            '}', ']' => {
                flushLine(ui, buf[0..blen], depth, out, &n);
                blen = 0;
                if (depth > 0) depth -= 1;
                if (blen < buf.len) {
                    buf[blen] = ch;
                    blen += 1;
                }
                // 收尾行可能带逗号，留到下一个字符一起冲刷
                if (i + 1 < json.len and json[i + 1] == ',') {
                    if (blen < buf.len) {
                        buf[blen] = ',';
                        blen += 1;
                    }
                    i += 1;
                }
                flushLine(ui, buf[0..blen], depth, out, &n);
                blen = 0;
            },
            ',' => {
                if (blen < buf.len) {
                    buf[blen] = ch;
                    blen += 1;
                }
                flushLine(ui, buf[0..blen], depth, out, &n);
                blen = 0;
            },
            ' ', '\t', '\r', '\n' => {},
            else => {
                if (blen < buf.len) {
                    buf[blen] = ch;
                    blen += 1;
                }
            },
        }
    }
    flushLine(ui, buf[0..blen], depth, out, &n);
    return n;
}

/// JSON 树视图（CUI `cui_json_view`）：按缩进展示键值，点行首三角折叠/展开容器。
/// 返回 true 表示本帧有展开/折叠操作。
pub fn jsonView(ui: *core.Context, id: []const u8, json: []const u8, state: *JsonState, opts: JsonOpts) bool {
    var lines: [core.MAX_LINES]JsonLine = undefined;
    const n = beautify(ui, json, &lines);

    if (!state.inited) {
        state.inited = true;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (lines[i].container and lines[i].depth <= opts.expand_depth) state.expanded |= (@as(u64, 1) << @intCast(i));
        }
    }

    const cw = charW(ui, opts.size);
    const lh = lineH(ui, opts.size);
    const pad: f32 = 10;
    const total_h = lh * @as(f32, @floatFromInt(if (n > 0) n else 1)) + pad * 2;
    const rect = ui.reserve(0, total_h, true);
    ui.addBox(rect, .{ .fill = theme.bg, .radius = 6, .border = theme.border });

    var changed = false;
    var hidden_depth: ?usize = null;
    var y = rect.y + pad;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ln = lines[i];
        if (hidden_depth) |hd| {
            if (ln.depth > hd) continue;
            hidden_depth = null;
        }
        const indent = cw * 2 * @as(f32, @floatFromInt(ln.depth));
        const ty = y;
        y += lh;

        if (ln.container) {
            const tri = t.Rect{ .x = rect.x + pad + indent, .y = ty, .w = 14, .h = lh };
            const hit = ui.interactEx(idOf(id, 0x1500) +% i, tri, true);
            // 先处理点击，再决定本帧的展开态：点击当帧就折/展，视觉无延迟
            var open = (state.expanded & (@as(u64, 1) << @intCast(i))) != 0;
            if (hit.clicked or hit.activated) {
                state.expanded ^= (@as(u64, 1) << @intCast(i));
                open = !open;
                changed = true;
            }
            const cy = ty + lh / 2;
            if (open) {
                ui.addOverlayLine(.{ .x = tri.x + 3, .y = cy + 2 }, .{ .x = tri.x + 7, .y = cy - 2 }, 1.4, theme.secondary);
                ui.addOverlayLine(.{ .x = tri.x + 7, .y = cy - 2 }, .{ .x = tri.x + 11, .y = cy + 2 }, 1.4, theme.secondary);
            } else {
                ui.addOverlayLine(.{ .x = tri.x + 5, .y = cy - 3 }, .{ .x = tri.x + 9, .y = cy }, 1.4, theme.secondary);
                ui.addOverlayLine(.{ .x = tri.x + 9, .y = cy }, .{ .x = tri.x + 5, .y = cy + 3 }, 1.4, theme.secondary);
            }
            if (!open) hidden_depth = ln.depth;
        }
        const text_x = rect.x + pad + indent + (if (ln.container) @as(f32, 14) else 0);
        ui.addMonoText(
            .{ .x = text_x, .y = ty, .w = cw * @as(f32, @floatFromInt(ln.text.len)), .h = lh },
            ln.text,
            opts.size,
            if (ln.closer) theme.secondary else theme.text,
        );
    }
    return changed;
}

// ------------------------------------------------------------------ 十六进制
pub const HexSelection = struct {
    start: usize = 0,
    length: usize = 0,
    cursor: usize = 0,
};

pub const HexRange = struct {
    offset: usize,
    length: usize,
    color: t.Color = .{ .r = 0x1F, .g = 0x6F, .b = 0xEB, .a = 70 },
};

pub const HexOpts = struct {
    /// 0 = 撑满父宽。
    width: f32 = 0,
    /// 0 = 按行数（最多 320）；负数 = 撑满可用高度。
    height: f32 = 0,
    /// 偏移列显示的起始地址。
    base: u64 = 0,
    /// 8 / 16 / 32。
    bytes_per_row: usize = 16,
    ranges: []const HexRange = &.{},
    no_ascii: bool = false,
    no_header: bool = false,
    size: f32 = 12,
};

pub const HexResult = struct {
    selection: HexSelection = .{},
    selection_changed: bool = false,
    hovered: i64 = -1,
    /// 本帧 Ctrl+C（调用方自行写剪贴板）。
    copied: bool = false,
};

const HEX_MONO_SIZE: f32 = 12;

/// 十六进制视图（CUI `cui_hex_view`）：偏移列 + 字节列 + ASCII 列，点击选中字节。
pub fn hexView(
    ui: *core.Context,
    id: []const u8,
    data: []const u8,
    sel: *HexSelection,
    opts: HexOpts,
) HexResult {
    const bpr = if (opts.bytes_per_row == 8 or opts.bytes_per_row == 16 or opts.bytes_per_row == 32) opts.bytes_per_row else 16;
    const cw = charW(ui, opts.size);
    const lh = lineH(ui, opts.size);
    const rows = (data.len + bpr - 1) / bpr;
    const header_h: f32 = if (opts.no_header) 0 else lh + 4;
    const ascii_w: f32 = if (opts.no_ascii) 0 else cw * (@as(f32, @floatFromInt(bpr)) + 2) + 8;
    const offset_w = cw * 9;
    const bytes_w = cw * (@as(f32, @floatFromInt(bpr)) * 3 - 1);
    const want_w = offset_w + bytes_w + ascii_w + 20;
    const rows_h = lh * @as(f32, @floatFromInt(if (rows > 0) rows else 1));

    var h: f32 = header_h + rows_h + 8;
    if (opts.height < 0) {
        h = -opts.height;
    } else if (opts.height > 0 and opts.height < h) {
        h = opts.height;
    } else if (rows_h > 320) {
        h = header_h + 320 + 8;
    }
    const rect = ui.reserve(if (opts.width > 0) opts.width else want_w, h, opts.width <= 0);
    const it = ui.interactEx(idOf(id, 0x4E8), rect, true);

    var res = HexResult{ .selection = sel.* };
    ui.addBox(rect, .{ .fill = theme.bg, .radius = 4, .border = theme.border });

    var body_clip_h = rect.h - header_h - 5;
    if (body_clip_h < lh) body_clip_h = lh;

    // 指针悬停 → 字节下标
    if (it.hover) {
        const rel_x = ui.input.mouse.x - (rect.x + 8 + offset_w);
        const rel_y = ui.input.mouse.y - (rect.y + header_h + 3);
        if (rel_x >= 0 and rel_y >= 0) {
            const byte_col: usize = @intFromFloat(rel_x / (cw * 3));
            const row_i: usize = @intFromFloat(rel_y / lh);
            if (byte_col < bpr) {
                const idx = row_i * bpr + byte_col;
                if (idx < data.len) res.hovered = @intCast(idx);
            }
        }
    }
    if (it.clicked and res.hovered >= 0) {
        const idx: usize = @intCast(res.hovered);
        if (ui.input.mods.shift) {
            const lo = @min(idx, sel.cursor);
            const hi = @max(idx, sel.cursor);
            sel.start = lo;
            sel.length = hi - lo + 1;
        } else {
            sel.start = idx;
            sel.length = 1;
            sel.cursor = idx;
        }
        res.selection = sel.*;
        res.selection_changed = true;
    }
    if (it.focused) {
        if (ui.input.keyPressed(.left) and sel.cursor > 0) {
            sel.cursor -= 1;
            if (!ui.input.mods.shift) {
                sel.start = sel.cursor;
                sel.length = 1;
            }
            res.selection_changed = true;
        }
        if (ui.input.keyPressed(.right) and sel.cursor + 1 < data.len) {
            sel.cursor += 1;
            if (!ui.input.mods.shift) {
                sel.start = sel.cursor;
                sel.length = 1;
            }
            res.selection_changed = true;
        }
        if (ui.input.mods.ctrl and (ui.input.keyPressed(.C))) res.copied = true;
    }

    // 表头：偏移 + 00 01 .. 0F
    if (!opts.no_header) {
        var hb: [16]u8 = undefined;
        const ht = num.fixed(&hb, 0, 0);
        _ = ht;
        ui.addMonoText(
            .{ .x = rect.x + 8, .y = rect.y + 3, .w = offset_w, .h = lh },
            "offset",
            opts.size,
            theme.secondary,
        );
        var col: usize = 0;
        while (col < bpr) : (col += 1) {
            var cb: [4]u8 = undefined;
            cb[0] = hexDigit(@intCast((col >> 4) & 0xF));
            cb[1] = hexDigit(@intCast(col & 0xF));
            ui.addMonoText(
                .{
                    .x = rect.x + 8 + offset_w + cw * 3 * @as(f32, @floatFromInt(col)),
                    .y = rect.y + 3,
                    .w = cw * 2,
                    .h = lh,
                },
                ui.frameStr(cb[0..2]),
                opts.size,
                theme.secondary,
            );
        }
    }

    // 正文（裁剪到 body 区域）
    ui.clip = .{ .x = rect.x + 1, .y = rect.y + header_h, .w = rect.w - 2, .h = body_clip_h };

    // 高亮区（选区 + 自定义范围）
    if (sel.length > 0) {
        var k: usize = 0;
        while (k < sel.length) : (k += 1) {
            const idx = sel.start + k;
            if (idx >= data.len) break;
            const ry = rect.y + header_h + 3 + lh * @as(f32, @floatFromInt(idx / bpr));
            const rx = rect.x + 8 + offset_w + cw * 3 * @as(f32, @floatFromInt(idx % bpr));
            ui.addBox(.{ .x = rx - 1, .y = ry, .w = cw * 2 + 2, .h = lh }, .{ .fill = t.Color.hex(0x2563EB, 60) });
            if (!opts.no_ascii) {
                const ax = rect.x + rect.w - 8 - ascii_w + cw * @as(f32, @floatFromInt(idx % bpr));
                ui.addBox(.{ .x = ax - 1, .y = ry, .w = cw + 2, .h = lh }, .{ .fill = t.Color.hex(0x2563EB, 60) });
            }
        }
    }
    for (opts.ranges) |rg| {
        var k: usize = 0;
        while (k < rg.length) : (k += 1) {
            const idx = rg.offset + k;
            if (idx >= data.len) break;
            const ry = rect.y + header_h + 3 + lh * @as(f32, @floatFromInt(idx / bpr));
            const rx = rect.x + 8 + offset_w + cw * 3 * @as(f32, @floatFromInt(idx % bpr));
            ui.addBox(.{ .x = rx - 1, .y = ry, .w = cw * 2 + 2, .h = lh }, .{ .fill = rg.color });
        }
    }

    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const ry = rect.y + header_h + 3 + lh * @as(f32, @floatFromInt(row));
        if (ry > rect.y + rect.h) break;
        var ob: [20]u8 = undefined;
        const ot = hexOffset(&ob, opts.base + @as(u64, @intCast(row * bpr)));
        ui.addMonoText(
            .{ .x = rect.x + 8, .y = ry, .w = cw * @as(f32, @floatFromInt(ot.len)), .h = lh },
            ui.frameStr(ot),
            opts.size,
            theme.secondary,
        );
        var col: usize = 0;
        while (col < bpr) : (col += 1) {
            const idx = row * bpr + col;
            if (idx >= data.len) break;
            var bb: [3]u8 = undefined;
            bb[0] = hexDigit(data[idx] >> 4);
            bb[1] = hexDigit(data[idx] & 0xF);
            ui.addMonoText(
                .{
                    .x = rect.x + 8 + offset_w + cw * 3 * @as(f32, @floatFromInt(col)),
                    .y = ry,
                    .w = cw * 2,
                    .h = lh,
                },
                ui.frameStr(bb[0..2]),
                opts.size,
                theme.text,
            );
        }
        if (!opts.no_ascii) {
            var ac: [40]u8 = @splat(0);
            var an: usize = 0;
            var k: usize = 0;
            while (k < bpr) : (k += 1) {
                const idx = row * bpr + k;
                if (idx >= data.len) break;
                const ch = data[idx];
                ac[an] = if (ch >= 0x20 and ch < 0x7F) ch else '.';
                an += 1;
            }
            ui.addMonoText(
                .{
                    .x = rect.x + rect.w - 8 - ascii_w + cw,
                    .y = ry,
                    .w = cw * @as(f32, @floatFromInt(an)),
                    .h = lh,
                },
                ui.frameStr(ac[0..an]),
                opts.size,
                theme.secondary,
            );
        }
    }
    ui.clip = null;

    // 悬停字节的提示（右下角）
    if (res.hovered >= 0) {
        var hb2: [24]u8 = undefined;
        const t2 = ui.frameStr(hexOffset(&hb2, opts.base + @as(u64, @intCast(res.hovered))));
        const hm = ui.measureText(t2, theme.font_small);
        ui.addText(
            .{ .x = rect.x + rect.w - hm.w - 10, .y = rect.y + rect.h - hm.h - 6, .w = hm.w, .h = hm.h },
            t2,
            theme.font_small,
            theme.secondary,
        );
    }
    _ = HEX_MONO_SIZE;
    return res;
}

fn hexDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + (v - 10);
}

fn hexOffset(buf: []u8, v: u64) []const u8 {
    var tmp: [16]u8 = undefined;
    const s = num.int(&tmp, @intCast(v));
    var n: usize = 0;
    // 左侧补 0 到 8 位
    while (n + s.len < 8) : (n += 1) buf[n] = '0';
    for (s) |c| {
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

/// 把视图滚动到指定偏移（CUI `cui_hex_view_goto`）：直接设置选区光标。
pub fn hexViewGoto(sel: *HexSelection, offset: usize) void {
    sel.cursor = offset;
    sel.start = offset;
    sel.length = 1;
}
