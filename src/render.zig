//! 软件光栅：把绘制指令写进 BGRA 像素缓冲（DIB / 位图共用），并提供 BMP 落盘。
//! 文本不在这里画：里程碑 1 由平台层用系统字体绘制（见 `platform/win32.zig`），
//! 这样二进制里不需要内嵌字体与 TTF 光栅器；后续里程碑再评估是否改成自带光栅。
const std = @import("std");
const t = @import("types.zig");
const core = @import("core.zig");
const theme = @import("theme.zig");

pub fn render(ui: *core.Context, pixels: []u8, width: u32, height: u32, scale: f32) void {
    clear(pixels, width, height, theme.bg);
    var i: usize = 0;
    while (i < ui.cmd_count) : (i += 1) {
        switch (ui.cmds[i]) {
            .rect => |c| fillRoundRect(pixels, width, height, c.rect, c.radius, c.color, scale),
            .line => |c| drawLine(pixels, width, height, c.from, c.to, c.width, c.color, scale),
            .text => {},
        }
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
    scale: f32,
) void {
    if (color.a == 0) return;
    const x0 = px(rect.x, scale);
    const y0 = px(rect.y, scale);
    const x1 = px(rect.x + rect.w, scale);
    const y1 = px(rect.y + rect.h, scale);
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

fn insideRound(x: f32, y: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) bool {
    if (r <= 0) return true;
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
