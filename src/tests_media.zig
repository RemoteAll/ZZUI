//! 媒体与动效族测试（`cui_media.c` 对位）：轮播 / 图片对比 / 卡片堆 / 翻牌数字 / 行情条。
//! 用 null 测量（0.55 em 估宽），不依赖任何平台 API。
const std = @import("std");
const core = @import("core.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");
const media = @import("media.zig");
const photo = @import("photo.zig");
const t = @import("types.zig");

fn sampleAt(p: []const u8, w: u32, x: u32, y: u32) [3]u8 {
    const i = (@as(usize, y) * w + x) * 4;
    return .{ p[i + 2], p[i + 1], p[i] };
}

// ---------------------------------------------------------------- 绘制顺序守卫

// **这条用例是护栏，别删**：每层顺序必须是 rect/line → image → overlay → text。
// 2026-11-11 踩过：位图在矩形之后画，把裁剪框的压暗/边框/三分线整个盖掉，
// 截图里完全看不见；当时误以为「改成 addOverlayLine 就好了」，其实覆盖层也在位图之前。
test "media: overlay draws above image, plain box does not" {
    var ui = core.Context{};
    ui.begin(64, 64);
    var px: [64 * 64 * 4]u8 = @splat(0);

    // 8x8 纯红位图铺满 64x64
    var img: [8 * 8 * 4]u8 = @splat(0);
    for (0..64) |i| {
        img[i * 4 + 2] = 255; // BGRA: R
        img[i * 4 + 3] = 255;
    }
    ui.addImage(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, .{ .pixels = &img, .w = 8, .h = 8 }, 0);
    ui.addBox(.{ .x = 20, .y = 20, .w = 10, .h = 10 }, .{ .fill = t.Color.hex(0x0000FF, 255) });
    ui.addOverlayLine(.{ .x = 0, .y = 32 }, .{ .x = 64, .y = 32 }, 6, t.Color.hex(0x00FF00, 255));
    ui.addOverlayBox(.{ .x = 40, .y = 40, .w = 8, .h = 8 }, .{ .fill = t.Color.hex(0x0000FF, 255) });
    ui.paint();

    render.render(&ui, &px, 64, 64, 1, 0);
    render.renderImages(&ui, &px, 64, 64, 1, 0);
    render.renderOverlays(&ui, &px, 64, 64, 1, 0);

    const on_line = sampleAt(&px, 64, 32, 32);
    try std.testing.expect(on_line[1] > 100); // 覆盖层线段压在位图之上
    const on_overlay_box = sampleAt(&px, 64, 43, 43);
    try std.testing.expect(on_overlay_box[2] > 100); // 覆盖层矩形也在位图之上
    const on_plain_box = sampleAt(&px, 64, 25, 25);
    try std.testing.expect(on_plain_box[1] == 0); // 普通 addBox 被位图盖住（顺序即如此）
}

// ---------------------------------------------------------------- 轮播

test "media: carousel shows one slide at a time and steps with the wheel" {
    var ui = core.Context{};
    var st = media.CarouselState{};
    ui.begin(400, 300);
    ui.time = 1.0;
    var car = media.carousel(&ui, "car", 3, &st, .{ .height = 200 });
    // 静止时只有第 0 张在视口内（其余被剔除，不占节点）
    const r0 = car.slideRect(0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), r0.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400), r0.w, 0.01);
    try std.testing.expect(car.slideRect(1) == null);
    try std.testing.expect(car.slideRect(3) == null);
    car.end();
    ui.paint();

    // 第二帧：鼠标悬停在轮播上滚轮向下 → 翻到第 1 张
    ui.input = .{ .mouse = .{ .x = 20, .y = 20 }, .wheel = -1 };
    ui.time = 1.1;
    ui.begin(400, 300);
    var car2 = media.carousel(&ui, "car", 3, &st, .{ .height = 200 });
    car2.end();
    try std.testing.expectEqual(@as(usize, 1), st.index);

    // 到了第 1 张，第 1 张进入视口、第 0 张移出
    ui.input = .{ .mouse = .{ .x = 20, .y = 20 } };
    ui.time = 1.5;
    ui.begin(400, 300);
    var car3 = media.carousel(&ui, "car", 3, &st, .{ .height = 200 });
    try std.testing.expect(car3.slideRect(1) != null);
    try std.testing.expect(car3.slideRect(0) == null);
    car3.end();
}

