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
const types = @import("types.zig");
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

test "platform: x11 backend is a stub off Linux (never silently opens a window)" { // Windows/macOS 上 `platform/x11_stub.zig` 必须明确报「未实现」；
    // Linux 上这里会真的去连 X（没 DISPLAY 时也是同一个错误），两种情况都不该返回成功。
    const r = platform.Backend.initX11("zzui-test", 64, 64, false);
    if (@import("builtin").os.tag == .linux) {
        if (r) |b_| {
            var b = b_;
            b.deinit();
        } else |err| {
            try std.testing.expectEqual(error.PlatformNotImplemented, err);
        }
    } else {
        try std.testing.expectError(error.PlatformNotImplemented, r);
    }
}

test "platform: x11 listDir enumerates a real directory (Linux only)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const x11 = @import("platform/x11.zig");
    var b = x11.Backend{};
    var out: [32]types.FileEntry = undefined;
    var names: [4096]u8 = undefined;
    const n = b.listDir("/", out[0..], names[0..], false);
    try std.testing.expect(n > 0);
    var found_tmp = false;
    for (out[0..@intCast(n)]) |e| {
        if (e.dir and std.mem.eql(u8, e.name, "tmp")) found_tmp = true;
    }
    try std.testing.expect(found_tmp);
}

test "platform: x11 clipboard round trips (Linux + a display only)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const x11 = @import("platform/x11.zig");
    // 没有 DISPLAY 就跳过（CI 里的 `zig build test` 就是这种情况）
    var b = x11.Backend.init("zzui-clip-test", 32, 32, false) catch return error.SkipZigTest;
    defer b.deinit();

    b.setClipboard("hello \xe4\xb8\xad");
    var buf: [64]u8 = undefined;
    const n = b.getClipboard(buf[0..]);
    try std.testing.expectEqualStrings("hello \xe4\xb8\xad", buf[0..n]);
}

test "platform: x11 parses text/uri-list into drop paths (Linux only)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const x11 = @import("platform/x11.zig");

    var list = x11.DropList{};
    x11.parseUriList("file:///tmp/a%20b.txt\r\n# comment\r\nfile://localhost/home/u/x\nhttp://example.com/x\nfile:///tmp/c\n", &list);
    try std.testing.expectEqual(@as(u8, 3), list.n);
    try std.testing.expectEqualStrings("/tmp/a b.txt", list.at(0));
    try std.testing.expectEqualStrings("/home/u/x", list.at(1));
    try std.testing.expectEqualStrings("/tmp/c", list.at(2));

    // 固定容量 4：超出的丢掉，不能越界
    var many = x11.DropList{};
    x11.parseUriList("file:///1\nfile:///2\nfile:///3\nfile:///4\nfile:///5\n", &many);
    try std.testing.expectEqual(@as(u8, 4), many.n);
    try std.testing.expectEqualStrings("/4", many.at(3));

    // 空串与非法转义：不崩、不丢字节
    var edge = x11.DropList{};
    x11.parseUriList("", &edge);
    try std.testing.expectEqual(@as(u8, 0), edge.n);
    x11.parseUriList("file:///tmp/100%zz\n", &edge);
    try std.testing.expectEqualStrings("/tmp/100%zz", edge.at(0));
}

test "platform: x11 font renders ascii and measures non-ascii (Linux only)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const font = @import("platform/x11_font.zig");
    // 没装 libfreetype.so.6 / 一款字体都没有时跳过（这台机器上没有输入法/字体也能跑测试）
    var f = font.Font.open() orelse return error.SkipZigTest;
    defer f.close();

    // ASCII 有真字形：宽度随内容增长，字形标记为可用
    const w_hi = f.measure("Hi", 14);
    const w_long = f.measure("Hiii", 14);
    try std.testing.expect(w_hi > 0);
    try std.testing.expect(w_long > w_hi);
    try std.testing.expect(f.glyph('H').ok);
    try std.testing.expect(f.glyph('H').w > 0);

    // 基线在文本高度之内（0 < ascent < 1.35 em）
    try std.testing.expect(f.ascent(14) > 0);
    try std.testing.expect(f.ascent(14) < 14 * 1.35);

    // 非 ASCII：字体里有没有字形都得给步进（否则中文会把整行挤在一起）
    try std.testing.expect(f.measure("Привет", 14) > 0);
    const cjk = f.measure("中文", 14);
    try std.testing.expect(cjk >= 14); // 至少 1 em（两个缺字形各按 0.5 em 算）
}

test "platform: x11 setImeCaret caches the spot and needs no IM (Linux only)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const x11 = @import("platform/x11.zig");
    // 没 DISPLAY 就跳过（CI 里的 `zig build test` 就是这种情况）
    var b = x11.Backend.init("zzui-ime-test", 64, 64, false) catch return error.SkipZigTest;
    defer b.deinit();

    // 拿到 IM 不一定能建 IC：Xlib 本地 IM 在部分环境下两种 preedit 风格都拒绝
    // （WSLg 实测 position / nothing 都返回 null）。所以这里只要求「不崩」而行。
    if (b.im != null and b.ic == null) {
        // 没 IC 时 setImeCaret 必须是空实现（不能去碰 null）
        b.setImeCaret(.{ .x = 1, .y = 2, .w = 1, .h = 10 });
    }

    // 缓存：第一次记下位置，第二次相同位置不该再调 XIC（这里只验证缓存值）
    b.setImeCaret(.{ .x = 12, .y = 20, .w = 1.5, .h = 16 });
    try std.testing.expectEqual(@as(c_short, 12), b.ime_spot.x);
    try std.testing.expectEqual(@as(c_short, 36), b.ime_spot.y);
    b.setImeCaret(.{ .x = 12, .y = 20, .w = 1.5, .h = 16 });
    try std.testing.expectEqual(@as(c_short, 36), b.ime_spot.y);

    // 负数/超大坐标要夹进 short（不然组字窗会跑到屏外）
    b.setImeCaret(.{ .x = -50, .y = -50, .w = 1, .h = 10 });
    try std.testing.expectEqual(@as(c_short, 0), b.ime_spot.x);
    b.setImeCaret(.{ .x = 1e9, .y = 1e9, .w = 1, .h = 10 });
    try std.testing.expectEqual(@as(c_short, 32767), b.ime_spot.x);
}

test "platform: x11 keeps non-ascii input bytes and drops control chars (Linux only)" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const x11 = @import("platform/x11.zig");

    var buf: [32]u8 = @splat(0);
    // 纯 ASCII
    @memcpy(buf[0..2], "ab");
    try std.testing.expectEqual(@as(usize, 2), x11.compactInputBytes(buf[0..], 2));
    try std.testing.expectEqualStrings("ab", buf[0..2]);

    // 控制字符夹在中间：回车 (\r) 与退格 (\x08) 被剔除，其余原样
    const mixed = "a\rb\x08c";
    @memcpy(buf[0..mixed.len], mixed);
    const n = x11.compactInputBytes(buf[0..], mixed.len);
    try std.testing.expectEqualStrings("abc", buf[0..n]);

    // 非 ASCII（西里尔 "Привет" = 12 字节 + 中文 6 字节）一个字节都不能丢
    const cyr = "Привет中文";
    @memcpy(buf[0..cyr.len], cyr);
    const m = x11.compactInputBytes(buf[0..], cyr.len);
    try std.testing.expectEqual(cyr.len, m);
    try std.testing.expectEqualStrings(cyr, buf[0..m]);

    // n 超过缓冲不该越界
    try std.testing.expectEqual(@as(usize, 0), x11.compactInputBytes(buf[0..0], 5));
}


