//! 开发者视图（对位 CUI `cui_devviews.c` 4 个 API）：服务可用性条、按时间堆叠的事件直方图、
//! 覆盖率树、git blame。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **时间标签一律按 UTC 算**：CUI 走 `localtime` 取本机时区，ZZUI 不链 libc、核心层也不碰
//!   系统时区接口，所以 `TimeHistogramOpts.utc` / `ScheduleOpts.utc` 这类开关只是**保留签名**，
//!   实际输出恒为 UTC；需要本地时间请调用方先把时间戳偏移好再传进来（写进 `opts` 注释）。
//! - **不做语法高亮的跨行块注释状态**：blame 复用 `editor.highlightLine`（逐行着色，与编辑器同口径）。
//! - **跨帧状态由调用方持有**（`CoverageState` / `BlameState`），与 `nodes.State` / `emoji.State` 一致；
//!   CUI 把这些藏在上下文的状态池里。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const trace = @import("trace.zig");
const month = @import("month.zig");
const editor = @import("editor.zig");

pub const Tone = trace.Tone;

fn idOf(id: []const u8) u64 {
    return core.Context.idOf(id);
}

/// 给命中 id 加一点盐与下标（避开 Zig 的 usize/u64 混算）。
fn kk(key: u64, salt: u64, i: usize) u64 {
    return key ^ (salt +% @as(u64, @intCast(i)));
}

/// 两位零填充（`7` → `07`）。
fn pad2(buf: []u8, v: u32) []const u8 {
    if (v < 10) {
        buf[0] = '0';
        const s = num.int(buf[1..], @intCast(v));
        return buf[0 .. 1 + s.len];
    }
    return num.int(buf, @intCast(v));
}

/// 线性混色（`k` = 0 取 `a`，1 取 `b`）。
fn mix(a: t.Color, b: t.Color, k: f32) t.Color {
    const f = std.math.clamp(k, 0, 1);
    const lerp = struct {
        fn one(x: u8, y: u8, kf: f32) u8 {
            const xf: f32 = @floatFromInt(x);
            const yf: f32 = @floatFromInt(y);
            return @intFromFloat(std.math.clamp(xf + (yf - xf) * kf, 0, 255));
        }
    }.one;
    return .{
        .r = lerp(a.r, b.r, f),
        .g = lerp(a.g, b.g, f),
        .b = lerp(a.b, b.b, f),
        .a = lerp(a.a, b.a, f),
    };
}

pub fn clipText(ui: *core.Context, s: []const u8, size: f32, max_w: f32) []const u8 {
    if (s.len == 0 or max_w <= 12) return "";
    if (ui.measureText(s, size).w <= max_w) return s;
    var take: usize = @min(s.len, 64);
    while (take > 0) : (take -= 1) {
        var n = take;
        while (n > 0 and (s[n - 1] & 0xC0) == 0x80) n -= 1;
        var buf: [72]u8 = undefined;
        if (n + 3 <= buf.len) {
            @memcpy(buf[0..n], s[0..n]);
            buf[n] = '.';
            buf[n + 1] = '.';
            buf[n + 2] = '.';
            if (ui.measureText(buf[0 .. n + 3], size).w <= max_w) return ui.frameStr(buf[0 .. n + 3]);
        }
    }
    return "";
}

// ============================================================ 服务可用性条

pub const UptimeService = struct {
    name: []const u8 = "",
    /// 从旧到新：当天在线比例 0..1，负数 = 没有数据。
    days: []const f32 = &.{},
};

pub const UptimeOpts = struct {
    /// 最后一天对应的日期（悬停提示用）。
    last_day: month.Date = .{},
};

pub const UptimeResult = struct {
    /// 指针下的服务下标，-1 = 无。
    service: i32 = -1,
    /// 指针下那天的下标（从 0 起，与 `days` 同序），-1 = 无。
    day: i32 = -1,
};

/// 一天的颜色：没有数据 → 边框色；≥ 99.9% 绿；≥ 99% 绿黄之间；≥ 95% 黄；否则红。
pub fn uptimeColor(v: f32) t.Color {
    if (v < 0) return theme.border;
    if (v >= 0.999) return trace.toneColor(.success);
    if (v >= 0.99) return mix(trace.toneColor(.success), trace.toneColor(.warn), 0.55);
    if (v >= 0.95) return trace.toneColor(.warn);
    return trace.toneColor(.danger);
}

fn uptimeState(v: f32) []const u8 {
    if (v < 0) return "No data";
    if (v >= 0.999) return "Operational";
    if (v >= 0.95) return "Degraded";
    return "Outage";
}

/// 一天里最新的 `fit` 天里能放下多少根条，以及每根的宽度与间距。
fn uptimeFit(w: f32, days: usize, bw: *f32, gap: *f32) usize {
    gap.* = if (w < 500) 2 else 3;
    const fit_f = (w + gap.*) / (3 + gap.*);
    const fit: usize = if (fit_f <= 0) 1 else @intFromFloat(fit_f);
    const n = @min(days, @max(1, fit));
    bw.* = if (n > 0) (w - gap.* * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n)) else 0;
    if (bw.* > 14) bw.* = 14;
    return if (days == 0) 0 else n;
}