test "media: carousel drags and snaps to the nearest slide" {
    var ui = core.Context{};
    var st = media.CarouselState{};
    const stride: f32 = 400 + 12;

    // 帧 1：按下
    ui.begin(412, 300);
    ui.time = 1.0;
    ui.input = .{ .mouse = .{ .x = 300, .y = 50 }, .pressed = true, .down = true };
    var c1 = media.carousel(&ui, "car", 3, &st, .{ .height = 200 });
    c1.end();
    try std.testing.expect(st.dragging);

    // 帧 2：向左拖过半张
    ui.input = .{ .mouse = .{ .x = 60, .y = 50 }, .down = true };
    ui.time = 1.1;
    ui.begin(412, 300);
    var c2 = media.carousel(&ui, "car", 3, &st, .{ .height = 200 });
    c2.end();
    try std.testing.expectApproxEqAbs(@as(f32, 240) / stride, st.pos, 0.05);

    // 帧 3：松手 → 吸附到第 1 张
    ui.input = .{ .mouse = .{ .x = 60, .y = 50 }, .down = false };
    ui.time = 1.2;
    ui.begin(412, 300);
    var c3 = media.carousel(&ui, "car", 3, &st, .{ .height = 200 });
    c3.end();
    try std.testing.expectEqual(@as(usize, 1), st.index);
}

test "media: carousel clamps without loop and wraps with loop" {
    var ui = core.Context{};
    var st = media.CarouselState{ .index = 2, .pos = 2, .init = true };
    ui.begin(300, 200);
    ui.time = 1.0;
    var c = media.carousel(&ui, "car", 3, &st, .{ .height = 100 });
    c.end();
    ui.paint();

    // 末页再往右翻：不循环 → 停在 2
    ui.input = .{ .mouse = .{ .x = 10, .y = 10 }, .wheel = -1 };
    ui.time = 1.1;
    ui.begin(300, 200);
    var c2 = media.carousel(&ui, "car", 3, &st, .{ .height = 100 });
    c2.end();
    try std.testing.expectEqual(@as(usize, 2), st.index);

    // 循环 → 回到 0
    ui.time = 1.2;
    ui.begin(300, 200);
    var c3 = media.carousel(&ui, "car", 3, &st, .{ .height = 100, .loop = true });
    c3.end();
    try std.testing.expectEqual(@as(usize, 0), st.index);
}

// ---------------------------------------------------------------- 图片对比

fn testImage() core.ImageSrc {
    const S = struct {
        var px: [4 * 4 * 4]u8 = @splat(0);
    };
    for (0..16) |i| {
        S.px[i * 4 + 0] = 0xFF; // B
        S.px[i * 4 + 3] = 0xFF;
    }
    return .{ .pixels = &S.px, .w = 4, .h = 4 };
}

test "media: imageCompare drags the split and steps with the keyboard" {
    var ui = core.Context{};
    var st = media.CompareState{};
    const src = testImage();

    ui.begin(400, 400);
    ui.time = 1.0;
    ui.input = .{ .mouse = .{ .x = 100, .y = 100 }, .pressed = true, .down = true };
    const changed = media.imageCompare(&ui, "cmp", src, src, &st, .{ .height = 200 });
    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), st.pos, 0.02);
    try std.testing.expect(ui.image_count == 2); // 两张位图（before 被裁到左半）
    ui.paint();

    // 释放后键盘微调
    ui.input = .{ .mouse = .{ .x = 100, .y = 100 }, .down = false, .key_count = 1, .keys = @splat(.unknown) };
    ui.input.keys[0] = .right;
    ui.time = 1.1;
    ui.begin(400, 400);
    _ = media.imageCompare(&ui, "cmp", src, src, &st, .{ .height = 200 });
    // 没有焦点时不响应键盘
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), st.pos, 0.02);

    ui.focus_id = core.Context.idOf("cmp") ^ 0xC04;
    ui.time = 1.2;
    ui.begin(400, 400);
    _ = media.imageCompare(&ui, "cmp", src, src, &st, .{ .height = 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), st.pos, 0.02);
}

