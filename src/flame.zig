//! 火焰图（对位 CUI `cui_flame.c` 的 flame graph 三件）：时间从左到右，调用深度从上到下。
//! spans / view / selected 都由调用方持有，组件按需缩放平移并写回。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **不做缩放动画**（CUI 有 `cui__fl_animate_to` + tween）：直接跳到目标范围；
//! - **不做键盘的完整映射**（CUI 有 Up/Down 走父子、Shift+箭头平移、Esc 清选）：
//!   只保留最常用的「←/→ 切选中、+/- 缩放、Home/F 适配」；
//! - **不做「比一个像素还窄的合并成中性条」**（CUI 有此逻辑）：直接按像素映射画，细条被裁掉；
//! - 悬浮提示是自绘小卡片（不走 `widgets.tooltip` 的 0.35s 延迟）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");

const RULER_H: f32 = 22;
const PAD_X: f32 = 8;
const PAD_Y: f32 = 4;
const DRAG_SLOP: f32 = 3;
/// 窄于这个宽度的条不画标签（三个字母 + 省略号都放不下）。
const LABEL_MIN: f32 = 42;
/// 最多画多少行（超过就只画前 N 行，防止节点预算被打爆）。
const MAX_ROWS = 24;

pub const Span = struct {
    name: []const u8 = "",
    /// 秒（任意原点；刻度从最早的那条 span 起算）。
    start: f64 = 0,
    end: f64 = 0,
    /// 行号，0 在最上面。同一深度的 span 不能重叠（子 span 落在父 span 内）。
    depth: i32 = 0,
    /// 0 = 用名字哈希（同一个函数永远同色）。
    color_key: u32 = 0,
};

pub const View = struct {
    /// 可见时间范围；`end <= start` 表示「适配全部」（组件会写回真实范围）。
    start: f64 = 0,
    end: f64 = 0,
    /// 顶部滚出视口的行高倍数（单位：行）。
    scroll: f32 = 0,
};

pub const FlameOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 0 = 按行数（上限 360）。
    height: f32 = 0,
    row_height: f32 = 20,
    /// 最深缩放（秒）。
    min_range: f64 = 1e-8,
};

pub const FlameResult = struct {
    /// `selected` 变了（点击或按键）。
    selection_changed: bool = false,
    /// `view` 变了（缩放/平移/适配）。
    view_changed: bool = false,
    /// 指针下的 span 下标，-1 = 无。
    hovered: i32 = -1,
    /// 本帧被缩放到的 span，-1 = 无。
    zoomed: i32 = -1,
};

// ------------------------------------------------------------------ 小工具

