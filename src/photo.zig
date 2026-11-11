//! 图片查看与裁剪（对位 CUI `cui_photo.c`）：`cui_image_viewer_ex` / `cui_cropper_ex`。
//!
//! 两个控件都**不解码图片**：像素由调用方给（`core.ImageSrc`，BGRA 顶行在前），
//! 这里只做坐标换算、交互与绘制。解码属应用层（见 `docs/迁移审计.md` §4「位图」）。
//!
//! 状态一律调用方持有（立即模式口径）：
//! - `ImageView{zoom, cx, cy}`：`zoom == 0` 表示「适配窗口」，否则是屏幕点/图像像素；
//!   `cx/cy` 是视口中心对应的图像像素坐标。
//! - 裁剪框 `t.Rect`：单位是**图像像素**（不是屏幕点）。
//! - `Drag{active, last}`：拖动过程中的「上一次鼠标位置」，用于算增量。
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

/// 在位图**之上**压一层半透明/边框：必须走覆盖层通道。
/// 每层的绘制顺序是 rect/line（`render`）→ image（`renderImages`）→ overlay
/// （`renderOverlays`）→ text，所以 `addBox` 画的压暗、边框、三分线会被位图整个盖掉
/// （2026-11-11 实测：用 addBox 的裁剪框在截图里完全不可见）。
fn fillBand(ui: *core.Context, r: t.Rect, color: t.Color) void {
    if (r.w <= 0 or r.h <= 0) return;
    ui.addOverlayBox(r, .{ .fill = color });
}

fn strokeRect(ui: *core.Context, r: t.Rect, w: f32, color: t.Color) void {
    ui.addOverlayBox(r, .{ .border = color, .border_width = w });
}

/// 拖动过程的临时状态（缩放平移与裁剪共用一套）。
pub const Drag = struct {
    active: bool = false,
    last: t.Point = .{},
};

/// 图像在视口里的摆放（屏幕点）。
const Fit = struct {
    rect: t.Rect,
    scale: f32,
};

fn fitScale(view: t.Rect, src: core.ImageSrc) f32 {
    if (src.w == 0 or src.h == 0) return 1;
    const iw: f32 = @floatFromInt(src.w);
    const ih: f32 = @floatFromInt(src.h);
    const s = @min(view.w / iw, view.h / ih);
    return if (s > 0) s else 1;
}

fn fitInside(view: t.Rect, src: core.ImageSrc, v: ImageView) Fit {
    if (src.w == 0 or src.h == 0) return .{ .rect = view, .scale = 1 };
    const iw: f32 = @floatFromInt(src.w);
    const ih: f32 = @floatFromInt(src.h);
    const fit_scale = fitScale(view, src);
    const scale = if (v.zoom > 0) v.zoom else fit_scale;
    const ccx = if (v.zoom > 0) v.cx else iw / 2;
    const ccy = if (v.zoom > 0) v.cy else ih / 2;
    return .{
        .rect = .{
            .x = view.x + view.w / 2 - ccx * scale,
            .y = view.y + view.h / 2 - ccy * scale,
            .w = iw * scale,
            .h = ih * scale,
        },
        .scale = scale,
    };
}

// ------------------------------------------------------------------ 查看器

pub const ImageView = struct {
    /// 屏幕点 / 图像像素；**0 = 适配窗口**（此时 cx/cy 无意义）。
    zoom: f32 = 0,
    /// 视口中心对应的图像像素。
    cx: f32 = 0,
    cy: f32 = 0,

    pub fn isFit(self: ImageView) bool {
        return self.zoom <= 0;
    }

    pub fn reset(self: *ImageView) void {
        self.* = .{};
    }
};

pub const ViewerOpts = struct {
    /// 0 = 撑满父宽。
    width: f32 = 0,
    height: f32 = 360,
    max_zoom: f32 = 16,
    /// 隐藏右下角的缩放工具条。
    no_toolbar: bool = false,
    /// 透明图后面铺棋盘格。
    checkerboard: bool = false,
};

const CHECKER: f32 = 12;

