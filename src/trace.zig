//! 追踪视图与网络瀑布（对位 CUI `cui_flame.c` 的 trace / waterfall 两件）。
//! 与火焰图同族：共用时间刻度（`flame.ruler`）、配色（`flame.spanKey` / `spanColor`）
//! 与时长文案（`flame.fmtSeconds`），并排看不会两套颜色。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **不做缩放动画**（CUI 有 spring tween）：缩放 / 适配直接跳到目标范围；
//! - **不做「比一个像素还窄的 span 合并成中性条」**：按像素映射画，细条被裁掉；
//! - **轨道上限 `MAX_TRACKS = 16`**（与 `MAX_SCROLLS` / `MAX_SIZES` 同口径的固定容量池）：
//!   超出的轨道不排布，见 `traceView`；
//! - 瀑布表的虚拟行用 `ui.scroll`（只画视口内的行），不用 CUI 的 `virtual_list_*`；
//! - 瀑布表底部统计条按可用宽度**自己换行**（CUI 用 `NF_ROW_WRAP`）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const flame = @import("flame.zig");

// ====================================================================== 追踪视图

/// 轨道（线程 / 进程 / 服务）上限：与其它跨帧池同口径的固定容量。
pub const MAX_TRACKS = 16;

const RULER_H: f32 = 22;
const MARKS_H: f32 = 18;
const PAD_X: f32 = 8;
const PAD_Y: f32 = 4;
const DRAG_SLOP: f32 = 3;
/// 窄于这个宽度不画 span 标签。
const LABEL_MIN: f32 = 42;
const GUTTER: f32 = 150;
const GUTTER_NARROW: f32 = 96;
const NARROW_W: f32 = 560;

pub const Track = struct {
    name: []const u8 = "",
    /// 折叠成一行（只留 depth 0）。
    collapsed: bool = false,
};

pub const Span = struct {
    name: []const u8 = "",
    /// 秒（任意原点；刻度从最早的那个点起算）。
    start: f64 = 0,
    end: f64 = 0,
    /// 轨道下标（`0..tracks.len`）。
    track: i32 = 0,
    /// 同一条轨道里的嵌套深度，0 最外层。
    depth: i32 = 0,
    /// 0 = 用名字哈希（同一个函数永远同色）。
    color_key: u32 = 0,
};

/// 标记的语义色调（帧、GC 停顿、发布……）。
pub const Tone = enum { neutral, accent, success, warn, danger, info, teal, violet };

pub const Marker = struct {
    name: []const u8 = "",
    time: f64 = 0,
    tone: Tone = .neutral,
};

pub const View = struct {
    /// 可见时间范围；`end <= start` 表示「适配全部」（组件会写回真实范围）。
    start: f64 = 0,
    end: f64 = 0,
    /// 顶部滚出视口的行高倍数（单位：点）。
    scroll: f32 = 0,
    /// Shift+拖拽量出的区间；`mark_end <= mark_start` 表示没有。
    mark_start: f64 = 0,
    mark_end: f64 = 0,
};

pub const Opts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 0 = 按轨道行数（上限 320）。
    height: f32 = 0,
    row_height: f32 = 20,
    /// 画成贯穿所有轨道的竖线 + 顶部小旗。
    markers: []const Marker = &.{},
};

pub const Result = struct {
    selection_changed: bool = false,
    view_changed: bool = false,
    /// 指针下的 span 下标，-1 = 无。
    hovered: i32 = -1,
};

pub const Mode = enum { idle, press, pan, measure };

/// 跨帧的按压状态（拖拽 / 量区间要跨帧记住起点）。调用方持有，初次 `.{}` 即可。
pub const State = struct {
    mode: Mode = .idle,
    press_x: f32 = 0,
    press_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    press_hit: i32 = -1,
    press_track: i32 = -1,
    press_double: bool = false,
};

fn lessSpan(_: void, a: Span, b: Span) bool {
    if (a.track != b.track) return a.track < b.track;
    if (a.depth != b.depth) return a.depth < b.depth;
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end; // 同起点时长者在前
}

/// 按视图需要的顺序排序：轨道 → 深度 → 起点。就地排序，录制后调一次即可。
pub fn sortSpans(spans: []Span) void {
    std.sort.pdq(Span, spans, {}, lessSpan);
}

// ---------------------------------------------------------------- 布局与查找

const Run = struct {
    track: i32 = 0,
    lo: usize = 0,
    hi: usize = 0,
    maxd: i32 = 0,
    row0: i32 = 0,
    rows: i32 = 0,
};

const Layout = struct {
    runs: [MAX_TRACKS]Run = @splat(.{}),
    nt: usize = 0,
    rows: i32 = 0,
    dmin: f64 = 0,
    dmax: f64 = 1,
    row_h: f32 = 20,
    gutter: f32 = GUTTER,
    plot_x: f32 = 0,
    plot_w: f32 = 600,
    body_y: f32 = 0,
    body_h: f32 = 200,
};

const Range = struct { lo: usize = 0, hi: usize = 0 };

/// [lo, hi) 里第一个 (track, depth) 不小于给定值的下标。
fn lowerBound(spans: []const Span, lo_in: usize, hi_in: usize, track: i32, depth: i32) usize {
    var lo = lo_in;
    var hi = hi_in;
    while (lo < hi) {
        const m = lo + (hi - lo) / 2;
        const before = spans[m].track < track or (spans[m].track == track and spans[m].depth < depth);
        if (before) lo = m + 1 else hi = m;
    }
    return lo;
}

fn rowRange(spans: []const Span, r: Run, depth: i32) Range {
    const lo = lowerBound(spans, r.lo, r.hi, r.track, depth);
    const hi = lowerBound(spans, lo, r.hi, r.track, depth + 1);
    return .{ .lo = lo, .hi = hi };
}

/// [lo, hi) 里最后一个 `start <= tt` 的下标；没有则 null。
fn startLe(spans: []const Span, lo_in: usize, hi_in: usize, tt: f64) ?usize {
    var lo = lo_in;
    var hi = hi_in;
    while (lo < hi) {
        const m = lo + (hi - lo) / 2;
        if (spans[m].start <= tt) lo = m + 1 else hi = m;
    }
    if (lo == lo_in) return null;
    return lo - 1;
}

/// [lo, hi) 里第一个 `end > tt` 的下标。
fn endGt(spans: []const Span, lo_in: usize, hi_in: usize, tt: f64) usize {
    var lo = lo_in;
    var hi = hi_in;
    while (lo < hi) {
        const m = lo + (hi - lo) / 2;
        if (spans[m].end <= tt) lo = m + 1 else hi = m;
    }
    return lo;
}

fn layoutOf(spans: []const Span, tracks: []const Track, lay: *Layout, opts: Opts) void {
    lay.row_h = if (opts.row_height > 0) opts.row_height else 20;
    lay.nt = @min(tracks.len, MAX_TRACKS);
    var any = false;
    var row: i32 = 0;
    var at: usize = 0;
    var ti: usize = 0;
    while (ti < lay.nt) : (ti += 1) {
        const tid: i32 = @intCast(ti);
        var r = Run{ .track = tid };
        r.lo = lowerBound(spans, at, spans.len, tid, 0);
        r.hi = lowerBound(spans, r.lo, spans.len, tid + 1, 0);
        at = r.hi;
        r.maxd = if (r.hi > r.lo) @max(spans[r.hi - 1].depth, 0) else 0;
        r.row0 = row;
        r.rows = if (tracks[ti].collapsed) 1 else r.maxd + 1;
        row += r.rows;
        var d: i32 = 0;
        while (d <= r.maxd and r.hi > r.lo) : (d += 1) {
            const rr = rowRange(spans, r, d);
            if (rr.lo >= rr.hi) continue;
            const a = spans[rr.lo].start;
            const b = spans[rr.hi - 1].end;
            if (!any or a < lay.dmin) lay.dmin = a;
            if (!any or b > lay.dmax) lay.dmax = b;
            any = true;
        }
        lay.runs[ti] = r;
    }
    for (opts.markers) |m| {
        if (!std.math.isFinite(m.time)) continue;
        if (!any or m.time < lay.dmin) lay.dmin = m.time;
        if (!any or m.time > lay.dmax) lay.dmax = m.time;
        any = true;
    }
    lay.rows = row;
    if (!any or !(lay.dmax > lay.dmin) or !std.math.isFinite(lay.dmin) or !std.math.isFinite(lay.dmax)) {
        const m: f64 = if (any and std.math.isFinite(lay.dmin)) lay.dmin else 0;
        lay.dmin = m;
        lay.dmax = m + 1;
    }
}

