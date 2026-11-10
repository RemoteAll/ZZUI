//! Win32 后端（里程碑 1）：窗口 + DIB 软件缓冲 + 系统字体文本 + 位块呈现。
//! 只依赖 core 的绘制指令，不含任何布局/控件逻辑；换成 Cocoa/X11 后端时本文件整体替换。
//!
//! 简化：单窗口应用，窗口过程通过模块级全局量与后端通信（多窗口留给后续里程碑）。
const std = @import("std");
const w = @import("../win32.zig");
const t = @import("../types.zig");
const core = @import("../core.zig");
const bmpfile = @import("../bmpfile.zig");

const WM_QUIT: u32 = 0x0012;
const cls_main = std.unicode.utf8ToUtf16LeStringLiteral("ZZUIMain");
const face_ui = std.unicode.utf8ToUtf16LeStringLiteral("Microsoft YaHei UI");

var g_mouse: t.Point = .{};
var g_down: bool = false;
var g_pressed: bool = false;
var g_pending_click: ?t.Point = null;
var g_keys: [8]u8 = @splat(0);
var g_key_count: usize = 0;
var g_chars: [64]u8 = @splat(0);
var g_chars_len: usize = 0;
var g_high_surrogate: u16 = 0;
var g_quit: bool = false;
var g_need_resize: bool = false;

const FontSlot = struct {
    key: f32 = 0,
    font: ?w.HFONT = null,
};

