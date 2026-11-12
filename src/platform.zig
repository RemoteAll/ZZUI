//! 平台后端选择。核心层（core/render/widgets）不依赖任何平台 API；
//! 每加一个平台就在这里加一个联合成员，并实现同一组方法。
//!
//! **契约是编译期强制的**：下面的 `assertBackendContract` 会用 `@hasDecl` /
//! `@hasField` 检查每个后端是否实现了完整方法集 —— 新增后端漏一个方法，
//! 构建直接失败，不会拖到运行期才发现「某个平台少了 drawTextLayer」。
//!
//! 已实现：`win32`（实机窗口）+ `null`（无窗口，全平台可用，供 `--once` 出图与回归）。
//! 待实现：`x11`（Linux）、`cocoa`（macOS）—— 各占一个联合成员，核心层不变。
const std = @import("std");
const builtin = @import("builtin");
const t = @import("types.zig");
const core = @import("core.zig");
const win32_backend = @import("platform/win32.zig");
const null_backend = @import("platform/null.zig");

pub const Platform = enum { win32, null_backend };

/// 后端必须提供的方法（`input` 是字段，单独检查）。
const backend_methods = [_][]const u8{
    "deinit",       "poll",      "size",     "scale",
    "now",          "pixels",    "present",  "drawTextLayer",
    "saveSurface",  "measure",   "droppedFile", "idle",
    "getClipboard", "setClipboard",
};

fn assertBackendContract(comptime T: type) void {
    for (backend_methods) |m| {
        if (!@hasDecl(T, m)) {
            @compileError("平台后端 " ++ @typeName(T) ++ " 缺少方法 `" ++ m ++
                "`：新增后端必须实现 platform.zig 里 backend_methods 列出的全部方法");
        }
    }
    if (!@hasField(T, "input")) {
        @compileError("平台后端 " ++ @typeName(T) ++ " 缺少字段 `input: t.Input`");
    }
}

comptime {
    assertBackendContract(win32_backend.Backend);
    assertBackendContract(null_backend.Backend);
}

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

    /// 空闲：阻塞到有输入或超时（`null` 后端是空实现）。见 `App.next` 的空闲节流。
    pub fn idle(self: *Backend, ms: u32) void {
        switch (self.*) {
            .win32 => |*b| b.idle(ms),
            .null_backend => |*b| b.idle(ms),
        }
    }

    pub fn now(self: *Backend) f64 {
        return switch (self.*) {
            .win32 => |*b| b.now(),
            .null_backend => |*b| b.now(),
        };
    }

    pub fn pixels(self: *Backend) []u8 {
        return switch (self.*) {
            .win32 => |*b| b.pixels(),
            .null_backend => |*b| b.pixels(),
        };
    }

    pub fn drawTextLayer(self: *Backend, ui: *core.Context, layer: u8) void {
        switch (self.*) {
            .win32 => |*b| b.drawTextLayer(ui, layer),
            .null_backend => |*b| b.drawTextLayer(ui, layer),
        }
    }

    pub fn present(self: *Backend) void {
        switch (self.*) {
            .win32 => |*b| b.present(),
            .null_backend => |*b| b.present(),
        }
    }

    pub fn measure(self: *Backend, s: []const u8, size_px: f32, bold: bool) t.Size {
        return switch (self.*) {
            .win32 => |*b| b.measure(s, size_px, bold),
            .null_backend => |*b| b.measure(s, size_px, bold),
        };
    }

    /// 列出目录（`files.zig` 的默认数据源）。返回条目数或 -1。
    pub fn listDir(self: *Backend, path: []const u8, out: []t.FileEntry, names: []u8, hidden: bool) i32 {
        return switch (self.*) {
            .win32 => |*b| b.listDir(path, out, names, hidden),
            .null_backend => |*b| b.listDir(path, out, names, hidden),
        };
    }

    pub fn input(self: *Backend) *t.Input {
        return switch (self.*) {
            .win32 => |*b| &b.input,
            .null_backend => |*b| &b.input,
        };
    }

    /// 本帧拖入窗口的第 `i` 个文件路径（UTF-8）；越界返回 null。
    pub fn droppedFile(self: *Backend, i: usize) ?[]const u8 {
        return switch (self.*) {
            .win32 => |*b| b.droppedFile(i),
            .null_backend => |*b| b.droppedFile(i),
        };
    }

    /// 读系统剪贴板文本（UTF-8），返回字节数（0 = 没有文本 / 不支持）。
    pub fn getClipboard(self: *Backend, out: []u8) usize {
        return switch (self.*) {
            .win32 => |*b| b.getClipboard(out),
            .null_backend => |*b| b.getClipboard(out),
        };
    }

    /// 写系统剪贴板文本（UTF-8）。
    pub fn setClipboard(self: *Backend, text: []const u8) void {
        switch (self.*) {
            .win32 => |*b| b.setClipboard(text),
            .null_backend => |*b| b.setClipboard(text),
        }
    }
};
