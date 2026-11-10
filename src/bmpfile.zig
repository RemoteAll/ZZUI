//! BMP 落盘：平台无关（Windows 走 Win32，其他平台走 `std.Io`）。
//!
//! 放这里而不是 `render.zig`：核心渲染要保持平台无关；文件写入属于平台层。
//! **为什么 Windows 不走 `std.Io`**：产物不链 libc/UCRT（Win7+ 硬约束），
//! `CreateFileW/WriteFile` 零依赖；`std.Io.Threaded` 会拉进线程池与同步原语，
//! 与「产物体积尽可能小」冲突。
//!
//! 非 Windows 分支走 `std.Io.Dir.createFile` + `writeStreamingAll`（Zig 0.17 的新
//! IO 模型，0.17 已移除 `std.fs.cwd()`）。这样 Linux/macOS 上 `--once` 也能出图，
//! 多平台的「出图验证链路」才是通的。
const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");

const GENERIC_WRITE: w.DWORD = 0x40000000;
const CREATE_ALWAYS: w.DWORD = 2;
const FILE_ATTRIBUTE_NORMAL: w.DWORD = 0x80;

/// 写 32 位 BMP：行序自下而上，像素缓冲为 BGRA（与 DIB 一致）。
pub fn saveBmp(path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    if (comptime builtin.os.tag == .windows) {
        return saveWin32(path, pixels, width, height);
    } else {
        return saveIo(path, pixels, width, height);
    }
}

/// 组装 54 字节文件头（两种平台共用，避免两份格式代码）。
fn header(width: u32, height: u32) [54]u8 {
    const row = rowBytes(width);
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
    return hdr;
}

/// 单行字节数（32 位 BMP 天然 4 字节对齐，无需 padding）。
fn rowBytes(width: u32) usize {
    return @as(usize, width) * 4;
}

fn saveWin32(path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    var path_buf: [512]u16 = undefined;
    const path_w = w.narrowToWide(&path_buf, path);
    const h = w.CreateFileW(path_w, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.CreateFileFailed;
    defer _ = w.CloseHandle(h);

    const hdr = header(width, height);
    try writeAll(h, &hdr);

    const row = rowBytes(width);
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

fn saveIo(path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hdr = header(width, height);
    const row = rowBytes(width);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, &hdr);
    var y: u32 = height;
    while (y > 0) {
        y -= 1;
        const start = @as(usize, y) * row;
        try file.writeStreamingAll(io, pixels[start .. start + row]);
    }
}
