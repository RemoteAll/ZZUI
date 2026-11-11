//! 图片解码测试：BMP / TGA / PNG 都是**在测试里现场构造**的字节流
//! （不往仓库塞二进制样例；PNG 用 zlib 的 stored 块手写，不依赖压缩器）。
const std = @import("std");
const image = @import("image.zig");

/// 测试用的静态缓冲：PNG 的 scratch = IDAT + 64 KB inflate 窗口，放栈上会很大。
const Bufs = struct {
    var scratch: [image.inflate_window + 4096]u8 = @splat(0);
};

fn put16(b: []u8, at: usize, v: u32) void {
    b[at] = @intCast(v & 0xFF);
    b[at + 1] = @intCast((v >> 8) & 0xFF);
}

fn put32(b: []u8, at: usize, v: u32) void {
    b[at] = @intCast(v & 0xFF);
    b[at + 1] = @intCast((v >> 8) & 0xFF);
    b[at + 2] = @intCast((v >> 16) & 0xFF);
    b[at + 3] = @intCast((v >> 24) & 0xFF);
}

/// 2×2、24bpp、自下而上（正高度 = bottom-up）的 BMP。
/// 文件第 0 行是**最下面**那行（蓝、白），第 1 行是最上面（红、绿）。
fn makeBmp24(buf: []u8) []const u8 {
    @memset(buf, 0);
    buf[0] = 'B';
    buf[1] = 'M';
    put32(buf, 2, 54 + 16);
    put32(buf, 10, 54); // 像素偏移
    put32(buf, 14, 40); // DIB 大小
    put32(buf, 18, 2); // 宽
    put32(buf, 22, 2); // 高（正 = bottom-up）
    put16(buf, 26, 1); // planes
    put16(buf, 28, 24); // bpp
    put32(buf, 30, 0); // BI_RGB
    // 底行：蓝(255,0,0) 白(255,255,255)，BGR + 2 字节 padding（行 8 字节对齐）
    var p: usize = 54;
    buf[p + 0] = 255;
    buf[p + 1] = 0;
    buf[p + 2] = 0;
    buf[p + 3] = 255;
    buf[p + 4] = 255;
    buf[p + 5] = 255;
    p += 8;
    // 顶行：红(0,0,255) 绿(0,255,0)
    buf[p + 0] = 0;
    buf[p + 1] = 0;
    buf[p + 2] = 255;
    buf[p + 3] = 0;
    buf[p + 4] = 255;
    buf[p + 5] = 0;
    return buf[0 .. 54 + 16];
}

/// 2×2、32bpp、top-down 的 TGA（类型 2）。
fn makeTga32(buf: []u8) []const u8 {
    @memset(buf, 0);
    buf[2] = 2; // truecolor
    put16(buf, 12, 2);
    put16(buf, 14, 2);
    buf[16] = 32;
    buf[17] = 0x28; // top-down + 8 位 alpha
    var p: usize = 18;
    const px = [_][4]u8{
        .{ 10, 20, 30, 255 },
        .{ 40, 50, 60, 128 },
        .{ 70, 80, 90, 200 },
        .{ 100, 110, 120, 64 },
    };
    for (px) |c| {
        @memcpy(buf[p..][0..4], &c);
        p += 4;
    }
    return buf[0..p];
}

