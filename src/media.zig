//! 媒体与动效族（对位 CUI `cui_media.c`：5 个控件 / 11 个 API）：
//! 轮播、图片对比、卡片堆、翻牌数字、滚动行情条。
//!
//! 状态一律由调用方持有（立即模式口径）。所有动画都用 `ui.time` 的时间差驱动，
//! 用「指数趋近」代替 CUI 的弹簧（无超调，见 `approach`）——框架不带弹簧系统。
//!
//! **三条约束（踩过，别再犯）**：
//! 1. **绘制顺序是 rect/line → image → overlay → text**。位图之上只能画覆盖层
//!    （`addOverlayBox` / `addOverlayLine`）；用 `addBox` 往图上半透明压暗会被盖掉。
//! 2. **平台层文本不吃 alpha**（GDI `SetTextColor` 无 alpha），但**吃裁剪**
//!    → 滚动与翻牌靠裁剪实现，不要指望淡出。
//! 3. **控件不自己起帧**：动画需要调用方持续出帧（`App.next` 循环）。
//!
//! **与 CUI 的差异**（`docs/迁移审计.md` §4）：弹簧→指数趋近；行情条不做两侧渐隐
//! （文本盖不住）；图片对比的标签底色走覆盖层。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const num = @import("num.zig");
const t = @import("types.zig");

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

