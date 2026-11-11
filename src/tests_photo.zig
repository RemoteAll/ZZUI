//! 图片查看与裁剪的测试（由 `tests.zig` 引入）。
const std = @import("std");
const core = @import("core.zig");
const photo = @import("photo.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

// 8×8 纯青位图（BGRA）
var img_px: [8 * 8 * 4]u8 = @splat(0);

fn setupImage() core.ImageSrc {
    var i: usize = 0;
    while (i < img_px.len) : (i += 4) {
        img_px[i] = 0xFF; // B
        img_px[i + 1] = 0xCC; // G
        img_px[i + 2] = 0x00;
        img_px[i + 3] = 0xFF;
    }
    return .{ .pixels = &img_px, .w = 8, .h = 8 };
}

fn runViewer(ui: *core.Context, src: core.ImageSrc, view: *photo.ImageView, drag: *photo.Drag, opts: photo.ViewerOpts) bool {
    ui.begin(520, 460);
    var col = ui.column(.{ .pad = 12, .gap = 8 });
    defer col.end();
    const changed = photo.imageViewer(ui, "iv", src, view, drag, opts);
    ui.paint();
    return changed;
}

fn runCropper(ui: *core.Context, src: core.ImageSrc, crop: *t.Rect, drag: *photo.CropDrag, opts: photo.CropOpts) bool {
    ui.begin(520, 460);
    var col = ui.column(.{ .pad = 12, .gap = 8 });
    defer col.end();
    const changed = photo.cropper(ui, "cr", src, crop, drag, opts);
    ui.paint();
    return changed;
}

/// 渲染期必须走 renderImages 才能落位图；这里只检查指令是否正确登记。
fn expectImageDrawn(ui: *core.Context) !void {
    try std.testing.expect(ui.image_count >= 1);
    const c = ui.images[0];
    try std.testing.expectEqual(@as(u32, 8), c.w);
    try std.testing.expectEqual(@as(u32, 8), c.h);
}

// ---------------------------------------------------------------- 查看器

test "photo: viewer defaults to fit and reports the fit scale" {
    const src = setupImage();
    var ui = core.Context{};
    var view = photo.ImageView{};
    var drag = photo.Drag{};
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 120 });
    try std.testing.expect(view.isFit());
    try expectImageDrawn(&ui);
    // 适配：8×8 的图在 200×120 里按 min(200/8,120/8)=15 倍铺满高度
    try std.testing.expect(!ui.overflowed);
}

test "photo: viewer wheel zooms in and clamps to max_zoom" {
    const src = setupImage();
    var ui = core.Context{};
    var view = photo.ImageView{};
    var drag = photo.Drag{};
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 120 });

    const rect = ui.lastRect(core.Context.idOf("iv") ^ 0x1A6E) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = rect.x + 20, .y = rect.y + 20 }, .wheel = 1 };
    const changed = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 120 });
    try std.testing.expect(changed);
    try std.testing.expect(!view.isFit());
    try std.testing.expect(view.zoom > 0);

    // 一直放大到上限
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        ui.input = .{ .mouse = .{ .x = rect.x + 20, .y = rect.y + 20 }, .wheel = 1 };
        _ = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 120, .max_zoom = 4 });
    }
    try std.testing.expect(view.zoom <= 4.0001);
}

test "photo: viewer toolbar plus button zooms" {
    const src = setupImage();
    var ui = core.Context{};
    var view = photo.ImageView{};
    var drag = photo.Drag{};
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 240, .height = 160 });

    const plus = ui.lastRect(core.Context.idOf("iv") ^ 0x2A22) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = plus.x + plus.w / 2, .y = plus.y + plus.h / 2 }, .click = .{ .x = plus.x + plus.w / 2, .y = plus.y + plus.h / 2 } };
    const changed = runViewer(&ui, src, &view, &drag, .{ .width = 240, .height = 160 });
    try std.testing.expect(changed);
    try std.testing.expect(!view.isFit());
}

test "photo: viewer drag pans the view in image pixels" {
    const src = setupImage();
    var ui = core.Context{};
    // 先放大
    var view = photo.ImageView{ .zoom = 20, .cx = 4, .cy = 4 };
    var drag = photo.Drag{};
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 200 });
    const rect = ui.lastRect(core.Context.idOf("iv") ^ 0x1A6E) orelse return error.NoHit;

    const cx0 = view.cx;
    // 第 2 帧按下（pressed 需要命中上一帧矩形）
    ui.input = .{ .mouse = .{ .x = rect.x + 100, .y = rect.y + 100 }, .down = true, .pressed = true };
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 200 });
    try std.testing.expect(drag.active);

    // 第 3 帧往右拖 40px → cx 减少 40/20 = 2
    ui.input = .{ .mouse = .{ .x = rect.x + 140, .y = rect.y + 100 }, .down = true };
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 200 });
    try std.testing.expectApproxEqAbs(cx0 - 2, view.cx, 0.01);

    // 松手复位拖动状态
    ui.input = .{ .mouse = .{ .x = rect.x + 140, .y = rect.y + 100 }, .down = false };
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 200, .height = 200 });
    try std.testing.expect(!drag.active);
}

// ---------------------------------------------------------------- 裁剪

test "photo: cropper starts with the largest centred rect for an aspect" {
    const src = setupImage();
    var ui = core.Context{};
    var crop = t.Rect{};
    var drag = photo.CropDrag{};
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300, .aspect = 1 });
    // 8×8 的图、1:1 → 整张图
    try std.testing.expectApproxEqAbs(@as(f32, 0), crop.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), crop.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 8), crop.h, 0.01);
}