const Row = struct { track: usize = 0, depth: i32 = 0 };

fn trackOf(lay: *const Layout, row: i32) ?Row {
    var ti: usize = 0;
    while (ti < lay.nt) : (ti += 1) {
        const r = lay.runs[ti];
        if (row >= r.row0 and row < r.row0 + r.rows) return .{ .track = ti, .depth = row - r.row0 };
    }
    return null;
}

const Hit = struct { span: i32 = -1, track: i32 = -1 };

fn hitTest(lay: *const Layout, spans: []const Span, v: View, mx: f32, my: f32) Hit {
    var h = Hit{};
    if (lay.plot_w <= 0) return h;
    const yy = my - lay.body_y + v.scroll;
    if (yy < 0) return h;
    const rel = yy / lay.row_h;
    const row: i32 = @intFromFloat(@floor(rel));
    const co = trackOf(lay, row) orelse return h;
    h.track = @intCast(co.track);
    if (mx < lay.plot_x - 1 or mx > lay.plot_x + lay.plot_w + 1) return h;
    if (rel - @floor(rel) > lay.row_h - 1) return h;
    const rr = rowRange(spans, lay.runs[co.track], co.depth);
    if (rr.lo >= rr.hi) return h;
    const range = v.end - v.start;
    if (!(range > 0)) return h;
    const tm = v.start + @as(f64, mx - lay.plot_x) / @as(f64, lay.plot_w) * range;
    const tol = range / @as(f64, lay.plot_w);
    var best: i32 = -1;
    var bd = tol;
    if (startLe(spans, rr.lo, rr.hi, tm)) |k| {
        if (spans[k].end >= tm) return .{ .span = @intCast(k), .track = h.track };
        const gap = tm - spans[k].end;
        if (gap <= bd) {
            bd = gap;
            best = @intCast(k);
        }
        if (k + 1 < rr.hi and spans[k + 1].start - tm <= bd) best = @intCast(k + 1);
    }
    h.span = best;
    return h;
}

fn clampView(lay: *const Layout, v: *View) void {
    const ext = lay.dmax - lay.dmin;
    var range = v.end - v.start;
    if (!(range > 0) or range > ext) range = ext;
    const min_range = ext * 1e-9;
    if (range < min_range) range = min_range;
    var st = v.start;
    if (!(st >= lay.dmin)) st = lay.dmin;
    if (st + range > lay.dmax) st = lay.dmax - range;
    v.start = st;
    v.end = st + range;
    const max_s = @max(0, @as(f32, @floatFromInt(lay.rows)) * lay.row_h - lay.body_h);
    if (!(v.scroll >= 0)) v.scroll = 0;
    if (v.scroll > max_s) v.scroll = max_s;
}

fn timeAt(lay: *const Layout, v: View, x: f32) f64 {
    if (lay.plot_w <= 0) return v.start;
    return v.start + @as(f64, x - lay.plot_x) / @as(f64, lay.plot_w) * (v.end - v.start);
}

fn parentOf(lay: *const Layout, spans: []const Span, i: usize) i32 {
    const sp = spans[i];
    if (sp.depth <= 0 or sp.track < 0 or @as(usize, @intCast(sp.track)) >= lay.nt) return -1;
    const rr = rowRange(spans, lay.runs[@intCast(sp.track)], sp.depth - 1);
    const k = startLe(spans, rr.lo, rr.hi, sp.start) orelse return -1;
    return if (spans[k].end >= sp.end) @intCast(k) else -1;
}

fn childOf(lay: *const Layout, tracks: []const Track, spans: []const Span, i: usize) i32 {
    const sp = spans[i];
    if (sp.track < 0 or @as(usize, @intCast(sp.track)) >= lay.nt) return -1;
    if (tracks[@intCast(sp.track)].collapsed) return -1;
    const rr = rowRange(spans, lay.runs[@intCast(sp.track)], sp.depth + 1);
    const k = endGt(spans, rr.lo, rr.hi, sp.start);
    if (k < rr.hi and spans[k].start >= sp.start and spans[k].start < sp.end) return @intCast(k);
    return -1;
}

fn reveal(lay: *const Layout, v: *View, spans: []const Span, i: usize) void {
    if (i >= spans.len) return;
    const sp = spans[i];
    const range = v.end - v.start;
    if (sp.end < v.start or sp.start > v.end) {
        const mid = (sp.start + sp.end) * 0.5;
        v.start = mid - range * 0.5;
        v.end = mid + range * 0.5;
    }
    if (sp.track >= 0 and @as(usize, @intCast(sp.track)) < lay.nt) {
        const r = lay.runs[@intCast(sp.track)];
        const depth = if (r.rows > 1) sp.depth else 0;
        const top = @as(f32, @floatFromInt(r.row0 + depth)) * lay.row_h;
        if (top < v.scroll) v.scroll = top;
        if (top + lay.row_h > v.scroll + lay.body_h) v.scroll = top + lay.row_h - lay.body_h;
    }
    clampView(lay, v);
}

// ---------------------------------------------------------------- 绘制

/// 色调 → 颜色（8 种语义色；深色主题下信息/青/紫三色提亮）。
/// 导出给同在 "时间轴" 语义下的族（`planning` 的日历/甘特）复用，避免两套色。
pub fn toneColor(tone: Tone) t.Color {
    const dark = theme.isDark();
    return switch (tone) {
        .neutral => theme.secondary,
        .accent => theme.accent,
        .success => theme.success,
        .warn => theme.warn,
        .danger => theme.danger,
        .info => flame.hsl(210.0 / 360.0, 0.62, if (dark) 0.58 else 0.46),
        .teal => flame.hsl(172.0 / 360.0, 0.55, if (dark) 0.52 else 0.40),
        .violet => flame.hsl(268.0 / 360.0, 0.52, if (dark) 0.62 else 0.50),
    };
}

pub fn mixColor(a: t.Color, b: t.Color, k: f32) t.Color {
    return theme.mix(a, b, k);
}

fn paintChevron(ui: *core.Context, x: f32, cy: f32, folded: bool, c: t.Color) void {
    if (folded) {
        ui.addOverlayLine(.{ .x = x, .y = cy - 4 }, .{ .x = x + 6, .y = cy }, 1.4, c);
        ui.addOverlayLine(.{ .x = x + 6, .y = cy }, .{ .x = x, .y = cy + 4 }, 1.4, c);
    } else {
        ui.addOverlayLine(.{ .x = x, .y = cy - 2 }, .{ .x = x + 3, .y = cy + 2 }, 1.4, c);
        ui.addOverlayLine(.{ .x = x + 3, .y = cy + 2 }, .{ .x = x + 6, .y = cy - 2 }, 1.4, c);
    }
}