/// 3×1、24bpp、RLE（类型 10）的 TGA：前两个像素相同（重复包），第三个单发。
fn makeTgaRle(buf: []u8) []const u8 {
    @memset(buf, 0);
    buf[2] = 10;
    put16(buf, 12, 3);
    put16(buf, 14, 1);
    buf[16] = 24;
    buf[17] = 0x20; // top-down
    var p: usize = 18;
    buf[p] = 0x81; // 重复 2 个
    p += 1;
    buf[p + 0] = 1;
    buf[p + 1] = 2;
    buf[p + 2] = 3;
    p += 3;
    buf[p] = 0x00; // 原始 1 个
    p += 1;
    buf[p + 0] = 9;
    buf[p + 1] = 8;
    buf[p + 2] = 7;
    p += 3;
    return buf[0..p];
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |c| {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// 把 raw 包成 zlib（只用 stored 块，免引压缩器）。
fn zlibStored(out: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    out[n] = 0x78;
    out[n + 1] = 0x01;
    n += 2;
    var off: usize = 0;
    while (true) {
        const take = @min(raw.len - off, 65535);
        const final: u8 = if (off + take >= raw.len) 1 else 0;
        out[n] = final;
        put16(out, n + 1, @intCast(take));
        put16(out, n + 3, @intCast(~@as(u16, @intCast(take)) & 0xFFFF));
        n += 5;
        @memcpy(out[n..][0..take], raw[off..][0..take]);
        n += take;
        off += take;
        if (off >= raw.len) break;
    }
    put32(out, n, adler32(raw));
    n += 4;
    return out[0..n];
}

fn crcChunk(out: []u8, tag: []const u8, body: []const u8) []const u8 {
    // 解码器不校验 CRC，写 0 即可（省掉 CRC 实现）
    put32(out, 0, @intCast(body.len));
    @memcpy(out[4..8], tag);
    @memcpy(out[8..][0..body.len], body);
    put32(out, 8 + body.len, 0);
    return out[0 .. 8 + body.len + 4];
}

/// 组装一个 PNG（8 位、非隔行）。`rows` 是**过滤后的**原始扫描行（含每行首字节的过滤类型）。
fn makePng(out: []u8, w: u32, h: u32, color_type: u8, rows: []const u8) []const u8 {
    var n: usize = 0;
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    @memcpy(out[0..8], &sig);
    n = 8;

    var ihdr: [13]u8 = undefined;
    put32(&ihdr, 0, w);
    put32(&ihdr, 4, h);
    ihdr[8] = 8; // bit depth
    ihdr[9] = color_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    const c1 = crcChunk(out[n..], "IHDR", &ihdr);
    n += c1.len;

    var zraw: [512]u8 = undefined;
    var zout: [600]u8 = undefined;
    const z = zlibStored(&zout, rows);
    _ = &zraw;
    const c2 = crcChunk(out[n..], "IDAT", z);
    n += c2.len;

    const c3 = crcChunk(out[n..], "IEND", "");
    n += c3.len;
    return out[0..n];
}

test "image: bmp 24bpp bottom-up is flipped into top-down BGRA" {
    var src: [80]u8 = undefined;
    const bytes = makeBmp24(&src);
    try std.testing.expectEqual(image.Format.bmp, image.sniff(bytes));

    var px: [2 * 2 * 4]u8 = @splat(0);
    const img = try image.decode(bytes, &px, &.{}, .{});
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqual(@as(u32, 2), img.h);
    // 顶行左 = 红（B=0,G=0,R=255）
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, px[0..4]);
    // 顶行右 = 绿
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, px[4..8]);
    // 底行左 = 蓝
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, px[8..12]);
}

test "image: bmp rejects unsupported and short buffers" {
    var src: [80]u8 = undefined;
    const bytes = makeBmp24(&src);
    var small: [4]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooSmall, image.decode(bytes, &small, &.{}, .{}));
    var sixteen: [16]u8 = @splat(0);
    try std.testing.expectError(error.TooLarge, image.decode(bytes, &sixteen, &.{}, .{ .max_pixels = 1 }));
    try std.testing.expectError(error.Truncated, image.decode(bytes[0..20], &sixteen, &.{}, .{}));
}

test "image: tga 32bpp top-down keeps alpha" {
    var src: [64]u8 = undefined;
    const bytes = makeTga32(&src);
    try std.testing.expectEqual(image.Format.tga, image.sniff(bytes));

    var px: [2 * 2 * 4]u8 = @splat(0);
    const img = try image.decodeTga(bytes, &px, .{});
    try std.testing.expectEqual(@as(u32, 2), img.h);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 255 }, px[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 40, 50, 60, 128 }, px[4..8]);
    // 第二行第一列：文件顺序本来就是 top-down，不需要翻转
    try std.testing.expectEqualSlices(u8, &[_]u8{ 70, 80, 90, 200 }, px[8..12]);
}

