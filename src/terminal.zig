//! 终端（对位 CUI `cui_terminal.c`）：带 ANSI 颜色的程序输出 + 带提示符的输入行。
//!
//! 输出进**调用方持有**的缓冲区（追加永不分配，满了从最老的行开始丢），写入时即解析：
//! `\n` 换行、`\r` 回到行首（进度条原地刷新）、`\t`、`\b`、`ESC [ ... m` 设置颜色与样式
//! （16 色 / 256 色 / 24 位色，粗体·暗淡·斜体·下划线·反显），其余转义序列丢弃。
//!
//! ```zig
//! var text: [64 * 1024]u8 = undefined;
//! var lines: [1024]terminal.Line = undefined;
//! var term: terminal.Buffer = .{};
//! terminal.init(&term, &text, &lines);      // 一次
//! terminal.write(&term, output);            // 随输出到达
//! var st = terminal.State{};
//! const r = terminal.terminal(ui, "term", &term, &st, .{ .height = 360 });
//! if (r.command) |cmd| run(cmd);            // 已经帮你回显
//! ```
//!
//! 与 CUI 的差异（有意为之）：
//! - **没有平台的剪贴板通道**：Ctrl+C 有选区时把文本放进 `Result.copy`（帧内有效），
//!   由调用方写系统剪贴板；没有选区时仍是 `interrupt`。
//! - **输入行复用 `widgets.input`**（正文字体、单行编辑），不是自己写的等宽输入框。
//! - **历史 16 条 × 96 字节**（CUI 32×256）；超出按字节边界安全截断。
//! - 逐**段**（run）画而不是逐字符画：本机字体是等宽的，逐段省一半以上的绘制指令。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const widgets = @import("widgets.zig");

pub const Mode = enum(u8) { text, esc, csi, osc, osc_esc };

pub const Line = struct {
    /// 文本缓冲里的起始字节。
    offset: u32 = 0,
    /// 字节数（含内嵌的 SGR 转义）。
    len: u32 = 0,
    /// 可见列数（UTF-8 续字节不算）。
    cols: u32 = 0,
};

/// 输出缓冲区：环形行表 + 一块由调用方给的文本。
pub const Buffer = struct {
    text: []u8 = &.{},
    lines: []Line = &.{},
    /// 环形行表：`first` 是行 0，`count` 是行数（最后一行的 `len` 还在增长）。
    first: u32 = 0,
    count: u32 = 0,
    /// 下一个字节写在这。
    end: u32 = 0,
    /// 累计起过多少行（选择与滚动的绝对行号基准）。
    total: u64 = 0,
    mode: Mode = .text,
    seq: [30]u8 = @splat(0),
    seq_n: usize = 0,
    /// 见过 `\r`：下一个字符从行首开始写。
    cr: bool = false,
    /// 0 = 参数非法（`init` 之后只读）。
    ok: bool = false,
};

/// 初始化（一次）。`lines.len` 至少 2，`text.len` 至少 64。
pub fn init(b: *Buffer, text: []u8, lines: []Line) void {
    b.* = .{};
    if (text.len < 64 or lines.len < 2) return;
    b.text = text;
    b.lines = lines;
    b.ok = true;
    b.count = 1;
    b.total = 1;
    b.lines[0] = .{};
}

pub fn clear(b: *Buffer) void {
    if (!b.ok) return;
    b.first = 0;
    b.count = 1;
    b.end = 0;
    b.total += 1;
    b.lines[0] = .{};
    b.cr = false;
    b.mode = .text;
    b.seq_n = 0;
}

fn curLine(b: *Buffer) *Line {
    return &b.lines[(b.first + b.count - 1) % b.lines.len];
}

fn lineAt(b: *Buffer, i: u32) *Line {
    return &b.lines[(b.first + i) % b.lines.len];
}

fn newLine(b: *Buffer) void {
    if (b.count == b.lines.len) {
        b.first = (b.first + 1) % @as(u32, @intCast(b.lines.len));
        b.count -= 1;
    }
    b.lines[(b.first + b.count) % b.lines.len] = .{ .offset = b.end };
    b.count += 1;
    b.total += 1;
}