// ---------------------------------------------------------------- 卡片堆

test "media: cardStack fans the deck and throws the top card" {
    var ui = core.Context{};
    var st = media.CardStackState{};
    ui.begin(400, 500);
    ui.time = 1.0;
    var cs = media.cardStack(&ui, "deck", 3, &st, .{ .height = 300 });
    const top = cs.cardRect(0);
    const second = cs.cardRect(1);
    try std.testing.expect(second.y > top.y); // 后面的往下错开
    try std.testing.expect(second.w < top.w); // 并且缩小
    const res = cs.end();
    try std.testing.expectEqual(@as(i32, 0), res);
    ui.paint();

    // 焦点 + 右方向键 → 甩出（小 dt 一帧飞不完）
    ui.focus_id = core.Context.idOf("deck") ^ 0x70B;
    ui.input = .{ .mouse = .{ .x = 200, .y = 150 }, .down = false, .key_count = 1, .keys = @splat(.unknown) };
    ui.input.keys[0] = .right;
    ui.time = 1.02;
    ui.begin(400, 500);
    var cs2 = media.cardStack(&ui, "deck", 3, &st, .{ .height = 300 });
    _ = cs2.end();
    try std.testing.expect(st.flying);
    try std.testing.expect(st.x > 0);

    // 继续飞，直到越过 1.3 倍宽度 → 返回方向 +1（最多 30 帧）
    var thrown: i32 = 0;
    var f: usize = 0;
    while (f < 30 and thrown == 0) : (f += 1) {
        ui.input = .{ .mouse = .{ .x = 200, .y = 150 } };
        ui.time += 0.05;
        ui.begin(400, 500);
        var csx = media.cardStack(&ui, "deck", 3, &st, .{ .height = 300 });
        thrown = csx.end();
    }
    try std.testing.expectEqual(@as(i32, 1), thrown);
    try std.testing.expect(!st.flying);
    try std.testing.expectApproxEqAbs(@as(f32, 0), st.x, 0.01);
}

test "media: cardStack drags horizontally with the mouse" {
    var ui = core.Context{};
    var st = media.CardStackState{};
    ui.begin(400, 500);
    ui.time = 1.0;
    ui.input = .{ .mouse = .{ .x = 200, .y = 100 }, .pressed = true, .down = true };
    var cs = media.cardStack(&ui, "deck", 3, &st, .{ .height = 300 });
    _ = cs.end();
    try std.testing.expect(st.dragging);

    ui.input = .{ .mouse = .{ .x = 260, .y = 160 }, .down = true };
    ui.time = 1.05;
    ui.begin(400, 500);
    var cs2 = media.cardStack(&ui, "deck", 3, &st, .{ .height = 300 });
    _ = cs2.end();
    try std.testing.expectApproxEqAbs(@as(f32, 60), st.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 18), st.y, 0.01); // 纵向只跟 30%
}

// ---------------------------------------------------------------- 翻牌数字

test "media: counter formats numbers with grouping" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("48,210", media.formatNumber(&buf, 48210, 0, true));
    try std.testing.expectEqualStrings("1234567", media.formatNumber(&buf, 1234567, 0, false));
    try std.testing.expectEqualStrings("-1,234.50", media.formatNumber(&buf, -1234.5, 2, true));
}

test "media: counter rolls each digit towards its target" {
    var ui = core.Context{};
    var st = media.CounterState{};
    ui.begin(300, 200);
    ui.time = 1.0;
    media.counter(&ui, "c", 9, &st, .{ .size = 32 });
    ui.paint();
    // 初次直接落位（不滚动）
    try std.testing.expectApproxEqAbs(@as(f32, 9), st.d[0], 0.01);

    // 9 → 10：个位应当**往前**滚到 10（展示 0），而不是倒退回 0
    ui.time = 1.2;
    ui.begin(300, 200);
    media.counter(&ui, "c", 10, &st, .{ .size = 32 });
    ui.paint();
    try std.testing.expect(st.d[0] > 9.0); // 进位方向
    try std.testing.expectApproxEqAbs(@as(f32, 1), st.d[1], 0.01);

    // 连续多帧后稳定在目标（个位 = 10 表示数字 0，十位 = 1）
    var f: usize = 0;
    while (f < 20) : (f += 1) {
        ui.time += 0.05;
        ui.begin(300, 200);
        media.counter(&ui, "c", 10, &st, .{ .size = 32 });
        ui.paint();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 10), st.d[0], 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 1), st.d[1], 0.05);
}

