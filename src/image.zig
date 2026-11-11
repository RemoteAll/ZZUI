//! 图片解码入口（对位 CUI `cui_image.c` 的 `cui_image_load`）：**BMP / TGA / PNG → BGRA**。
//!
//! 三条硬约束（都是用户级要求推出来的）：
//! 1. **不用 stb_image**（291 KB 源码）：手写解码器，只做「读像素」这一件事；
//! 2. **零堆分配**：像素缓冲 `out` 由调用方给，解码器只写不申请
//!    （PNG 的 IDAT 需要连续，调用方另给 `scratch`；BMP/TGA 不用）；
//! 3. **按需付费**：Zig 只编译**被调用到**的函数 —— 只调 `decodeBmp` 的产物不含 PNG 的 inflate。
//!
//! 输出口径与 `core.addImage` 一致：**BGRA，顶行在前**（与 BMP 的 DIB 相同）。
//! 框架仍然不解码「由它自己找文件」的图片：文件读取是应用层的事，这里只解内存里的字节。
//!
//! **限制（明确记录，不假装支持）**：
//! - PNG 只支持 8 位通道、非隔行（color type 0/2/4/6）；16 位、调色板、隔行返回 `error.Unsupported`；
//! - PNG 的 IDAT 必须是连续的（多数库会切成多个 8 KB 块）→ 调用方按 `pngIdatSize` 给 `scratch`；
//! - PNG 单行最大 16384 字节（4096 px RGBA），超了返回 `error.ImageTooWide`；
//! - TGA 只支持 truecolor（类型 2/10，24/32 bpp），不带调色板；
//! - BMP 只支持 BI_RGB（不压缩）24/32 bpp。
const std = @import("std");
const core = @import("core.zig");

pub const Image = struct {
    /// BGRA，顶行在前。
    pixels: []u8,
    w: u32,
    h: u32,

    /// 直接交给 `Context.addImage` 用。
    pub fn src(self: Image) core.ImageSrc {
        return .{ .pixels = self.pixels, .w = self.w, .h = self.h };
    }
};

pub const Format = enum { bmp, tga, png, jpeg, gif, unknown };

pub const Options = struct {
    /// 像素数上限（防「解压炸弹」把调用方缓冲写爆）。
    max_pixels: u32 = 4096 * 4096,
};

pub const Error = error{
    UnknownFormat,
    Truncated,
    Unsupported,
    TooLarge,
    BufferTooSmall,
    ImageTooWide,
    Corrupt,
};

/// PNG 单行上限：4096 px × RGBA。
pub const max_row_bytes = 16384;

/// inflate 需要的工作窗口（`std.compress.flate` 硬要求，实测 ≥ 64 KB）。
pub const inflate_window = std.compress.flate.max_window_len;