/// 当前行末尾还有 n 字节的位置吗（当前行必须保持连续）。
fn room(b: *Buffer, n: u32) bool {
    const cap: u32 = @intCast(b.text.len);
    const c = curLine(b);
    if (c.len + n > cap) return false; // 比整个缓冲还长
    if (c.offset + c.len + n > cap) {
        // 回绕：最老的行在最前面，腾出来再把当前行搬到开头
        const need = c.len + n;
        while (b.count > 1) {
            const o = lineAt(b, 0);
            if (o.offset < need) {
                b.first = (b.first + 1) % @as(u32, @intCast(b.lines.len));
                b.count -= 1;
            } else break;
        }
        const src = c.offset;
        std.mem.copyForwards(u8, b.text[0..c.len], b.text[src .. src + c.len]);
        c.offset = 0;
        b.end = c.len;
    }
    // 挡在要写的字节上的老行也走
    while (b.count > 1) {
        const o = lineAt(b, 0);
        if (o.offset >= b.end and o.offset < b.end + n) {
            b.first = (b.first + 1) % @as(u32, @intCast(b.lines.len));
            b.count -= 1;
        } else break;
    }
    return true;
}

fn put(b: *Buffer, bytes: []const u8, cols: u32) void {
    const n: u32 = @intCast(bytes.len);
    if (!room(b, n)) return;
    @memcpy(b.text[b.end .. b.end + n], bytes);
    b.end += n;
    const c = curLine(b);
    c.len += n;
    c.cols += cols;
}

/// 见过 `\r` 之后的输出：这一行从头重写。
fn restart(b: *Buffer) void {
    const c = curLine(b);
    b.end = c.offset;
    c.len = 0;
    c.cols = 0;
    b.cr = false;
}

fn countCols(bytes: []const u8) u32 {
    var n: u32 = 0;
    for (bytes) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// 写入输出（解析在写入时发生，一条转义序列可以跨两次写入）。
pub fn write(b: *Buffer, data: []const u8) void {
    if (!b.ok or data.len == 0) return;
    var run_start: ?usize = null;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const ch = data[i];
        switch (b.mode) {
            .text => {
                if (ch == 0x1b) {
                    flush(b, data, &run_start, i);
                    b.mode = .esc;
                    b.seq_n = 0;
                    b.seq[b.seq_n] = ch;
                    b.seq_n += 1;
                } else if (ch == '\n') {
                    flush(b, data, &run_start, i);
                    b.cr = false;
                    newLine(b);
                } else if (ch == '\r') {
                    flush(b, data, &run_start, i);
                    b.cr = true;
                } else if (ch == '\t') {
                    flush(b, data, &run_start, i);
                    if (b.cr) restart(b);
                    const sp = 8 - curLine(b).cols % 8;
                    put(b, "        "[0..sp], sp);
                } else if (ch == 0x08) {
                    flush(b, data, &run_start, i);
                    const c = curLine(b);
                    // 只对纯 ASCII 行做退格（多字节字符删不干净）
                    if (c.len > 0 and c.len == c.cols) {
                        c.len -= 1;
                        c.cols -= 1;
                        b.end -= 1;
                    }
                } else if (ch < 0x20 or ch == 0x7f) {
                    flush(b, data, &run_start, i);
                } else {
                    if (b.cr) {
                        flush(b, data, &run_start, i);
                        restart(b);
                    }
                    if (run_start == null) run_start = i;
                }
            },
            .esc => {
                if (ch == '[') {
                    b.mode = .csi;
                    if (b.seq_n < b.seq.len) {
                        b.seq[b.seq_n] = ch;
                        b.seq_n += 1;
                    }
                } else if (ch == ']') {
                    b.mode = .osc;
                } else {
                    b.mode = .text; // 两字节转义：丢弃
                }
            },
            .csi => {
                if (b.seq_n < b.seq.len) {
                    b.seq[b.seq_n] = ch;
                    b.seq_n += 1;
                }
                if (ch >= 0x40 and ch <= 0x7e) {
                    b.mode = .text;
                    if (ch == 'm') {
                        if (b.cr) restart(b);
                        put(b, b.seq[0..b.seq_n], 0); // SGR 原样留在文本里，画的时候再解析
                    } else if (ch == 'K') {
                        if (b.cr) restart(b);
                    } else if (ch == 'J') {
                        if (std.mem.indexOfScalar(u8, b.seq[0..b.seq_n], '2') != null) clear(b);
                    }
                }
            },
            .osc => {
                if (ch == 0x07) {
                    b.mode = .text;
                } else if (ch == 0x1b) {
                    b.mode = .osc_esc;
                }
            },
            .osc_esc => {
                b.mode = if (ch == '\\') .text else .osc;
            },
        }
    }
    flush(b, data, &run_start, data.len);
}