pub const Backend = struct {
    hwnd: ?w.HWND = null,
    hdc_mem: ?w.HDC = null,
    hbmp: ?w.HANDLE = null,
    bits: [*]u8 = undefined,
    px_w: u32 = 0,
    px_h: u32 = 0,
    dpi: f32 = 1,
    input: t.Input = .{},
    fonts: [8]FontSlot = @splat(.{}),

    pub fn init(title: []const u8, width: u32, height: u32, show: bool) !Backend {
        _ = w.SetProcessDPIAware();
        const hinst = w.GetModuleHandleW(null) orelse return error.NoInstance;

        var wc: w.WNDCLASSEXW = std.mem.zeroes(w.WNDCLASSEXW);
        wc.cbSize = @sizeOf(w.WNDCLASSEXW);
        wc.style = w.CS_HREDRAW | w.CS_VREDRAW;
        wc.lpfnWndProc = wndProc;
        wc.hInstance = hinst;
        wc.hCursor = w.LoadCursorW(null, @ptrFromInt(w.IDC_ARROW));
        wc.lpszClassName = cls_main;
        _ = w.RegisterClassExW(&wc);

        var title_buf: [256]u16 = undefined;
        const title_w = w.narrowToWide(&title_buf, title);
        const hwnd = w.CreateWindowExW(
            0,
            cls_main,
            title_w,
            w.WS_OVERLAPPEDWINDOW,
            w.CW_USEDEFAULT,
            w.CW_USEDEFAULT,
            @intCast(width),
            @intCast(height),
            null,
            null,
            hinst,
            null,
        ) orelse return error.CreateWindow;

        var self = Backend{ .hwnd = hwnd };
        self.dpi = queryDpi(hwnd);
        self.createSurface();
        if (show) {
            _ = w.ShowWindow(hwnd, w.SW_SHOW);
            _ = w.UpdateWindow(hwnd);
        }
        return self;
    }

    pub fn deinit(self: *Backend) void {
        for (&self.fonts) |*slot| {
            if (slot.font) |f| _ = w.DeleteObject(f);
            slot.font = null;
        }
        if (self.hbmp) |b| _ = w.DeleteObject(b);
        if (self.hdc_mem) |dc| _ = w.DeleteDC(dc);
        if (self.hwnd) |hwnd| _ = w.DestroyWindow(hwnd);
        self.hbmp = null;
        self.hdc_mem = null;
        self.hwnd = null;
    }

    pub fn poll(self: *Backend) bool {
        var msg: w.MSG = undefined;
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) {
            if (msg.message == WM_QUIT) return false;
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        self.input.mouse = .{ .x = g_mouse.x / self.dpi, .y = g_mouse.y / self.dpi };
        self.input.down = g_down;
        self.input.pressed = g_pressed;
        g_pressed = false;
        self.input.key_count = 0;
        var ki: usize = 0;
        while (ki < g_key_count) : (ki += 1) {
            self.input.addKey(mapKey(g_keys[ki]));
        }
        g_key_count = 0;
        self.input.chars_len = 0;
        if (g_chars_len > 0) {
            self.input.addCharBytes(g_chars[0..g_chars_len]);
            g_chars_len = 0;
        }
        if (g_pending_click) |p| {
            self.input.click = .{ .x = p.x / self.dpi, .y = p.y / self.dpi };
            g_pending_click = null;
        }
        if (g_need_resize) {
            g_need_resize = false;
            self.createSurface();
        }
        if (g_quit) return false;
        w.Sleep(1);
        return true;
    }

    pub fn size(self: *Backend) t.Size {
        return .{
            .w = @as(f32, @floatFromInt(self.px_w)) / self.dpi,
            .h = @as(f32, @floatFromInt(self.px_h)) / self.dpi,
        };
    }

    pub fn scale(self: *Backend) f32 {
        return self.dpi;
    }

    pub fn pixels(self: *Backend) []u8 {
        const n = @as(usize, self.px_w) * @as(usize, self.px_h) * 4;
        return self.bits[0..n];
    }

    /// 把当前 DIB 写成 BMP（含 GDI 文本），用于无人工干预的视觉校验。
    pub fn saveSurface(self: *Backend, path: []const u8) !void {
        if (self.px_w == 0 or self.px_h == 0) return error.NoSurface;
        return bmpfile.saveBmp(path, self.pixels(), self.px_w, self.px_h);
    }

    pub fn present(self: *Backend, ui: *core.Context) void {
        const dc = self.hdc_mem orelse return;
        var i: usize = 0;
        while (i < ui.cmd_count) : (i += 1) {
            switch (ui.cmds[i]) {
                .text => |c| self.drawTextCmd(dc, c),
                .rect => {},
                .line => {},
            }
        }
        const wdc = w.GetDC(self.hwnd) orelse return;
        _ = w.BitBlt(wdc, 0, 0, @intCast(self.px_w), @intCast(self.px_h), dc, 0, 0, w.SRCCOPY);
        _ = w.ReleaseDC(self.hwnd, wdc);
    }

    pub fn measure(self: *Backend, s: []const u8, size_px: f32) t.Size {
        const dc = self.hdc_mem orelse return .{ .w = 0, .h = size_px * 1.35 };
        const font = self.fontFor(size_px) orelse return .{ .w = 0, .h = size_px * 1.35 };
        var buf: [512]u16 = undefined;
        const ws = w.narrowToWide(&buf, s);
        const old = w.SelectObject(dc, font) orelse return .{ .w = 0, .h = size_px * 1.35 };
        var sz: w.SIZE = undefined;
        _ = w.GetTextExtentPoint32W(dc, ws.ptr, @intCast(ws.len), &sz);
        _ = w.SelectObject(dc, old);
        return .{
            .w = @as(f32, @floatFromInt(sz.cx)) / self.dpi,
            .h = @as(f32, @floatFromInt(sz.cy)) / self.dpi,
        };
    }

    fn drawTextCmd(self: *Backend, dc: w.HDC, c: core.TextCmd) void {
        const font = self.fontFor(c.size) orelse return;
        var buf: [512]u16 = undefined;
        const ws = w.narrowToWide(&buf, c.text);
        const old = w.SelectObject(dc, font) orelse return;
        _ = w.SetBkMode(dc, w.TRANSPARENT);
        const color: w.DWORD = @as(w.DWORD, c.color.r) | (@as(w.DWORD, c.color.g) << 8) | (@as(w.DWORD, c.color.b) << 16);
        _ = w.SetTextColor(dc, color);
        const x: i32 = @intFromFloat(@round(c.rect.x * self.dpi));
        const y: i32 = @intFromFloat(@round(c.rect.y * self.dpi));
        _ = w.TextOutW(dc, x, y, ws.ptr, @intCast(ws.len));
        _ = w.SelectObject(dc, old);
    }

    fn fontFor(self: *Backend, size_px: f32) ?w.HFONT {
        const weight: i32 = if (size_px >= 20) 600 else 400;
        const key = size_px * 1000 + @as(f32, @floatFromInt(weight));
        for (&self.fonts) |*slot| {
            if (slot.font != null and slot.key == key) return slot.font;
        }
        const height: i32 = -@as(i32, @intFromFloat(@round(size_px * self.dpi)));
        const font = w.CreateFontW(height, 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 0, 0, face_ui);
        for (&self.fonts) |*slot| {
            if (slot.font == null) {
                slot.* = .{ .key = key, .font = font };
                break;
            }
        }
        return font;
    }

    fn createSurface(self: *Backend) void {
        const hwnd = self.hwnd orelse return;
        var rc: w.RECT = undefined;
        if (w.GetClientRect(hwnd, &rc) == 0) return;
        const cw: u32 = @intCast(rc.right - rc.left);
        const ch: u32 = @intCast(rc.bottom - rc.top);
        if (cw == 0 or ch == 0) return;
        if (self.hbmp != null and cw == self.px_w and ch == self.px_h) return;

        self.dpi = queryDpi(hwnd);
        if (self.hdc_mem == null) self.hdc_mem = w.CreateCompatibleDC(null);
        const dc = self.hdc_mem orelse return;

        var bmi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = @intCast(cw);
        bmi.bmiHeader.biHeight = -@as(w.LONG, @intCast(ch));
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = w.BI_RGB;
        bmi.bmiHeader.biSizeImage = cw * ch * 4;

        var bits: ?*anyopaque = null;
        const hbmp = w.CreateDIBSection(dc, &bmi, w.DIB_RGB_COLORS, &bits, null, 0) orelse return;
        _ = w.SelectObject(dc, hbmp);
        if (self.hbmp) |old| _ = w.DeleteObject(old);
        self.hbmp = hbmp;
        self.bits = @ptrCast(bits.?);
        self.px_w = cw;
        self.px_h = ch;
    }
};