/// 追踪视图：每个轨道一行，行内是嵌套的 span，一条时间轴 + 贯穿的标记。
///
/// 交互：滚轮在时间轴上缩放（围绕指针）、在轨道名上纵向滚动；Shift+拖拽量区间；
/// 拖拽平移；点击选中；双击缩放到该 span（空白处双击适配全部）；点轨道名折叠。
/// 键盘（需要焦点）：←/→ 同行移动、↑ 父、↓ 子、+/- 缩放、Enter 缩放到选中、F 适配、
/// Esc 先清区间再清选中。
///
/// `state` 由调用方持有并跨帧保留；`selected` 可为 null（不关心选中）。
pub fn traceView(
    ui: *core.Context,
    id: []const u8,
    tracks: []Track,
    spans: []const Span,
    view: *View,
    selected: ?*i32,
    state: *State,
    opts: Opts,
) Result {
    var res = Result{};
    var lay = Layout{ .row_h = if (opts.row_height > 0) opts.row_height else 20 };
    layoutOf(spans, tracks, &lay, opts);

    const head = RULER_H + (if (opts.markers.len > 0) MARKS_H else 0);
    const def_h = head + 2 * PAD_Y + @as(f32, @floatFromInt(@max(4, lay.rows))) * lay.row_h + 2;
    const panel_h = if (opts.height > 0) opts.height else @min(320, def_h);
    const rect0 = ui.reserve(opts.width, panel_h, opts.width <= 0);
    const panel_w = if (opts.width > 0) opts.width else if (rect0.w > 0) rect0.w else 480;
    const rect = t.Rect{ .x = rect0.x, .y = rect0.y, .w = panel_w, .h = panel_h };

    lay.gutter = if (panel_w < NARROW_W) GUTTER_NARROW else GUTTER;
    lay.plot_x = rect.x + lay.gutter + PAD_X;
    lay.plot_w = @max(1, rect.w - lay.gutter - 1 - 2 * PAD_X);
    lay.body_y = rect.y + head + 1 + PAD_Y;
    lay.body_h = @max(1, rect.h - head - 2 - 2 * PAD_Y);

    // 视口首次适配
    if (!(view.end > view.start) or !std.math.isFinite(view.start) or !std.math.isFinite(view.end)) {
        view.start = lay.dmin;
        view.end = lay.dmax;
        res.view_changed = true;
    }

    const pid = core.Context.idOf(id);
    const it = ui.interactEx(pid, rect, true);
    const mx = ui.input.mouse.x;
    const my = ui.input.mouse.y;

    // ---- 滚轮：时间轴上缩放、Shift 平移、轨道名上纵向滚动
    if (it.hover and ui.input.wheel != 0 and lay.plot_w > 0) {
        const range = view.end - view.start;
        if (mx < rect.x + lay.gutter) {
            view.scroll -= ui.input.wheel * 40;
        } else if (ui.input.mods.shift) {
            const dt = @as(f64, ui.input.wheel) * 40.0 / @as(f64, lay.plot_w) * range;
            view.start -= dt;
            view.end -= dt;
        } else {
            const z = zoomFactor(ui.input.wheel);
            const nr = @min(range / z, lay.dmax - lay.dmin);
            const u = clamp01(@as(f64, mx - lay.plot_x) / @as(f64, lay.plot_w));
            const tm = view.start + u * range;
            view.start = tm - u * nr;
            view.end = view.start + nr;
        }
        res.view_changed = true;
    }

    // ---- 按压：折叠轨道 / Shift+拖拽量区间 / 拖拽平移 / 点击选中 / 双击缩放
    if (it.hover and ui.input.pressed and state.mode == .idle and my >= lay.body_y - PAD_Y) {
        state.press_x = mx;
        state.press_y = my;
        state.last_x = mx;
        state.last_y = my;
        const hh = hitTest(&lay, spans, view.*, mx, my);
        state.press_hit = hh.span;
        state.press_track = hh.track;
        state.press_double = false;
        if (mx < rect.x + lay.gutter) {
            const ti = hh.track;
            if (ti >= 0 and ti < @as(i32, @intCast(lay.nt)) and lay.runs[@intCast(ti)].maxd > 0) {
                tracks[@intCast(ti)].collapsed = !tracks[@intCast(ti)].collapsed;
                layoutOf(spans, tracks, &lay, opts);
                res.view_changed = true;
            }
        } else if (ui.input.mods.shift) {
            state.mode = .measure;
            view.mark_start = timeAt(&lay, view.*, mx);
            view.mark_end = view.mark_start;
        } else {
            state.mode = .press;
        }
    }
    if (state.mode == .measure) {
        const a = timeAt(&lay, view.*, state.press_x);
        const b = timeAt(&lay, view.*, mx);
        view.mark_start = @min(a, b);
        view.mark_end = @max(a, b);
        res.view_changed = true;
        if (!ui.input.down) state.mode = .idle;
    } else {
        if (state.mode == .press and ui.input.down) {
            const dx = mx - state.press_x;
            const dy = my - state.press_y;
            if (dx * dx + dy * dy > DRAG_SLOP * DRAG_SLOP) state.mode = .pan;
        }
        if (state.mode == .pan) {
            if (lay.plot_w > 0) {
                const dt = @as(f64, mx - state.last_x) / @as(f64, lay.plot_w) * (view.end - view.start);
                view.start -= dt;
                view.end -= dt;
            }
            view.scroll -= my - state.last_y;
            state.last_x = mx;
            state.last_y = my;
            res.view_changed = true;
            if (!ui.input.down) state.mode = .idle;
        } else if (state.mode == .press and !ui.input.down) {
            state.mode = .idle;
            // 双击 = 两次点击间隔 < 450ms 且落在同一处（用尺寸池记，不加字段）
            const dbl_key = pid ^ 0x7A1B;
            const prev = ui.knownSize(dbl_key);
            const is_double = if (prev) |p|
                (ui.time * 1000.0 - @as(f64, p.w) < 450.0 and @as(i32, @intFromFloat(@max(p.h, -1))) == state.press_hit)
            else
                false;
            ui.rememberSize(dbl_key, @as(f32, @floatCast(ui.time * 1000.0)), @floatFromInt(state.press_hit));
            state.press_double = is_double;
            if (selected) |s| {
                if (s.* != state.press_hit) {
                    s.* = state.press_hit;
                    res.selection_changed = true;
                }
            }
            if (is_double) {
                if (state.press_hit >= 0 and @as(usize, @intCast(state.press_hit)) < spans.len) {
                    const sp = spans[@intCast(state.press_hit)];
                    const d = @max(sp.end - sp.start, (lay.dmax - lay.dmin) * 1e-9);
                    view.start = sp.start - d * 0.05;
                    view.end = sp.start + d * 1.05;
                } else {
                    view.start = lay.dmin;
                    view.end = lay.dmax;
                }
                res.view_changed = true;
            }
        }
    }

    // ---- 键盘
    const sel_before: i32 = if (selected) |s| s.* else -1;
    if (it.focused) keys(ui, &lay, tracks, spans, view, selected, &res);
    if (selected) |s| {
        if (s.* >= @as(i32, @intCast(spans.len))) s.* = -1;
        if (s.* != sel_before) res.selection_changed = true;
    }
    clampView(&lay, view);

    const sel: i32 = if (selected) |s| s.* else -1;
    const hover = if (it.hover and state.mode != .pan and rect.contains(mx, my)) hitTest(&lay, spans, view.*, mx, my) else Hit{};
    res.hovered = hover.span;

    // ---- 绘制
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 10, .border = theme.border });
    const cap = @min(head, 12);
    ui.addBox(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = cap }, .{ .fill = theme.raised, .radius = 10 });
    ui.addBox(.{ .x = rect.x, .y = rect.y + cap, .w = rect.w, .h = head - cap }, .{ .fill = theme.raised });

    const plot = t.Rect{ .x = lay.plot_x, .y = rect.y, .w = lay.plot_w, .h = lay.body_h + PAD_Y };
    flame.ruler(ui, .{ .x = plot.x, .y = plot.y, .w = plot.w, .h = rect.h - head - 2 }, lay.plot_x, lay.plot_w, rect.h - RULER_H - 2, view.start, view.end, lay.dmin);

    const range = view.end - view.start;
    const k: f32 = if (range > 0) @floatCast(@as(f64, lay.plot_w) / range) else 0;

    // 横道：隔一条轨道压一层，轨道之间一条细线
    const saved_clip = ui.clip;
    ui.clip = intersect(saved_clip, t.Rect{ .x = rect.x, .y = lay.body_y - PAD_Y, .w = rect.w, .h = lay.body_h + PAD_Y * 2 });
    var ti: usize = 0;
    while (ti < lay.nt) : (ti += 1) {
        const r = lay.runs[ti];
        const y = lay.body_y + @as(f32, @floatFromInt(r.row0)) * lay.row_h - view.scroll;
        const h = @as(f32, @floatFromInt(r.rows)) * lay.row_h;
        if (y > rect.y + rect.h or y + h < lay.body_y) continue;
        if (ti % 2 == 1) ui.addBox(.{ .x = rect.x + 1, .y = y - 1, .w = rect.w - 2, .h = h + 1 }, .{ .fill = theme.row_alt });
        if (ti > 0) ui.addOverlayLine(.{ .x = rect.x, .y = y - 1 }, .{ .x = rect.x + rect.w, .y = y - 1 }, 1, theme.hair);
    }
    // 轨道名（含折叠箭头）
    ti = 0;
    while (ti < lay.nt) : (ti += 1) {
        const r = lay.runs[ti];
        const y = lay.body_y + @as(f32, @floatFromInt(r.row0)) * lay.row_h - view.scroll;
        if (y > lay.body_y + lay.body_h or y + lay.row_h < lay.body_y) continue;
        const foldable = r.maxd > 0;
        const c = if (hover.track == @as(i32, @intCast(ti)) and foldable) theme.text else theme.secondary;
        if (foldable) paintChevron(ui, rect.x + 9, y + (lay.row_h - 1) * 0.5, tracks[ti].collapsed, theme.withAlpha(c, 200));
        const tx = rect.x + 22;
        ui.addText(.{ .x = tx, .y = y + (lay.row_h - 1 - theme.font_small * 1.35) / 2, .w = @max(0, lay.gutter - 30), .h = theme.font_small * 1.35 }, tracks[ti].name, theme.font_small, c);
    }
    ui.clip = saved_clip;

    // span：只画视口内的行
    ui.clip = intersect(saved_clip, .{ .x = lay.plot_x, .y = lay.body_y - 1, .w = lay.plot_w, .h = lay.body_h + 2 });
    if (k > 0) {
        const first: i32 = @intFromFloat(@floor(view.scroll / lay.row_h));
        const last: i32 = @intFromFloat(@floor((view.scroll + lay.body_h) / lay.row_h));
        var row = @max(0, first);
        while (row <= @min(lay.rows - 1, last)) : (row += 1) {
            const co = trackOf(&lay, row) orelse continue;
            if (tracks[co.track].collapsed and co.depth > 0) continue;
            const rr = rowRange(spans, lay.runs[co.track], co.depth);
            const y = lay.body_y + @as(f32, @floatFromInt(row)) * lay.row_h - view.scroll;
            var i = endGt(spans, rr.lo, rr.hi, view.start);
            while (i < rr.hi and spans[i].start < view.end) : (i += 1) {
                const sp = spans[i];
                const x0 = lay.plot_x + @as(f32, @floatCast((sp.start - view.start) * @as(f64, @floatCast(k))));
                const x1 = lay.plot_x + @as(f32, @floatCast((sp.end - view.start) * @as(f64, @floatCast(k))));
                const w = @max(x1 - x0, 1.0);
                const bar = t.Rect{ .x = x0, .y = y, .w = w, .h = lay.row_h - 2 };
                ui.addBox(bar, .{ .fill = flame.spanColor(flame.spanKey(sp.name, sp.color_key)), .radius = 3 });
                if (sel == @as(i32, @intCast(i))) ui.addBox(bar.inset(1), .{ .border = theme.accent_text, .radius = 3 });
                if (w >= LABEL_MIN and sp.name.len > 0) {
                    ui.addText(.{ .x = bar.x + 4, .y = bar.y + (bar.h - theme.font_small * 1.35) / 2, .w = w - 8, .h = theme.font_small * 1.35 }, sp.name, theme.font_small, theme.text);
                }
            }
        }
    }
    ui.clip = saved_clip;

    // 标记：贯穿所有轨道的竖线 + 顶部小旗 + 名字
    if (opts.markers.len > 0 and k > 0) {
        const strip_y = rect.y + RULER_H;
        for (opts.markers) |m| {
            const x = @floor(lay.plot_x + @as(f32, @floatCast((m.time - view.start) * @as(f64, @floatCast(k)))));
            if (x < lay.plot_x - 40 or x > lay.plot_x + lay.plot_w) continue;
            const c = toneColor(m.tone);
            ui.addOverlayLine(.{ .x = x, .y = strip_y }, .{ .x = x, .y = lay.body_y + lay.body_h }, 1, theme.withAlpha(c, 140));
            ui.addOverlayBox(.{ .x = x - 3, .y = strip_y + 3, .w = 7, .h = 5 }, .{ .fill = c, .radius = 1 });
            if (m.name.len > 0 and x >= lay.plot_x) {
                var next = lay.plot_x + lay.plot_w;
                for (opts.markers) |o| {
                    const xj = lay.plot_x + @as(f32, @floatCast((o.time - view.start) * @as(f64, @floatCast(k))));
                    if (xj > x + 1 and xj < next) next = xj;
                }
                const avail = next - (x + 8) - 6;
                if (avail >= 24) {
                    ui.addText(.{ .x = x + 8, .y = strip_y + (MARKS_H - theme.font_small * 1.35) / 2, .w = avail, .h = theme.font_small * 1.35 }, m.name, theme.font_small, theme.secondary);
                }
            }
        }
    }

    // 量出的区间：淡底 + 两条边 + 刻度栏里的时长药丸
    if (view.mark_end > view.mark_start and k > 0) {
        const x0 = clampF(lay.plot_x + @as(f32, @floatCast((view.mark_start - view.start) * @as(f64, @floatCast(k)))), lay.plot_x - 2, lay.plot_x + lay.plot_w + 2);
        const x1 = clampF(lay.plot_x + @as(f32, @floatCast((view.mark_end - view.start) * @as(f64, @floatCast(k)))), lay.plot_x - 2, lay.plot_x + lay.plot_w + 2);
        if (x1 > x0) {
            ui.addOverlayBox(.{ .x = x0, .y = lay.body_y - PAD_Y, .w = x1 - x0, .h = lay.body_h + PAD_Y }, .{ .fill = theme.accent_bg });
            ui.addOverlayLine(.{ .x = x0, .y = lay.body_y - PAD_Y }, .{ .x = x0, .y = lay.body_y + lay.body_h }, 1, theme.accent);
            ui.addOverlayLine(.{ .x = x1, .y = lay.body_y - PAD_Y }, .{ .x = x1, .y = lay.body_y + lay.body_h }, 1, theme.accent);
            var buf: [32]u8 = undefined;
            const lbl = ui.frameStr(flame.fmtSeconds(buf[0..], view.mark_end - view.mark_start));
            const lw = ui.measureText(lbl, theme.font_small).w;
            const cx = clampF((x0 + x1) * 0.5, lay.plot_x + lw * 0.5 + 2, lay.plot_x + lay.plot_w - lw * 0.5 - 2);
            const pill = t.Rect{ .x = cx - lw * 0.5 - 6, .y = rect.y + 3, .w = lw + 12, .h = RULER_H - 6 };
            ui.addOverlayBox(pill, .{ .fill = theme.accent, .radius = pill.h * 0.5 });
            ui.addText(.{ .x = pill.x + 6, .y = pill.y + (pill.h - theme.font_small * 1.35) / 2, .w = lw, .h = theme.font_small * 1.35 }, lbl, theme.font_small, theme.accent_text);
        }
    }

    // 空状态 + 纵向滚动条
    if (spans.len == 0) {
        ui.addText(.{ .x = lay.plot_x + lay.plot_w * 0.5 - 40, .y = lay.body_y + lay.body_h * 0.5 - 8, .w = 90, .h = 18 }, "No spans", theme.font_small, theme.secondary);
    }
    const content_h = @as(f32, @floatFromInt(lay.rows)) * lay.row_h;
    if (content_h > lay.body_h + 0.5 and lay.body_h > 8) {
        const th = @max(16, lay.body_h * lay.body_h / content_h);
        const ty = lay.body_y + (lay.body_h - th) * (view.scroll / (content_h - lay.body_h));
        ui.addBox(.{ .x = rect.x + rect.w - 5, .y = ty, .w = 3, .h = th }, .{ .fill = theme.withAlpha(theme.secondary, 110), .radius = 1.5 });
    }

    // 悬浮提示（自绘小卡片：名字 / 时长 / 起点 / 轨道）
    if (hover.span >= 0 and @as(usize, @intCast(hover.span)) < spans.len and state.mode != .pan) {
        const sp = spans[@intCast(hover.span)];
        var lines: [4][]const u8 = undefined;
        var n: usize = 0;
        lines[n] = if (sp.name.len > 0) sp.name else "Unnamed span";
        n += 1;
        var d1: [32]u8 = undefined;
        lines[n] = ui.frameStr(flame.fmtSeconds(d1[0..], sp.end - sp.start));
        n += 1;
        var d2: [48]u8 = undefined;
        const off = flame.fmtSeconds(d2[0..], sp.start - lay.dmin);
        var ob: [64]u8 = undefined;
        var on: usize = 0;
        const pfx = "at ";
        @memcpy(ob[0..pfx.len], pfx);
        on = pfx.len;
        @memcpy(ob[on..][0..off.len], off);
        on += off.len;
        lines[n] = ui.frameStr(ob[0..on]);
        n += 1;
        if (sp.track >= 0 and @as(usize, @intCast(sp.track)) < tracks.len and tracks[@intCast(sp.track)].name.len > 0) {
            lines[n] = tracks[@intCast(sp.track)].name;
            n += 1;
        }
        tooltip(ui, &lay, rect, mx, my, lines[0..n]);
    }

    return res;
}