fn flush(b: *Buffer, data: []const u8, run_start: *?usize, upto: usize) void {
    if (run_start.*) |s| {
        put(b, data[s..upto], countCols(data[s..upto]));
        run_start.* = null;
    }
}

/// 格式化写入（对应 CUI 的 `cui_terminal_printf`）。超长则整段丢弃（不写半截）。
pub fn print(b: *Buffer, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(buf[0..], fmt, args) catch return;
    write(b, s);
}

// ====================================================================== 样式

const Style = struct {
    fg: t.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    bg: t.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    has_fg: bool = false,
    has_bg: bool = false,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
};

const palette_light = [16]u32{
    0x27272a, 0xc4302b, 0x2e7d32, 0x9a6700, 0x1f5fbf, 0x8e3fb0, 0x0f7c84, 0x71717a,
    0x52525b, 0xe5484d, 0x30a46c, 0xb08300, 0x3e7bfa, 0xab4aba, 0x12a4ad, 0x18181b,
};
const palette_dark = [16]u32{
    0x52525b, 0xff6b6b, 0x5bd18b, 0xf5c451, 0x6aa8ff, 0xd38cf2, 0x4fd1d9, 0xd4d4d8,
    0x71717a, 0xff8f8f, 0x7ee2a8, 0xffd97a, 0x93c0ff, 0xe2adf7, 0x7fe3e9, 0xfafafa,
};

fn palette(k: u8) t.Color {
    const v = (if (theme.isDark()) palette_dark else palette_light)[k & 15];
    return t.Color.hex(v, 255);
}

fn color256(n: u8) t.Color {
    if (n < 16) return palette(n);
    if (n < 232) {
        const idx: u16 = @as(u16, n) - 16;
        const lv = [6]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = lv[idx / 36], .g = lv[(idx / 6) % 6], .b = lv[idx % 6], .a = 255 };
    }
    const g: u8 = @intCast(8 + (@as(u16, n) - 232) * 10);
    return .{ .r = g, .g = g, .b = g, .a = 255 };
}

/// 把 `ESC [ p ; p ... m` 应用到 `st`。
fn applySgr(st: *Style, s: []const u8) void {
    var p: [16]u8 = @splat(0);
    var np: usize = 0;
    var v: i32 = -1;
    var k: usize = 2;
    while (k + 1 < s.len and np < p.len) : (k += 1) {
        const c = s[k];
        if (c >= '0' and c <= '9') {
            v = (if (v < 0) 0 else v) * 10 + @as(i32, c - '0');
        } else if (c == ';' or c == ':') {
            p[np] = @intCast(std.math.clamp(v, 0, 255));
            np += 1;
            v = -1;
        }
    }
    if (np < p.len) {
        p[np] = @intCast(std.math.clamp(v, 0, 255));
        np += 1;
    }
    var i: usize = 0;
    while (i < np) : (i += 1) {
        const c = p[i];
        if (c == 0) {
            st.* = .{};
        } else if (c == 1) {
            st.bold = true;
        } else if (c == 2) {
            st.dim = true;
        } else if (c == 3) {
            st.italic = true;
        } else if (c == 4) {
            st.underline = true;
        } else if (c == 7) {
            st.inverse = true;
        } else if (c == 22) {
            st.bold = false;
            st.dim = false;
        } else if (c == 23) {
            st.italic = false;
        } else if (c == 24) {
            st.underline = false;
        } else if (c == 27) {
            st.inverse = false;
        } else if (c >= 30 and c <= 37) {
            st.fg = palette(@intCast(c - 30));
            st.has_fg = true;
        } else if (c >= 90 and c <= 97) {
            st.fg = palette(@intCast(c - 90 + 8));
            st.has_fg = true;
        } else if (c >= 40 and c <= 47) {
            st.bg = palette(@intCast(c - 40));
            st.has_bg = true;
        } else if (c >= 100 and c <= 107) {
            st.bg = palette(@intCast(c - 100 + 8));
            st.has_bg = true;
        } else if (c == 39) {
            st.has_fg = false;
        } else if (c == 49) {
            st.has_bg = false;
        } else if ((c == 38 or c == 48) and i + 1 < np) {
            var col: t.Color = undefined;
            if (p[i + 1] == 5 and i + 2 < np) {
                col = color256(p[i + 2]);
                i += 2;
            } else if (p[i + 1] == 2 and i + 4 < np) {
                col = .{ .r = p[i + 2], .g = p[i + 3], .b = p[i + 4], .a = 255 };
                i += 4;
            } else continue;
            if (c == 38) {
                st.fg = col;
                st.has_fg = true;
            } else {
                st.bg = col;
                st.has_bg = true;
            }
        }
    }
}

