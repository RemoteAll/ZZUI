//! 平台层测试（由 `tests.zig` 引入）：后端契约 + BMP 落盘 + 跨平台出图链路。
//!
//! 这里不测真实窗口（需要显示服务器），只测**任何平台都能断言**的部分：
//! 无窗口后端的契约、BMP 字节格式、行序、以及「像素缓冲 → 文件 → 读回」整条链路。
//! 真实窗口的三个后端（win32 / x11 / cocoa）各自有自己的手工验证清单（见审计 §5）。
const std = @import("std");
const builtin = @import("builtin");
const bmpfile = @import("bmpfile.zig");
const core = @import("core.zig");
const platform = @import("platform.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");

const tmp_name = "zzui-test-bmpfile.bmp";

fn readAll(path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(1 << 22));
}

fn removeQuiet(path: []const u8) void {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ---------------------------------------------------------------- 后端契约

test "platform: null backend honours the size/scale/meter contract" {
    var b = try platform.Backend.initNull(64, 32);
    defer b.deinit();

    const sz = b.size();
    try std.testing.expectEqual(@as(f32, 64), sz.w);
    try std.testing.expectEqual(@as(f32, 32), sz.h);
    try std.testing.expectEqual(@as(f32, 1), b.scale());
    // 像素缓冲长度必须是 w*h*4（BGRA）
    try std.testing.expectEqual(@as(usize, 64 * 32 * 4), b.pixels().len);
    // 无窗口后端没有时间源：`now()` 恒 0（悬停计时依赖 `App` 覆写 ui.time）
    try std.testing.expectEqual(@as(f64, 0), b.now());
    // 估宽：0.55em×字符数，高 1.35em
    const m = b.measure("abcd", 10, false);
    try std.testing.expectApproxEqAbs(@as(f32, 22), m.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 13.5), m.h, 0.001);
    // 输入区可读写（App 每帧把 backend.input() 复制进 ui）
    b.input().mouse = .{ .x = 5, .y = 6 };
    try std.testing.expectEqual(@as(f32, 5), b.input().mouse.x);
}

test "platform: null backend renders exactly one frame" {
    var b = try platform.Backend.initNull(16, 16);
    defer b.deinit();
    try std.testing.expect(b.poll()); // 第一帧
    try std.testing.expect(!b.poll()); // 之后关闭
    try std.testing.expect(!b.poll());
}

test "platform: App.initHeadless works on every platform" {
    // `App.init`（真窗口）在非 Windows 上返回 PlatformNotImplemented；
    // `initHeadless` 必须全平台可用，否则 Linux 上连 --once 都跑不了。
    var app = try @import("zzui.zig").App.initHeadless(40, 20);
    defer app.deinit();
    try std.testing.expect(app.next());
    try std.testing.expectEqual(@as(f32, 40), app.backend.size().w);
}

// ---------------------------------------------------------------- BMP 格式

test "platform: saveBmp writes a valid 32-bit BMP header" {
    const w: u32 = 4;
    const h: u32 = 3;
    var px: [4 * 3 * 4]u8 = @splat(0);
    // 全部涂成 BGRA 蓝
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i] = 0xFF;
        px[i + 3] = 0xFF;
    }
    defer removeQuiet(tmp_name);
    try bmpfile.saveBmp(tmp_name, &px, w, h);

    const data = try readAll(tmp_name);
    defer std.testing.allocator.free(data);

    try std.testing.expectEqual(@as(usize, 54 + px.len), data.len);
    try std.testing.expectEqualStrings("BM", data[0..2]);
    try std.testing.expectEqual(@as(u32, @intCast(54 + px.len)), std.mem.readInt(u32, data[2..6], .little));
    try std.testing.expectEqual(@as(u32, 54), std.mem.readInt(u32, data[10..14], .little)); // 像素数据偏移
    try std.testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, data[14..18], .little)); // DIB 头大小
    try std.testing.expectEqual(@as(i32, 4), std.mem.readInt(i32, data[18..22], .little));
    try std.testing.expectEqual(@as(i32, 3), std.mem.readInt(i32, data[22..26], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, data[26..28], .little)); // planes
    try std.testing.expectEqual(@as(u16, 32), std.mem.readInt(u16, data[28..30], .little)); // bpp
    try std.testing.expectEqual(@as(u32, @intCast(px.len)), std.mem.readInt(u32, data[34..38], .little)); // image size
}