/// 按文件头魔数判断格式（不做完整校验）。
pub fn sniff(bytes: []const u8) Format {
    if (bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M') return .bmp;
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpeg;
    if (bytes.len >= 6 and (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a"))) return .gif;
    // TGA 没有魔数：靠第 3 字节的 image type 猜（2/10 = truecolor，3/11 = 灰度）
    if (bytes.len >= 18) {
        const t = bytes[2];
        if ((t == 2 or t == 10 or t == 3 or t == 11) and (bytes[16] == 24 or bytes[16] == 32 or bytes[16] == 8)) return .tga;
    }
    return .unknown;
}

/// 按魔数分派。`scratch` 只有 PNG 需要（见 `pngIdatSize`），BMP/TGA 传空切片即可。
pub fn decode(bytes: []const u8, out: []u8, scratch: []u8, opts: Options) Error!Image {
    return switch (sniff(bytes)) {
        .bmp => decodeBmp(bytes, out, opts),
        .tga => decodeTga(bytes, out, opts),
        .png => decodePng(bytes, out, scratch, opts),
        .jpeg => error.Unsupported, // 需要 DCT，代价与体积都不合适
        .gif => error.Unsupported,
        .unknown => error.UnknownFormat,
    };
}

fn sizeOk(w: u32, h: u32, out: []u8, opts: Options) Error!void {
    if (w == 0 or h == 0) return error.Corrupt;
    const px = @as(u64, w) * @as(u64, h);
    if (px > opts.max_pixels) return error.TooLarge;
    if (out.len < px * 4) return error.BufferTooSmall;
}

fn le16(b: []const u8, at: usize) u32 {
    return @as(u32, b[at]) | (@as(u32, b[at + 1]) << 8);
}

fn le32(b: []const u8, at: usize) u32 {
    return @as(u32, b[at]) | (@as(u32, b[at + 1]) << 8) | (@as(u32, b[at + 2]) << 16) | (@as(u32, b[at + 3]) << 24);
}

// ====================================================================== BMP

/// BMP（BI_RGB，24/32 bpp，可正可倒）。BMP 的像素本来就是 BGRA 顺序，直接搬。
pub fn decodeBmp(bytes: []const u8, out: []u8, opts: Options) Error!Image {
    if (bytes.len < 54) return error.Truncated;
    if (bytes[0] != 'B' or bytes[1] != 'M') return error.UnknownFormat;
    const data_off = le32(bytes, 10);
    const dib = le32(bytes, 14);
    if (dib < 40) return error.Unsupported; // BITMAPCOREHEADER 之类
    const w_i: i32 = @bitCast(le32(bytes, 18));
    const h_i: i32 = @bitCast(le32(bytes, 22));
    const bpp = le16(bytes, 28);
    const comp = le32(bytes, 30);
    if (le16(bytes, 26) != 1) return error.Unsupported; // planes
    if (comp != 0) return error.Unsupported; // 只做 BI_RGB
    if (bpp != 24 and bpp != 32) return error.Unsupported;
    if (w_i <= 0 or h_i == 0) return error.Corrupt;

    const w: u32 = @intCast(w_i);
    const h: u32 = @intCast(if (h_i < 0) -h_i else h_i);
    const top_down = h_i < 0;
    try sizeOk(w, h, out, opts);

    const row = ((w * bpp / 8) + 3) / 4 * 4;
    const need = @as(u64, data_off) + @as(u64, row) * h;
    if (need > bytes.len) return error.Truncated;

    // 32bpp BI_RGB 的 alpha 常常整片写 0（老工具），按「首像素 alpha=0 视为不透明」处理
    var is_opaque = bpp == 24;
    if (!is_opaque) is_opaque = bytes[data_off + 3] == 0;

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src_y = if (top_down) y else h - 1 - y;
        const src = bytes[@intCast(@as(u64, data_off) + @as(u64, src_y) * row)..];
        var x: u32 = 0;
        const dst_row = @as(usize, y) * w * 4;
        while (x < w) : (x += 1) {
            const s = @as(usize, x) * (bpp / 8);
            const d = dst_row + @as(usize, x) * 4;
            out[d] = src[s];
            out[d + 1] = src[s + 1];
            out[d + 2] = src[s + 2];
            out[d + 3] = if (bpp == 24 or is_opaque) 255 else src[s + 3];
        }
    }
    return .{ .pixels = out[0 .. @as(usize, w) * h * 4], .w = w, .h = h };
}

// ====================================================================== TGA

/// TGA truecolor（类型 2 = 未压缩 / 10 = RLE，24/32 bpp）。像素顺序也是 BGRA。
pub fn decodeTga(bytes: []const u8, out: []u8, opts: Options) Error!Image {
    if (bytes.len < 18) return error.Truncated;
    const id_len = bytes[0];
    if (bytes[1] != 0) return error.Unsupported; // 带调色板
    const kind = bytes[2];
    if (kind != 2 and kind != 10) return error.Unsupported;
    const w = le16(bytes, 12);
    const h = le16(bytes, 14);
    const bpp = bytes[16];
    if (bpp != 24 and bpp != 32) return error.Unsupported;
    try sizeOk(w, h, out, opts);

    const bpp_b = bpp / 8;
    const top_down = (bytes[17] & 0x20) != 0;
    var pos: usize = 18 + id_len;
    const total = @as(usize, w) * h;

    var i: usize = 0;
    while (i < total) {
        if (kind == 2) {
            if (pos + bpp_b > bytes.len) return error.Truncated;
            writeTgaPixel(out, w, h, top_down, i, bytes[pos..][0..bpp_b], bpp_b);
            pos += bpp_b;
            i += 1;
            continue;
        }
        // RLE（类型 10）
        if (pos >= bytes.len) return error.Truncated;
        const head = bytes[pos];
        pos += 1;
        const count = @as(usize, head & 0x7F) + 1;
        if ((head & 0x80) != 0) {
            // 重复包：一个像素写 count 次
            if (pos + bpp_b > bytes.len) return error.Truncated;
            const p = bytes[pos..][0..bpp_b];
            pos += bpp_b;
            var k: usize = 0;
            while (k < count and i < total) : (k += 1) {
                writeTgaPixel(out, w, h, top_down, i, p, bpp_b);
                i += 1;
            }
        } else {
            // 原始包：count 个像素
            if (pos + count * bpp_b > bytes.len) return error.Truncated;
            const p = bytes[pos .. pos + count * bpp_b];
            pos += count * bpp_b;
            var k: usize = 0;
            while (k < count and i < total) : (k += 1) {
                writeTgaPixel(out, w, h, top_down, i, p[k * bpp_b ..], bpp_b);
                i += 1;
            }
        }
    }
    return .{ .pixels = out[0 .. total * 4], .w = w, .h = h };
}

fn writeTgaPixel(out: []u8, w: u32, h: u32, top_down: bool, i: usize, p: []const u8, bpp_b: usize) void {
    const x = i % w;
    const fy = i / w; // 文件顺序的行号
    const y = if (top_down) fy else h - 1 - fy;
    const d = (@as(usize, y) * w + x) * 4;
    out[d] = p[0];
    out[d + 1] = p[1];
    out[d + 2] = p[2];
    out[d + 3] = if (bpp_b == 4) p[3] else 255;
}

// ====================================================================== PNG

/// PNG 里所有 IDAT 负载的总字节数（仅用于参考；请用 `pngScratchSize` 准备缓冲）。
pub fn pngIdatSize(bytes: []const u8) usize {
    if (bytes.len < 8) return 0;
    var pos: usize = 8;
    var total: usize = 0;
    while (pos + 8 <= bytes.len) {
        const len = le32(bytes, pos);
        const tag = bytes[pos + 4 .. pos + 8];
        const body = pos + 8;
        if (body + len > bytes.len) break;
        if (std.mem.eql(u8, tag, "IDAT")) total += len;
        if (std.mem.eql(u8, tag, "IEND")) break;
        pos = body + len + 4; // + CRC
    }
    return total;
}

/// `decodePng` 所需 scratch 大小：**IDAT 总长 + inflate 窗口**。
pub fn pngScratchSize(bytes: []const u8) usize {
    return pngIdatSize(bytes) + inflate_window;
}

/// PNG 解码（8 位、非隔行）。
/// `scratch` 必须 ≥ `pngScratchSize(bytes)`：前段放合并后的 IDAT，后段是 inflate 的工作窗口
/// （std 的 flate 解压器需要一块 ≥ 64 KB 的缓冲，这里不藏在全局变量里，保持零分配、可重入）。
pub fn decodePng(bytes: []const u8, out: []u8, scratch: []u8, opts: Options) Error!Image {
    if (bytes.len < 8 + 25) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) return error.UnknownFormat;
    // IHDR 必须是第一个块
    var pos: usize = 8;
    if (pos + 8 > bytes.len or !std.mem.eql(u8, bytes[pos + 4 .. pos + 8], "IHDR")) return error.Corrupt;
    const ihdr_len = le32(bytes, pos);
    if (ihdr_len < 13 or pos + 8 + ihdr_len > bytes.len) return error.Truncated;
    const ihdr = bytes[pos + 8 ..];
    const w = le32(ihdr, 0);
    const h = le32(ihdr, 4);
    const depth = ihdr[8];
    const color = ihdr[9];
    if (ihdr[10] != 0 or ihdr[11] != 0 or ihdr[12] != 0) return error.Unsupported; // 压缩/滤波/隔行
    if (depth != 8) return error.Unsupported;
    const channels: u32 = switch (color) {
        0 => 1, // 灰度
        2 => 3, // RGB
        4 => 2, // 灰度 + alpha
        6 => 4, // RGBA
        else => return error.Unsupported, // 调色板等
    };
    try sizeOk(w, h, out, opts);
    const row_bytes = @as(usize, w) * channels;
    if (row_bytes > max_row_bytes) return error.ImageTooWide;

    // 收集 IDAT（多数编码器会切成多个 8 KB 块，flate 流必须连续）
    var idat_len: usize = 0;
    pos = 8;
    while (pos + 8 <= bytes.len) {
        const len = le32(bytes, pos);
        const tag = bytes[pos + 4 .. pos + 8];
        const body = pos + 8;
        if (body + len > bytes.len) return error.Truncated;
        if (std.mem.eql(u8, tag, "IDAT")) {
            if (idat_len + len + inflate_window > scratch.len) return error.BufferTooSmall;
            @memcpy(scratch[idat_len..][0..len], bytes[body..][0..len]);
            idat_len += len;
        } else if (std.mem.eql(u8, tag, "IEND")) break;
        pos = body + len + 4;
    }
    if (idat_len == 0) return error.Corrupt;

    var reader = std.Io.Reader.fixed(scratch[0..idat_len]);
    const window = scratch[idat_len..][0..inflate_window];
    var dc = std.compress.flate.Decompress.init(&reader, .zlib, window);

    var prev: [max_row_bytes]u8 = undefined;
    var cur: [max_row_bytes]u8 = undefined;
    var filter: [1]u8 = undefined;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        dc.reader.readSliceAll(&filter) catch return error.Truncated;
        dc.reader.readSliceAll(cur[0..row_bytes]) catch return error.Truncated;
        unfilter(filter[0], cur[0..row_bytes], if (y > 0) prev[0..row_bytes] else null, channels) catch return error.Corrupt;
        const dst_row = @as(usize, y) * w * 4;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const s = @as(usize, x) * channels;
            const d = dst_row + @as(usize, x) * 4;
            switch (channels) {
                1 => {
                    out[d] = cur[s];
                    out[d + 1] = cur[s];
                    out[d + 2] = cur[s];
                    out[d + 3] = 255;
                },
                2 => {
                    out[d] = cur[s];
                    out[d + 1] = cur[s];
                    out[d + 2] = cur[s];
                    out[d + 3] = cur[s + 1];
                },
                3 => {
                    out[d] = cur[s + 2];
                    out[d + 1] = cur[s + 1];
                    out[d + 2] = cur[s];
                    out[d + 3] = 255;
                },
                else => {
                    out[d] = cur[s + 2];
                    out[d + 1] = cur[s + 1];
                    out[d + 2] = cur[s];
                    out[d + 3] = cur[s + 3];
                },
            }
        }
        @memcpy(prev[0..row_bytes], cur[0..row_bytes]);
    }
    return .{ .pixels = out[0 .. @as(usize, w) * h * 4], .w = w, .h = h };
}

fn unfilter(ft: u8, cur: []u8, prev: ?[]const u8, bpp: u32) !void {
    const n = cur.len;
    switch (ft) {
        0 => {},
        1 => { // Sub
            var i: usize = bpp;
            while (i < n) : (i += 1) cur[i] +%= cur[i - bpp];
        },
        2 => { // Up
            if (prev) |p| {
                var i: usize = 0;
                while (i < n) : (i += 1) cur[i] +%= p[i];
            }
        },
        3 => { // Average
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const left: u16 = if (i >= bpp) cur[i - bpp] else 0;
                const up: u16 = if (prev) |p| p[i] else 0;
                cur[i] +%= @intCast((left + up) / 2);
            }
        },
        4 => { // Paeth
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const a: i32 = if (i >= bpp) cur[i - bpp] else 0;
                const b: i32 = if (prev) |p| p[i] else 0;
                const c: i32 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                const p = a + b - c;
                const pa = @abs(p - a);
                const pb = @abs(p - b);
                const pc = @abs(p - c);
                const pr = if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
                cur[i] +%= @intCast(pr & 0xFF);
            }
        },
        else => return error.Corrupt,
    }
}