// ====================================================================== 视图

/// 文本位置：绝对行号（`total` 基准）+ 可见列。
pub const Pos = struct { line: u64 = 0, col: u32 = 0 };

pub const State = struct {
    /// 视口顶部在第几个「行」（已按宽度折行后的行，可以是小数）。
    top: f64 = 0,
    /// 跟着最新行（滚上去看历史后自动关掉）。
    follow: bool = true,
    selecting: bool = false,
    has_sel: bool = false,
    a: Pos = .{},
    b: Pos = .{},
    /// 输入行（末字节留 0）。
    input: [512]u8 = @splat(0),
    input_len: usize = 0,
    caret: usize = 0,
    /// 历史（新到旧）与浏览位置。
    hist: [16][96]u8 = @splat(@splat(0)),
    hist_len: [16]usize = @splat(0),
    hn: usize = 0,
    hpos: usize = 0,
    browsing: bool = false,
    press_x: f32 = 0,
    press_y: f32 = 0,
};

pub const Opts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 负值 = 撑满剩余高度。
    height: f32 = 320,
    size: f32 = 13,
    prompt: []const u8 = "$ ",
    /// 只看输出，不要输入行。
    no_input: bool = false,
};

pub const Result = struct {
    /// 回车提交的命令行（本帧有效，已经回显）。
    command: ?[]const u8 = null,
    /// Ctrl+C 且没有选区（中断请求）。
    interrupt: bool = false,
    /// Ctrl+C 且有选区：选中文本（本帧有效），由调用方写剪贴板。
    copy: ?[]const u8 = null,
};

const PAD: f32 = 10;
/// 每帧最多画多少段文本（`MAX_NODES` 256，留够输入行与边框）。
const MAX_RUNS: usize = 180;
const BLOCK_FIRST: u21 = 0x2580;
const BLOCK_LAST: u21 = 0x2593;

fn rowsOf(cols: u32, width_cols: u32) u32 {
    if (cols == 0) return 1;
    return (cols + width_cols - 1) / width_cols;
}

