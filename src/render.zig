//! 软件光栅：把绘制指令写进 BGRA 像素缓冲（DIB / 位图共用），并提供 BMP 落盘。
//! 文本不在这里画：里程碑 1 由平台层用系统字体绘制（见 `platform/win32.zig`），
//! 这样二进制里不需要内嵌字体与 TTF 光栅器；后续里程碑再评估是否改成自带光栅。
const std = @import("std");
const t = @import("types.zig");
const core = @import("core.zig");
const theme = @import("theme.zig");

pub fn render(ui: *core.Context, pixels: []u8, width: u32, height: u32, scale: f32, layer: u8) void {
    if (layer == 0) clear(pixels, width, height, theme.bg);
    var i: usize = 0;
    while (i < ui.cmd_count) : (i += 1) {
        switch (ui.cmds[i]) {
            .rect => |c| {
                if (c.layer == layer) fillRoundRect(pixels, width, height, c.rect, c.radius, c.color, c.clip, scale);
            },
            .line => |c| {
                if (c.layer == layer) drawLine(pixels, width, height, c.from, c.to, c.width, c.color, c.clip, scale);
            },
            .text => {},
        }
    }
}

/// 位图画（独立通道）：在矩形/线段之后、文本之前，逐层调用。
pub fn renderImages(ui: *core.Context, pixels: []u8, width: u32, height: u32, scale: f32, layer: u8) void {
    var i: usize = 0;
    while (i < ui.image_count) : (i += 1) {
        const c = ui.images[i];
        if (c.layer == layer) blitImage(pixels, width, height, c, scale);
    }
}

pub fn clear(pixels: []u8, width: u32, height: u32, color: t.Color) void {
    const n = @as(usize, width) * height;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        put(pixels, i * 4, color);
    }
}

fn px(v: f32, scale: f32) i32 {
    return @intFromFloat(@round(v * scale));
}

fn fillRoundRect(
    pixels: []u8,
    width: u32,
    height: u32,
    rect: t.Rect,
    radius: f32,
    color: t.Color,
    clip: ?t.Rect,
    scale: f32,
) void {
    if (color.a == 0) return;
    var x0 = px(rect.x, scale);
    var y0 = px(rect.y, scale);
    var x1 = px(rect.x + rect.w, scale);
    var y1 = px(rect.y + rect.h, scale);
    if (clip) |cl| {
        const cx0 = px(cl.x, scale);
        const cy0 = px(cl.y, scale);
        const cx1 = px(cl.x + cl.w, scale);
        const cy1 = px(cl.y + cl.h, scale);
        if (x0 < cx0) x0 = cx0;
        if (y0 < cy0) y0 = cy0;
        if (x1 > cx1) x1 = cx1;
        if (y1 > cy1) y1 = cy1;
    }
    if (x1 <= x0 or y1 <= y0) return;
    // 圆角不能超过短边的一半，否则角点判定会把整块跳过（胶囊按钮就是 radius=999）。
    const half_short = @min(@as(f32, @floatFromInt(x1 - x0)), @as(f32, @floatFromInt(y1 - y0))) / 2;
    const r = @min(@round(radius * scale), half_short);
    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);

    const cx0: i32 = if (x0 < 0) 0 else x0;
    const cy0: i32 = if (y0 < 0) 0 else y0;
    const cx1: i32 = if (x1 > w) w else x1;
    const cy1: i32 = if (y1 > h) h else y1;

    var y: i32 = cy0;
    while (y < cy1) : (y += 1) {
        var x: i32 = cx0;
        while (x < cx1) : (x += 1) {
            if (r > 0) {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                if (!insideRound(fx, fy, @floatFromInt(x0), @floatFromInt(y0), @floatFromInt(x1), @floatFromInt(y1), r)) continue;
            }
            const idx: usize = (@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))) * 4;
            blend(pixels, idx, color);
        }
    }
}

fn insideRound(x: f32, y: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) bool {    if (r <= 0) return true;
    var cx = x;
    var cy = y;
    if (x < x0 + r) {
        cx = x0 + r;
    } else if (x > x1 - r) {
        cx = x1 - r;
    } else {
        return true;
    }
    if (y < y0 + r) {
        cy = y0 + r;
    } else if (y > y1 - r) {
        cy = y1 - r;
    } else {
        return true;
    }
    const dx = x - cx;
    const dy = y - cy;
    return dx * dx + dy * dy <= r * r;
}

