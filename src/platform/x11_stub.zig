//! 非 Linux 目标上的 x11 后端**占位**。
//!
//! 为什么需要它：`platform.Backend` 是个 `union(enum)`，`deinit` / `poll` 这类方法里对每个成员
//! 都有 `switch` 分支；Zig 的惰性分析对**被引用类型的全部成员**都会做语义分析与代码生成，
//! 所以哪怕在 Windows 上根本不调用 `.x11`，`x11.zig` 里那堆 `extern "X11"` 也会被拉进链接
//! （与 `win32_stub.zig` 是同一条约束的反方向）。
//!
//! 解法：非 Linux 目标把 `platform/x11.zig` 换成这个占位文件 —— 方法集与
//! `platform.zig` 的 `backend_methods` 契约一致（少一个就编译失败），所有入口都返回
//! 「平台未实现」，不会静默出一个空窗口。
//!
//! 注意：这里**不引用任何平台 API**，所以 windows / macos 目标可以直接编过。
const std = @import("std");
const t = @import("../types.zig");
const core = @import("../core.zig");

pub const Backend = struct {
    input: t.Input = .{},

    pub fn init(title: []const u8, width: u32, height: u32, show: bool) !Backend {
        _ = title;
        _ = width;
        _ = height;
        _ = show;
        return error.PlatformNotImplemented;
    }

    pub fn deinit(_: *Backend) void {}

    pub fn poll(_: *Backend) bool {
        return false;
    }

    pub fn size(_: *Backend) t.Size {
        return .{ .w = 0, .h = 0 };
    }

    pub fn scale(_: *Backend) f32 {
        return 1;
    }

    pub fn idle(_: *Backend, _: u32) void {}

    pub fn now(_: *Backend) f64 {
        return 0;
    }

    pub fn pixels(_: *Backend) []u8 {
        return &.{};
    }

    pub fn drawTextLayer(_: *Backend, _: *core.Context, _: u8) void {}

    pub fn present(_: *Backend) void {}

    pub fn measure(_: *Backend, s: []const u8, size_px: f32, bold: bool) t.Size {
        // 与 null 后端同口径：0.55 em 宽、1.35 em 高
        const k: f32 = if (bold) 0.58 else 0.55;
        const w = @as(f32, @floatFromInt(s.len)) * size_px * k;
        return .{ .w = w, .h = size_px * 1.35 };
    }

    pub fn saveSurface(_: *Backend, _: []const u8) !void {
        return error.PlatformNotImplemented;
    }

    pub fn listDir(_: *Backend, _: []const u8, _: []t.FileEntry, _: []u8, _: bool) i32 {
        return -1;
    }

    pub fn droppedFile(_: *Backend, _: usize) ?[]const u8 {
        return null;
    }

    pub fn getClipboard(_: *Backend, _: []u8) usize {
        return 0;
    }

    pub fn setClipboard(_: *Backend, _: []const u8) void {}
};