/// 终端视图。
pub fn terminal(ui: *core.Context, id: []const u8, b: *Buffer, st: *State, opts: Opts) Result {
    var res = Result{};
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 640;
    const h = if (opts.height < 0) @max(120, ui.height - 8) else if (opts.height > 0) opts.height else 320;
    const size = if (opts.size > 0) opts.size else 13;
    const cw = ui.measureText("0", size).w;
    const lh = @ceil(size * 1.45);
    const input_h: f32 = if (opts.no_input) 0 else 46;
    const cols: u32 = @intCast(@max(8, @as(i32, @intFromFloat((w - PAD * 2) / cw))));

    const rect = ui.reserve(w, h, opts.width <= 0);
    const view = t.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @max(40, rect.h - input_h) };
    const field = t.Rect{ .x = rect.x, .y = view.y + view.h, .w = rect.w, .h = input_h };

    ui.addBox(rect, .{ .fill = theme.surface, .radius = theme.radius_control, .border = theme.border });

    // ---- 总行数（按当前宽度折行）
    var rows_total: f64 = 0;
    if (b.ok) {
        var i: u32 = 0;
        while (i < b.count) : (i += 1) rows_total += @floatFromInt(rowsOf(lineAt(b, i).cols, cols));
    }
    const page = @max(1.0, (view.h - 12) / lh);
    const max_top = @max(0.0, rows_total - page);

    // ---- 滚动
    const hit = ui.interact(core.Context.idOf(id) ^ 0x7E2D, view);
    if (hit.hover and ui.input.wheel != 0) {
        st.top -= ui.input.wheel * 3;
        st.follow = st.top >= max_top - 0.5;
    }
    if (st.follow) st.top = max_top;
    st.top = std.math.clamp(st.top, 0, max_top);
    if (st.top >= max_top - 0.01) st.follow = true;

    // ---- 指针 → 文本位置
    var at = Pos{};
    var at_ok = false;
    if (b.ok and hit.hover) {
        var rr = st.top + (ui.input.mouse.y - view.y - 6) / lh;
        if (rr < 0) rr = 0;
        var row: f64 = 0;
        var li: u32 = 0;
        while (li + 1 < b.count) : (li += 1) {
            const nr = rowsOf(lineAt(b, li).cols, cols);
            if (row + @as(f64, @floatFromInt(nr)) > rr) break;
            row += @floatFromInt(nr);
        }
        const sub: u32 = @intFromFloat(@max(0, rr - row));
        const cc = std.math.clamp(@as(i32, @intFromFloat(@floor((ui.input.mouse.x - view.x - PAD) / cw + 0.5))), 0, @as(i32, @intCast(cols)));
        var col: u32 = sub * cols + @as(u32, @intCast(cc));
        col = @min(col, lineAt(b, li).cols);
        at = .{ .line = b.total - b.count + li, .col = col };
        at_ok = true;
    }

    // ---- 选区
    if (hit.pressed and at_ok) {
        st.a = at;
        st.b = at;
        st.selecting = true;
        st.has_sel = false;
        st.press_x = ui.input.mouse.x;
        st.press_y = ui.input.mouse.y;
    }
    if (st.selecting and ui.input.down and at_ok) {
        st.b = at;
        if (@abs(ui.input.mouse.x - st.press_x) + @abs(ui.input.mouse.y - st.press_y) > 3) st.has_sel = true;
        // 拖出边缘继续滚
        if (ui.input.mouse.y < view.y) {
            st.top = @max(0, st.top - 0.5);
            st.follow = false;
            ui.requestFrame();
        }
        if (ui.input.mouse.y > view.y + view.h) {
            st.top = @min(max_top, st.top + 0.5);
            ui.requestFrame();
        }
    }
    if (st.selecting and !ui.input.down) st.selecting = false;

    var s0 = st.a;
    var s1 = st.b;
    if (s1.line < s0.line or (s1.line == s0.line and s1.col < s0.col)) {
        const tmp = s0;
        s0 = s1;
        s1 = tmp;
    }

    // ---- 快捷键：Ctrl+C 复制/中断、Ctrl+L 清屏
    const input_key = core.Context.idOf("term-input") ^ 0x7FEB352D ^ core.Context.idOf(id);
    const field_focused = ui.focus_id == input_key;
    const mods = ui.input.mods;
    if (mods.ctrl and ui.input.keyPressed(.C)) {
        if (st.has_sel) {
            var buf: [2048]u8 = undefined;
            const n = copySelection(b, s0, s1, buf[0..]);
            res.copy = ui.frameStr(buf[0..n]);
            st.has_sel = false;
        } else {
            res.interrupt = true;
            write(b, "^C\n");
            st.input_len = 0;
            st.caret = 0;
            st.input[0] = 0;
        }
    }
    if (mods.ctrl and ui.input.keyPressed(.L)) {
        clear(b);
        st.top = 0;
        st.follow = true;
        st.has_sel = false;
    }

    // ---- 画输出区
    ui.addBox(view, .{ .fill = if (theme.isDark()) theme.bg else theme.surface, .radius = theme.radius_control });
    {
        const saved = ui.clip;
        ui.clip = .{ .x = view.x, .y = view.y + 3, .w = view.w, .h = view.h - 6 };
        if (b.ok) drawRows(ui, b, view, st, s0, s1, cols, cw, lh, size);
        ui.clip = saved;
    }
    // 滚动条（有历史才出现）
    if (rows_total * lh > view.h) {
        const th = @max(24, view.h * view.h / @as(f32, @floatCast(rows_total * lh)));
        const ty = view.y + (if (max_top > 0) @as(f32, @floatCast(st.top / max_top)) else 1) * (view.h - th);
        ui.addBox(.{ .x = view.x + view.w - 6, .y = ty, .w = 3, .h = th }, .{ .fill = theme.withAlpha(theme.secondary, 120), .radius = 1.5 });
    }

    // ---- 输入行
    if (!opts.no_input) {
        ui.addOverlayLine(.{ .x = field.x, .y = field.y }, .{ .x = field.x + field.w, .y = field.y }, 1, theme.border);
        var row = ui.panel(.{ .x = field.x + 10, .y = field.y + 4, .w = field.w - 20, .h = 36 }, .{ .dir = .row, .gap = 6 });
        defer row.end();
        const pm = ui.measureText(opts.prompt, size);
        const pr = ui.reserve(pm.w + 2, pm.h, false);
        ui.addMonoText(pr, opts.prompt, size, theme.accent);
        // 行布局里 `width = 0` 会得到零宽，输入框必须拿到明确的剩余宽
        const input_w = @max(60, field.w - 20 - pm.w - 2 - 6);
        const changed = widgets.input(ui, "term-input", st.input[0..], &st.input_len, &st.caret, .{
            .width = input_w,
            .placeholder = "",
        });
        if (changed) st.browsing = false;
        // 历史：上下键（在输入框处理之前拦下来）
        if (field_focused and st.hn > 0 and ui.input.keyPressed(.up)) {
            if (!st.browsing) {
                st.hpos = st.hn;
                st.browsing = true;
            }
            st.hpos = if (st.hpos > 0) st.hpos - 1 else 0;
            setInput(st, if (st.hpos < st.hn) st.hist[st.hpos][0..st.hist_len[st.hpos]] else "");
        } else if (field_focused and st.hn > 0 and ui.input.keyPressed(.down)) {
            if (!st.browsing) {
                st.hpos = st.hn;
                st.browsing = true;
            }
            st.hpos = @min(st.hn, st.hpos + 1);
            setInput(st, if (st.hpos < st.hn) st.hist[st.hpos][0..st.hist_len[st.hpos]] else "");
        }
        // 回车：回显 + 记历史 + 交回命令
        if (field_focused and ui.input.keyPressed(.enter)) {
            const cmd = st.input[0..st.input_len];
            write(b, "\x1b[2m");
            write(b, opts.prompt);
            write(b, "\x1b[0m");
            write(b, cmd);
            write(b, "\n");
            pushHistory(st, cmd);
            res.command = ui.frameStr(cmd);
            setInput(st, "");
            st.browsing = false;
            st.follow = true;
        }
    }

    return res;
}