fn tooltip(ui: *core.Context, lay: *const Layout, rect: t.Rect, mx: f32, my: f32, lines: []const []const u8) void {
    var w: f32 = 0;
    for (lines) |l| {
        const m = ui.measureText(l, theme.font_small).w;
        if (m > w) w = m;
    }
    const lh = theme.font_small * 1.35 + 2;
    const box = t.Rect{
        .x = clampF(mx + 12, rect.x + 4, @max(rect.x + 4, rect.x + rect.w - w - 20)),
        .y = clampF(my - 10, rect.y + 2, @max(rect.y + 2, lay.body_y + lay.body_h - lh * @as(f32, @floatFromInt(lines.len)) - 8)),
        .w = w + 16,
        .h = lh * @as(f32, @floatFromInt(lines.len)) + 8,
    };
    ui.addOverlayBox(box, .{ .fill = theme.overlay_bg, .radius = 6 });
    for (lines, 0..) |l, i| {
        ui.addText(.{ .x = box.x + 8, .y = box.y + 4 + lh * @as(f32, @floatFromInt(i)), .w = w, .h = lh }, l, theme.font_small, theme.overlay_fg);
    }
}

fn keys(
    ui: *core.Context,
    lay: *Layout,
    tracks: []const Track,
    spans: []const Span,
    view: *View,
    selected: ?*i32,
    res: *Result,
) void {
    const cur: i32 = if (selected) |s| s.* else -1;
    var nxt = cur;
    const left = ui.input.keyPressed(.left);
    const right = ui.input.keyPressed(.right);
    const up = ui.input.keyPressed(.up);
    const down = ui.input.keyPressed(.down);
    if (left or right or up or down) {
        if (cur < 0) {
            var ti: usize = 0;
            while (ti < lay.nt and nxt < 0) : (ti += 1) {
                const rr = rowRange(spans, lay.runs[ti], 0);
                const k = endGt(spans, rr.lo, rr.hi, view.start);
                if (k < rr.hi) nxt = @intCast(k);
            }
        } else if (left) {
            if (cur > 0 and spans[@intCast(cur - 1)].track == spans[@intCast(cur)].track and spans[@intCast(cur - 1)].depth == spans[@intCast(cur)].depth) nxt = cur - 1;
        } else if (right) {
            const n = @as(i32, @intCast(spans.len));
            if (cur + 1 < n and spans[@intCast(cur + 1)].track == spans[@intCast(cur)].track and spans[@intCast(cur + 1)].depth == spans[@intCast(cur)].depth) nxt = cur + 1;
        } else if (up) {
            const pk = parentOf(lay, spans, @intCast(cur));
            if (pk >= 0) nxt = pk;
        } else {
            const ck = childOf(lay, tracks, spans, @intCast(cur));
            if (ck >= 0) nxt = ck;
        }
        if (nxt >= 0 and nxt != cur) {
            if (selected) |s| s.* = nxt;
            reveal(lay, view, spans, @intCast(nxt));
            res.selection_changed = true;
            res.view_changed = true;
        }
    }
    const plus = ui.input.keyPressed(.equal);
    if (plus or ui.input.keyPressed(.minus)) {
        const cx = (view.start + view.end) * 0.5;
        const z: f64 = if (plus) 1.0 / 1.25 else 1.25;
        const nr = @min((view.end - view.start) * z, lay.dmax - lay.dmin);
        view.start = cx - nr * 0.5;
        view.end = cx + nr * 0.5;
        res.view_changed = true;
    }
    if (ui.input.keyPressed(.enter) and cur >= 0 and @as(usize, @intCast(cur)) < spans.len) {
        const sp = spans[@intCast(cur)];
        const d = @max(sp.end - sp.start, (lay.dmax - lay.dmin) * 1e-9);
        view.start = sp.start - d * 0.05;
        view.end = sp.start + d * 1.05;
        res.view_changed = true;
    }
    if ((ui.input.keyPressed(.F) or ui.input.keyPressed(.home)) and !ui.input.mods.ctrl) {
        view.start = lay.dmin;
        view.end = lay.dmax;
        res.view_changed = true;
    }
    if (ui.input.keyPressed(.escape)) {
        if (view.mark_end > view.mark_start) {
            view.mark_start = 0;
            view.mark_end = 0;
        } else if (selected) |s| {
            if (s.* != -1) {
                s.* = -1;
                res.selection_changed = true;
            }
        }
        res.view_changed = true;
    }
}

