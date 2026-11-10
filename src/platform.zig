//! 平台后端选择。核心层（core/render/widgets）不依赖任何平台 API；
//! 每加一个平台就在这里加一个联合成员，并实现同一组方法：
//! `size / scale / pixels / poll / present / measure / deinit`。
//!
//! 里程碑 1：`win32`（实机窗口）+ `null`（无窗口，供 `--once` 出图与回归）。
//! 多平台路线：Cocoa / X11 后端各占一个成员，核心层不变。
const std = @import("std");
const t = @import("types.zig");
const core = @import("core.zig");
const win32_backend = @import("platform/win32.zig");
const null_backend = @import("platform/null.zig");

pub const Platform = enum { win32, null_backend };

pub const Backend = union(enum) {
    win32: win32_backend.Backend,
    null_backend: null_backend.Backend,

    pub fn initNull(width: u32, height: u32) !Backend {
        return .{ .null_backend = try null_backend.Backend.init(width, height) };
    }

    pub fn initWin32(title: []const u8, width: u32, height: u32, show: bool) !Backend {
        return .{ .win32 = try win32_backend.Backend.init(title, width, height, show) };
    }

    /// 把当前帧的像素缓冲写成 BMP（验证字体/图形用）。
    pub fn saveSurface(self: *Backend, path: []const u8) !void {
        switch (self.*) {
            .win32 => |*b| try b.saveSurface(path),
            .null_backend => |*b| try b.saveSurface(path),
        }
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .win32 => |*b| b.deinit(),
            .null_backend => |*b| b.deinit(),
        }
    }

    pub fn poll(self: *Backend) bool {
        return switch (self.*) {
            .win32 => |*b| b.poll(),
            .null_backend => |*b| b.poll(),
        };
    }

    pub fn size(self: *Backend) t.Size {
        return switch (self.*) {
            .win32 => |*b| b.size(),
            .null_backend => |*b| b.size(),
        };
    }

    pub fn scale(self: *Backend) f32 {
        return switch (self.*) {
            .win32 => |*b| b.scale(),
            .null_backend => |*b| b.scale(),
        };
    }

    pub fn pixels(self: *Backend) []u8 {
        return switch (self.*) {
            .win32 => |*b| b.pixels(),
            .null_backend => |*b| b.pixels(),
        };
    }

    pub fn present(self: *Backend, ui: *core.Context) void {
        switch (self.*) {
            .win32 => |*b| b.present(ui),
            .null_backend => |*b| b.present(ui),
        }
    }

    pub fn measure(self: *Backend, s: []const u8, size_px: f32) t.Size {
        return switch (self.*) {
            .win32 => |*b| b.measure(s, size_px),
            .null_backend => |*b| b.measure(s, size_px),
        };
    }

    pub fn input(self: *Backend) *t.Input {
        return switch (self.*) {
            .win32 => |*b| &b.input,
            .null_backend => |*b| &b.input,
        };
    }
};