/// 状态页：每个服务一行「状态点 + 名字 + 状态 + 可用率」，下面是逐日的可用性条。
/// 悬停返回服务与那天（`UptimeResult`），并弹出日期 + 可用率的提示。
pub fn uptime(ui: *core.Context, id: []const u8, services: []const UptimeService, opts: UptimeOpts) UptimeResult {
    var res = UptimeResult{};
    const key = idOf(id);
    var s: usize = 0;
    while (s < services.len) : (s += 1) {
        const sv = services[s];
        const last: f32 = if (sv.days.len > 0) sv.days[sv.days.len - 1] else -1;
        // ---- 标题行
        const head = ui.reserve(0, 24, true);
        ui.addBox(.{ .x = head.x, .y = head.y + 8, .w = 8, .h = 8 }, .{ .fill = uptimeColor(last), .radius = 4 });
        const name_w = @min(ui.measureText(sv.name, theme.font_body).w + 2, @max(20, head.w * 0.45));
        ui.addText(.{ .x = head.x + 14, .y = head.y + 3, .w = name_w, .h = 18 }, clipText(ui, sv.name, theme.font_body, name_w), theme.font_body, theme.text);
        const state = uptimeState(last);
        const st_col = if (last < 0) theme.secondary else if (last >= 0.999) theme.secondary else uptimeColor(last);
        ui.addText(.{ .x = head.x + 14 + name_w + 8, .y = head.y + 4, .w = 90, .h = 18 }, state, theme.font_small, st_col);
        // 可用率（右对齐）
        var sum: f32 = 0;
        var with: usize = 0;
        for (sv.days) |d| {
            if (d >= 0) {
                sum += d;
                with += 1;
            }
        }
        var pbuf: [24]u8 = undefined;
        var ubuf: [40]u8 = undefined;
        const label = if (with > 0) blk: {
            const pct = num.fixed(pbuf[0..], sum / @as(f32, @floatFromInt(with)) * 100.0, 2);
            break :blk std.fmt.bufPrint(ubuf[0..], "{s}% uptime", .{pct}) catch pct;
        } else "\u{2014}";
        const uw = ui.measureText(label, theme.font_small).w;
        ui.addText(.{ .x = head.x + head.w - uw, .y = head.y + 4, .w = uw + 1, .h = 18 }, ui.frameStr(label), theme.font_small, theme.secondary);

        // ---- 逐日条
        const bars = ui.reserve(0, 30, true);
        const hit = ui.interactEx(key ^ (0x7A00 + s), bars, false);
        var bw: f32 = 0;
        var gap: f32 = 0;
        const n = uptimeFit(bars.w, sv.days.len, &bw, &gap);
        const first = sv.days.len - n;
        var hover_k: i32 = -1;
        if (hit.hover and n > 0 and bw > 0) {
            const rel = (ui.input.mouse.x - bars.x) / (bw + gap);
            if (rel >= 0) {
                const k: usize = @intFromFloat(rel);
                if (k < n) hover_k = @intCast(k);
            }
        }
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const v = sv.days[first + k];
            const x = bars.x + @as(f32, @floatFromInt(k)) * (bw + gap);
            var c = uptimeColor(v);
            const inset: f32 = if (hover_k >= 0 and @as(usize, @intCast(hover_k)) == k) 0 else 2;
            if (hover_k >= 0 and @as(usize, @intCast(hover_k)) != k) c = theme.withAlpha(c, 190);
            ui.addBox(.{ .x = x, .y = bars.y + inset, .w = bw, .h = bars.h - inset * 2 }, .{
                .fill = c,
                .radius = @min(@as(f32, 2), bw * 0.5),
            });
        }
        if (hover_k >= 0) {
            res.service = @intCast(s);
            res.day = @intCast(first + @as(usize, @intCast(hover_k)));
            // 提示：日期 + 当天可用率
            const idx: usize = @intCast(res.day);
            const back: i64 = @intCast(sv.days.len - 1 - idx);
            const day_date = month.fromDays(month.daysFromCivil(opts.last_day) - back);
            var db: [12]u8 = undefined;
            var mb: [4]u8 = undefined;
            var yb: [8]u8 = undefined;
            var dd: [4]u8 = undefined;
            const date_txt = std.fmt.bufPrint(db[0..], "{s}-{s}-{s}", .{
                num.int(yb[0..], day_date.year),
                pad2(mb[0..], day_date.month),
                pad2(dd[0..], day_date.day),
            }) catch "day";
            var tb: [64]u8 = undefined;
            const v = sv.days[idx];
            const tip = if (v < 0)
                std.fmt.bufPrint(tb[0..], "{s}  no data", .{date_txt}) catch date_txt
            else
                std.fmt.bufPrint(tb[0..], "{s}  {s}% uptime", .{ date_txt, num.fixed(pbuf[0..], v * 100.0, 2) }) catch date_txt;
            const tipw = ui.measureText(tip, theme.font_small).w + 20;
            const card = t.Rect{ .x = @max(0, ui.input.mouse.x + 12), .y = bars.y - 30, .w = tipw, .h = 24 };
            ui.addOverlayBox(card, .{ .fill = theme.overlay_bg, .radius = 6 });
            ui.addText(.{ .x = card.x + 10, .y = card.y + 4, .w = card.w - 12, .h = 18 }, ui.frameStr(tip), theme.font_small, theme.overlay_fg);
        }
    }
    return res;
}

// ============================================================ 事件直方图

pub const HistogramSeries = struct {
    name: []const u8 = "",
    /// 每桶一个计数（长度应 ≥ `buckets`，短的当 0）。
    counts: []const f32 = &.{},
    /// 不给就用系列色（按序循环）。
    tone: ?Tone = null,
};

pub const TimeHistogramOpts = struct {
    height: f32 = 140,
    /// 保留签名：本实现的时间标签**恒为 UTC**（见文件头说明）。
    utc: bool = false,
};

pub const TimeHistogramResult = struct {
    selection_changed: bool = false,
    /// 指针下的桶，-1 = 无。
    hovered: i32 = -1,
};

/// 系列色：0..5 循环（与 `trace` 的语义色错开，便于和状态色区分）。
fn seriesColor(i: usize) t.Color {
    const pal = [_]t.Color{
        t.Color.hex(0x2F81F7, 255),
        t.Color.hex(0x3FB950, 255),
        t.Color.hex(0xD29922, 255),
        t.Color.hex(0xBC8CFF, 255),
        t.Color.hex(0x39C5CF, 255),
        t.Color.hex(0xDB6D28, 255),
    };
    return pal[i % pal.len];
}