fn eqName(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nameKey(sp: Span) u32 {
    if (sp.color_key != 0) return sp.color_key;
    var h: u32 = 0xF1A3;
    for (sp.name) |c| {
        h ^= c;
        h *%= 16777619; // FNV-1a 32
    }
    return h;
}

/// 由 key 得到稳定的条色：色相散布、饱和度低，与主题底混合后不刺眼。
fn spanColor(key: u32) t.Color {
    const hue: f32 = @floatFromInt(key % 360);
    const sat: f32 = 0.40;
    const light: f32 = if (theme.isDark()) 0.40 else 0.74;
    return hsl(hue / 360.0, sat, light);
}

fn hsl(h: f32, s: f32, l: f32) t.Color {
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
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

/// 1 / 2 / 5 × 10^n（不用 log10，省掉数学库）。
fn niceStep(raw: f64) f64 {
    if (!(raw > 0)) return 1;
    var v = raw;
    var p: f64 = 1;
    while (v >= 10) {
        v /= 10;
        p *= 10;
    }
    while (v < 1) {
        v *= 10;
        p /= 10;
    }
    const m: f64 = if (v <= 1) 1 else if (v <= 2) 2 else if (v <= 5) 5 else 10;
    return m * p;
}

/// 秒 → 带单位的文本（1.23 ms / 456 µs / 3.2 s），写进 buf。
fn fmtSeconds(buf: []u8, sec: f64) []const u8 {
    var v = sec;
    var unit: []const u8 = "s";
    if (sec < 1e-6) {
        v = sec * 1e9;
        unit = "ns";
    } else if (sec < 1e-3) {
        v = sec * 1e6;
        unit = "\xc2\xb5s"; // µ
    } else if (sec < 1) {
        v = sec * 1e3;
        unit = "ms";
    }
    const dec: u8 = if (v >= 100) 0 else if (v >= 10) 1 else 2;
    var tmp: [24]u8 = undefined;
    const s = num.fixed(tmp[0..], @floatCast(v), dec);
    var n: usize = 0;
    const take = @min(s.len, buf.len - 4);
    @memcpy(buf[0..take], s[0..take]);
    n += take;
    buf[n] = ' ';
    n += 1;
    @memcpy(buf[n..][0..unit.len], unit);
    n += unit.len;
    return buf[0..n];
}

// ------------------------------------------------------------------ 排序与查找

fn lessSpan(_: void, a: Span, b: Span) bool {
    if (a.depth != b.depth) return a.depth < b.depth;
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end; // 同起点时长者在前
}

/// 按 graph 需要的顺序排序：深度 → 起点（同起点长的在前）。就地排序，一次即可。
pub fn sortSpans(spans: []Span) void {
    std.sort.pdq(Span, spans, {}, lessSpan);
}

/// 第 `row` 行在已排序数组里的范围 [lo, hi)。
fn rowRange(spans: []const Span, row: i32) struct { lo: usize, hi: usize } {
    var lo: usize = 0;
    while (lo < spans.len and spans[lo].depth < row) lo += 1;
    var hi = lo;
    while (hi < spans.len and spans[hi].depth == row) hi += 1;
    return .{ .lo = lo, .hi = hi };
}

fn maxDepth(spans: []const Span) i32 {
    var d: i32 = 0;
    for (spans) |sp| {
        if (sp.depth > d) d = sp.depth;
    }
    return d;
}

// ------------------------------------------------------------------ 绘制

pub fn flameGraph(
    ui: *core.Context,
    id: []const u8,
    spans: []const Span,
    view: *View,
    selected: ?*i32,
    opts: FlameOpts,
) FlameResult {
    var res = FlameResult{};
    if (spans.len == 0) return res;

    // 全量时间范围
    var t0 = spans[0].start;
    var t1 = spans[0].end;
    for (spans) |sp| {
        if (sp.start < t0) t0 = sp.start;
        if (sp.end > t1) t1 = sp.end;
    }
    if (!(t1 > t0)) t1 = t0 + 1e-9;

    const rows_total: usize = @intCast(@max(maxDepth(spans) + 1, 1));
    const row_h = if (opts.row_height > 0) opts.row_height else 20;
    const shown_rows = @min(rows_total, MAX_ROWS);
    const body_h = row_h * @as(f32, @floatFromInt(shown_rows));
    const panel_h = RULER_H + PAD_Y * 2 + body_h;
    _ = if (opts.height > 0) opts.height else 0;

    const rect0 = ui.reserve(0, panel_h, true);
    const frame = &ui.stack[ui.depth - 1];
    _ = frame;
    const panel_w = if (opts.width > 0) opts.width else if (rect0.w > 0) rect0.w else 320;
    const rect = t.Rect{ .x = rect0.x, .y = rect0.y, .w = panel_w, .h = panel_h };

    // 视口适配
    if (!(view.end > view.start)) {
        view.start = t0;
        view.end = t1;
        res.view_changed = true;
    }
    var range = view.end - view.start;
    const min_range = if (opts.min_range > 0) opts.min_range else 1e-8;
    if (range < min_range) {
        view.end = view.start + min_range;
        range = min_range;
        res.view_changed = true;
    }

    // 交互：整块面板一个命中（不做逐条命中，避免打爆 MAX_HITS）
    const pid = core.Context.idOf(id);
    const it = ui.interact(pid ^ 0xF1A9, rect);
    const hovered = hitTest(spans, view.*, rect, ui.input.mouse.x, ui.input.mouse.y, row_h, shown_rows);
    res.hovered = if (it.hover) hovered else -1;

    // 滚轮缩放（围绕指针）与 Shift 平移
    const k: f32 = rect.w - PAD_X * 2;
    const px0 = rect.x + PAD_X;
    const plot_w = rect.w - PAD_X * 2;
    if (it.hover and ui.input.wheel != 0 and plot_w > 0) {
        const shift = ui.input.mods.ctrl or ui.input.mods.shift;
        if (shift) {
            const d = -ui.input.wheel * 0.08 * range;
            view.start += d;
            view.end += d;
        } else {
            const mx = (ui.input.mouse.x - px0) / plot_w;
            const factor: f64 = if (ui.input.wheel > 0) 0.8 else 1.25;
            var anchor = view.start + @as(f64, clampF(mx, 0, 1)) * range;
            var nr = range * factor;
            if (nr < min_range) nr = min_range;
            if (nr > t1 - t0) nr = t1 - t0;
            view.start = anchor - @as(f64, clampF(mx, 0, 1)) * nr;
            view.end = view.start + nr;
            anchor = 0;
            range = nr;
        }
        res.view_changed = true;
    }
    _ = k;

    // 拖拽平移：用尺寸池记住上一帧的鼠标 x 与当时的时间起点（不存全局量，与状态池口径一致）
    const drag_key = pid ^ 0xF1A3;
    if (it.dragging and plot_w > 0) {
        if (ui.knownSize(drag_key)) |p| {
            const dx = ui.input.mouse.x - p.w;
            if (@abs(dx) > 0.01) {
                const dtt = -@as(f64, dx) * range / @as(f64, plot_w);
                const prev_start = t0 + @as(f64, p.h);
                view.start = prev_start + dtt;
                view.end = view.start + range;
                res.view_changed = true;
            }
        }
    }
    ui.rememberSize(drag_key, ui.input.mouse.x, @as(f32, @floatCast(view.start - t0)));

    // 点击选中 / 双击缩放（双击 = 两次点击间隔 < 0.45s 且位置几乎相同）
    if (it.clicked) {
        const prev_click = ui.knownSize(pid ^ 0xF1A4);
        const is_double = if (prev_click) |p|
            (ui.time * 1000.0 - @as(f64, p.w) < 450.0 and @abs(ui.input.mouse.x - p.h) < 6)
        else
            false;
        ui.rememberSize(pid ^ 0xF1A4, @as(f32, @floatCast(ui.time * 1000.0)), ui.input.mouse.x);
        if (is_double and hovered >= 0) {
            zoomTo(spans, view, @intCast(hovered), min_range);
            res.view_changed = true;
            res.zoomed = hovered;
        } else if (hovered >= 0) {
            if (selected) |p| {
                if (p.* != hovered) {
                    p.* = hovered;
                    res.selection_changed = true;
                }
            }
        } else if (selected) |p| {
            if (p.* != -1) {
                p.* = -1;
                res.selection_changed = true;
            }
        }
    }

    // 键盘：←/→ 切换选中、+/- 缩放、Home/F 适配
    const cur: i32 = if (selected) |p| p.* else -1;
    if (ui.input.keyPressed(.home) or ui.input.keyPressed(.F)) {
        view.start = t0;
        view.end = t1;
        res.view_changed = true;
    }
    if (ui.input.keyPressed(.equal)) {
        const mid = (view.start + view.end) / 2;
        view.end = mid + range * 0.4;
        view.start = mid - range * 0.4;
        res.view_changed = true;
    }
    if (ui.input.keyPressed(.minus)) {
        const mid = (view.start + view.end) / 2;
        view.end = mid + range * 0.625;
        view.start = mid - range * 0.625;
        res.view_changed = true;
    }
    if (cur >= 0 and (ui.input.keyPressed(.left) or ui.input.keyPressed(.right))) {
        const step: i32 = if (ui.input.keyPressed(.right)) 1 else -1;
        var nxt = cur + step;
        if (nxt < 0) nxt = 0;
        if (nxt >= @as(i32, @intCast(spans.len))) nxt = @as(i32, @intCast(spans.len - 1));
        if (selected) |p| p.* = nxt;
        res.selection_changed = true;
        reveal(spans, view, @intCast(nxt));
        res.view_changed = true;
    }

    // 夹取：不能缩到全量之外
    if (view.end - view.start > t1 - t0) {
        view.start = t0;
        view.end = t1;
    }
    if (view.start < t0) {
        view.end += t0 - view.start;
        view.start = t0;
    }
    if (view.end > t1) {
        view.start -= view.end - t1;
        view.end = t1;
        if (view.start < t0) view.start = t0;
    }
    range = view.end - view.start;

    // 背景
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 10, .border = theme.border });
    // 刻度栏
    const ruler = t.Rect{ .x = rect.x, .y = rect.y, .w = rect.w, .h = RULER_H };
    ui.addBox(ruler, .{ .fill = theme.raised, .radius = 10 });
    ui.addOverlayLine(.{ .x = rect.x, .y = rect.y + RULER_H }, .{ .x = rect.x + rect.w, .y = rect.y + RULER_H }, 1, theme.border);

    const kf: f32 = @floatCast(plot_w / range);
    const body_y0 = rect.y + RULER_H + PAD_Y;
    const scroll_rows = @floor(view.scroll);
    const scroll_px = (view.scroll - scroll_rows) * row_h;
    const first_row: i32 = @intFromFloat(scroll_rows);

    // 时间刻度与网格
    drawRuler(ui, view.*, rect, px0, plot_w, body_h + PAD_Y * 2, t0);

    // 视口裁剪：条只画在面板内
    const saved_clip = ui.clip;
    ui.clip = rect;
    var row_i: i32 = 0;
    while (row_i < @as(i32, @intCast(shown_rows))) : (row_i += 1) {
        const row = first_row + row_i;
        if (row < 0 or row > maxDepth(spans)) continue;
        const y = body_y0 + @as(f32, @floatFromInt(row_i)) * row_h - scroll_px;
        if (y + row_h < rect.y + RULER_H or y > rect.y + rect.h) continue;
        const rr = rowRange(spans, row);
        var i = rr.lo;
        while (i < rr.hi) : (i += 1) {
            const sp = spans[i];
            if (sp.end < view.start or sp.start > view.end) continue;
            const x0 = px0 + @as(f32, @floatCast((sp.start - view.start) * kf));
            const x1 = px0 + @as(f32, @floatCast((sp.end - view.start) * kf));
            const w = @max(x1 - x0, 1.0);
            const bar = t.Rect{ .x = x0, .y = y, .w = w, .h = row_h - 2 };
            const fill = spanColor(nameKey(sp));
            ui.addBox(bar, .{ .fill = fill, .radius = 3 });
            const is_sel = cur == @as(i32, @intCast(i));
            if (is_sel) {
                ui.addBox(bar.inset(1), .{ .border = theme.accent_text, .radius = 3 });
            }
            if (w >= LABEL_MIN and sp.name.len > 0) {
                const tw = w - 8;
                ui.addText(.{ .x = bar.x + 4, .y = bar.y + (bar.h - theme.font_small * 1.35) / 2, .w = tw, .h = theme.font_small * 1.35 }, sp.name, theme.font_small, theme.text);
            }
        }
    }
    ui.clip = saved_clip;

    // 悬浮提示（自绘小卡片，不进 tooltip 池）
    if (res.hovered >= 0 and res.hovered < @as(i32, @intCast(spans.len))) {
        const sp = spans[@intCast(res.hovered)];
        var buf: [64]u8 = undefined;
        const dur = fmtSeconds(buf[0..], sp.end - sp.start);
        const mx = clampF(ui.input.mouse.x, rect.x + 4, rect.x + rect.w - 180);
        const my = clampF(ui.input.mouse.y - 28, rect.y + 2, rect.y + rect.h - 24);
        const tw = ui.measureText(sp.name, theme.font_small).w + ui.measureText(dur, theme.font_small).w + 28;
        const box = t.Rect{ .x = mx, .y = my, .w = tw, .h = 22 };
        ui.addOverlayBox(box, .{ .fill = theme.overlay_bg, .radius = 6 });
        ui.addText(.{ .x = box.x + 8, .y = box.y + 4, .w = box.w, .h = 14 }, sp.name, theme.font_small, theme.overlay_fg);
        ui.addText(.{ .x = box.x + box.w - 8 - ui.measureText(dur, theme.font_small).w, .y = box.y + 4, .w = 60, .h = 14 }, dur, theme.font_small, theme.overlay_fg);
    }

    // 给 `spanRect` 存映射：面板原点与每单位时间的像素
    ui.rememberSize(pid ^ 0xF1A1, px0, kf);
    ui.rememberSize(pid ^ 0xF1A2, body_y0 - scroll_px, row_h);

    return res;
}