test "image: tga RLE decodes repeat and raw packets" {
    var src: [64]u8 = undefined;
    const bytes = makeTgaRle(&src);
    var px: [3 * 4]u8 = @splat(0);
    const img = try image.decodeTga(bytes, &px, .{});
    try std.testing.expectEqual(@as(u32, 3), img.w);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 255 }, px[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 255 }, px[4..8]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 255 }, px[8..12]);
}

test "image: png rgb with none filter" {
    // 2×2 RGB，每行 6 字节
    const rows = [_]u8{
        0, 255, 0, 0, 0, 255, 0, // 红、绿
        0, 0, 0, 255, 255, 255, 255, // 蓝、白
    };
    var src: [1024]u8 = undefined;
    const bytes = makePng(&src, 2, 2, 2, &rows);
    try std.testing.expectEqual(image.Format.png, image.sniff(bytes));

    var px: [2 * 2 * 4]u8 = @splat(0);
    const img = try image.decode(bytes, &px, &Bufs.scratch, .{});
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, px[0..4]); // 红
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, px[4..8]); // 绿
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, px[8..12]); // 蓝
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, px[12..16]); // 白
}

test "image: png rgba with sub filter and shared idat scratch" {
    // 2×2 RGBA。第二行用 Sub 过滤（左邻相减，bpp = 4）：
    //   原始 (100,110,120,130) (150,160,170,180)
    //   编码 首像素原样 + 第二像素存差值 (50,50,50,50)
    const rows = [_]u8{
        0, 10,  20,  30,  40,  50, 60, 70, 80,
        1, 100, 110, 120, 130, 50, 50, 50, 50,
    };
    var src: [1024]u8 = undefined;
    const bytes = makePng(&src, 2, 2, 6, &rows);
    // scratch = IDAT 总长 + inflate 窗口
    try std.testing.expect(image.pngScratchSize(bytes) <= Bufs.scratch.len);
    var px: [2 * 2 * 4]u8 = @splat(0);
    _ = try image.decode(bytes, &px, &Bufs.scratch, .{});
    // 第一行（filter none）
    try std.testing.expectEqualSlices(u8, &[_]u8{ 30, 20, 10, 40 }, px[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 70, 60, 50, 80 }, px[4..8]);
    // 第二行（filter sub 还原后）
    try std.testing.expectEqualSlices(u8, &[_]u8{ 120, 110, 100, 130 }, px[8..12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 170, 160, 150, 180 }, px[12..16]);
}

test "image: png needs scratch big enough and rejects 16-bit" {
    const rows = [_]u8{ 0, 1, 2, 3, 4, 5, 6 };
    var src: [1024]u8 = undefined;
    const bytes = makePng(&src, 2, 1, 2, &rows);
    var tiny: [4]u8 = @splat(0);
    var out64: [64]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooSmall, image.decode(bytes, &out64, &tiny, .{}));

    // 把 IHDR 的 bit depth 改成 16（offset 24）→ Unsupported
    src[24] = 16;
    try std.testing.expectError(error.Unsupported, image.decode(bytes, &out64, &Bufs.scratch, .{}));
}

test "image: sniff recognises unknown and unsupported formats" {
    var src: [80]u8 = undefined;
    const bmp = makeBmp24(&src);
    try std.testing.expectEqual(image.Format.bmp, image.sniff(bmp));
    try std.testing.expectEqual(image.Format.unknown, image.sniff("hello world!"));
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(image.Format.jpeg, image.sniff(&jpeg));
    var out16: [16]u8 = @splat(0);
    try std.testing.expectError(error.Unsupported, image.decode(&jpeg, &out16, &.{}, .{}));
}

test "image: decoded pixels feed straight into addImage" {
    const core = @import("core.zig");
    var src: [80]u8 = undefined;
    const bytes = makeBmp24(&src);
    var px: [2 * 2 * 4]u8 = @splat(0);
    const img = try image.decode(bytes, &px, &.{}, .{});

    var ui = core.Context{};
    ui.begin(40, 40);
    ui.addImage(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, img.src(), 0);
    ui.paint();
    try std.testing.expectEqual(@as(usize, 1), ui.image_count);
    try std.testing.expectEqual(@as(u32, 2), ui.images[0].w);
}