/// 「好看的」刻度步长：1 / 2 / 5 × 10^k。
fn niceStep(v: f32) f32 {
    if (v <= 1) return 1;
    var pow: f32 = 1;
    while (pow * 10 <= v) pow *= 10;
    if (v <= pow * 1) return pow;
    if (v <= pow * 2) return pow * 2;
    if (v <= pow * 5) return pow * 5;
    return pow * 10;
}

/// UTC 的 `HH:MM`（`utc` 标志只为保留签名，见文件头）。
fn hhmm(buf: []u8, unix_secs: f64) []const u8 {
    const secs: u64 = if (unix_secs <= 0) 0 else @intFromFloat(unix_secs);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ds = es.getDaySeconds();
    var hb: [4]u8 = undefined;
    var mb: [4]u8 = undefined;
    const hs = pad2(hb[0..], ds.getHoursIntoDay());
    const ms = pad2(mb[0..], ds.getMinutesIntoHour());
    return std.fmt.bufPrint(buf, "{s}:{s}", .{ hs, ms }) catch "";
}

/// 事件计数随时间堆叠的柱状图。拖拽选时间范围（写回 `sel_start` / `sel_end`，Unix 秒），
/// 单击清除选区，悬停返回桶下标并显示时间 + 各系列计数。
pub fn timeHistogram(
    ui: *core.Context,
    id: []const u8,
    start: f64,
    bucket_seconds: f64,
    buckets: usize,
    series: []const HistogramSeries,
    sel_start: *f64,
    sel_end: *f64,
    opts: TimeHistogramOpts,
) TimeHistogramResult {
    var res = TimeHistogramResult{};
    const key = idOf(id);
    const area = ui.reserve(0, opts.height, true);
    const pad_l: f32 = 44;
    const pad_b: f32 = 20;
    const pad_r: f32 = 8;
    const pad_t: f32 = 8;
    const plot = t.Rect{
        .x = area.x + pad_l,
        .y = area.y + pad_t,
        .w = @max(20, area.w - pad_l - pad_r),
        .h = @max(20, area.h - pad_t - pad_b),
    };
    if (buckets == 0 or bucket_seconds <= 0 or series.len == 0) {
        ui.addText(.{ .x = plot.x, .y = plot.y + plot.h * 0.5 - 9, .w = plot.w, .h = 18 }, "no data", theme.font_small, theme.secondary);
        return res;
    }
    // 堆叠最大值
    var vmax: f32 = 0;
    var b: usize = 0;
    while (b < buckets) : (b += 1) {
        var sum: f32 = 0;
        for (series) |sr| {
            if (b < sr.counts.len) sum += @max(0, sr.counts[b]);
        }
        if (sum > vmax) vmax = sum;
    }
    const step = niceStep(@max(vmax, 1) / 4.0);
    const top = @max(step, @ceil(@max(vmax, 1) / step) * step);

    // ---- 交互：拖拽选区 / 悬停
    const hit = ui.interactEx(kk(key, 0x4B01, 0), plot, false);
    const bw = plot.w / @as(f32, @floatFromInt(buckets));
    const t_start = start;
    const t_span = bucket_seconds * @as(f64, @floatFromInt(buckets));
    if (hit.hover or hit.dragging) {
        const rel = (ui.input.mouse.x - plot.x) / bw;
        if (rel >= 0) {
            const bi: usize = @min(buckets - 1, @as(usize, @intFromFloat(rel)));
            res.hovered = @intCast(bi);
        }
    }
    if (hit.pressed) {
        // 记录拖拽起点：存**桶下标**而不是绝对时间（f32 存不下 1.7e9 级别的秒数，
        // 1700000030 会被舍入成 1700000000，选区就差半桶）
        const bi: f64 = if (res.hovered >= 0) @floatFromInt(@as(usize, @intCast(res.hovered))) else 0;
        const at = start + (bi + 0.5) * bucket_seconds;
        ui.rememberSize(kk(key, 0x4B02, 0), @floatCast(bi), 1);
        sel_start.* = at;
        sel_end.* = at;
    }
    if (hit.dragging) {
        if (ui.knownSize(kk(key, 0x4B02, 0))) |from| {
            const bi0: f64 = from.w;
            const from_at = start + (bi0 + 0.5) * bucket_seconds;
            const bi1: f64 = if (res.hovered >= 0) @floatFromInt(@as(usize, @intCast(res.hovered))) else 0;
            const at = start + (bi1 + 0.5) * bucket_seconds;
            sel_start.* = @min(from_at, at);
            sel_end.* = @max(from_at, at);
            res.selection_changed = true;
        }
    }
    if (hit.clicked and !hit.dragging) {
        // 单击（没有拖出范围）→ 清除选区
        if (sel_start.* != 0 or sel_end.* != 0) {
            sel_start.* = 0;
            sel_end.* = 0;
            res.selection_changed = true;
        }
    }

    // ---- 背景网格与 y 刻度
    var g: usize = 0;
    while (g <= 4) : (g += 1) {
        const vy = @as(f32, @floatFromInt(g)) * step;
        if (vy > top) break;
        const y = plot.y + plot.h * (1 - vy / top);
        ui.addBox(.{ .x = plot.x, .y = y, .w = plot.w, .h = 1 }, .{ .fill = theme.hair });
        var lb: [16]u8 = undefined;
        const lbl = num.int(lb[0..], @intFromFloat(vy));
        ui.addText(.{ .x = area.x, .y = y - 8, .w = pad_l - 6, .h = 16 }, ui.frameStr(lbl), theme.font_small, theme.secondary);
    }

    // ---- 选区底色
    if (sel_end.* > sel_start.* and t_span > 0) {
        const x0 = plot.x + @as(f32, @floatCast((sel_start.* - t_start) / t_span)) * plot.w;
        const x1 = plot.x + @as(f32, @floatCast((sel_end.* - t_start) / t_span)) * plot.w;
        const xa = std.math.clamp(x0, plot.x, plot.x + plot.w);
        const xb = std.math.clamp(x1, plot.x, plot.x + plot.w);
        if (xb > xa) ui.addBox(.{ .x = xa, .y = plot.y, .w = xb - xa, .h = plot.h }, .{ .fill = theme.withAlpha(theme.accent, 28) });
    }

    // ---- 堆叠柱
    b = 0;
    while (b < buckets) : (b += 1) {
        const x = plot.x + @as(f32, @floatFromInt(b)) * bw;
        const w = @max(1, bw - 1);
        var acc: f32 = 0;
        for (series, 0..) |sr, si| {
            const v = if (b < sr.counts.len) @max(0, sr.counts[b]) else 0;
            if (v <= 0) continue;
            const c = if (sr.tone) |tn| trace.toneColor(tn) else seriesColor(si);
            const y0 = plot.y + plot.h * (1 - acc / top);
            acc += v;
            const y1 = plot.y + plot.h * (1 - acc / top);
            const hh = @max(1, y0 - y1);
            const dim = res.hovered >= 0 and @as(usize, @intCast(res.hovered)) != b;
            ui.addBox(.{ .x = x, .y = y1, .w = w, .h = hh }, .{ .fill = if (dim) theme.withAlpha(c, 150) else c });
        }
    }

    // ---- 时间轴
    const ticks: usize = if (plot.w < 260) 2 else if (plot.w < 520) 3 else 5;
    var k: usize = 0;
    while (k < ticks) : (k += 1) {
        const frac = if (ticks <= 1) 0.0 else @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(ticks - 1));
        const tv = t_start + t_span * frac;
        var tb: [8]u8 = undefined;
        const txt = hhmm(tb[0..], tv);
        const tw = ui.measureText(txt, theme.font_small).w;
        var x = plot.x + @as(f32, @floatCast(frac)) * plot.w - tw * 0.5;
        x = std.math.clamp(x, area.x, area.x + area.w - tw);
        ui.addText(.{ .x = x, .y = plot.y + plot.h + 3, .w = tw + 1, .h = 16 }, ui.frameStr(txt), theme.font_small, theme.secondary);
    }

    // ---- 悬停明细
    if (res.hovered >= 0) {
        const bi: usize = @intCast(res.hovered);
        var buf: [96]u8 = undefined;
        var w: usize = 0;
        var tb: [8]u8 = undefined;
        const head = hhmm(tb[0..], t_start + @as(f64, @floatFromInt(bi)) * bucket_seconds);
        const pre = std.fmt.bufPrint(buf[0..], "{s}", .{head}) catch "";
        w = pre.len;
        for (series) |sr| {
            if (bi >= sr.counts.len) continue;
            var nb: [24]u8 = undefined;
            const part = std.fmt.bufPrint(nb[0..], "  {s} {d}", .{ sr.name, @as(i64, @intFromFloat(@max(0, sr.counts[bi]))) }) catch "";
            if (w + part.len <= buf.len) {
                @memcpy(buf[w .. w + part.len], part);
                w += part.len;
            }
        }
        const tipw = ui.measureText(buf[0..w], theme.font_small).w + 20;
        const card = t.Rect{ .x = @min(plot.x + plot.w - tipw, @max(plot.x, ui.input.mouse.x + 12)), .y = plot.y + 2, .w = tipw, .h = 24 };
        ui.addOverlayBox(card, .{ .fill = theme.overlay_bg, .radius = 6 });
        ui.addText(.{ .x = card.x + 10, .y = card.y + 4, .w = card.w - 12, .h = 18 }, ui.frameStr(buf[0..w]), theme.font_small, theme.overlay_fg);
    }
    return res;
}

