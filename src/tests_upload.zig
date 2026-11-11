//! 拖放区与头像上传的测试（由 `tests.zig` 引入）。
const std = @import("std");
const core = @import("core.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");
const upload = @import("upload.zig");
const t = @import("types.zig");

// ---------------------------------------------------------------- 扩展名过滤

test "upload: pathHasExtension matches the allow list" {
    try std.testing.expect(upload.pathHasExtension("a.png", ""));
    try std.testing.expect(upload.pathHasExtension("C:\\dir\\a.PNG", "png;jpg"));
    try std.testing.expect(upload.pathHasExtension("a.jpeg", "png; .jpeg"));
    try std.testing.expect(!upload.pathHasExtension("a.gif", "png;jpg"));
    try std.testing.expect(!upload.pathHasExtension("noext", "png"));
    try std.testing.expect(!upload.pathHasExtension("a.", "png"));
    // 只比较最后一段扩展名
    try std.testing.expect(upload.pathHasExtension("a.b.png", "png"));
    try std.testing.expect(!upload.pathHasExtension("a.png.txt", "png"));
    // 分隔符容忍空格与点前缀
    try std.testing.expect(upload.pathHasExtension("x.pdf", "doc; pdf ;txt"));
}

// ---------------------------------------------------------------- 拖放区

fn runDrop(ui: *core.Context, opts: upload.DropOpts) upload.DropResult {
    ui.begin(420, 320);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    defer col.end();
    const r = upload.dropzone(ui, "dz", opts);
    ui.paint();
    return r;
}

test "upload: dropzone reports clicks" {
    var ui = core.Context{};
    _ = runDrop(&ui, .{});
    const r = ui.lastRect(core.Context.idOf("dz") ^ 0xD40F) orelse return error.NoHit;
    ui.input = .{ .mouse = .{ .x = r.x + 8, .y = r.y + 8 }, .click = .{ .x = r.x + 8, .y = r.y + 8 } };
    const res = runDrop(&ui, .{});
    try std.testing.expect(res.clicked);
    ui.input = .{ .mouse = .{ .x = r.x + 8, .y = r.y + 8 }, .click = .{ .x = r.x - 40, .y = r.y - 40 } };
    const res2 = runDrop(&ui, .{});
    try std.testing.expect(!res2.clicked);
}

test "upload: dropzone counts dropped files from Input" {
    var ui = core.Context{};
    _ = runDrop(&ui, .{});
    ui.input = .{ .dropped = 2 };
    const res = runDrop(&ui, .{ .accept = "png" });
    try std.testing.expectEqual(@as(u8, 2), res.accepted);
    // drop 是「本帧事件」：下一帧清零
    ui.input = .{};
    const res2 = runDrop(&ui, .{});
    try std.testing.expectEqual(@as(u8, 0), res2.accepted);
}

test "upload: compact dropzone is one row tall" {
    var ui = core.Context{};
    ui.begin(420, 200);
    var col = ui.column(.{ .pad = 10, .gap = 6 });
    defer col.end();
    _ = upload.dropzone(&ui, "dzc", .{ .compact = true });
    ui.paint();
    const r = ui.lastRect(core.Context.idOf("dzc") ^ 0xD40F) orelse return error.NoHit;
    try std.testing.expect(r.h <= 40);
}

// ---------------------------------------------------------------- 头像上传

var avatar_px: [4 * 4 * 4]u8 = @splat(0);

fn runAvatar(ui: *core.Context, st: *upload.AvatarState, img: ?core.ImageSrc) bool {
    ui.begin(200, 200);
    var col = ui.column(.{ .pad = 10, .gap = 6 });
    defer col.end();
    const clicked = upload.avatarUpload(ui, "av", "Ada", img, st, .{ .size = 64, .status = "online" });
    ui.paint();
    return clicked;
}

test "upload: avatar upload hits the corner badge, not the picture" {
    var ui = core.Context{};
    var st = upload.AvatarState{};
    _ = runAvatar(&ui, &st, null);

    const badge = ui.lastRect(core.Context.idOf("av") ^ 0xA7A7) orelse return error.NoHit;
    // 点角标 → true
    ui.input = .{ .mouse = .{ .x = badge.x + badge.w / 2, .y = badge.y + badge.h / 2 }, .click = .{ .x = badge.x + badge.w / 2, .y = badge.y + badge.h / 2 } };
    try std.testing.expect(runAvatar(&ui, &st, null));
    // 点头像中心 ≠ 点角标
    ui.input = .{ .mouse = .{ .x = 40, .y = 40 }, .click = .{ .x = 40, .y = 40 } };
    try std.testing.expect(!runAvatar(&ui, &st, null));
}

test "upload: avatar draws the image through the renderer with a circular mask" {
    // 4×4 纯红位图（BGRA）
    var i: usize = 0;
    while (i < avatar_px.len) : (i += 4) {
        avatar_px[i] = 0x00;
        avatar_px[i + 1] = 0x00;
        avatar_px[i + 2] = 0xFF;
        avatar_px[i + 3] = 0xFF;
    }
    const src = core.ImageSrc{ .pixels = &avatar_px, .w = 4, .h = 4 };

    var ui = core.Context{};
    var st = upload.AvatarState{};
    _ = runAvatar(&ui, &st, src);
    try std.testing.expect(!ui.overflowed);

    // 光栅化到 200×200 的缓冲上（位图走独立通道，必须单独调 renderImages）
    var buf: [200 * 200 * 4]u8 = @splat(0);
    render.render(&ui, &buf, 200, 200, 1, 0);
    render.renderImages(&ui, &buf, 200, 200, 1, 0);

    // 头像圆心（rect 从 (10,10) 起、边长 64 → 圆心约 (45,45)）应是红色
    const cidx = (@as(usize, 45) * 200 + 45) * 4;
    try std.testing.expectEqual(@as(u8, 0xFF), buf[cidx + 2]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[cidx]);

    // 圆形遮罩：左上角（圆外）不该是纯红
    const corner = (@as(usize, 12) * 200 + 13) * 4;
    const is_red = buf[corner + 2] == 0xFF and buf[corner] == 0x00 and buf[corner + 1] == 0x00;
    try std.testing.expect(!is_red);
}

// 冒烟：两个控件同页不溢出
test "smoke: dropzone + avatar build without overflowing" {
    var ui = core.Context{};
    var st = upload.AvatarState{};
    const src = core.ImageSrc{ .pixels = &avatar_px, .w = 4, .h = 4 };

    var frame: usize = 0;
    while (frame < 2) : (frame += 1) {
        ui.begin(560, 420);
        var col = ui.column(.{ .pad = 16, .gap = 10 });
        defer col.end();
        _ = upload.avatarUpload(&ui, "s-av", "Ada Lovelace", src, &st, .{ .size = 72 });
        _ = upload.avatarUpload(&ui, "s-av2", "Bob", null, &st, .{ .size = 48, .square = true, .status = "busy" });
        _ = upload.dropzone(&ui, "s-dz", .{ .accept = "png;jpg", .height = 140 });
        _ = upload.dropzone(&ui, "s-dz2", .{ .compact = true, .title = "Replace file" });
        ui.paint();
    }
    try std.testing.expect(!ui.overflowed);
}