/// 透明背景：交叉条纹（不是逐格 addBox —— 240×200 的格子会吃掉 750 个节点，
/// 直接顶穿 `MAX_NODES`）。条纹交叉处的叠加色足够表达「这里是透明的」。
fn drawCheckerboard(ui: *core.Context, rect: t.Rect) void {
    ui.addBox(rect, .{ .fill = theme.bg });
    var x = rect.x;
    while (x < rect.x + rect.w) : (x += CHECKER * 2) {
        const w = @min(CHECKER, rect.x + rect.w - x);
        if (w > 0) ui.addBox(.{ .x = x, .y = rect.y, .w = w, .h = rect.h }, .{ .fill = theme.surface });
    }
    var y = rect.y;
    while (y < rect.y + rect.h) : (y += CHECKER * 2) {
        const hh = @min(CHECKER, rect.y + rect.h - y);
        if (hh > 0) ui.addBox(.{ .x = rect.x, .y = y, .w = rect.w, .h = hh }, .{ .fill = theme.surface });
    }
}

fn clampView(v: *ImageView, src: core.ImageSrc, opts: ViewerOpts) void {
    const max_zoom = if (opts.max_zoom > 0) opts.max_zoom else 16;
    if (v.zoom < 0) v.zoom = 0;
    if (v.zoom > max_zoom) v.zoom = max_zoom;
    const iw: f32 = @floatFromInt(src.w);
    const ih: f32 = @floatFromInt(src.h);
    v.cx = clampF(v.cx, 0, iw);
    v.cy = clampF(v.cy, 0, ih);
}

/// 图片查看器：滚轮以光标为中心缩放、按住拖动平移、右下角 −/百分比/+ 工具条。
/// 返回 `view` 是否变化。
pub fn imageViewer(
    ui: *core.Context,
    id: []const u8,
    src: core.ImageSrc,
    view: *ImageView,
    drag: *Drag,
    opts: ViewerOpts,
) bool {
    const h = if (opts.height > 40) opts.height else 360;
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const it = ui.interactEx(idOf(id, 0x1A6E), rect, true);
    const before = view.*;
    const fit_base = fitScale(rect, src);

    // 拖动平移（只在放大状态生效；适配状态图像刚好铺满，没有可平移空间）
    if (it.pressed and !view.isFit()) {
        drag.active = true;
        drag.last = ui.input.mouse;
    }
    if (drag.active and ui.input.down) {
        const dx = ui.input.mouse.x - drag.last.x;
        const dy = ui.input.mouse.y - drag.last.y;
        drag.last = ui.input.mouse;
        // 屏幕位移 → 图像像素（反向：拖动内容往右 = 中心左移）
        view.cx -= dx / view.zoom;
        view.cy -= dy / view.zoom;
    }
    if (drag.active and !ui.input.down) drag.active = false;

    // 滚轮缩放（以光标位置为中心）
    if (it.hover and ui.input.wheel != 0) {
        const f0 = fitInside(rect, src, view.*);
        // 光标下的图像坐标
        const ix = (ui.input.mouse.x - f0.rect.x) / f0.scale;
        const iy = (ui.input.mouse.y - f0.rect.y) / f0.scale;
        const factor: f32 = if (ui.input.wheel > 0) 1.15 else @as(f32, 1.0) / 1.15;
        const base = if (view.isFit()) fit_base else view.zoom;
        view.zoom = base * factor;
        clampView(view, src, opts);
        // 让这个图像点回到光标下：视口中心 = 光标点 + (中心 - 光标) / 缩放
        if (view.zoom > 0) {
            const f1 = fitInside(rect, src, view.*);
            _ = f1;
            const cx_screen = rect.x + rect.w / 2;
            const cy_screen = rect.y + rect.h / 2;
            view.cx = ix - (ui.input.mouse.x - cx_screen) / view.zoom;
            view.cy = iy - (ui.input.mouse.y - cy_screen) / view.zoom;
            clampView(view, src, opts);
        }
    }

    // 工具条按钮
    const th: f32 = 24;
    const bar = t.Rect{ .x = rect.x + rect.w - 132, .y = rect.y + rect.h - th - 8, .w = 124, .h = th };
    var minus_clicked = false;
    var plus_clicked = false;
    if (!opts.no_toolbar) {
        const minus = t.Rect{ .x = bar.x + 4, .y = bar.y + 2, .w = th - 6, .h = th - 6 };
        const plus = t.Rect{ .x = bar.x + bar.w - th + 2, .y = bar.y + 2, .w = th - 6, .h = th - 6 };
        minus_clicked = ui.interactEx(idOf(id, 0x2A11), minus, false).clicked;
        plus_clicked = ui.interactEx(idOf(id, 0x2A22), plus, false).clicked;
    }
    if (minus_clicked or plus_clicked) {
        const base = if (view.isFit()) fit_base else view.zoom;
        const factor: f32 = if (plus_clicked) 1.25 else 0.8;
        const was_fit = view.isFit();
        view.zoom = base * factor;
        if (was_fit) {
            view.cx = @as(f32, @floatFromInt(src.w)) / 2;
            view.cy = @as(f32, @floatFromInt(src.h)) / 2;
        }
        clampView(view, src, opts);
    }

    const changed = view.zoom != before.zoom or view.cx != before.cx or view.cy != before.cy;

    // ---- 绘制
    // 裁剪必须**还原到父级**，不能硬置 null（在 scroll 里会把滚动视口的裁剪也去掉）
    const outer_clip = ui.clip;
    if (opts.checkerboard) {
        ui.clip = rect;
        drawCheckerboard(ui, rect);
        ui.clip = outer_clip;
    } else {
        ui.addBox(rect, .{ .fill = theme.surface, .radius = 6 });
    }
    const f = fitInside(rect, src, view.*);
    ui.clip = rect;
    ui.addImage(f.rect, src, 0);
    ui.clip = outer_clip;
    ui.addBox(rect, .{ .border = theme.border, .radius = 6 });

    if (opts.no_toolbar) return changed;

    ui.addBox(bar, .{ .fill = theme.bg, .radius = th / 2, .border = theme.border });
    const minus = t.Rect{ .x = bar.x + 4, .y = bar.y + 2, .w = th - 6, .h = th - 6 };
    const plus = t.Rect{ .x = bar.x + bar.w - th + 2, .y = bar.y + 2, .w = th - 6, .h = th - 6 };
    const my = minus.y + minus.h / 2;
    const py = plus.y + plus.h / 2;
    ui.addOverlayLine(.{ .x = minus.x + 5, .y = my }, .{ .x = minus.x + minus.w - 5, .y = my }, 1.6, theme.text);
    ui.addOverlayLine(.{ .x = plus.x + 5, .y = py }, .{ .x = plus.x + plus.w - 5, .y = py }, 1.6, theme.text);
    ui.addOverlayLine(.{ .x = plus.x + plus.w / 2, .y = plus.y + 5 }, .{ .x = plus.x + plus.w / 2, .y = plus.y + plus.h - 5 }, 1.6, theme.text);

    var pb: [12]u8 = undefined;
    const ratio = if (view.isFit()) 1 else view.zoom / fit_base;
    const ps = ui.frameStr(num.percent(&pb, ratio));
    const pm = ui.measureText(ps, theme.font_small);
    ui.addText(.{
        .x = bar.x + (bar.w - pm.w) / 2,
        .y = bar.y + (bar.h - pm.h) / 2,
        .w = pm.w,
        .h = pm.h,
    }, ps, theme.font_small, theme.secondary);
    return changed;
}