// ============================================================ 覆盖率

pub const CoverageFile = struct {
    /// "src/core/layout.zig"：斜杠分段建树。
    path: []const u8 = "",
    lines: i32 = 0,
    lines_hit: i32 = 0,
    branches: i32 = 0,
    branches_hit: i32 = 0,
    functions: i32 = 0,
    functions_hit: i32 = 0,
};

pub const CoverageOpts = struct {
    /// 0 = 按行数自适应（最多 360）；负 = 撑满内容宽。
    height: f32 = 0,
    /// 低于它算红，默认 50。
    low: f32 = 50,
    /// 低于它算黄，默认 80。
    high: f32 = 80,
};

pub const CoverageState = struct {
    /// 折叠的节点键（名字哈希 ^ 深度 ^ 父下标），固定容量。
    folded: [16]u32 = @splat(0),
    nfolded: usize = 0,
    /// 排序：0 = File，1 = Lines，2 = Branches，3 = Functions。
    sort_col: u8 = 0,
    /// 0 = 升序，1 = 降序。
    sort_desc: u8 = 0,
};

pub const CoverageResult = struct {
    /// 本帧激活的文件下标，-1 = 无（双击文件行或回车）。
    activated: i32 = -1,
    /// 整体行覆盖率（百分比，没有行时为 0）。
    lines: f32 = 0,
};

const MAX_COV_NODES = 96;
const MAX_COV_NAME = 40;
const COV_ROW: f32 = 24;

const CovNode = struct {
    name: [MAX_COV_NAME]u8 = @splat(0),
    name_len: u8 = 0,
    parent: i16 = -1,
    depth: u8 = 0,
    file: i32 = -1,
    lines: i32 = 0,
    lines_hit: i32 = 0,
    br: i32 = 0,
    br_hit: i32 = 0,
    fn_: i32 = 0,
    fn_hit: i32 = 0,
};

