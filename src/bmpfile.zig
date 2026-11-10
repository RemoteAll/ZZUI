//! BMP 落盘（Win32，里程碑 1）。
//! 放这里而不是 render.zig：核心渲染要保持平台无关；文件写入属于平台层，
//! Cocoa / X11 后端各自提供同签名的实现即可。
const std = @import("std");
const w = @import("win32.zig");

const GENERIC_WRITE: w.DWORD = 0x40000000;
const CREATE_ALWAYS: w.DWORD = 2;
const FILE_ATTRIBUTE_NORMAL: w.DWORD = 0x80;

/// 写 32 位 BMP：行序自下而上，像素缓冲为 BGRA（与 DIB 一致）。
pub fn saveBmp(path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    var path_buf: [512]u16 = undefined;
    const path_w = w.narrowToWide(&path_buf, path);
    const h = w.CreateFileW(path_w, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.CreateFileFailed;
    defer _ = w.CloseHandle(h);

    const row = @as(usize, width) * 4;
    const image_size = row * @as(usize, height);
    const file_size: u32 = @intCast(54 + image_size);

    var hdr: [54]u8 = @splat(0);
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], file_size, .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little);
    std.mem.writeInt(i32, hdr[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, hdr[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 32, .little);
    std.mem.writeInt(u32, hdr[30..34], 0, .little);
    std.mem.writeInt(u32, hdr[34..38], @intCast(image_size), .little);
    try writeAll(h, &hdr);

    var y: u32 = height;
    while (y > 0) {
        y -= 1;
        const start = @as(usize, y) * row;
        try writeAll(h, pixels[start .. start + row]);
    }
}

fn writeAll(h: w.HANDLE, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const chunk = data[off..];
        var wrote: w.DWORD = 0;
        if (w.WriteFile(h, chunk.ptr, @intCast(chunk.len), &wrote, null) == 0) return error.WriteFailed;
        if (wrote == 0) return error.WriteFailed;
        off += wrote;
    }
}
