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

    pub fn init(width: u32, height: u32) !Backend {
        const len = @as(usize, width) * @as(usize, height) * 4;
        const buf = try std.heap.page_allocator.alloc(u8, len);
        @memset(buf, 0);
        return .{ .w = width, .h = height, .buf = buf };
    }

    pub fn deinit(self: *Backend) void {
        std.heap.page_allocator.free(self.buf);
    }

    pub fn poll(self: *Backend) bool {
        self.frames += 1;
        return self.frames <= 1;
    }

    pub fn size(self: *Backend) t.Size {
        return .{ .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) };
    }

    pub fn scale(_: *Backend) f32 {
        return 1;
    }

    pub fn pixels(self: *Backend) []u8 {
        return self.buf;
    }

    pub fn present(_: *Backend, _: *core.Context) void {}

    /// 无系统字体可用：按 0.55 em 估宽、1.35 em 估高（与 core 的默认测量一致）。
    pub fn measure(_: *Backend, s: []const u8, size_px: f32) t.Size {
        const n: f32 = @floatFromInt(s.len);
        return .{ .w = n * size_px * 0.55, .h = size_px * 1.35 };
    }
};