fn covName(n: *const CovNode) []const u8 {
    return n.name[0..n.name_len];
}

fn covKey(n: *const CovNode) u32 {
    var h: u32 = 2166136261;
    for (covName(n)) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h ^ (@as(u32, n.depth) *% 977) ^ @as(u32, @intCast(@as(i32, n.parent) & 0xFFFF));
}

fn covPct(hit: i32, all: i32) f32 {
    if (all <= 0) return -1;
    return 100.0 * @as(f32, @floatFromInt(hit)) / @as(f32, @floatFromInt(all));
}

fn covColor(pct: f32, low: f32, high: f32) t.Color {
    if (pct < 0) return theme.secondary;
    if (pct < low) return trace.toneColor(.danger);
    if (pct < high) return trace.toneColor(.warn);
    return trace.toneColor(.success);
}

fn covFolded(st: *CoverageState, n: *const CovNode) bool {
    const k = covKey(n);
    for (st.folded[0..st.nfolded]) |f| {
        if (f == k) return true;
    }
    return false;
}

fn covToggle(st: *CoverageState, n: *const CovNode) void {
    const k = covKey(n);
    var i: usize = 0;
    while (i < st.nfolded) : (i += 1) {
        if (st.folded[i] == k) {
            st.folded[i] = st.folded[st.nfolded - 1];
            st.nfolded -= 1;
            return;
        }
    }
    if (st.nfolded < st.folded.len) {
        st.folded[st.nfolded] = k;
        st.nfolded += 1;
    }
}

fn covEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 建树：根 = "All files"，按路径分段建文件夹，最后挂文件叶子，并把指标累加到祖先。
fn covBuild(nodes: *[MAX_COV_NODES]CovNode, count: *usize, files: []const CoverageFile) void {
    count.* = 0;
    const root = CovNode{ .parent = -1, .depth = 0, .file = -1 };
    nodes[0] = root;
    @memcpy(nodes[0].name[0..9], "All files");
    nodes[0].name_len = 9;
    count.* = 1;
    for (files, 0..) |f, fi| {
        var path = f.path;
        // 跳过开头的斜杠
        while (path.len > 0 and path[0] == '/') path = path[1..];
        var parent: i16 = 0;
        var depth: u8 = 1;
        var rest = path;
        while (rest.len > 0) {
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const seg = if (slash) |p| rest[0..p] else rest;
            const is_last = slash == null;
            if (seg.len == 0) {
                rest = if (slash) |p| rest[p + 1 ..] else "";
                continue;
            }
            if (is_last) {
                // 文件叶子
                if (count.* < MAX_COV_NODES) {
                    var n = CovNode{
                        .parent = parent,
                        .depth = depth,
                        .file = @intCast(fi),
                        .lines = f.lines,
                        .lines_hit = f.lines_hit,
                        .br = f.branches,
                        .br_hit = f.branches_hit,
                        .fn_ = f.functions,
                        .fn_hit = f.functions_hit,
                    };
                    const take = @min(seg.len, MAX_COV_NAME);
                    @memcpy(n.name[0..take], seg[0..take]);
                    n.name_len = @intCast(take);
                    nodes[count.*] = n;
                    count.* += 1;
                }
            } else {
                // 文件夹：找同级同名，没有就建
                var found: i16 = -1;
                var i: usize = 0;
                while (i < count.*) : (i += 1) {
                    if (nodes[i].parent == parent and nodes[i].file < 0 and covEq(covName(&nodes[i]), seg)) {
                        found = @intCast(i);
                        break;
                    }
                }
                if (found < 0) {
                    if (count.* >= MAX_COV_NODES) return;
                    var n = CovNode{ .parent = parent, .depth = depth, .file = -1 };
                    const take = @min(seg.len, MAX_COV_NAME);
                    @memcpy(n.name[0..take], seg[0..take]);
                    n.name_len = @intCast(take);
                    nodes[count.*] = n;
                    found = @intCast(count.*);
                    count.* += 1;
                }
                parent = found;
            }
            depth += 1;
            rest = if (slash) |p| rest[p + 1 ..] else "";
        }
        // 累加到祖先链
        var cur: i32 = parent;
        while (cur >= 0) {
            const k: usize = @intCast(cur);
            nodes[k].lines += f.lines;
            nodes[k].lines_hit += f.lines_hit;
            nodes[k].br += f.branches;
            nodes[k].br_hit += f.branches_hit;
            nodes[k].fn_ += f.functions;
            nodes[k].fn_hit += f.functions_hit;
            cur = nodes[k].parent;
        }
    }
}

fn covMetric(n: *const CovNode, col: u8) f32 {
    return switch (col) {
        1 => covPct(n.lines_hit, n.lines),
        2 => covPct(n.br_hit, n.br),
        3 => covPct(n.fn_hit, n.fn_),
        else => -1,
    };
}

/// 同级排序（按列；File 列按名字）：`a` 是否应排在 `b` 前面。
fn covBefore(a: *const CovNode, b: *const CovNode, col: u8, desc: bool) bool {
    if (col == 0) {
        const ord = std.mem.order(u8, covName(a), covName(b));
        return if (desc) ord == .gt else ord == .lt;
    }
    const pa = covMetric(a, col);
    const pb = covMetric(b, col);
    const va: f32 = if (pa < 0) -1 else pa;
    const vb: f32 = if (pb < 0) -1 else pb;
    return if (desc) va > vb else va < vb;
}