// ------------------------------------------------------------------ 裁剪

pub const CropOpts = struct {
    width: f32 = 0,
    height: f32 = 360,
    /// 宽高比（宽/高），0 = 自由。
    aspect: f32 = 0,
    /// 圆形遮罩（头像用，自动按 1:1）。
    round: bool = false,
    /// 最小边长（图像像素）。
    min_size: f32 = 16,
};

/// 裁剪拖动状态：`handle` 记住按下时抓到的是哪条边/哪个角。
pub const CropDrag = struct {
    active: bool = false,
    handle: Handle = .none,
    last: t.Point = .{},
};

pub const Handle = enum { none, move, left, right, top, bottom, tl, tr, bl, br };

fn cropDefault(src: core.ImageSrc, opts: CropOpts) t.Rect {
    const iw: f32 = @floatFromInt(src.w);
    const ih: f32 = @floatFromInt(src.h);
    const aspect = if (opts.round) 1.0 else opts.aspect;
    if (aspect <= 0) return .{ .x = 0, .y = 0, .w = iw, .h = ih };
    var w = iw;
    var h = iw / aspect;
    if (h > ih) {
        h = ih;
        w = ih * aspect;
    }
    return .{ .x = (iw - w) / 2, .y = (ih - h) / 2, .w = w, .h = h };
}