fn setInput(st: *State, s: []const u8) void {
    const n = @min(s.len, st.input.len - 1);
    var cut = n;
    while (cut > 0 and cut < s.len and (s[cut] & 0xC0) == 0x80) cut -= 1;
    @memcpy(st.input[0..cut], s[0..cut]);
    st.input[cut] = 0;
    st.input_len = cut;
    st.caret = cut;
    st.input[cut] = 0;
}

fn pushHistory(st: *State, cmd: []const u8) void {
    if (cmd.len == 0) return;
    if (st.hn > 0 and std.mem.eql(u8, st.hist[st.hn - 1][0..st.hist_len[st.hn - 1]], cmd)) return;
    if (st.hn == st.hist.len) {
        var k: usize = 1;
        while (k < st.hist.len) : (k += 1) {
            st.hist[k - 1] = st.hist[k];
            st.hist_len[k - 1] = st.hist_len[k];
        }
        st.hn -= 1;
    }
    var n = @min(cmd.len, st.hist[0].len - 1);
    while (n > 0 and n < cmd.len and (cmd[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(st.hist[st.hn][0..n], cmd[0..n]);
    st.hist[st.hn][n] = 0;
    st.hist_len[st.hn] = n;
    st.hn += 1;
}

/// 选中区域的可见文本（转义序列去掉，行间用 `\n`）。
pub fn copySelection(b: *Buffer, s0: Pos, s1: Pos, out: []u8) usize {
    if (!b.ok) return 0;
    const first_no = b.total - b.count;
    var n: usize = 0;
    var no = @max(s0.line, first_no);
    while (no <= s1.line and no < b.total) : (no += 1) {
        const li: u32 = @intCast(no - first_no);
        const c0: u32 = if (no == s0.line) s0.col else 0;
        const c1: u32 = if (no == s1.line) s1.col else 0xFFFF_FFFF;
        n += copyLine(b, li, c0, c1, out[n..]);
        if (no != s1.line and n + 1 < out.len) {
            out[n] = '\n';
            n += 1;
        }
    }
    return n;
}

fn copyLine(b: *Buffer, li: u32, c0: u32, c1: u32, out: []u8) usize {
    const L = lineAt(b, li);
    const s = b.text[L.offset .. L.offset + L.len];
    var n: usize = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            var j = i + 1;
            while (j < s.len and !(s[j] >= 0x40 and s[j] <= 0x7e and j > i + 1)) j += 1;
            i = j + 1;
            continue;
        }
        var e = i + 1;
        while (e < s.len and (s[e] & 0xC0) == 0x80) e += 1;
        if (col >= c0 and col < c1 and n + (e - i) < out.len) {
            @memcpy(out[n .. n + (e - i)], s[i..e]);
            n += e - i;
        }
        col += 1;
        i = e;
    }
    return n;
}

fn drawRows(
    ui: *core.Context,
    b: *Buffer,
    view: t.Rect,
    st: *State,
    s0: Pos,
    s1: Pos,
    cols: u32,
    cw: f32,
    lh: f32,
    size: f32,
) void {
    const x0 = view.x + PAD;
    const y0 = view.y + 6;
    // 找到视口第一行落在哪一条逻辑行
    var row: f64 = 0;
    var li: u32 = 0;
    const want = @floor(st.top);
    while (li < b.count) {
        const rr = rowsOf(lineAt(b, li).cols, cols);
        if (row + @as(f64, @floatFromInt(rr)) > want) break;
        row += @floatFromInt(rr);
        li += 1;
    }
    var y = y0 + @as(f32, @floatCast(row - st.top)) * lh;
    const first_no = b.total - b.count;
    const sel_bg = theme.withAlpha(theme.accent, if (theme.isDark()) 76 else 46);
    var budget = MAX_RUNS;

    while (li < b.count and y < view.y + view.h and budget > 0) : (li += 1) {
        const L = lineAt(b, li);
        const no = first_no + li;
        const nrows = rowsOf(L.cols, cols);

        // 选区底色（按可见列）
        if (st.has_sel and no >= s0.line and no <= s1.line) {
            const c0: u32 = if (no == s0.line) s0.col else 0;
            const c1: u32 = if (no == s1.line) s1.col else L.cols + 1;
            var c = c0;
            while (c < c1) {
                const rowi = c / cols;
                const end = @min(c1, (rowi + 1) * cols);
                ui.addBox(.{
                    .x = x0 + @as(f32, @floatFromInt(c % cols)) * cw,
                    .y = y + @as(f32, @floatFromInt(rowi)) * lh,
                    .w = @as(f32, @floatFromInt(end - c)) * cw,
                    .h = lh,
                }, .{ .fill = sel_bg });
                c = end;
            }
        }

        // 文本：按 SGR 分段
        const s = b.text[L.offset .. L.offset + L.len];
        var style = Style{};
        var i: usize = 0;
        var col: u32 = 0;
        while (i < s.len and budget > 0) {
            if (s[i] == 0x1b) {
                var j = i + 1;
                while (j < s.len and !(s[j] >= 0x40 and s[j] <= 0x7e and j > i + 1)) j += 1;
                if (j < s.len) applySgr(&style, s[i .. j + 1]);
                i = j + 1;
                continue;
            }
            // 一段普通文本：到下一个转义或本行末尾
            var j = i;
            var taken: u32 = 0;
            const room_cols = cols - col % cols;
            while (j < s.len and s[j] != 0x1b) {
                const lead = (s[j] & 0xC0) != 0x80;
                if (lead) {
                    if (taken == room_cols) break;
                    taken += 1;
                }
                j += 1;
            }
            if (taken == 0) {
                i = j;
                continue;
            }
            var fg = if (style.has_fg) style.fg else theme.text;
            var bg = if (style.has_bg) style.bg else t.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            if (style.inverse) {
                const tmp = fg;
                fg = if (style.has_bg) style.bg else theme.surface;
                bg = tmp;
            }
            if (style.dim) fg = theme.withAlpha(fg, 150);
            const rx = x0 + @as(f32, @floatFromInt(col % cols)) * cw;
            const ry = y + @as(f32, @floatFromInt(col / cols)) * lh;
            if (ry > view.y + view.h) break;
            if (bg.a != 0) ui.addBox(.{ .x = rx, .y = ry, .w = @as(f32, @floatFromInt(taken)) * cw, .h = lh }, .{ .fill = bg });
            // 一段一次画完（本机字体等宽）；块元素逐字符画成矩形（字体里常没有这些字形）
            if (blockKind(s[i..j]) != null) {
                var q = i;
                while (q < j and budget > 0) {
                    var e = q + 1;
                    while (e < j and (s[e] & 0xC0) == 0x80) e += 1;
                    const cols_before = countCols(s[i..q]);
                    if (blockKind(s[q..e])) |_| {
                        drawBlock(ui, s[q..e], .{
                            .x = rx + @as(f32, @floatFromInt(cols_before)) * cw,
                            .y = ry,
                            .w = cw,
                            .h = lh,
                        }, fg);
                    } else {
                        // 等宽字体：列对齐是终端的语义；粗体用二次绘制模拟（CUI 同口径）
                        const cell = t.Rect{
                            .x = rx + @as(f32, @floatFromInt(cols_before)) * cw,
                            .y = ry + (lh - size * 1.2) * 0.5,
                            .w = cw + 2,
                            .h = lh,
                        };
                        ui.addMonoText(cell, s[q..e], size, fg);
                        if (style.bold) ui.addMonoText(.{ .x = cell.x + 0.45, .y = cell.y, .w = cell.w, .h = cell.h }, s[q..e], size, fg);
                    }
                    budget -= 1;
                    q = e;
                }
            } else {
                // 一段一次画完（本机字体是等宽的）；粗体画两遍，斜体忽略（终端里少见）
                const cell = t.Rect{ .x = rx, .y = ry + (lh - size * 1.2) * 0.5, .w = @as(f32, @floatFromInt(taken)) * cw + 2, .h = lh };
                ui.addMonoText(cell, s[i..j], size, fg);
                if (style.bold) ui.addMonoText(.{ .x = cell.x + 0.45, .y = cell.y, .w = cell.w, .h = cell.h }, s[i..j], size, fg);
                budget -= 1;
            }
            if (style.underline) {
                ui.addOverlayLine(
                    .{ .x = rx, .y = ry + lh - 3 },
                    .{ .x = rx + @as(f32, @floatFromInt(taken)) * cw, .y = ry + lh - 3 },
                    1,
                    fg,
                );
            }
            col += taken;
            i = j;
        }
        y += @as(f32, @floatFromInt(nrows)) * lh;
    }
}

/// 块元素（U+2580..U+2593）的种类；其它返回 null。
fn blockKind(s: []const u8) ?u8 {
    if (s.len != 3 or s[0] != 0xE2 or s[1] != 0x96) return null;
    if (s[2] < 0x80 or s[2] > 0x93) return null;
    return s[2] - 0x80;
}

/// 块元素画成矩形（字体里常常没有这些字形，进度条会断）。
fn drawBlock(ui: *core.Context, s: []const u8, cell: t.Rect, col: t.Color) void {
    const kind = blockKind(s) orelse return;
    var r = cell;
    var c = col;
    if (kind == 0) {
        r.h = @floor(cell.h * 0.5);
    } else if (kind >= 1 and kind <= 8) {
        const f: f32 = @as(f32, @floatFromInt(kind)) / 8.0;
        r.h = @floor(cell.h * f + 0.5);
        r.y = cell.y + cell.h - r.h;
    } else if (kind >= 9 and kind <= 15) {
        r.w = @floor(cell.w * @as(f32, @floatFromInt(16 - kind)) / 8.0 + 0.5);
    } else if (kind == 16) {
        r.x = cell.x + @floor(cell.w * 0.5);
        r.w = cell.w - @floor(cell.w * 0.5);
    } else if (kind >= 17 and kind <= 19) {
        c = theme.withAlpha(col, @intCast((kind - 16) * 64));
    }
    ui.addBox(r, .{ .fill = c });
}