const CovOrder = struct {
    nodes: *[MAX_COV_NODES]CovNode,
    count: usize,

    /// 收集某父节点的子节点，按当前排序规则排序。
    fn children(self: *const CovOrder, parent: i16, col: u8, desc: bool, out: []i16) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.nodes[i].parent != parent) continue;
            if (n < out.len) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        // 插入排序（子节点通常很少）
        var a: usize = 1;
        while (a < n) : (a += 1) {
            const v = out[a];
            var b = a;
            while (b > 0 and covBefore(&self.nodes[@intCast(v)], &self.nodes[@intCast(out[b - 1])], col, desc)) : (b -= 1) {
                out[b] = out[b - 1];
            }
            out[b] = v;
        }
        return n;
    }
};

/// 覆盖率树：路径建树、文件夹折叠、点表头排序、行覆盖率条 + 分支/函数百分比。
/// 双击文件行（或选中后回车）返回 `activated`；`lines` 是整体行覆盖率。
pub fn coverage(ui: *core.Context, id: []const u8, files: []const CoverageFile, st: *CoverageState, opts: CoverageOpts) CoverageResult {
    var res = CoverageResult{};
    var nodes: [MAX_COV_NODES]CovNode = undefined;
    var nn: usize = 0;
    covBuild(&nodes, &nn, files);
    if (nn == 0) return res;
    res.lines = @max(0, covPct(nodes[0].lines_hit, nodes[0].lines));
    const low = if (opts.low > 0) opts.low else 50;
    const high = if (opts.high > 0) opts.high else 80;
    const col = st.sort_col;
    const desc = st.sort_desc == 1;

    // ---- 可见行（深度优先 + 折叠）
    var rows: [MAX_COV_NODES]i16 = undefined;
    var nr: usize = 0;
    var stack: [MAX_COV_NODES]i16 = undefined;
    var order: [MAX_COV_NODES]i16 = undefined;
    const ord = CovOrder{ .nodes = &nodes, .count = nn };
    // 先压根，再按排序逐个展开
    var sp: usize = 0;
    stack[sp] = 0;
    sp += 1;
    while (sp > 0) {
        sp -= 1;
        const cur = stack[sp];
        if (nr < rows.len) {
            rows[nr] = cur;
            nr += 1;
        }
        const node = &nodes[@intCast(cur)];
        if (node.file >= 0) continue;
        if (cur != 0 and covFolded(st, node)) continue;
        const cn = ord.children(cur, col, desc, order[0..]);
        // 逆序压栈，保证升序展开
        var k: usize = cn;
        while (k > 0) {
            k -= 1;
            if (sp < stack.len) {
                stack[sp] = order[k];
                sp += 1;
            }
        }
    }

    const h: f32 = if (opts.height > 0) opts.height else @min(360, COV_ROW * @as(f32, @floatFromInt(nr + 1)) + 4);

    var area = ui.scroll(.{ .id = id, .height = h });
    defer area.end();
    const avail = area.rect.w;
    const narrow = avail < 560;
    const key = idOf(id);

    // ---- 表头（可点排序）
    const head = ui.reserve(0, COV_ROW, true);
    ui.addBox(head, .{ .fill = theme.track, .radius = 6 });
    const titles = [_][]const u8{ "File", "Lines", "Branches", "Functions" };
    const cols: usize = if (narrow) 2 else 4;
    const bar_w: f32 = if (narrow) 56 else 90;
    const cell_w: f32 = if (narrow) 54 else 74;
    const left_w = @max(60, avail - @as(f32, @floatFromInt(cols - 1)) * (bar_w + cell_w + 12) - 24);
    var x = head.x + 12;
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        const wcol = if (c == 0) left_w else if (c == 1) bar_w + cell_w else cell_w;
        const hit = ui.interactEx(kk(key, 0x5E00, c), .{ .x = x, .y = head.y, .w = wcol, .h = COV_ROW }, true);
        const arrow: []const u8 = if (col == c) (if (desc) " v" else " ^") else "";
        var tb: [24]u8 = undefined;
        const lbl = std.fmt.bufPrint(tb[0..], "{s}{s}", .{ titles[c], arrow }) catch titles[c];
        ui.addText(.{ .x = x + (if (c == 0) @as(f32, 0) else 6), .y = head.y + 3, .w = wcol - 8, .h = 18 }, ui.frameStr(lbl), theme.font_small, if (col == c) theme.text else theme.secondary);
        if (hit.clicked) {
            if (col == c) {
                st.sort_desc = if (desc) 0 else 1;
            } else {
                st.sort_col = @intCast(c);
                st.sort_desc = 0;
            }
        }
        x += wcol + 12;
    }

    // ---- 行
    var r: usize = 0;
    while (r < nr) : (r += 1) {
        const idx: usize = @intCast(rows[r]);
        const n = &nodes[idx];
        const row = ui.reserve(0, COV_ROW, true);
        const hit = ui.interactEx(kk(key, 0xD00, r), row, true);
        if (hit.hover) ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
        // 展开箭头 + 图标
        var tx = row.x + 4 + @as(f32, @floatFromInt(n.depth)) * 12;
        if (n.file < 0) {
            const folded = covFolded(st, n);
            ui.addText(.{ .x = tx, .y = row.y + 3, .w = 12, .h = 18 }, if (folded) ">" else "v", theme.font_small, theme.secondary);
            if (hit.clicked) covToggled(st, n);
        }
        tx += 14;
        ui.addText(.{ .x = tx, .y = row.y + 3, .w = 12, .h = 18 }, if (n.file < 0) "#" else ".", theme.font_small, theme.secondary);
        tx += 14;
        const name_w = @max(20, row.x + 12 + left_w - tx);
        ui.addText(.{ .x = tx, .y = row.y + 3, .w = name_w, .h = 18 }, clipText(ui, covName(n), theme.font_body, name_w), theme.font_body, theme.text);
        // 行覆盖率条
        var bx = row.x + 12 + left_w;
        const lp = covPct(n.lines_hit, n.lines);
        ui.addBox(.{ .x = bx, .y = row.y + 6, .w = bar_w, .h = 12 }, .{ .fill = theme.track, .radius = 6 });
        if (lp > 0) {
            const fw = @max(2, bar_w * std.math.clamp(lp / 100.0, 0, 1));
            ui.addBox(.{ .x = bx, .y = row.y + 6, .w = fw, .h = 12 }, .{ .fill = covColor(lp, low, high), .radius = 6 });
        }
        bx += bar_w + 6;
        pctCell(ui, bx, row.y, cell_w, lp, low, high);
        if (!narrow) {
            bx += cell_w + 6;
            pctCell(ui, bx, row.y, cell_w, covPct(n.br_hit, n.br), low, high);
            bx += cell_w + 6;
            pctCell(ui, bx, row.y, cell_w, covPct(n.fn_hit, n.fn_), low, high);
        }
        // 双击文件行 / 选中后回车 → 激活
        if (n.file >= 0) {
            if (hit.clicked) {
                const dbl_key = kk(key, 0xD1B, 0);
                const prev = ui.knownSize(dbl_key);
                const is_double = if (prev) |p|
                    (ui.time * 1000.0 - @as(f64, p.w) < 450.0 and @as(usize, @intFromFloat(@max(p.h, 0))) == idx)
                else
                    false;
                ui.rememberSize(dbl_key, @as(f32, @floatCast(ui.time * 1000.0)), @floatFromInt(idx));
                if (is_double) res.activated = n.file;
            }
            if (hit.activated) res.activated = n.file;
        }
        if (hit.hover and n.file >= 0) {
            var tb: [64]u8 = undefined;
            const tip = std.fmt.bufPrint(tb[0..], "{d} of {d} lines", .{ n.lines_hit, n.lines }) catch "lines";
            const tipw = ui.measureText(tip, theme.font_small).w + 20;
            const card = t.Rect{ .x = @max(0, ui.input.mouse.x + 12), .y = row.y + COV_ROW, .w = tipw, .h = 24 };
            ui.addOverlayBox(card, .{ .fill = theme.overlay_bg, .radius = 6 });
            ui.addText(.{ .x = card.x + 10, .y = card.y + 4, .w = card.w - 12, .h = 18 }, ui.frameStr(tip), theme.font_small, theme.overlay_fg);
        }
    }
    return res;
}