test "platform: saveBmp stores rows bottom-up" {
    const w: u32 = 2;
    const h: u32 = 2;
    // 顶行 = 红（BGR: 00 00 FF），底行 = 绿（BGR: 00 FF 00）
    var px: [2 * 2 * 4]u8 = @splat(0);
    // 缓冲第 0 行是「顶」
    px[0] = 0x00;
    px[1] = 0x00;
    px[2] = 0xFF;
    px[3] = 0xFF;
    px[4] = 0x00;
    px[5] = 0x00;
    px[6] = 0xFF;
    px[7] = 0xFF;
    // 缓冲第 1 行是「底」
    px[8] = 0x00;
    px[9] = 0xFF;
    px[10] = 0x00;
    px[11] = 0xFF;
    px[12] = 0x00;
    px[13] = 0xFF;
    px[14] = 0x00;
    px[15] = 0xFF;

    defer removeQuiet(tmp_name);
    try bmpfile.saveBmp(tmp_name, &px, w, h);
    const data = try readAll(tmp_name);
    defer std.testing.allocator.free(data);

    // BMP 里第 0 行数据 = 图像的**底**行 → 应是绿色
    try std.testing.expectEqual(@as(u8, 0x00), data[54 + 0]);
    try std.testing.expectEqual(@as(u8, 0xFF), data[54 + 1]);
    try std.testing.expectEqual(@as(u8, 0x00), data[54 + 2]);
    // 最后一行数据 = 图像的顶行 → 红色
    const last = 54 + 8;
    try std.testing.expectEqual(@as(u8, 0x00), data[last + 0]);
    try std.testing.expectEqual(@as(u8, 0x00), data[last + 1]);
    try std.testing.expectEqual(@as(u8, 0xFF), data[last + 2]);
}

test "platform: null backend saveSurface goes through bmpfile" {
    var b = try platform.Backend.initNull(3, 2);
    defer b.deinit();
    // 涂一块已知颜色，确认落盘的就是这块缓冲
    const px = b.pixels();
    px[0] = 0x11;
    px[1] = 0x22;
    px[2] = 0x33;
    px[3] = 0xFF;

    defer removeQuiet(tmp_name);
    try b.saveSurface(tmp_name);
    const data = try readAll(tmp_name);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 54 + 3 * 2 * 4), data.len);
    // 3×2 的顶行在像素缓冲开头 → BMP 里落在**最后**一行
    const last_row = 54 + 3 * 4;
    try std.testing.expectEqual(@as(u8, 0x11), data[last_row + 0]);
    try std.testing.expectEqual(@as(u8, 0x22), data[last_row + 1]);
    try std.testing.expectEqual(@as(u8, 0x33), data[last_row + 2]);
}

// ---------------------------------------------------------------- 跨平台出图链路

test "platform: headless App paints pixels and saves them" {
    // 整条「渲染 → 像素 → 文件」链路在无窗口条件下必须通；
    // Linux 上没有这条路径就没法验证渲染结果（真窗口另说）。
    var app = try @import("zzui.zig").App.initHeadless(120, 80);
    defer app.deinit();
    try std.testing.expect(app.next());

    var col = app.ui.column(.{ .pad = 8, .gap = 6 });
    col.end();
    app.ui.addBox(.{ .x = 8, .y = 8, .w = 40, .h = 20 }, .{ .fill = theme.accent });
    app.end();

    const px = app.backend.pixels();
    // 强调色 BGRA = EB 63 25 FF，确认真的画进了像素缓冲
    var found = false;
    var i: usize = 0;
    while (i + 3 < px.len) : (i += 4) {
        if (px[i] == 0xEB and px[i + 1] == 0x63 and px[i + 2] == 0x25) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    defer removeQuiet(tmp_name);
    try app.saveSurface(tmp_name);
    const data = try readAll(tmp_name);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 54 + 120 * 80 * 4), data.len);
}