fn hitCrop(cr: t.Rect, x: f32, y: f32) Handle {
    const edge: f32 = 9;
    if (x < cr.x - edge or x > cr.x + cr.w + edge) return .none;
    if (y < cr.y - edge or y > cr.y + cr.h + edge) return .none;
    const near_l = @abs(x - cr.x) <= edge;
    const near_r = @abs(x - (cr.x + cr.w)) <= edge;
    const near_t = @abs(y - cr.y) <= edge;
    const near_b = @abs(y - (cr.y + cr.h)) <= edge;
    if (near_l and near_t) return .tl;
    if (near_r and near_t) return .tr;
    if (near_l and near_b) return .bl;
    if (near_r and near_b) return .br;
    if (near_l) return .left;
    if (near_r) return .right;
    if (near_t) return .top;
    if (near_b) return .bottom;
    if (cr.contains(x, y)) return .move;
    return .none;
}

/// 裁剪框：内部拖动移动、四边/四角拖动缩放、外侧压暗 + 三分线、`round` 时圆形遮罩；
/// 聚焦时方向键微调（Shift ×10）。`crop` 单位是**图像像素**，零尺寸时取最大居中矩形。
/// 返回 `crop` 是否变化。
pub fn cropper(
    ui: *core.Context,
    id: []const u8,
    src: core.ImageSrc,
    crop: *t.Rect,
    drag: *CropDrag,
    opts: CropOpts,
) bool {
    const h = if (opts.height > 60) opts.height else 360;
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const iw: f32 = @floatFromInt(src.w);
    const ih: f32 = @floatFromInt(src.h);
    if (iw <= 0 or ih <= 0) return false;

    const pad: f32 = 10;
    const inner = t.Rect{ .x = rect.x + pad, .y = rect.y + pad, .w = rect.w - pad * 2, .h = rect.h - pad * 2 };
    const scale = @min(inner.w / iw, inner.h / ih);
    const img = t.Rect{
        .x = inner.x + (inner.w - iw * scale) / 2,
        .y = inner.y + (inner.h - ih * scale) / 2,
        .w = iw * scale,
        .h = ih * scale,
    };

    if (crop.w <= 0 or crop.h <= 0) crop.* = cropDefault(src, opts);
    const before = crop.*;
    const it = ui.interactEx(idOf(id, 0xC209), rect, true);
    // `min_size` 不能超过图片本身：8×8 的图配默认 16 会让 `clampF` 的 lo > hi，
    // 直接把裁剪框撑到 16 像素（实测：保持宽高比的用例因此失败）。
    const min_size = @min(if (opts.min_size > 1) opts.min_size else 16, @min(iw, ih));
    const aspect: f32 = if (opts.round) 1.0 else opts.aspect;

    const cr0 = t.Rect{
        .x = img.x + crop.x * scale,
        .y = img.y + crop.y * scale,
        .w = crop.w * scale,
        .h = crop.h * scale,
    };
    if (it.pressed) {
        const hd = hitCrop(cr0, ui.input.mouse.x, ui.input.mouse.y);
        if (hd != .none) {
            drag.active = true;
            drag.handle = hd;
            drag.last = ui.input.mouse;
        }
    }
    if (drag.active and ui.input.down) {
        const mdx = (ui.input.mouse.x - drag.last.x) / scale;
        const mdy = (ui.input.mouse.y - drag.last.y) / scale;
        drag.last = ui.input.mouse;
        switch (drag.handle) {
            .none => {},
            .move => {
                crop.x = clampF(crop.x + mdx, 0, iw - crop.w);
                crop.y = clampF(crop.y + mdy, 0, ih - crop.h);
            },
            .left => {
                const nx = clampF(crop.x + mdx, 0, crop.x + crop.w - min_size);
                crop.w -= nx - crop.x;
                crop.x = nx;
            },
            .right => crop.w = clampF(crop.w + mdx, min_size, iw - crop.x),
            .top => {
                const ny = clampF(crop.y + mdy, 0, crop.y + crop.h - min_size);
                crop.h -= ny - crop.y;
                crop.y = ny;
            },
            .bottom => crop.h = clampF(crop.h + mdy, min_size, ih - crop.y),
            .tl, .tr, .bl, .br => {
                if (drag.handle == .tr or drag.handle == .br) crop.w = clampF(crop.w + mdx, min_size, iw - crop.x);
                if (drag.handle == .tl or drag.handle == .bl) {
                    const nx = clampF(crop.x + mdx, 0, crop.x + crop.w - min_size);
                    crop.w -= nx - crop.x;
                    crop.x = nx;
                }
                if (drag.handle == .bl or drag.handle == .br) crop.h = clampF(crop.h + mdy, min_size, ih - crop.y);
                if (drag.handle == .tl or drag.handle == .tr) {
                    const ny = clampF(crop.y + mdy, 0, crop.y + crop.h - min_size);
                    crop.h -= ny - crop.y;
                    crop.y = ny;
                }
            },
        }
        if (aspect > 0) {
            crop.h = @max(min_size, crop.w / aspect);
            if (crop.y + crop.h > ih) crop.h = ih - crop.y;
        }
    }
    if (drag.active and !ui.input.down) drag.active = false;

    if (it.focused and !drag.active) {
        const step: f32 = if (ui.input.mods.shift) 10 else 1;
        for (ui.input.keys[0..ui.input.key_count]) |k| {
            switch (k) {
                .left => crop.x = clampF(crop.x - step, 0, iw - crop.w),
                .right => crop.x = clampF(crop.x + step, 0, iw - crop.w),
                .up => crop.y = clampF(crop.y - step, 0, ih - crop.h),
                .down => crop.y = clampF(crop.y + step, 0, ih - crop.h),
                else => {},
            }
        }
    }

    const changed = crop.x != before.x or crop.y != before.y or crop.w != before.w or crop.h != before.h;

    // ---- 绘制
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 6 });
    const outer_clip = ui.clip;
    ui.clip = rect;
    ui.addImage(img, src, 0);

    const cr = t.Rect{
        .x = img.x + crop.x * scale,
        .y = img.y + crop.y * scale,
        .w = crop.w * scale,
        .h = crop.h * scale,
    };
    const dim = t.Color.hex(0x000000, 110);
    if (cr.y > img.y) fillBand(ui, .{ .x = img.x, .y = img.y, .w = img.w, .h = cr.y - img.y }, dim);
    if (cr.y + cr.h < img.y + img.h) {
        fillBand(ui, .{ .x = img.x, .y = cr.y + cr.h, .w = img.w, .h = img.y + img.h - (cr.y + cr.h) }, dim);
    }
    if (cr.x > img.x) fillBand(ui, .{ .x = img.x, .y = cr.y, .w = cr.x - img.x, .h = cr.h }, dim);
    if (cr.x + cr.w < img.x + img.w) {
        fillBand(ui, .{ .x = cr.x + cr.w, .y = cr.y, .w = img.x + img.w - (cr.x + cr.w), .h = cr.h }, dim);
    }

    if (opts.round) {
        const r = @min(cr.w, cr.h) / 2;
        const cx = cr.x + cr.w / 2;
        const cy = cr.y + cr.h / 2;
        const steps: usize = 24;
        var prev = t.Point{ .x = cx + r, .y = cy };
        var i: usize = 1;
        while (i <= steps) : (i += 1) {
            const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)) * 2 * std.math.pi;
            const p = t.Point{ .x = cx + @cos(a) * r, .y = cy + @sin(a) * r };
            ui.addOverlayLine(prev, p, 2.5, theme.accent);
            prev = p;
        }
    } else {
        strokeRect(ui, cr, 2, theme.accent);
        var k: usize = 1;
        while (k < 3) : (k += 1) {
            const fx = cr.x + cr.w * @as(f32, @floatFromInt(k)) / 3;
            const fy = cr.y + cr.h * @as(f32, @floatFromInt(k)) / 3;
            ui.addOverlayLine(.{ .x = fx, .y = cr.y }, .{ .x = fx, .y = cr.y + cr.h }, 1.5, theme.accent_text);
            ui.addOverlayLine(.{ .x = cr.x, .y = fy }, .{ .x = cr.x + cr.w, .y = fy }, 1.5, theme.accent_text);
        }
        const cl: f32 = 12;
        const corners = [_]t.Point{
            .{ .x = cr.x, .y = cr.y },
            .{ .x = cr.x + cr.w, .y = cr.y },
            .{ .x = cr.x, .y = cr.y + cr.h },
            .{ .x = cr.x + cr.w, .y = cr.y + cr.h },
        };
        for (corners, 0..) |c0, ci| {
            const sx: f32 = if (ci == 0 or ci == 2) cl else -cl;
            const sy: f32 = if (ci < 2) cl else -cl;
            ui.addOverlayLine(c0, .{ .x = c0.x + sx, .y = c0.y }, 4, theme.accent);
            ui.addOverlayLine(c0, .{ .x = c0.x, .y = c0.y + sy }, 4, theme.accent);
        }
    }
    ui.clip = outer_clip;
    ui.addBox(rect, .{ .border = theme.border, .radius = 6 });
    return changed;
}