fn covToggled(st: *CoverageState, n: *const CovNode) void {
    covToggle(st, n);
}

fn pctCell(ui: *core.Context, x: f32, y: f32, w: f32, pct: f32, low: f32, high: f32) void {
    var nb: [12]u8 = undefined;
    var sb: [16]u8 = undefined;
    const txt = if (pct < 0) "\u{2014}" else blk: {
        const t2 = num.fixed(nb[0..], pct, 1);
        break :blk std.fmt.bufPrint(sb[0..], "{s}%", .{t2}) catch t2;
    };
    const tw = ui.measureText(txt, theme.font_small).w;
    ui.addText(.{ .x = x + w - tw, .y = y + 3, .w = tw + 1, .h = 18 }, ui.frameStr(txt), theme.font_small, covColor(pct, low, high));
}

// ============================================================ Blame

pub const BlameCommit = struct {
    hash: []const u8 = "",
    author: []const u8 = "",
    summary: []const u8 = "",
    /// Unix 秒。
    time: i64 = 0,
};

pub const BlameOpts = struct {
    height: f32 = 360,
    /// 语法高亮语言（与 `editor.Opts.lang` 同口径）；空 = 不着色。
    lang: []const u8 = "",
    /// 年龄算到这一刻（Unix 秒）；**0 = 以最新的那个提交为基准**（不读系统时钟：
    /// 核心层不链 libc，Zig 0.17 的 `std.time` 也不再提供时间戳接口）。
    now: i64 = 0,
    /// 第一行的行号，默认 1。
    first_line: i32 = 1,
};

pub const BlameState = struct {
    hovered: i32 = -1,
};

pub const BlameResult = struct {
    /// 被点的提交下标，-1 = 无。
    clicked: i32 = -1,
    /// 指针下的提交下标，-1 = 无。
    hovered: i32 = -1,
};

const BLAME_ROW: f32 = 20;

/// 相对年龄：`just now` / `5m` / `3h` / `2d` / `3w` / `5mo` / `2y`。
fn fmtAge(buf: []u8, secs: i64) []const u8 {
    const s = if (secs < 0) 0 else secs;
    if (s < 60) return "just now";
    const mins = @divTrunc(s, 60);
    if (mins < 60) return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "m";
    const hours = @divTrunc(mins, 60);
    if (hours < 24) return std.fmt.bufPrint(buf, "{d}h", .{hours}) catch "h";
    const days = @divTrunc(hours, 24);
    if (days < 7) return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "d";
    if (days < 30) return std.fmt.bufPrint(buf, "{d}w", .{@divTrunc(days, 7)}) catch "w";
    if (days < 365) return std.fmt.bufPrint(buf, "{d}mo", .{@divTrunc(days, 30)}) catch "mo";
    return std.fmt.bufPrint(buf, "{d}y", .{@divTrunc(days, 365)}) catch "y";
}