test "photo: cropper drags the crop rectangle by its inside" {
    const src = setupImage();
    var ui = core.Context{};
    var crop = t.Rect{ .x = 2, .y = 2, .w = 4, .h = 4 };
    var drag = photo.CropDrag{};
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300 });
    const rect = ui.lastRect(core.Context.idOf("cr") ^ 0xC209) orelse return error.NoHit;

    // 图像铺在 rect 内（pad 10），8×8 图在 496×280 内 → scale = 35，img.x = 12 + (476-280)/2
    const scale: f32 = 35;
    const img_x = rect.x + 10 + (rect.w - 20 - 280) / 2;
    const img_y = rect.y + 10 + (rect.h - 20 - 280) / 2;
    // 裁剪框中心（图像像素 4,4）
    const px = img_x + 4 * scale;
    const py = img_y + 4 * scale;

    ui.input = .{ .mouse = .{ .x = px, .y = py }, .down = true, .pressed = true };
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300 });
    try std.testing.expect(drag.active);
    try std.testing.expectEqual(photo.Handle.move, drag.handle);

    // 右移 scale*2 屏幕点 → crop.x + 2 图像像素
    ui.input = .{ .mouse = .{ .x = px + scale * 2, .y = py }, .down = true };
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300 });
    try std.testing.expectApproxEqAbs(@as(f32, 4), crop.x, 0.2);
}

test "photo: cropper keeps aspect while resizing from a corner" {
    const src = setupImage();
    var ui = core.Context{};
    var crop = t.Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };
    var drag = photo.CropDrag{};
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300, .aspect = 1 });
    const rect = ui.lastRect(core.Context.idOf("cr") ^ 0xC209) orelse return error.NoHit;
    const scale: f32 = 35;
    const img_x = rect.x + 10 + (rect.w - 20 - 280) / 2;
    const img_y = rect.y + 10 + (rect.h - 20 - 280) / 2;

    // 抓右下角（图像像素 4,4）
    const px = img_x + 4 * scale;
    const py = img_y + 4 * scale;
    ui.input = .{ .mouse = .{ .x = px, .y = py }, .down = true, .pressed = true };
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300, .aspect = 1 });
    try std.testing.expectEqual(photo.Handle.br, drag.handle);

    ui.input = .{ .mouse = .{ .x = px + scale * 2, .y = py }, .down = true };
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300, .aspect = 1 });
    // 宽高比保持 1:1
    try std.testing.expectApproxEqAbs(crop.w, crop.h, 0.01);
    try std.testing.expect(crop.w > 5);
}

test "photo: cropper arrow keys nudge the crop when focused" {
    const src = setupImage();
    var ui = core.Context{};
    var crop = t.Rect{ .x = 2, .y = 2, .w = 4, .h = 4 };
    var drag = photo.CropDrag{};
    // 先点一下让它拿到焦点
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300 });
    const rect = ui.lastRect(core.Context.idOf("cr") ^ 0xC209) orelse return error.NoHit;
    const scale: f32 = 35;
    const img_x = rect.x + 10 + (rect.w - 20 - 280) / 2;
    const img_y = rect.y + 10 + (rect.h - 20 - 280) / 2;
    const px = img_x + 4 * scale;
    const py = img_y + 4 * scale;
    ui.input = .{ .mouse = .{ .x = px, .y = py }, .click = .{ .x = px, .y = py } };
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300 });

    // 方向键右移 1 像素
    const x0 = crop.x;
    ui.input = .{};
    ui.input.addKey(.right);
    _ = runCropper(&ui, src, &crop, &drag, .{ .height = 300 });
    try std.testing.expectApproxEqAbs(x0 + 1, crop.x, 0.01);
}

// 冒烟：两个控件同页不溢出
test "smoke: viewer + cropper build without overflowing" {
    const src = setupImage();
    var ui = core.Context{};
    var view = photo.ImageView{};
    var drag = photo.Drag{};
    var crop = t.Rect{};
    var cdrag = photo.CropDrag{};

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(560, 900);
        var col = ui.column(.{ .pad = 14, .gap = 10 });
        defer col.end();
        _ = photo.imageViewer(&ui, "s-v", src, &view, &drag, .{ .height = 200, .checkerboard = true });
        _ = photo.imageViewer(&ui, "s-v2", src, &view, &drag, .{ .height = 140, .no_toolbar = true });
        _ = photo.cropper(&ui, "s-c", src, &crop, &cdrag, .{ .height = 220 });
        _ = photo.cropper(&ui, "s-c2", src, &crop, &cdrag, .{ .height = 160, .round = true });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}

// 位图真的进了通道：渲染后能在缓冲里找到青色像素
test "photo: viewer puts image pixels on screen" {
    const src = setupImage();
    var ui = core.Context{};
    var view = photo.ImageView{};
    var drag = photo.Drag{};
    _ = runViewer(&ui, src, &view, &drag, .{ .width = 240, .height = 240 });
    var buf: [520 * 460 * 4]u8 = @splat(0);
    render.render(&ui, &buf, 520, 460, 1, 0);
    render.renderImages(&ui, &buf, 520, 460, 1, 0);
    var found = false;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 4) {
        if (buf[i] == 0xFF and buf[i + 1] == 0xCC and buf[i + 2] == 0x00) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
