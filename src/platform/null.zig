//! 无窗口后端：固定尺寸、内存像素缓冲、不画文本。
//! 用途：`--once` 出图（BMP 校验）与单元测试；任何平台都能编译，不引用系统 API。
const std = @import("std");
const t = @import("../types.zig");
const core = @import("../core.zig");

pub const Backend = struct {
    w: u32,
    h: u32,
    buf: []u8,
    input: t.Input = .{},
    frames: usize = 0,
    /// 注入的拖放路径（测试用：模拟 OS 拖入文件）。
    drops: [4][260]u8 = @splat(@splat(0)),
    drop_lens: [4]u16 = @splat(0),

    pub fn init(width: u32, height: u32) !Backend {
        const len = @as(usize, width) * @as(usize, height) * 4;
        const buf = try std.heap.page_allocator.alloc(u8, len);
        @memset(buf, 0);
        return .{ .w = width, .h = height, .buf = buf };
    }

    /// 模拟「用户拖入了一个文件」（只对下一帧有效）。
    pub fn pushDrop(self: *Backend, path: []const u8) void {
        if (self.input.dropped >= 4 or path.len == 0) return;
        const i = self.input.dropped;
        const n = @min(path.len, 260);
        @memcpy(self.drops[i][0..n], path[0..n]);
        self.drop_lens[i] = @intCast(n);
        self.input.dropped += 1;
    }

    pub fn droppedFile(self: *Backend, i: usize) ?[]const u8 {
        if (i >= self.input.dropped or i >= 4) return null;
        return self.drops[i][0..self.drop_lens[i]];
    }

    pub fn deinit(self: *Backend) void {
        std.heap.page_allocator.free(self.buf);
    }

    pub fn poll(self: *Backend) bool {
        self.frames += 1;
        // 拖放是「本帧事件」：第二帧起清空（与 Win32 后端一致）
        if (self.frames > 1) self.input.dropped = 0;
        return self.frames <= 1;
    }

    pub fn size(self: *Backend) t.Size {
        return .{ .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) };
    }

    pub fn scale(_: *Backend) f32 {
        return 1;
    }

    /// 无窗口后端没有消息队列：`--once` / 测试都是同步出帧，这里只需占位满足契约。
    pub fn idle(_: *Backend, _: u32) void {}

    pub fn now(_: *Backend) f64 {
        return 0;
    }

    pub fn pixels(self: *Backend) []u8 {
        return self.buf;
    }

    pub fn present(_: *Backend) void {}

    pub fn drawTextLayer(_: *Backend, _: *core.Context, _: u8) void {}

    pub fn saveSurface(self: *Backend, path: []const u8) !void {
        // 无窗口后端也能存图（Linux/macOS 的 --once 验证就靠这条路径）
        const bmpfile = @import("../bmpfile.zig");
        try bmpfile.saveBmp(path, self.buf, self.w, self.h);
    }

    /// 无系统字体可用：按 0.55 em 估宽、1.35 em 估高（与 core 的默认测量一致）。
    pub fn measure(_: *Backend, s: []const u8, size_px: f32) t.Size {
        const n: f32 = @floatFromInt(s.len);
        return .{ .w = n * size_px * 0.55, .h = size_px * 1.35 };
    }
};