/// 源码 + 每行归属的提交：连续同提交的行共用一条抬头（作者 / 年龄 / 短哈希），
/// 左边缘 3px 是新旧热条（越新越浓）。悬停弹出提交摘要并高亮它的所有行，点它返回提交下标。
pub fn blame(
    ui: *core.Context,
    id: []const u8,
    lines: []const []const u8,
    line_commit: []const i32,
    commits: []const BlameCommit,
    st: *BlameState,
    opts: BlameOpts,
) BlameResult {
    var res = BlameResult{};
    if (lines.len == 0) return res;
    const m = @min(lines.len, line_commit.len);
    var tmin: i64 = 0;
    var tmax: i64 = 0;
    for (commits, 0..) |c, i| {
        if (i == 0 or c.time < tmin) tmin = c.time;
        if (i == 0 or c.time > tmax) tmax = c.time;
    }
    const now = if (opts.now != 0) opts.now else tmax;
    const key = idOf(id);
    var area = ui.scroll(.{ .id = id, .height = opts.height });
    defer area.end();
    const avail = area.rect.w;
    const narrow = avail < 560;
    const gutter: f32 = if (narrow) 64 else std.math.clamp(avail * 0.32, 200, 300);
    const size: f32 = if (narrow) 12 else 12.5;
    const num_w: f32 = 34;
    st.hovered = -1;

    var i: usize = 0;
    while (i < m) : (i += 1) {
        const ci = line_commit[i];
        const valid = ci >= 0 and @as(usize, @intCast(ci)) < commits.len;
        const cm = if (valid) commits[@intCast(ci)] else BlameCommit{};
        const run_start = i == 0 or line_commit[i - 1] != ci;
        const row = ui.reserve(0, BLAME_ROW, true);
        const hit = ui.interactEx(kk(key, 0xB10, i), row, false);
        if (hit.hover and valid) {
            st.hovered = ci;
            res.hovered = ci;
        }
        if (hit.clicked and valid) res.clicked = ci;
        const marked = valid and st.hovered == ci;
        if (marked) ui.addBox(row, .{ .fill = theme.withAlpha(theme.accent, if (theme.isDark()) 30 else 18) });
        if (run_start and i > 0) ui.addBox(.{ .x = row.x, .y = row.y, .w = row.w, .h = 1 }, .{ .fill = theme.hair });
        // 热条：越新越浓
        const heat: f32 = if (tmax > tmin and valid) @as(f32, @floatFromInt(@max(0, cm.time - tmin))) / @as(f32, @floatFromInt(tmax - tmin)) else 0;
        ui.addBox(.{ .x = row.x, .y = row.y, .w = 3, .h = row.h }, .{ .fill = theme.withAlpha(theme.accent, @intFromFloat(38 + 217 * heat)) });
        // 抬头
        if (run_start and valid) {
            var x = row.x + 8;
            if (narrow) {
                // 窄版：只留首字母
                var ib: [2]u8 = undefined;
                const initial = if (cm.author.len > 0) blk: {
                    ib[0] = cm.author[0];
                    break :blk ib[0..1];
                } else "?";
                ui.addText(.{ .x = x, .y = row.y + 1, .w = 14, .h = 18 }, initial, theme.font_small, theme.secondary);
            } else {
                const aw = @min(ui.measureText(cm.author, theme.font_small).w + 2, @max(24, gutter - 40));
                ui.addText(.{ .x = x, .y = row.y + 1, .w = aw, .h = 18 }, clipText(ui, cm.author, theme.font_small, aw), theme.font_small, theme.text);
                x += aw + 6;
                var ab: [16]u8 = undefined;
                const age = fmtAge(ab[0..], now - cm.time);
                const agew = ui.measureText(age, theme.font_small).w;
                ui.addText(.{ .x = x, .y = row.y + 1, .w = agew + 1, .h = 18 }, ui.frameStr(age), theme.font_small, theme.secondary);
                x += agew + 8;
                var hb: [16]u8 = undefined;
                const hash = std.fmt.bufPrint(hb[0..], "{s}", .{cm.hash[0..@min(cm.hash.len, 8)]}) catch "";
                const hw = ui.measureText(hash, theme.font_small).w;
                if (x + hw < row.x + gutter - 6) {
                    ui.addText(.{ .x = row.x + gutter - 8 - hw, .y = row.y + 1, .w = hw + 1, .h = 18 }, ui.frameStr(hash), theme.font_small, theme.secondary);
                }
            }
        }
        // 行号
        var nb: [12]u8 = undefined;
        const numtxt = num.int(nb[0..], opts.first_line + @as(i32, @intCast(i)));
        const nw = ui.measureText(numtxt, theme.font_small).w;
        ui.addText(.{ .x = row.x + gutter + num_w - nw, .y = row.y + 1, .w = nw + 1, .h = 18 }, ui.frameStr(numtxt), theme.font_small, theme.secondary);
        // 代码
        const cx = row.x + gutter + num_w + 8;
        const cw = @max(0, row.x + row.w - cx);
        if (cw > 8) {
            if (opts.lang.len > 0) {
                editor.highlightLine(ui, opts.lang, lines[i], cx, row.y + 1, size, cw);
            } else {
                ui.addMonoText(.{ .x = cx, .y = row.y + 1, .w = cw, .h = 18 }, lines[i], size, theme.text);
            }
        }
        // 悬停抬头 → 提交摘要
        if (marked and cm.summary.len > 0) {
            var sb: [128]u8 = undefined;
            const tip = std.fmt.bufPrint(sb[0..], "{s}  {s}", .{ cm.hash[0..@min(cm.hash.len, 8)], cm.summary }) catch cm.summary;
            const tipw = @min(avail - 24, ui.measureText(tip, theme.font_small).w + 20);
            const card = t.Rect{ .x = row.x + gutter + 8, .y = row.y + BLAME_ROW, .w = @max(60, tipw), .h = 24 };
            ui.addOverlayBox(card, .{ .fill = theme.overlay_bg, .radius = 6 });
            ui.addText(.{ .x = card.x + 10, .y = card.y + 4, .w = card.w - 12, .h = 18 }, ui.frameStr(tip), theme.font_small, theme.overlay_fg);
        }
    }
    return res;
}