fn clampF(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn clamp01(v: f64) f64 {
    if (!(v > 0)) return 0;
    if (v > 1) return 1;
    return v;
}

/// 1.12^steps（一次滚动通常是 ±1~±5 格）：不用 libm 的 pow。
fn zoomFactor(steps: f32) f64 {
    var s = steps;
    const up = s > 0;
    if (s < 0) s = -s;
    var z: f64 = 1;
    var i: usize = 0;
    while (i < 20 and s >= 1) : (i += 1) {
        z *= 1.12;
        s -= 1;
    }
    if (s > 0) z *= 1.0 + 0.12 * @as(f64, s);
    return if (up) z else 1.0 / z;
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

// ====================================================================== 网络瀑布

/// 一轮请求的计时分段数：排队 / DNS / 连接 / TLS / 等待首字节 / 下载。
pub const PHASES = 6;
pub const phase_names = [PHASES][]const u8{ "Queued", "DNS", "Connect", "TLS", "Waiting", "Download" };

pub const NetRequest = struct {
    name: []const u8 = "",
    method: []const u8 = "",
    /// HTTP 状态码，0 = 还没回来（显示 pending）。
    status: i32 = 0,
    type: []const u8 = "",
    /// 响应字节数，0 = 未知（显示 —）。
    size: u64 = 0,
    /// 从页面开始算起的起点（秒）。
    start: f64 = 0,
    timing: [PHASES]f32 = @splat(0),
};

pub const WaterfallOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 整块面板高度（表头 + 行 + 统计条），默认 320。
    height: f32 = 0,
    /// 当前选中行（可为 null：不关心）。
    selected: ?*i32 = null,
    /// DOMContentLoaded / load 的竖线（秒）；0 = 不画。
    dom_loaded: f64 = 0,
    loaded: f64 = 0,
};

pub const WaterfallResult = struct {
    clicked: i32 = -1,
    /// 本帧被「激活」（双击或回车）。
    activated: i32 = -1,
    hovered: i32 = -1,
};

const WF_HEAD: f32 = 28;
const WF_ROW: f32 = 26;
const WF_NARROW: f32 = 600;
const WF_PADX: f32 = 10;

fn wfTotal(q: NetRequest) f64 {
    var s: f64 = 0;
    for (q.timing) |p| {
        if (p > 0) s += p;
    }
    return s;
}

fn phaseColor(k: usize) t.Color {
    return switch (k) {
        0 => theme.secondary,
        1 => toneColor(.teal),
        2 => toneColor(.warn),
        3 => toneColor(.violet),
        4 => mixColor(theme.surface, toneColor(.success), 0.55),
        else => toneColor(.info),
    };
}

fn fmtBytes(buf: []u8, bytes: u64) []const u8 {
    if (bytes == 0) return "0 B";
    if (bytes < 1024) {
        var tmp: [24]u8 = undefined;
        const d = num.int(tmp[0..], @intCast(bytes));
        @memcpy(buf[0..d.len], d);
        buf[d.len] = ' ';
        buf[d.len + 1] = 'B';
        return buf[0 .. d.len + 2];
    }
    const kv: f32 = @floatFromInt(bytes);
    var tmp: [24]u8 = undefined;
    if (bytes < 1024 * 1024) {
        const d = num.fixed(tmp[0..], kv / 1024.0, if (bytes < 10 * 1024) 1 else 0);
        @memcpy(buf[0..d.len], d);
        buf[d.len] = ' ';
        buf[d.len + 1] = 'K';
        buf[d.len + 2] = 'B';
        return buf[0 .. d.len + 3];
    }
    const d = num.fixed(tmp[0..], kv / (1024.0 * 1024.0), 1);
    @memcpy(buf[0..d.len], d);
    buf[d.len] = ' ';
    buf[d.len + 1] = 'M';
    buf[d.len + 2] = 'B';
    return buf[0 .. d.len + 3];
}

/// 路径的最后一段（`/a/b.js?v=1` → `b.js`）：名字列要短。
fn shortName(name: []const u8) []const u8 {
    var slash: ?usize = null;
    var i: usize = 0;
    while (i < name.len and name[i] != '?' and name[i] != '#') : (i += 1) {
        if (name[i] == '/' and i + 1 < name.len and name[i + 1] != '?' and name[i + 1] != '#') slash = i;
    }
    if (slash) |s| return name[s + 1 .. name.len];
    return name;
}

const Note = struct { text: []const u8, color: t.Color, swatch: ?t.Color = null };

/// 底部统计条的内容（请求数 / 体积 / 完成时间 / 两条事件线 / 五个阶段的图例）。
fn wfNotes(ui: *core.Context, requests: []const NetRequest, opts: WaterfallOpts, out: *[10]Note) usize {
    var bytes: u64 = 0;
    var fin: f64 = 0;
    for (requests) |q| {
        bytes += q.size;
        fin = @max(fin, q.start + wfTotal(q));
    }
    var n: usize = 0;
    {
        var buf: [40]u8 = undefined;
        const d = num.int(buf[0..], @intCast(requests.len));
        const m = d.len;
        const sfx = if (requests.len == 1) " request" else " requests";
        @memcpy(buf[m..][0..sfx.len], sfx);
        out[n] = .{ .text = ui.frameStr(buf[0 .. m + sfx.len]), .color = theme.secondary };
        n += 1;
    }
    {
        var buf: [24]u8 = undefined;
        out[n] = .{ .text = ui.frameStr(fmtBytes(buf[0..], bytes)), .color = theme.secondary };
        n += 1;
    }
    {
        var d: [32]u8 = undefined;
        var buf: [48]u8 = undefined;
        const pfx = "Finished in ";
        @memcpy(buf[0..pfx.len], pfx);
        const s = flame.fmtSeconds(d[0..], fin);
        @memcpy(buf[pfx.len..][0..s.len], s);
        out[n] = .{ .text = ui.frameStr(buf[0 .. pfx.len + s.len]), .color = theme.secondary };
        n += 1;
    }
    if (opts.dom_loaded > 0) {
        var d: [32]u8 = undefined;
        var buf: [56]u8 = undefined;
        const pfx = "DOMContentLoaded ";
        @memcpy(buf[0..pfx.len], pfx);
        const s = flame.fmtSeconds(d[0..], opts.dom_loaded);
        @memcpy(buf[pfx.len..][0..s.len], s);
        out[n] = .{ .text = ui.frameStr(buf[0 .. pfx.len + s.len]), .color = toneColor(.info) };
        n += 1;
    }
    if (opts.loaded > 0) {
        var d: [32]u8 = undefined;
        var buf: [48]u8 = undefined;
        const pfx = "Load ";
        @memcpy(buf[0..pfx.len], pfx);
        const s = flame.fmtSeconds(d[0..], opts.loaded);
        @memcpy(buf[pfx.len..][0..s.len], s);
        out[n] = .{ .text = ui.frameStr(buf[0 .. pfx.len + s.len]), .color = theme.danger };
        n += 1;
    }
    var ph: usize = 1;
    while (ph < PHASES) : (ph += 1) {
        out[n] = .{ .text = phase_names[ph], .color = theme.secondary, .swatch = phaseColor(ph) };
        n += 1;
    }
    return n;
}

fn notesHeight(ui: *core.Context, notes: []const Note, w: f32) f32 {
    const lh: f32 = 18;
    var lines: f32 = 1;
    var x: f32 = 0;
    for (notes) |nt| {
        const iw = ui.measureText(nt.text, theme.font_small).w + (if (nt.swatch != null) @as(f32, 18) else 14);
        if (x > 0 and x + iw > w) {
            lines += 1;
            x = 0;
        }
        x += iw;
    }
    return lines * lh + 10;
}

fn notesDraw(ui: *core.Context, notes: []const Note, rect: t.Rect) void {
    const lh: f32 = 18;
    var x: f32 = rect.x;
    var y: f32 = rect.y + 5;
    for (notes) |nt| {
        const tw = ui.measureText(nt.text, theme.font_small).w;
        const iw = tw + (if (nt.swatch != null) @as(f32, 18) else 14);
        if (x > rect.x and x + iw > rect.x + rect.w) {
            x = rect.x;
            y += lh;
        }
        if (nt.swatch) |sw| {
            ui.addBox(.{ .x = x + 4, .y = y + 4, .w = 8, .h = 8 }, .{ .fill = sw, .radius = 2 });
        }
        ui.addText(.{ .x = x + (if (nt.swatch != null) @as(f32, 16) else 10), .y = y + (lh - theme.font_small * 1.35) / 2, .w = tw + 2, .h = theme.font_small * 1.35 }, nt.text, theme.font_small, nt.color);
        x += iw;
    }
}

/// 网络瀑布：一张表（名字 / 方法 / 状态 / 类型 / 体积）+ 一条共用的时间条。
///
/// 每行的条把请求拆成排队 / DNS / 连接 / TLS / 等待首字节 / 下载，和两条事件线
/// （DOMContentLoaded、load）同一条时间轴；悬停看分段明细；↑↓ 移动、Enter 激活、
/// Esc 取消选中。只画视口内的行。
pub fn waterfall(ui: *core.Context, id: []const u8, requests: []const NetRequest, opts: WaterfallOpts) WaterfallResult {
    var res = WaterfallResult{};
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 800;
    const narrow = w < WF_NARROW;
    const name_w = if (narrow) clampF(w * 0.36, 90, 170) else clampF(w * 0.26, 140, 300);
    const total_h = if (opts.height > 0) opts.height else 320;

    var notes: [10]Note = undefined;
    const nn = wfNotes(ui, requests, opts, &notes);
    const foot_h = notesHeight(ui, notes[0..nn], @max(w - 20, 120));
    const list_h = @max(60, total_h - WF_HEAD - 1 - foot_h);

    // 时间轴上限：最后一个字节或事件线，再留 4%
    var end: f64 = 0;
    for (requests) |q| end = @max(end, q.start + wfTotal(q));
    end = @max(end, @max(opts.dom_loaded, opts.loaded));
    end = if (end > 0) end * 1.04 else 1;

    // 时间条列的位置：固定的列之后
    const fixed: f32 = if (narrow) 44 else (48 + 44 + 56 + 60);
    const gap: f32 = 8;
    const col_gaps: f32 = if (narrow) 2 else 5;
    const bar_w_col = @max(60, w - WF_PADX * 2 - name_w - fixed - gap * col_gaps - 6);

    // 整块面板一次占位（表头 / 行区 / 统计条都按绝对坐标排：
    // 试过 `ui.column` + `ui.scroll`，靠 defer 关作用域时行区与统计条的位置会串，
    // 这里直白算，几何一眼可验）
    const panel = ui.reserve(w, total_h, opts.width <= 0);
    ui.addBox(panel, .{ .fill = theme.surface, .radius = 10, .border = theme.border });
    const hdr = t.Rect{ .x = panel.x, .y = panel.y, .w = panel.w, .h = WF_HEAD };
    const list = t.Rect{ .x = panel.x, .y = panel.y + WF_HEAD + 1, .w = panel.w, .h = list_h };
    const foot = t.Rect{ .x = panel.x, .y = panel.y + total_h - foot_h, .w = panel.w, .h = foot_h };

    // ---- 表头（含时间刻度）
    {
        ui.addBox(hdr, .{ .fill = theme.raised, .radius = 10 });
        ui.addBox(.{ .x = hdr.x, .y = hdr.y + 10, .w = hdr.w, .h = WF_HEAD - 10 }, .{ .fill = theme.raised });
        const ty = hdr.y + (WF_HEAD - theme.font_small * 1.35) / 2;
        var x = hdr.x + 4 + WF_PADX;
        ui.addText(.{ .x = x, .y = ty, .w = name_w, .h = theme.font_small * 1.35 }, "Name", theme.font_small, theme.secondary);
        x += name_w + gap;
        if (!narrow) {
            ui.addText(.{ .x = x, .y = ty, .w = 48, .h = theme.font_small * 1.35 }, "Method", theme.font_small, theme.secondary);
            x += 48 + gap;
        }
        ui.addText(.{ .x = x, .y = ty, .w = 44, .h = theme.font_small * 1.35 }, "Status", theme.font_small, theme.secondary);
        x += 44 + gap;
        if (!narrow) {
            ui.addText(.{ .x = x, .y = ty, .w = 56, .h = theme.font_small * 1.35 }, "Type", theme.font_small, theme.secondary);
            x += 56 + gap;
            const sw = ui.measureText("Size", theme.font_small).w;
            ui.addText(.{ .x = x + 60 - sw, .y = ty, .w = sw + 2, .h = theme.font_small * 1.35 }, "Size", theme.font_small, theme.secondary);
            x += 60 + gap;
        }
        // 刻度：与行里的条共用 0..end 的时间轴
        const bar_w_here = @max(40, hdr.x + hdr.w - 6 - x);
        flame.ruler(ui, .{ .x = x, .y = hdr.y, .w = bar_w_here, .h = WF_HEAD }, x, bar_w_here, 0, 0, end, 0);
        ui.addOverlayLine(.{ .x = hdr.x, .y = hdr.y + WF_HEAD - 1 }, .{ .x = hdr.x + hdr.w, .y = hdr.y + WF_HEAD - 1 }, 1, theme.border);
        // 事件线的小旗（表头里，压在刻度的底部）
        const kx: f32 = @floatCast(@as(f64, bar_w_here) / end);
        if (opts.dom_loaded > 0) ui.addOverlayBox(.{ .x = @floor(x + @as(f32, @floatCast(opts.dom_loaded * @as(f64, @floatCast(kx))))) - 1, .y = hdr.y + WF_HEAD - 9, .w = 7, .h = 5 }, .{ .fill = toneColor(.info), .radius = 1 });
        if (opts.loaded > 0) ui.addOverlayBox(.{ .x = @floor(x + @as(f32, @floatCast(opts.loaded * @as(f64, @floatCast(kx))))) - 1, .y = hdr.y + WF_HEAD - 9, .w = 7, .h = 5 }, .{ .fill = theme.danger, .radius = 1 });
    }

    // ---- 行区：自己滚（滚轮 + 裁剪 + 滚动条），只画视口内的行
    const content_h = @as(f32, @floatFromInt(requests.len)) * WF_ROW;
    var off = ui.scrollOffset(id);
    const max_off = @max(0, content_h - list.h);
    const list_hit = ui.interact(core.Context.idOf(id) ^ 0x5C0F, list);
    if (list_hit.hover and ui.input.wheel != 0) {
        off -= ui.input.wheel * 32;
        if (off < 0) off = 0;
        if (off > max_off) off = max_off;
        ui.scrollTo(id, off);
    }
    if (off > max_off) off = max_off;
    const row_x0 = list.x + 4;
    {
        const saved = ui.clip;
        ui.clip = intersect(saved, list);
        if (requests.len == 0) {
            ui.addText(.{ .x = list.x + list.w * 0.5 - 45, .y = list.y + list.h * 0.5 - 8, .w = 100, .h = 18 }, "No requests", theme.font_small, theme.secondary);
        } else {
            // 表格竖网格：一次画到底（比每行各画一遍省指令，视觉一样）
            {
                const gx0 = row_x0 + WF_PADX + name_w + fixed + gap * col_gaps;
                const kx = bar_w_col / end;
                const step = flame.niceStep(end * 72.0 / @as(f64, bar_w_col));
                var q: usize = 1;
                while (@as(f64, @floatFromInt(q)) * step <= end + 1e-9 and q < 400) : (q += 1) {
                    const gx = gx0 + @as(f32, @floatCast(step * @as(f64, @floatFromInt(q)) * kx));
                    ui.addOverlayLine(.{ .x = @floor(gx), .y = list.y }, .{ .x = @floor(gx), .y = list.y + list.h }, 1, theme.hair);
                }
                // 事件线贯穿所有行
                if (opts.dom_loaded > 0) {
                    const ex = @floor(gx0 + @as(f32, @floatCast(opts.dom_loaded * kx)));
                    ui.addOverlayLine(.{ .x = ex, .y = list.y }, .{ .x = ex, .y = list.y + list.h }, 1, toneColor(.info));
                }
                if (opts.loaded > 0) {
                    const ex = @floor(gx0 + @as(f32, @floatCast(opts.loaded * kx)));
                    ui.addOverlayLine(.{ .x = ex, .y = list.y }, .{ .x = ex, .y = list.y + list.h }, 1, theme.danger);
                }
            }

            for (requests, 0..) |q, i| {
                const row = t.Rect{
                    .x = row_x0,
                    .y = list.y + @as(f32, @floatFromInt(i)) * WF_ROW - off,
                    .w = list.w - 8,
                    .h = WF_ROW,
                };
                if (row.y + WF_ROW < list.y - 1 or row.y > list.y + list.h + 1) continue;
                const idx: i32 = @intCast(i);
                const rid = core.Context.idOf(id) ^ 0x3EF1 ^ (@as(u64, @intCast(i)) *% 0x9E37);
                const it = ui.interactEx(rid, row, false);
                const sel = if (opts.selected) |s| s.* == idx else false;
                if (sel) {
                    ui.addBox(row, .{ .fill = theme.accent_bg, .radius = 4 });
                } else if (it.hover) {
                    ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
                }
                const bad = q.status >= 400;
                const fg = if (bad) theme.danger else theme.text;
                const mut = if (bad) theme.danger else theme.secondary;
                var x = row.x + WF_PADX;
                const ty = row.y + (WF_ROW - theme.font_small * 1.35) / 2;
                ui.addText(.{ .x = x, .y = ty, .w = name_w, .h = theme.font_small * 1.35 }, shortName(q.name), theme.font_small, fg);
                x += name_w + gap;
                if (!narrow) {
                    ui.addText(.{ .x = x, .y = ty, .w = 48, .h = theme.font_small * 1.35 }, if (q.method.len > 0) q.method else "GET", theme.font_small, mut);
                    x += 48 + gap;
                }
                var sb: [16]u8 = undefined;
                if (q.status > 0) {
                    const sd = ui.frameStr(num.int(sb[0..], q.status));
                    ui.addText(.{ .x = x, .y = ty, .w = 44, .h = theme.font_small * 1.35 }, sd, theme.font_small, if (bad) mut else if (q.status >= 300) theme.secondary else fg);
                } else {
                    ui.addText(.{ .x = x, .y = ty, .w = 44, .h = theme.font_small * 1.35 }, "pending", theme.font_small, theme.secondary);
                }
                x += 44 + gap;
                if (!narrow) {
                    ui.addText(.{ .x = x, .y = ty, .w = 56, .h = theme.font_small * 1.35 }, q.type, theme.font_small, mut);
                    x += 56 + gap;
                    var zb: [24]u8 = undefined;
                    const zt = if (q.size > 0) ui.frameStr(fmtBytes(zb[0..], q.size)) else "\xe2\x80\x94";
                    const zw = ui.measureText(zt, theme.font_small).w;
                    ui.addText(.{ .x = x + 60 - zw, .y = ty, .w = zw + 2, .h = theme.font_small * 1.35 }, zt, theme.font_small, mut);
                    x += 60 + gap;
                }
                // 时间条
                const bx = x;
                const bw = @max(40, row.x + row.w - 6 - bx);
                if (bw > 20) {
                    const kx: f32 = @floatCast(@as(f64, bw) / end);
                    const cy = row.y + WF_ROW * 0.5;
                    var px = bx + @as(f32, @floatCast(q.start * @as(f64, @floatCast(kx))));
                    for (q.timing, 0..) |ph, pi| {
                        if (ph <= 0) continue;
                        const pw = @as(f32, @floatCast(@as(f64, @floatCast(ph)) * @as(f64, @floatCast(kx))));
                        if (pi == 0) {
                            ui.addBox(.{ .x = px, .y = cy - 1, .w = @max(pw, 1), .h = 2 }, .{ .fill = theme.withAlpha(phaseColor(0), 150), .radius = 1 });
                        } else {
                            ui.addBox(.{ .x = px, .y = cy - 5, .w = @max(pw, 1), .h = 10 }, .{ .fill = phaseColor(pi), .radius = 2 });
                        }
                        px += pw;
                    }
                }
                if (it.clicked) {
                    if (opts.selected) |s| s.* = idx;
                    res.clicked = idx;
                    if (it.activated) res.activated = idx;
                }
                if (it.activated and !it.clicked) res.activated = idx;
                if (it.hover) res.hovered = idx;
            }
        }
        ui.clip = saved;
    }

    // ---- 统计条（固定在面板底部，不随行滚动）
    ui.addOverlayLine(.{ .x = foot.x, .y = foot.y }, .{ .x = foot.x + foot.w, .y = foot.y }, 1, theme.border);
    ui.addBox(foot, .{ .fill = theme.raised });
    notesDraw(ui, notes[0..nn], .{ .x = foot.x + 10, .y = foot.y, .w = foot.w - 20, .h = foot_h });
    // 纵向滚动条
    if (max_off > 0) {
        const th = @max(16, list.h * list.h / content_h);
        const ty = list.y + (list.h - th) * (off / max_off);
        ui.addBox(.{ .x = panel.x + panel.w - 5, .y = ty, .w = 3, .h = th }, .{ .fill = theme.withAlpha(theme.secondary, 110), .radius = 1.5 });
    }

    // ---- 键盘（表格行移动）
    if (ui.input.keyPressed(.down) or ui.input.keyPressed(.up) or ui.input.keyPressed(.home) or ui.input.keyPressed(.end)) {
        const s = if (opts.selected) |p| p.* else -1;
        var ns = s;
        const n: i32 = @intCast(requests.len);
        if (ui.input.keyPressed(.down)) ns = if (s < 0) 0 else @min(n - 1, s + 1);
        if (ui.input.keyPressed(.up)) ns = if (s < 0) 0 else @max(0, s - 1);
        if (ui.input.keyPressed(.home)) ns = 0;
        if (ui.input.keyPressed(.end)) ns = n - 1;
        if (ns != s and n > 0) {
            if (opts.selected) |p| p.* = ns;
            // 把选中行滚进视口（下一帧按内容高夹取）
            const top = @as(f32, @floatFromInt(ns)) * WF_ROW;
            const cur = ui.scrollOffset(id);
            if (top < cur) ui.scrollTo(id, top) else if (top + WF_ROW > cur + list_h) ui.scrollTo(id, top + WF_ROW - list_h);
        }
        if (ui.input.keyPressed(.enter) and s >= 0) res.activated = s;
    }

    // ---- 悬停明细（自绘小卡片：名字 + 各段耗时 + 合计）
    if (res.hovered >= 0 and @as(usize, @intCast(res.hovered)) < requests.len) {
        const q = requests[@intCast(res.hovered)];
        var lines: [8][]const u8 = undefined;
        var n: usize = 0;
        lines[n] = if (q.name.len > 0) q.name else "request";
        n += 1;
        for (q.timing, 0..) |ph, pi| {
            if (ph <= 0 or n >= lines.len - 1) continue;
            var db: [32]u8 = undefined;
            var bb: [64]u8 = undefined;
            var m: usize = 0;
            @memcpy(bb[0..phase_names[pi].len], phase_names[pi]);
            m = phase_names[pi].len;
            bb[m] = ' ';
            m += 1;
            const s = flame.fmtSeconds(db[0..], ph);
            @memcpy(bb[m..][0..s.len], s);
            m += s.len;
            lines[n] = ui.frameStr(bb[0..m]);
            n += 1;
        }
        if (n < lines.len) {
            var db: [32]u8 = undefined;
            var bb: [72]u8 = undefined;
            var m: usize = 0;
            const pfx = "Total ";
            @memcpy(bb[0..pfx.len], pfx);
            m = pfx.len;
            const s = flame.fmtSeconds(db[0..], wfTotal(q));
            @memcpy(bb[m..][0..s.len], s);
            m += s.len;
            const pfx2 = " from ";
            @memcpy(bb[m..][0..pfx2.len], pfx2);
            m += pfx2.len;
            const s2 = flame.fmtSeconds(db[0..], q.start);
            @memcpy(bb[m..][0..s2.len], s2);
            m += s2.len;
            lines[n] = ui.frameStr(bb[0..m]);
            n += 1;
        }
        const lh = theme.font_small * 1.35 + 2;
        var tw: f32 = 0;
        for (lines[0..n]) |l| {
            const mw = ui.measureText(l, theme.font_small).w;
            if (mw > tw) tw = mw;
        }
        const bx = clampF(ui.input.mouse.x + 14, 4, @max(4, w - tw - 24));
        const by = clampF(ui.input.mouse.y + 10, 4, @max(4, total_h - lh * @as(f32, @floatFromInt(n)) - 10));
        const box = t.Rect{ .x = bx, .y = by, .w = tw + 16, .h = lh * @as(f32, @floatFromInt(n)) + 8 };
        ui.addOverlayBox(box, .{ .fill = theme.overlay_bg, .radius = 6 });
        for (lines[0..n], 0..) |l, i| {
            ui.addText(.{ .x = box.x + 8, .y = box.y + 4 + lh * @as(f32, @floatFromInt(i)), .w = tw, .h = lh }, l, theme.font_small, if (i == 0) theme.overlay_fg else theme.secondary);
        }
    }

    return res;
}