// ---------------------------------------------------------------- 行情条

test "media: ticker scrolls while idle and pauses on hover" {
    var ui = core.Context{};
    var st = media.TickerState{};
    const items = [_]media.TickerItem{
        .{ .label = "cpu", .value = "12%", .delta = -1.5, .lower_is_better = true },
        .{ .label = "rps", .value = "820", .delta = 3.2 },
    };

    ui.begin(400, 200);
    ui.time = 1.0;
    ui.input = .{ .mouse = .{ .x = 900, .y = 900 } }; // 鼠标在控件外 → 滚动
    media.ticker(&ui, "tk", &items, &st, .{ .height = 40, .speed = 40 });
    ui.paint();
    try std.testing.expect(!ui.overflowed);

    const before = st.off;
    ui.time = 1.5;
    ui.begin(400, 200);
    media.ticker(&ui, "tk", &items, &st, .{ .height = 40, .speed = 40 });
    ui.paint();
    try std.testing.expect(st.off > before); // 在滚

    // 悬停 → 暂停
    const held = st.off;
    ui.input = .{ .mouse = .{ .x = 50, .y = 20 } };
    ui.time = 2.5;
    ui.begin(400, 200);
    media.ticker(&ui, "tk", &items, &st, .{ .height = 40, .speed = 40 });
    ui.paint();
    try std.testing.expectApproxEqAbs(held, st.off, 0.01);
}

test "media: ticker survives many frames without node overflow" {
    var ui = core.Context{};
    var st = media.TickerState{};
    var items: [8]media.TickerItem = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .label = "node", .value = "ok", .delta = @floatFromInt(@as(i32, @intCast(i)) - 4) };
    }
    var f: usize = 0;
    while (f < 60) : (f += 1) {
        ui.time = 1.0 + @as(f64, @floatFromInt(f)) * 0.05;
        ui.begin(400, 200);
        ui.input = .{ .mouse = .{ .x = 900, .y = 900 } };
        media.ticker(&ui, "tk", &items, &st, .{ .height = 40 });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}

// ---------------------------------------------------------------- 与 photo 的联动回归

// photo 的裁剪框靠覆盖层压在位图之上；这条用例把它固定住（渲染后断言强调色可见）。
test "media: photo cropper frame is visible above the bitmap" {
    const S = struct {
        var px: [16 * 16 * 4]u8 = @splat(0);
    };
    for (0..256) |i| {
        S.px[i * 4 + 1] = 0xCC; // 纯绿位图（G）
        S.px[i * 4 + 3] = 0xFF;
    }
    const src = core.ImageSrc{ .pixels = &S.px, .w = 16, .h = 16 };

    var ui = core.Context{};
    var crop = t.Rect{ .x = 2, .y = 2, .w = 12, .h = 12 };
    var drag = photo.CropDrag{};
    ui.begin(300, 300);
    ui.time = 1.0;
    _ = photo.cropper(&ui, "c", src, &crop, &drag, .{ .height = 240 });
    ui.paint();

    var buf: [300 * 300 * 4]u8 = @splat(0);
    render.render(&ui, &buf, 300, 300, 1, 0);
    render.renderImages(&ui, &buf, 300, 300, 1, 0);
    render.renderOverlays(&ui, &buf, 300, 300, 1, 0);

    // 强调色 0x2563EB（B=0xEB, G=0x63, R=0x25）出现在位图区域内
    var found = false;
    var i: usize = 0;
    while (i + 3 < buf.len) : (i += 4) {
        if (buf[i] == 0xEB and buf[i + 1] == 0x63 and buf[i + 2] == 0x25) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    _ = theme.accent;
}