/// 线段光栅：按到线段的距离填像素（半宽 = width / 2）。
fn drawLine(
    pixels: []u8,
    width: u32,
    height: u32,
    from: t.Point,
    to: t.Point,
    line_width: f32,
    color: t.Color,
    clip: ?t.Rect,
    scale: f32,
) void {
    if (color.a == 0 or line_width <= 0) return;
    const ax = from.x * scale;
    const ay = from.y * scale;
    const bx = to.x * scale;
    const by = to.y * scale;
    const half = line_width * scale / 2;
    const pad = half + 1;

    var x0: i32 = @intFromFloat(@floor(@min(ax, bx) - pad));
    var y0: i32 = @intFromFloat(@floor(@min(ay, by) - pad));
    var x1: i32 = @intFromFloat(@ceil(@max(ax, bx) + pad));
    var y1: i32 = @intFromFloat(@ceil(@max(ay, by) + pad));
    if (clip) |cl| {
        const cx0 = px(cl.x, scale);
        const cy0 = px(cl.y, scale);
        const cx1 = px(cl.x + cl.w, scale);
        const cy1 = px(cl.y + cl.h, scale);
        if (x0 < cx0) x0 = cx0;
        if (y0 < cy0) y0 = cy0;
        if (x1 > cx1) x1 = cx1;
        if (y1 > cy1) y1 = cy1;
    }
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > @as(i32, @intCast(width))) x1 = @intCast(width);
    if (y1 > @as(i32, @intCast(height))) y1 = @intCast(height);

    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;

    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        var x: i32 = x0;
        while (x < x1) : (x += 1) {
            const px_f: f32 = @floatFromInt(x);
            const py_f: f32 = @floatFromInt(y);
            var tt: f32 = 0;
            if (len2 > 0) {
                tt = ((px_f - ax) * dx + (py_f - ay) * dy) / len2;
                if (tt < 0) tt = 0;
                if (tt > 1) tt = 1;
            }
            const cx = ax + dx * tt;
            const cy = ay + dy * tt;
            const ddx = px_f + 0.5 - cx;
            const ddy = py_f + 0.5 - cy;
            if (ddx * ddx + ddy * ddy > half * half) continue;
            const idx: usize = (@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))) * 4;
            blend(pixels, idx, color);
        }
    }
}

fn put(pixels: []u8, idx: usize, c: t.Color) void {
    pixels[idx] = c.b;
    pixels[idx + 1] = c.g;
    pixels[idx + 2] = c.r;
    pixels[idx + 3] = c.a;
}

/// 位图 blit：最近邻缩放 + 圆角/圆形遮罩 + 裁剪。
/// 源像素是 BGRA（顶行在前），与 BMP/DIB 同口径，所以不需要翻转。
fn blitImage(pixels: []u8, width: u32, height: u32, cmd: core.ImageCmd, scale: f32) void {
    const sw = cmd.w;
    const sh = cmd.h;
    if (sw == 0 or sh == 0) return;
    const src_row = @as(usize, sw) * 4;
    if (cmd.pixels.len < src_row * @as(usize, sh)) return;

    var x0 = px(cmd.rect.x, scale);
    var y0 = px(cmd.rect.y, scale);
    var x1 = px(cmd.rect.x + cmd.rect.w, scale);
    var y1 = px(cmd.rect.y + cmd.rect.h, scale);
    if (cmd.clip.w > 0 and cmd.clip.h > 0) {
        const cl = cmd.clip;
        x0 = @max(x0, px(cl.x, scale));
        y0 = @max(y0, px(cl.y, scale));
        x1 = @min(x1, px(cl.x + cl.w, scale));
        y1 = @min(y1, px(cl.y + cl.h, scale));
    }
    if (x1 <= x0 or y1 <= y0) return;

    const half_short = @min(@as(f32, @floatFromInt(x1 - x0)), @as(f32, @floatFromInt(y1 - y0))) / 2;
    const r = @min(@round(cmd.radius * scale), half_short);

    const cw: i32 = @intCast(width);
    const ch: i32 = @intCast(height);
    const cx0: i32 = @max(x0, 0);
    const cy0: i32 = @max(y0, 0);
    const cx1: i32 = @min(x1, cw);
    const cy1: i32 = @min(y1, ch);

    const dst_w: f32 = @floatFromInt(x1 - x0);
    const dst_h: f32 = @floatFromInt(y1 - y0);

    var y: i32 = cy0;
    while (y < cy1) : (y += 1) {
        var x: i32 = cx0;
        while (x < cx1) : (x += 1) {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            if (r > 0 and !insideRound(fx, fy, @floatFromInt(x0), @floatFromInt(y0), @floatFromInt(x1), @floatFromInt(y1), r)) continue;
            // 最近邻采样（像素中心对齐）
            const u: f32 = (fx + 0.5 - @as(f32, @floatFromInt(x0))) / dst_w;
            const v: f32 = (fy + 0.5 - @as(f32, @floatFromInt(y0))) / dst_h;
            var sx: usize = @intFromFloat(u * @as(f32, @floatFromInt(sw)));
            var sy: usize = @intFromFloat(v * @as(f32, @floatFromInt(sh)));
            if (sx >= sw) sx = sw - 1;
            if (sy >= sh) sy = sh - 1;
            const si = sy * src_row + sx * 4;
            const c = t.Color{
                .b = cmd.pixels[si],
                .g = cmd.pixels[si + 1],
                .r = cmd.pixels[si + 2],
                .a = cmd.pixels[si + 3],
            };
            const idx: usize = (@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))) * 4;
            blend(pixels, idx, c);
        }
    }
}

fn blend(pixels: []u8, idx: usize, c: t.Color) void {
    if (c.a == 255) {
        put(pixels, idx, c);
        return;
    }
    const a: u32 = c.a;
    const inv: u32 = 255 - a;
    pixels[idx] = @intCast((@as(u32, c.b) * a + @as(u32, pixels[idx]) * inv) / 255);
    pixels[idx + 1] = @intCast((@as(u32, c.g) * a + @as(u32, pixels[idx + 1]) * inv) / 255);
    pixels[idx + 2] = @intCast((@as(u32, c.r) * a + @as(u32, pixels[idx + 2]) * inv) / 255);
    pixels[idx + 3] = 255;
}