fn clampF(v: f32, lo: f32, hi: f32) f32 {
    if (hi < lo) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/// 帧时间差（秒），夹到 0..0.1 防止掉帧时跳变；同时把 `last` 推进到当前时间。
fn dtOf(ui: *core.Context, last: *f64) f32 {
    var dt: f32 = 0;
    if (last.* > 0 and ui.time > last.*) dt = @floatCast(ui.time - last.*);
    last.* = ui.time;
    if (dt > 0.1) dt = 0.1;
    return dt;
}

/// 指数趋近：每帧向目标走 `dt * rate` 比例（`rate` 越大越快，永远不超调）。
fn approach(cur: f32, target: f32, dt: f32, rate: f32) f32 {
    const k = @min(@as(f32, 1.0), dt * rate);
    return cur + (target - cur) * k;
}

fn intersect(a: t.Rect, b: t.Rect) ?t.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// 把裁剪收窄到 `r`，返回旧值（调用方负责还原）。
fn pushClip(ui: *core.Context, r: t.Rect) ?t.Rect {
    const old = ui.clip;
    ui.clip = if (old) |o| intersect(o, r) else r;
    return old;
}

// ============================================================== 轮播

pub const CarouselOpts = struct {
    height: f32 = 220,
    gap: f32 = 12,
    /// 首尾相接。
    loop: bool = false,
    no_arrows: bool = false,
    no_dots: bool = false,
    /// 自动切换间隔（秒），0 = 不自动。
    auto_advance: f64 = 0,
};

pub const CarouselState = struct {
    /// 当前落在第几页（吸附后）。
    index: usize = 0,
    /// 连续滑动位置（以「张」为单位）。
    pos: f32 = 0,
    init: bool = false,
    dragging: bool = false,
    press_x: f32 = 0,
    start_pos: f32 = 0,
    last_x: f32 = 0,
    vel: f32 = 0,
    last_t: f64 = 0,
    last_change: f64 = 0,
    hover: f32 = 0,
};

pub const CarouselScope = struct {
    ui: *core.Context,
    view: t.Rect = .{},
    stride: f32 = 0,
    pos: f32 = 0,
    count: usize = 0,
    opts: CarouselOpts = .{},
    st: *CarouselState = undefined,
    id: u64 = 0,
    old_clip: ?t.Rect = null,
    ended: bool = false,

    /// 第 `i` 张滑片的矩形（绝对定位，直接交给 `ui.panel`）。
    /// 完全在视口外返回 `null` —— 调用方跳过绘制，省节点也省光栅时间。
    pub fn slideRect(self: *CarouselScope, i: usize) ?t.Rect {
        if (i >= self.count) return null;
        const x = self.view.x + (@as(f32, @floatFromInt(i)) - self.pos) * self.stride;
        if (x >= self.view.x + self.view.w) return null;
        if (x + self.view.w <= self.view.x) return null;
        return .{ .x = x, .y = self.view.y, .w = self.view.w, .h = self.view.h };
    }

    pub fn end(self: *CarouselScope) void {
        if (self.ended) return;
        self.ended = true;
        const ui = self.ui;
        const st = self.st;
        ui.clip = self.old_clip;

        // 左右箭头：叠在滑片之上 → 覆盖层
        if (!self.opts.no_arrows and self.count > 1 and st.hover > 0.02) {
            const a = clampF(st.hover, 0.0, 1.0);
            var k: usize = 0;
            while (k < 2) : (k += 1) {
                const next = k == 1;
                const enabled = self.opts.loop or (next and st.index + 1 < self.count) or (!next and st.index > 0);
                const size: f32 = 32;
                const bx = if (next) self.view.x + self.view.w - size - 10 else self.view.x + 10;
                const r = t.Rect{ .x = bx, .y = self.view.y + (self.view.h - size) / 2, .w = size, .h = size };
                const aid = self.id ^ @as(u64, if (next) 0x0A11 else 0x0A12);
                const it = ui.interactEx(aid, r, true);
                var fill = t.Color.hex(0xFFFFFF, @intFromFloat(210.0 * a));
                if (it.hover and enabled) fill = t.Color.hex(0xFFFFFF, 245);
                ui.addOverlayBox(r, .{
                    .fill = fill,
                    .radius = size / 2,
                    .border = t.Color.hex(0x000000, @intFromFloat(40.0 * a)),
                    .border_width = 1,
                });
                // 雪佛龙（两条线段）
                const cx = r.x + r.w / 2;
                const cy = r.y + r.h / 2;
                const dx: f32 = if (next) 3 else -3;
                const col = if (enabled) theme.text else theme.secondary;
                ui.addOverlayLine(.{ .x = cx - dx, .y = cy - 5 }, .{ .x = cx + dx, .y = cy }, 1.8, col);
                ui.addOverlayLine(.{ .x = cx + dx, .y = cy }, .{ .x = cx - dx, .y = cy + 5 }, 1.8, col);
                if (it.clicked and enabled) {
                    self.go(if (next) 1 else -1);
                }
            }
        }

        // 圆点：在视口下方（不压位图，普通节点即可）
        if (!self.opts.no_dots and self.count > 1) {
            const dots = ui.reserve(0, 10, true);
            const per: f32 = 18;
            const total = per * @as(f32, @floatFromInt(self.count));
            var x = dots.x + (dots.w - total) / 2;
            var k: usize = 0;
            while (k < self.count) : (k += 1) {
                const dr = t.Rect{ .x = x + 4, .y = dots.y + 3, .w = 10, .h = 4 };
                const it = ui.interactEx(self.id ^ 0x0D00 ^ @as(u64, k), dr, false);
                const on = k == st.index;
                ui.addBox(dr, .{
                    .fill = if (on) theme.text else if (it.hover) theme.secondary else theme.border,
                    .radius = 2,
                });
                if (it.clicked) {
                    st.index = k;
                    st.last_change = ui.time;
                }
                x += per;
            }
        }
    }

    fn go(self: *CarouselScope, delta: i32) void {
        const n: i32 = @intCast(self.count);
        var target: i32 = @as(i32, @intCast(self.st.index)) + delta;
        if (self.opts.loop) {
            target = @mod(target, n);
        } else {
            target = std.math.clamp(target, 0, n - 1);
        }
        self.st.index = @intCast(target);
        self.st.last_change = self.ui.time;
    }
};

/// 轮播：先 `carousel(...)`，再用 `scope.slideRect(i)` 逐张画，最后 `scope.end()`（画箭头与圆点）。
pub fn carousel(
    ui: *core.Context,
    id_str: []const u8,
    count: usize,
    st: *CarouselState,
    opts: CarouselOpts,
) CarouselScope {
    const id = idOf(id_str, 0xCA0);
    const view = ui.reserve(0, opts.height, true);
    const dt = dtOf(ui, &st.last_t);
    if (!st.init) {
        st.pos = @floatFromInt(st.index);
        st.init = true;
        st.last_change = ui.time;
    }
    if (st.index >= count) st.index = if (count > 0) count - 1 else 0;

    const gap = if (opts.gap > 0) opts.gap else 12;
    const stride = view.w + gap;
    const it = ui.interactEx(id, view, true);
    st.hover = approach(st.hover, if (it.hover) 1 else 0, dt, 14);

    var target: i32 = @intCast(st.index);
    if (it.pressed and !st.dragging and count > 0) {
        st.dragging = true;
        st.press_x = ui.input.mouse.x;
        st.start_pos = st.pos;
        st.last_x = ui.input.mouse.x;
        st.vel = 0;
    }
    if (st.dragging) {
        if (ui.input.down) {
            var p = st.start_pos - (ui.input.mouse.x - st.press_x) / stride;
            // 越界阻尼（与 CUI 同：0.3 倍）
            const last: f32 = if (count > 0) @floatFromInt(count - 1) else 0;
            if (p < 0) p *= 0.3;
            if (p > last) p = last + (p - last) * 0.3;
            const moved = ui.input.mouse.x - st.last_x;
            st.vel = st.vel + (moved / stride / @max(dt, 0.001) - st.vel) * 0.4;
            st.last_x = ui.input.mouse.x;
            st.pos = p;
        } else {
            st.dragging = false;
            const land = st.pos + clampF(st.vel, -8, 8) * 0.12;
            target = @intFromFloat(@round(land));
            // 快速甩动至少翻一页
            if (target == @as(i32, @intCast(st.index)) and @abs(st.vel) > 1.2) {
                target += if (st.vel > 0) -1 else 1;
            }
        }
    }
    if (it.hover and !st.dragging and ui.input.wheel != 0) {
        target -= if (ui.input.wheel > 0) 1 else -1;
        ui.wheel_used = true;
    }
    if (it.focused and !st.dragging) {
        for (ui.input.keys[0..ui.input.key_count]) |k| {
            switch (k) {
                .right => target += 1,
                .left => target -= 1,
                else => {},
            }
        }
    }
    if (opts.auto_advance > 0 and !it.hover and !st.dragging and count > 1) {
        if (ui.time - st.last_change >= opts.auto_advance) target += 1;
    }
    if (count == 0) {
        target = 0;
    } else if (opts.loop) {
        target = @mod(target, @as(i32, @intCast(count)));
    } else {
        target = std.math.clamp(target, 0, @as(i32, @intCast(count - 1)));
    }
    if (target != @as(i32, @intCast(st.index))) {
        st.index = @intCast(target);
        st.last_change = ui.time;
    }
    if (!st.dragging) st.pos = approach(st.pos, @floatFromInt(st.index), dt, 16);
    if (@abs(st.pos - @as(f32, @floatFromInt(st.index))) < 0.001) st.pos = @floatFromInt(st.index);

    const old_clip = pushClip(ui, view);
    ui.addBox(view, .{ .fill = theme.surface, .radius = theme.radius_control });

    return .{
        .ui = ui,
        .view = view,
        .stride = stride,
        .pos = st.pos,
        .count = count,
        .opts = opts,
        .st = st,
        .id = id,
        .old_clip = old_clip,
    };
}

// ============================================================== 图片对比

pub const CompareOpts = struct {
    /// 0 = 撑满父容器宽度。
    width: f32 = 0,
    height: f32 = 280,
    /// 图片宽高比；0 = 用 `src.w / src.h`。
    aspect: f32 = 0,
    before_label: []const u8 = "Before",
    after_label: []const u8 = "After",
    no_labels: bool = false,
};

pub const CompareState = struct {
    /// 分割位置 0..1。
    pos: f32 = 0.5,
    last_t: f64 = 0,
};

/// 图片对比（拖动分割线）。返回分割位置是否变化。
pub fn imageCompare(
    ui: *core.Context,
    id_str: []const u8,
    before: core.ImageSrc,
    after: core.ImageSrc,
    st: *CompareState,
    opts: CompareOpts,
) bool {
    const id = idOf(id_str, 0xC04);
    _ = dtOf(ui, &st.last_t);
    const rect = ui.reserve(opts.width, opts.height, opts.width <= 0);
    const it = ui.interactEx(id, rect, true);
    const old = st.pos;
    if (it.dragging and rect.w > 0) {
        st.pos = clampF((ui.input.mouse.x - rect.x) / rect.w, 0, 1);
    }
    if (it.focused) {
        for (ui.input.keys[0..ui.input.key_count]) |k| {
            switch (k) {
                .left => st.pos = clampF(st.pos - 0.05, 0, 1),
                .right => st.pos = clampF(st.pos + 0.05, 0, 1),
                else => {},
            }
        }
    }

    const radius = theme.radius_control;
    ui.addBox(rect, .{ .fill = theme.surface, .radius = radius });

    // cover 摆放：按宽高比放大到**盖满**控件矩形，超出部分靠裁剪切掉（与 CUI 的 uv 裁切等价）
    const ar = if (opts.aspect > 0)
        opts.aspect
    else if (after.h > 0 and after.w > 0)
        @as(f32, @floatFromInt(after.w)) / @as(f32, @floatFromInt(after.h))
    else
        0;
    var img = rect;
    if (ar > 0 and rect.h > 0 and rect.w > 0) {
        const ra = rect.w / rect.h;
        if (ar > ra) {
            // 图更宽：对齐高度，左右溢出
            img.h = rect.h;
            img.w = rect.h * ar;
            img.x = rect.x + (rect.w - img.w) / 2;
        } else {
            // 图更高：对齐宽度，上下溢出
            img.w = rect.w;
            img.h = rect.w / ar;
            img.y = rect.y + (rect.h - img.h) / 2;
        }
    }

    const inner_old = pushClip(ui, rect);
    ui.addImage(img, after, radius);
    const split = rect.x + rect.w * st.pos;
    ui.clip = intersect(inner_old orelse rect, .{ .x = rect.x, .y = rect.y, .w = split - rect.x, .h = rect.h });
    if (ui.clip != null) ui.addImage(img, before, radius);
    ui.clip = inner_old;

    // 分割线 + 圆柄 + 雪佛龙：必须走覆盖层（位图在上面画完才轮到它）
    ui.addOverlayLine(.{ .x = split, .y = rect.y }, .{ .x = split, .y = rect.y + rect.h }, 2, t.Color.hex(0xFFFFFF, 230));
    if (it.hover or it.dragging) {
        // 悬停时给分割线加一点提示（加宽）
        ui.addOverlayLine(.{ .x = split, .y = rect.y }, .{ .x = split, .y = rect.y + rect.h }, 6, t.Color.hex(0xFFFFFF, 60));
    }
    const hr: f32 = 16;
    const cy = rect.y + rect.h / 2;
    ui.addOverlayBox(.{ .x = split - hr, .y = cy - hr, .w = hr * 2, .h = hr * 2 }, .{
        .fill = t.Color.hex(0xFFFFFF, 255),
        .radius = hr,
        .border = t.Color.hex(0x000000, 40),
        .border_width = 1,
    });
    ui.addOverlayLine(.{ .x = split - 3, .y = cy - 4 }, .{ .x = split - 8, .y = cy }, 1.6, theme.text);
    ui.addOverlayLine(.{ .x = split - 8, .y = cy }, .{ .x = split - 3, .y = cy + 4 }, 1.6, theme.text);
    ui.addOverlayLine(.{ .x = split + 3, .y = cy - 4 }, .{ .x = split + 8, .y = cy }, 1.6, theme.text);
    ui.addOverlayLine(.{ .x = split + 8, .y = cy }, .{ .x = split + 3, .y = cy + 4 }, 1.6, theme.text);

    // 标签：文本在覆盖层之上（文本最后画），底色走覆盖层
    if (!opts.no_labels) {
        labelPill(ui, opts.before_label, .{ .x = rect.x + 10, .y = rect.y + 10 }, false);
        labelPill(ui, opts.after_label, .{ .x = rect.x + rect.w - 10, .y = rect.y + 10 }, true);
    }
    return st.pos != old;
}

fn labelPill(ui: *core.Context, label: []const u8, at: t.Point, right: bool) void {
    if (label.len == 0) return;
    const m = ui.measureText(label, theme.font_small);
    const w = m.w + 14;
    const h: f32 = 20;
    const r = t.Rect{ .x = if (right) at.x - w else at.x, .y = at.y, .w = w, .h = h };
    ui.addOverlayBox(r, .{ .fill = t.Color.hex(0x000000, 120), .radius = 6 });
    ui.addText(.{ .x = r.x + 7, .y = r.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_small, t.Color.hex(0xFFFFFF, 255));
}

// ============================================================== 卡片堆

pub const CardStackOpts = struct {
    height: f32 = 320,
    /// 同时可见的张数（后面的只露出一条边）。
    visible: usize = 3,
    width: f32 = 0,
};

pub const CardStackState = struct {
    x: f32 = 0,
    y: f32 = 0,
    promote: f32 = 0,
    dragging: bool = false,
    flying: bool = false,
    fly_dir: i32 = 0,
    press_x: f32 = 0,
    press_y: f32 = 0,
    last_x: f32 = 0,
    vel: f32 = 0,
    last_t: f64 = 0,
};

pub const CardStackScope = struct {
    ui: *core.Context,
    base: t.Rect = .{},
    st: *CardStackState = undefined,
    visible: usize = 3,
    result: i32 = 0,
    old_clip: ?t.Rect = null,
    ended: bool = false,

    /// 第 `depth` 层的卡片矩形（0 = 最上面那张）。
    /// **从深到浅画**（`depth` 大 → 小），最后画 0 层，才能叠在上面。
    pub fn cardRect(self: *CardStackScope, depth: usize) t.Rect {
        const dd = @as(f32, @floatFromInt(depth)) + self.st.promote;
        const s = 1.0 - 0.05 * dd;
        const w = self.base.w * s;
        const h = self.base.h * s;
        var x = self.base.x + (self.base.w - w) / 2;
        var y = self.base.y + 12 * dd;
        if (depth == 0) {
            x += self.st.x;
            y += self.st.y;
        }
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    /// 收尾，返回本帧被甩出的方向（-1 左 / +1 右 / 0 无）。调用方据此推进自己的卡片索引。
    pub fn end(self: *CardStackScope) i32 {
        if (self.ended) return 0;
        self.ended = true;
        self.ui.clip = self.old_clip;
        return self.result;
    }
};

/// 卡片堆：甩动（或方向键）把最上面一张扔出去。
pub fn cardStack(
    ui: *core.Context,
    id_str: []const u8,
    count: usize,
    st: *CardStackState,
    opts: CardStackOpts,
) CardStackScope {
    const id = idOf(id_str, 0x70B);
    const dt = dtOf(ui, &st.last_t);
    const visible = if (opts.visible > 0) opts.visible else 3;
    const base = ui.reserve(opts.width, opts.height + 12 * @as(f32, @floatFromInt(visible -| 1)), opts.width <= 0);
    const top = t.Rect{ .x = base.x, .y = base.y, .w = base.w, .h = opts.height };
    const it = ui.interactEx(id, top, true);

    var result: i32 = 0;
    if (!st.flying and it.pressed and !st.dragging and count > 0) {
        st.dragging = true;
        st.press_x = ui.input.mouse.x;
        st.press_y = ui.input.mouse.y;
        st.last_x = ui.input.mouse.x;
        st.vel = 0;
    }
    var throw_dir: i32 = 0;
    if (st.dragging) {
        if (ui.input.down) {
            st.x = ui.input.mouse.x - st.press_x;
            st.y = (ui.input.mouse.y - st.press_y) * 0.3;
            const moved = ui.input.mouse.x - st.last_x;
            st.vel = st.vel + (moved / @max(dt, 0.001) - st.vel) * 0.4;
            st.last_x = ui.input.mouse.x;
        } else {
            st.dragging = false;
            if (@abs(st.x) > base.w * 0.35 or @abs(st.vel) > 900) {
                throw_dir = if (st.x + st.vel * 0.1 > 0) 1 else -1;
            }
        }
    }
    if (it.focused and !st.flying) {
        for (ui.input.keys[0..ui.input.key_count]) |k| {
            switch (k) {
                .right => throw_dir = 1,
                .left => throw_dir = -1,
                else => {},
            }
        }
    }
    if (throw_dir != 0 and count > 0) {
        st.flying = true;
        st.fly_dir = throw_dir;
    }
    const fly_to = @as(f32, @floatFromInt(st.fly_dir)) * (base.w * 1.5 + 80);
    if (st.flying) {
        st.x = approach(st.x, fly_to, dt, 11);
        if (@abs(st.x) > base.w * 1.3) {
            result = st.fly_dir;
            st.flying = false;
            st.x = 0;
            st.y = 0;
            st.promote = 1;
        }
    } else if (!st.dragging) {
        st.x = approach(st.x, 0, dt, 18);
        st.y = approach(st.y, 0, dt, 18);
    }
    st.promote = approach(st.promote, 0, dt, 14);

    const old_clip = pushClip(ui, base);
    return .{ .ui = ui, .base = base, .st = st, .visible = visible, .result = result, .old_clip = old_clip };
}

// ============================================================== 翻牌数字

pub const CounterOpts = struct {
    size: f32 = 32,
    decimals: u8 = 0,
    group_thousands: bool = false,
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    color: ?t.Color = null,
};

pub const CounterState = struct {
    /// 每一位的滚动位置（从右往左 0..23），整数部分为当前显示的数字。
    d: [24]f32 = @splat(0),
    init: bool = false,
    last_t: f64 = 0,
};

/// 翻牌数字（odometer）：数字变化时每一位像里程表一样向上滚。
pub fn counter(ui: *core.Context, id_str: []const u8, value: f64, st: *CounterState, opts: CounterOpts) void {
    _ = id_str;
    const dt = dtOf(ui, &st.last_t);
    const size = if (opts.size > 0) opts.size else 32;
    const color = opts.color orelse theme.text;

    var grp: [64]u8 = undefined;
    const digits = ui.frameStr(formatNumber(&grp, value, opts.decimals, opts.group_thousands));

    // 拼成 "前缀 + 数字 + 后缀" 一条串，后面按单字符走布局
    var composed: [128]u8 = undefined;
    var composed_len: usize = 0;
    for ([_][]const u8{ opts.prefix, digits, opts.suffix }) |seg| {
        const n = @min(seg.len, composed.len - composed_len);
        @memcpy(composed[composed_len..][0..n], seg[0..n]);
        composed_len += n;
    }
    const s = composed[0..composed_len];
    if (s.len == 0) return;

    const lh = size * 1.15;
    const zero = ui.measureText("0", size);
    const dw = if (zero.w > 0) zero.w else size * 0.55;

    // 先算总宽（数字用固定宽，其余字符按实测）
    var total_w: f32 = 0;
    var slot: usize = countDigits(s);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (isDigit(s[i])) {
            total_w += dw;
        } else {
            total_w += ui.measureText(s[i .. i + 1], size).w;
        }
    }

    const row = ui.reserve(total_w, lh, false);
    var x = row.x;
    i = 0;
    while (i < s.len) : (i += 1) {
        if (isDigit(s[i])) {
            if (slot > 0) slot -= 1;
            const si = @min(slot, st.d.len - 1);
            const target = @as(f32, @floatFromInt(s[i] - '0'));
            const sp = &st.d[si];
            if (!st.init) sp.* = target;
            const cur = sp.*;
            // 顺着计数方向滚：目标带上整圈，9→0 也是前进一步
            const turns = @floor(cur / 10.0) * 10.0;
            var t1 = turns + target;
            if (t1 - cur > 5) t1 -= 10;
            if (cur - t1 > 5) t1 += 10;
            sp.* = approach(cur, t1, dt, 14);
            drawDigit(ui, t.Rect{ .x = x, .y = row.y, .w = dw, .h = lh }, sp.*, lh, size, dw, color);
            x += dw;
        } else {
            const m = ui.measureText(s[i .. i + 1], size);
            ui.addText(.{ .x = x, .y = row.y, .w = m.w, .h = lh }, ui.frameStr(s[i .. i + 1]), size, color);
            x += m.w;
        }
    }
    st.init = true;
}

fn drawDigit(ui: *core.Context, cell: t.Rect, v: f32, lh: f32, size: f32, dw: f32, color: t.Color) void {
    const old = pushClip(ui, cell);
    const base = @floor(v);
    var k: i32 = -1;
    while (k <= 1) : (k += 1) {
        const vv = base + @as(f32, @floatFromInt(k));
        if (@abs(vv - v) >= 1) continue;
        const wrapped = @mod(@mod(vv, 10.0) + 10.0, 10.0);
        const digit: u8 = @intFromFloat(wrapped);
        const buf = [1]u8{'0' + digit};
        const y = cell.y + (vv - v) * lh;
        ui.addText(.{ .x = cell.x + (cell.w - dw) / 2, .y = y, .w = dw, .h = lh }, ui.frameStr(&buf), size, color);
    }
    ui.clip = old;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn countDigits(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (isDigit(c)) n += 1;
    }
    return n;
}

/// 把数值格式化成字符串（写进 `out`，返回其切片）：
/// `formatNumber(buf, 48210, 0, true)` → `48,210`；`decimals` 控制小数位。
pub fn formatNumber(out: []u8, value: f64, decimals: u8, group: bool) []const u8 {
    var tmp: [48]u8 = undefined;
    const ds = num.fixed(&tmp, @floatCast(value), decimals);
    if (!group) {
        const n = @min(ds.len, out.len);
        @memcpy(out[0..n], ds[0..n]);
        return out[0..n];
    }
    return groupThousands(out, ds);
}

/// `48210` → `48,210`（只给第一段连续数字加逗号，与 CUI 同口径）。
fn groupThousands(out: []u8, s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and !(s[a] >= '0' and s[a] <= '9')) a += 1;
    var b = a;
    while (b < s.len and (s[b] >= '0' and s[b] <= '9')) b += 1;
    var n: usize = 0;
    var k: usize = 0;
    while (k < a and n < out.len) : (k += 1) {
        out[n] = s[k];
        n += 1;
    }
    k = a;
    while (k < b and n < out.len) : (k += 1) {
        out[n] = s[k];
        n += 1;
        const left = b - k - 1;
        if (left > 0 and left % 3 == 0 and n < out.len) {
            out[n] = ',';
            n += 1;
        }
    }
    k = b;
    while (k < s.len and n < out.len) : (k += 1) {
        out[n] = s[k];
        n += 1;
    }
    return out[0..n];
}

// ============================================================== 滚动行情条

pub const TickerItem = struct {
    label: []const u8,
    value: []const u8 = "",
    /// 涨跌幅（百分比数值，如 1.8 表示 +1.8%）。
    delta: f32 = 0,
    /// 跌为好（如延迟、错误率）。
    lower_is_better: bool = false,
};

pub const TickerOpts = struct {
    height: f32 = 40,
    /// 每秒滚动像素。
    speed: f32 = 40,
    /// 标签与数值之间的间距。
    gap: f32 = 6,
    /// 条目之间的间距（分隔点在中间）。
    item_gap: f32 = 18,
    show_panel: bool = true,
};

pub const TickerState = struct {
    off: f32 = 0,
    set_w: f32 = 0,
    last_t: f64 = 0,
};

/// 滚动行情条：一条无限循环的「标签 数值 涨跌」带，鼠标悬停暂停。
pub fn ticker(ui: *core.Context, id_str: []const u8, items: []const TickerItem, st: *TickerState, opts: TickerOpts) void {
    const id = idOf(id_str, 0x5E7);
    const dt = dtOf(ui, &st.last_t);
    const rect = ui.reserve(0, opts.height, true);
    const it = ui.interact(id, rect);

    // 一组（所有条目 + 分隔）的宽度
    var set_w: f32 = 0;
    for (items) |item| {
        set_w += measureItem(ui, item, opts).w + opts.item_gap * 2 + 4;
    }
    if (set_w <= 0) set_w = rect.w;
    st.set_w = set_w;

    if (!it.hover) {
        st.off += dt * (if (opts.speed > 0) opts.speed else 40);
        while (st.off >= set_w) st.off -= set_w;
    }

    if (opts.show_panel) ui.addBox(rect, .{ .fill = theme.surface, .radius = 6 });
    const old_clip = pushClip(ui, rect);
    const cy = rect.y + rect.h / 2;

    // 三份副本铺满视口
    var copy: usize = 0;
    while (copy < 3) : (copy += 1) {
        var x = rect.x - st.off + @as(f32, @floatFromInt(copy)) * set_w;
        for (items) |item| {
            const m = measureItem(ui, item, opts);
            var px = x;
            const label_m = ui.measureText(item.label, theme.font_small);
            ui.addText(.{ .x = px, .y = cy - label_m.h / 2, .w = label_m.w, .h = label_m.h }, item.label, theme.font_small, theme.secondary);
            px += label_m.w + opts.gap;
            if (item.value.len > 0) {
                const vm = ui.measureText(item.value, theme.font_small);
                ui.addText(.{ .x = px, .y = cy - vm.h / 2, .w = vm.w, .h = vm.h }, item.value, theme.font_small, theme.text);
                px += vm.w + opts.gap;
            }
            if (item.delta != 0) {
                const good = if (item.lower_is_better) item.delta < 0 else item.delta > 0;
                const col = if (good) theme.success else theme.danger;
                // 小三角（覆盖层线段，省字体依赖）
                const ty = cy - 3;
                if (item.delta > 0) {
                    ui.addOverlayLine(.{ .x = px, .y = ty + 6 }, .{ .x = px + 4, .y = ty }, 1.4, col);
                    ui.addOverlayLine(.{ .x = px + 4, .y = ty }, .{ .x = px + 8, .y = ty + 6 }, 1.4, col);
                    ui.addOverlayLine(.{ .x = px + 8, .y = ty + 6 }, .{ .x = px, .y = ty + 6 }, 1.4, col);
                } else {
                    ui.addOverlayLine(.{ .x = px, .y = ty }, .{ .x = px + 4, .y = ty + 6 }, 1.4, col);
                    ui.addOverlayLine(.{ .x = px + 4, .y = ty + 6 }, .{ .x = px + 8, .y = ty }, 1.4, col);
                    ui.addOverlayLine(.{ .x = px + 8, .y = ty }, .{ .x = px, .y = ty }, 1.4, col);
                }
                px += 10;
                var db: [24]u8 = undefined;
                const ds = ui.frameStr(num.fixed(&db, @abs(item.delta), 1));
                const sign: u8 = if (item.delta > 0) '+' else '-';
                var pb: [40]u8 = undefined;
                var pn: usize = 0;
                pb[pn] = sign;
                pn += 1;
                @memcpy(pb[pn .. pn + ds.len], ds);
                pn += ds.len;
                pb[pn] = '%';
                pn += 1;
                const dm = ui.measureText(pb[0..pn], theme.font_small);
                ui.addText(.{ .x = px, .y = cy - dm.h / 2, .w = dm.w, .h = dm.h }, ui.frameStr(pb[0..pn]), theme.font_small, col);
                px += dm.w;
            }
            x += m.w + opts.item_gap;
            // 分隔点
            ui.addBox(.{ .x = x, .y = cy - 2, .w = 4, .h = 4 }, .{ .fill = theme.border, .radius = 2 });
            x += 4 + opts.item_gap;
        }
    }
    ui.clip = old_clip;
}

fn measureItem(ui: *core.Context, item: TickerItem, opts: TickerOpts) t.Size {
    var w: f32 = 0;
    var h: f32 = 0;
    const lm = ui.measureText(item.label, theme.font_small);
    w += lm.w;
    if (lm.h > h) h = lm.h;
    if (item.value.len > 0) {
        const vm = ui.measureText(item.value, theme.font_small);
        w += opts.gap + vm.w;
        if (vm.h > h) h = vm.h;
    }
    if (item.delta != 0) w += opts.gap + 10 + 34;
    return .{ .w = w, .h = h };
}