fn clampF(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn hitTest(spans: []const Span, view: View, rect: t.Rect, mx: f32, my: f32, row_h: f32, shown_rows: usize) i32 {
    if (!rect.contains(mx, my)) return -1;
    if (my < rect.y + RULER_H) return -1;
    const plot_w = rect.w - PAD_X * 2;
    if (plot_w <= 0) return -1;
    const range = view.end - view.start;
    if (!(range > 0)) return -1;
    const kf: f64 = @as(f64, plot_w) / range;
    const tt = view.start + @as(f64, mx - (rect.x + PAD_X)) / kf;
    const scroll_rows = @floor(view.scroll);
    const scroll_px = (view.scroll - scroll_rows) * row_h;
    const first_row: i32 = @intFromFloat(scroll_rows);
    const rel = my - (rect.y + RULER_H + PAD_Y) + scroll_px;
    if (rel < 0) return -1;
    const row_i = @floor(rel / row_h);
    if (row_i < 0 or row_i >= @as(f32, @floatFromInt(shown_rows))) return -1;
    const row = first_row + @as(i32, @intFromFloat(row_i));
    const rr = rowRange(spans, row);
    var i = rr.lo;
    while (i < rr.hi) : (i += 1) {
        if (tt >= spans[i].start and tt <= spans[i].end) return @intCast(i);
    }
    return -1;
}

fn drawRuler(ui: *core.Context, view: View, rect: t.Rect, px0: f32, plot_w: f32, grid_h: f32, origin: f64) void {
    const range = view.end - view.start;
    if (!(range > 0) or plot_w <= 0) return;
    const step = niceStep(range * 72.0 / @as(f64, plot_w));
    var unit: f64 = 1;
    var uname: []const u8 = "s";
    if (step < 0.1) {
        if (step >= 1e-5) {
            unit = 1e-3;
            uname = "ms";
        } else if (step >= 1e-8) {
            unit = 1e-6;
            uname = "\xc2\xb5s";
        } else {
            unit = 1e-9;
            uname = "ns";
        }
    }
    const kf: f64 = @as(f64, plot_w) / range;
    const first = @ceil((view.start - origin) / step - 1e-9);
    const last = @floor((view.end - origin) / step + 1e-9);
    var q = first;
    var guard: usize = 0;
    while (q <= last and guard < 64) : (guard += 1) {
        const tt = origin + q * step;
        const x = px0 + @as(f32, @floatCast((tt - view.start) * kf));
        ui.addOverlayLine(.{ .x = x, .y = rect.y + RULER_H }, .{ .x = x, .y = rect.y + RULER_H + grid_h }, 1, theme.hair);
        ui.addOverlayLine(.{ .x = x, .y = rect.y + RULER_H - 5 }, .{ .x = x, .y = rect.y + RULER_H }, 1, theme.border);
        var vb = q * step / unit;
        if (@abs(vb) < 1e-9) vb = 0;
        var tmp: [24]u8 = undefined;
        const dec: u8 = if (@abs(vb) >= 100) 0 else if (@abs(vb) >= 10) 1 else 2;
        const ns = num.fixed(tmp[0..], @floatCast(vb), dec);
        var buf: [40]u8 = undefined;
        var n: usize = 0;
        @memcpy(buf[0..ns.len], ns);
        n = ns.len;
        buf[n] = ' ';
        n += 1;
        @memcpy(buf[n..][0..uname.len], uname);
        n += uname.len;
        const lbl = ui.frameStr(buf[0..n]);
        const lw = ui.measureText(lbl, theme.font_small).w;
        if (x + 4 + lw <= rect.x + rect.w - 6) {
            ui.addText(.{ .x = x + 4, .y = rect.y + (RULER_H - 4 - theme.font_small * 1.35) / 2 + 1, .w = lw, .h = theme.font_small * 1.35 }, lbl, theme.font_small, theme.secondary);
        }
        q += 1;
    }
}

fn zoomTo(spans: []const Span, view: *View, index: usize, min_range: f64) void {
    if (index >= spans.len) return;
    const sp = spans[index];
    const span = sp.end - sp.start;
    view.start = sp.start;
    view.end = if (span < min_range) sp.start + min_range else sp.end;
}

fn reveal(spans: []const Span, view: *View, index: usize) void {
    if (index >= spans.len) return;
    const sp = spans[index];
    if (sp.start >= view.start and sp.end <= view.end) return;
    const range = view.end - view.start;
    view.start = sp.start - range * 0.25;
    view.end = view.start + range;
}

/// span 在最近一帧里画在哪儿（点为单位；不在视口内时宽高为 0）。
pub fn spanRect(ui: *core.Context, id: []const u8, spans: []const Span, view: View, span: Span) t.Rect {
    const pid = core.Context.idOf(id);
    const m1 = ui.knownSize(pid ^ 0xF1A1) orelse return .{};
    const m2 = ui.knownSize(pid ^ 0xF1A2) orelse return .{};
    const px0 = m1.w;
    const kf = m1.h;
    const body_y = m2.w;
    const row_h = m2.h;
    if (!(kf > 0)) return .{};
    if (span.end < view.start or span.start > view.end) return .{};
    const x0 = px0 + @as(f32, @floatCast((span.start - view.start) * kf));
    const x1 = px0 + @as(f32, @floatCast((span.end - view.start) * kf));
    const y = body_y + @as(f32, @floatFromInt(span.depth)) * row_h;
    _ = spans;
    return .{ .x = x0, .y = y, .w = @max(x1 - x0, 1), .h = row_h - 2 };
}