fn mouseFrom(lp: w.LPARAM) t.Point {
    const v: usize = @bitCast(lp);
    return .{ .x = @floatFromInt(w.loword(v)), .y = @floatFromInt(w.hiword(v)) };
}

fn mapKey(vk: u8) t.Key {
    return switch (vk) {
        8 => .backspace,
        9 => .tab,
        13 => .enter,
        27 => .escape,
        32 => .space,
        35 => .end,
        36 => .home,
        37 => .left,
        38 => .up,
        39 => .right,
        40 => .down,
        46 => .delete,
        else => .unknown,
    };
}

/// WM_CHAR 给的是 UTF-16 码元：控制字符交给 WM_KEYDOWN 处理；代理对合并后转 UTF-8。
fn appendUtf16(u: u16) void {
    if (u < 0x20) return;
    if (u >= 0xD800 and u <= 0xDBFF) {
        g_high_surrogate = u;
        return;
    }
    var cp: u21 = u;
    if (u >= 0xDC00 and u <= 0xDFFF) {
        if (g_high_surrogate == 0) return;
        cp = @intCast(0x10000 + (@as(u32, g_high_surrogate - 0xD800) << 10) + (u - 0xDC00));
        g_high_surrogate = 0;
    }
    var buf4: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf4) catch return;
    if (g_chars_len + n > g_chars.len) return;
    @memcpy(g_chars[g_chars_len .. g_chars_len + n], buf4[0..n]);
    g_chars_len += n;
}

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_MOUSEMOVE => {
            g_mouse = mouseFrom(lp);
            return 0;
        },
        w.WM_LBUTTONDOWN => {
            g_down = true;
            g_pressed = true;
            g_mouse = mouseFrom(lp);
            return 0;
        },
        w.WM_LBUTTONUP => {
            g_down = false;
            const p = mouseFrom(lp);
            g_mouse = p;
            g_pending_click = p;
            return 0;
        },
        w.WM_SIZE => {
            g_need_resize = true;
            return 0;
        },
        w.WM_KEYDOWN => {
            if (g_key_count < g_keys.len) {
                g_keys[g_key_count] = @truncate(wp);
                g_key_count += 1;
            }
            return 0;
        },
        w.WM_CHAR => {
            appendUtf16(@truncate(wp));
            return 0;
        },
        w.WM_CLOSE => {
            _ = w.DestroyWindow(hwnd);
            return 0;
        },
        w.WM_DESTROY => {
            g_quit = true;
            w.PostQuitMessage(0);
            return 0;
        },
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            _ = w.BeginPaint(hwnd, &ps);
            _ = w.EndPaint(hwnd, &ps);
            return 0;
        },
        w.WM_DPICHANGED => {
            g_need_resize = true;
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

var g_get_dpi_for_window: ?*const fn (w.HWND) callconv(.winapi) u32 = null;

fn resolveDpiApi() void {
    if (g_get_dpi_for_window != null) return;
    const mod = w.GetModuleHandleW(@ptrCast(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"))) orelse return;
    if (w.GetProcAddress(mod, "GetDpiForWindow")) |p| g_get_dpi_for_window = @ptrCast(@alignCast(p));
}

fn queryDpi(hwnd: w.HWND) f32 {
    resolveDpiApi();
    if (g_get_dpi_for_window) |f| {
        const d = f(hwnd);
        if (d >= 48 and d <= 960) return @as(f32, @floatFromInt(d)) / 96.0;
    }
    const dc = w.GetDC(null) orelse return 1;
    defer _ = w.ReleaseDC(null, dc);
    const d = w.GetDeviceCaps(dc, w.LOGPIXELSX);
    if (d >= 48 and d <= 960) return @as(f32, @floatFromInt(d)) / 96.0;
    return 1;
}
