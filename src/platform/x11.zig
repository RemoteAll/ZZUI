//! X11 后端（Linux）。只依赖 core 的绘制指令，不含布局/控件逻辑。
//!
//! 与 Win32 后端的差别（都是「平台能力」范畴，核心层无感）：
//! - **文本**：X11 核心字体（`fixed`，服务端位图字体）→ 启动时把 ASCII 32..126 画进 1-bit Pixmap，
//!   `XGetImage` 读回成字形图集，之后按请求字号**最近邻缩放**画进 BGRA 缓冲（与 Win32 同口径：
//!   文本落在帧缓冲里，层级顺序正确）。**非 ASCII（中文/emoji）目前不画**，只按字号推进光标 ——
//!   要中文得接 Xft/fontconfig（`apt install libxft-dev`），文件头记着这条待办；
//! - **像素格式**：X 服务端是 0x00RRGGBB，我们是 BGRA 字节序，`present` 时逐像素换 R/B；
//! - **剪贴板**：`CLIPBOARD` selection（`setClipboard` 当 owner，别的客户端来要就回 `UTF8_STRING`；
//!   `getClipboard` 自己持有就直接给，否则 `XConvertSelection` + 120ms 超时往返，超时返回 0）；
//! - **目录枚举**：`std.Io.Dir`（0.17 已移除 `std.fs.cwd()`），与 `bmpfile.zig` 同口径；
//! - **文件拖放（XDND v5）**：窗口声明 `XdndAware`，接受 `XdndPosition`（回 `XdndStatus` 表示 copy）、
//!   `XdndDrop`（把 `text/uri-list` 转成属性）→ 解析 `file://` 行（支持 `%XX`）→ 下一帧 `input.dropped` 生效；
//!   固定 4 个文件 / 单路径 260 字节，与 Win32 同口径；
//! - **空闲节流**：`idle(ms)` 用 `poll()` 阻塞在 X 连接上，有事件立刻返回（同 Win32 口径）。
//!
//! 实测环境：Windows 11 + WSL2（Ubuntu）+ WSLg（XWayland，`DISPLAY=:0`）。

const std = @import("std");
const t = @import("../types.zig");
const core = @import("../core.zig");
const bmpfile = @import("../bmpfile.zig");

// ------------------------------------------------------------------ Xlib ABI（手写声明）

const Display = opaque {};
const XID = c_ulong;
const Window = XID;
const Pixmap = XID;
const Font = XID;
const Atom = c_ulong;
const GC = ?*opaque {};
const Visual = opaque {};
const XFontStruct = opaque {};

const Expose = 12;
const ClientMessage = 33;
const ButtonPress = 4;
const ButtonRelease = 5;
const KeyPress = 2;
const KeyRelease = 3;
const MotionNotify = 6;
const ConfigureNotify = 22;
const DestroyNotify = 17;
const SelectionClear = 29;
const SelectionRequest = 30;
const SelectionNotify = 31;
/// XA_ATOM / XA_STRING 是预定义 atom 的固定编号
const XA_STRING: Atom = 31;
const XA_ATOM: Atom = 4;
const PropModeReplace: c_int = 0;

const KeyPressMask: c_long = 1 << 0;
const KeyReleaseMask: c_long = 1 << 1;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const ExposureMask: c_long = 1 << 15;
const StructureNotifyMask: c_long = 1 << 17;
const ZPixmap: c_int = 2;
const GCFont: c_ulong = 1 << 14;
const AllPlanes: c_ulong = ~@as(c_ulong, 0);
const LSBFirst: c_int = 0;
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3;
const Mod4Mask: c_uint = 1 << 6;
const Button1Mask: c_uint = 1 << 8;
const Button3Mask: c_uint = 1 << 10;

const XRectangle = extern struct { x: c_short, y: c_short, width: c_ushort, height: c_ushort };
const XCharStruct = extern struct {
    lbearing: c_short,
    rbearing: c_short,
    width: c_short,
    ascent: c_short,
    descent: c_short,
    attributes: c_ushort,
};

const XGCValues = extern struct {
    function: c_int = 0,
    plane_mask: c_ulong = 0,
    foreground: c_ulong = 0,
    background: c_ulong = 0,
    line_width: c_int = 0,
    line_style: c_int = 0,
    cap_style: c_int = 0,
    join_style: c_int = 0,
    fill_style: c_int = 0,
    fill_rule: c_int = 0,
    arc_mode: c_int = 0,
    tile: Pixmap = 0,
    stipple: Pixmap = 0,
    ts_x_origin: c_int = 0,
    ts_y_origin: c_int = 0,
    font: Font = 0,
    subwindow_mode: c_int = 0,
    graphics_exposures: c_int = 0,
    clip_x_origin: c_int = 0,
    clip_y_origin: c_int = 0,
    clip_mask: Pixmap = 0,
    dash_offset: c_int = 0,
    dashes: u8 = 0,
};

const XImage = extern struct {
    width: c_int,
    height: c_int,
    xoffset: c_int,
    format: c_int,
    /// 可空：销毁前先置 null，Xlib 就不会去 free 这块（我们自己用 page_allocator 管理）
    data: ?[*]u8,
    byte_order: c_int,
    bitmap_unit: c_int,
    bitmap_bit_order: c_int,
    bitmap_pad: c_int,
    depth: c_int,
    bytes_per_line: c_int,
    bits_per_pixel: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    obdata: ?*anyopaque,
    /// XImage 内部的函数表（我们只透传指针，不调用）
    f: [6]?*anyopaque,
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};

const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: c_int,
};

const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: c_int,
};

const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union { b: [20]u8, s: [10]c_short, l: [5]c_long },
};

const XSelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

const XSelectionRequestEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

const XEvent = extern union {
    type: c_int,
    key: XKeyEvent,
    button: XButtonEvent,
    motion: XMotionEvent,
    configure: XConfigureEvent,
    client: XClientMessageEvent,
    selection: XSelectionEvent,
    selreq: XSelectionRequestEvent,
    pad: [24]c_long,
};

extern fn XOpenDisplay(?[*:0]const u8) ?*Display;
extern fn XCloseDisplay(*Display) c_int;
extern fn XDefaultScreen(*Display) c_int;
extern fn XRootWindow(*Display, c_int) Window;
extern fn XDefaultVisual(*Display, c_int) *Visual;
extern fn XDefaultDepth(*Display, c_int) c_int;
extern fn XCreateSimpleWindow(*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) Window;
extern fn XDestroyWindow(*Display, Window) c_int;
extern fn XSelectInput(*Display, Window, c_long) c_int;
extern fn XStoreName(*Display, Window, [*:0]const u8) c_int;
extern fn XMapWindow(*Display, Window) c_int;
extern fn XFlush(*Display) c_int;
extern fn XSync(*Display, c_int) c_int;
extern fn XPending(*Display) c_int;
extern fn XNextEvent(*Display, *XEvent) c_int;
extern fn XConnectionNumber(*Display) c_int;
extern fn XInternAtom(*Display, [*:0]const u8, c_int) Atom;
extern fn XSetWMProtocols(*Display, Window, [*]Atom, c_int) c_int;
extern fn XCreateGC(*Display, XID, c_ulong, ?*const XGCValues) GC;
extern fn XFreeGC(*Display, GC) c_int;
extern fn XSetForeground(*Display, GC, c_ulong) c_int;
extern fn XSetClipRectangles(*Display, GC, c_int, c_int, [*]const XRectangle, c_int, c_int) c_int;
extern fn XSetClipMask(*Display, GC, Pixmap) c_int;
extern fn XCreateImage(*Display, *Visual, c_uint, c_int, c_int, [*]u8, c_uint, c_uint, c_int, c_int) ?*XImage;
extern fn XPutImage(*Display, Window, GC, *XImage, c_int, c_int, c_int, c_int, c_uint, c_uint) c_int;
extern fn XDestroyImage(*XImage) c_int;
extern fn XLoadFont(*Display, [*:0]const u8) Font;
extern fn XQueryFont(*Display, Font) ?*XFontStruct;
extern fn XFreeFont(*Display, *XFontStruct) c_int;
extern fn XTextWidth(*XFontStruct, [*]const u8, c_int) c_int;
extern fn XTextExtents(
    *XFontStruct,
    [*]const u8,
    c_int,
    *c_int,
    *c_int,
    *c_int,
    *XCharStruct,
) c_int;
extern fn XDrawString(*Display, XID, GC, c_int, c_int, [*]const u8, c_int) c_int;
extern fn XCreatePixmap(*Display, XID, c_uint, c_uint, c_uint) Pixmap;
extern fn XFreePixmap(*Display, Pixmap) c_int;
extern fn XGetImage(*Display, XID, c_int, c_int, c_uint, c_uint, c_ulong, c_int) ?*XImage;
extern fn XLookupString(*const XKeyEvent, [*]u8, c_int, ?*c_ulong, ?*anyopaque) c_int;
extern fn XkbSetDetectableAutoRepeat(*Display, c_int, ?*c_int) c_int;
extern fn XSetSelectionOwner(*Display, Atom, Window, c_ulong) c_int;
extern fn XGetSelectionOwner(*Display, Atom) Window;
extern fn XConvertSelection(*Display, Atom, Atom, Atom, Window, c_ulong) c_int;
extern fn XChangeProperty(*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) c_int;
extern fn XGetWindowProperty(*Display, Window, Atom, c_long, c_long, c_int, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *?[*]u8) c_int;
extern fn XDeleteProperty(*Display, Window, Atom) c_int;
extern fn XSendEvent(*Display, Window, c_int, c_long, *XEvent) c_int;
extern fn XFree(?*anyopaque) c_int;

// ------------------------------------------------------------------ 字形图集

const GLYPH_FIRST = 32;
const GLYPH_LAST = 126;
const GLYPH_COUNT = GLYPH_LAST - GLYPH_FIRST + 1;
/// 单字形位图的最大宽高（核心 `fixed` 字体约 6×13，留些余量）
const GW = 8;
const GH = 16;

const Glyphs = struct {
    bits: [GLYPH_COUNT][GH]u8 = @splat(@splat(0)),
    adv: u8 = 6,
    ascent: u8 = 10,
    descent: u8 = 3,
    ok: bool = false,
};

pub const Backend = struct {
    dpy: ?*Display = null,
    win: Window = 0,
    gc: GC = null,
    img: ?*XImage = null,
    wm_delete: Atom = 0,
    wm_protocols: Atom = 0,
    px_w: u32 = 0,
    px_h: u32 = 0,
    /// 我们的 BGRA 缓冲（与 Windows 后端同格式）
    buf: []u8 = &.{},
    /// 给 XPutImage 的 0x00RRGGBB 缓冲
    xbuf: []u32 = &.{},
    input: t.Input = .{},
    glyphs: Glyphs = .{},
    font_id: Font = 0,
    closed: bool = false,
    /// 鼠标按键状态（点击在**抬起**那帧上报，与 Win32 一致）
    btn1: bool = false,
    btn3: bool = false,
    last_ms: f64 = 0,
    // ---- 剪贴板（X selections）：atom + 自己持有的文本
    atom_clipboard: Atom = 0,
    atom_utf8: Atom = 0,
    atom_targets: Atom = 0,
    atom_prop: Atom = 0,
    clip_text: [4096]u8 = @splat(0),
    clip_len: usize = 0,
    // ---- XDND 文件拖放
    atom_xdnd_aware: Atom = 0,
    atom_xdnd_enter: Atom = 0,
    atom_xdnd_position: Atom = 0,
    atom_xdnd_status: Atom = 0,
    atom_xdnd_drop: Atom = 0,
    atom_xdnd_finished: Atom = 0,
    atom_xdnd_selection: Atom = 0,
    atom_xdnd_action_copy: Atom = 0,
    atom_uri_list: Atom = 0,
    atom_drop_prop: Atom = 0,
    /// 拖放源窗口（Drop 后要回 XdndFinished，可能要跨帧）
    xdnd_src: Window = 0,
    drops: DropList = .{},
    /// 本帧有效的拖放条数（与 Win32 同口径："本帧事件"）
    drop_active: u8 = 0,

    pub fn init(title: []const u8, width: u32, height: u32, show: bool) !Backend {
        const dpy = XOpenDisplay(null) orelse return error.PlatformNotImplemented;
        const scr = XDefaultScreen(dpy);
        const root = XRootWindow(dpy, scr);
        const vis = XDefaultVisual(dpy, scr);
        const depth: c_uint = @intCast(XDefaultDepth(dpy, scr));

        var self = Backend{ .dpy = dpy };
        self.win = XCreateSimpleWindow(dpy, root, 0, 0, width, height, 1, 0x000000, 0xFFFFFF);
        _ = XSelectInput(dpy, self.win, KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask |
            PointerMotionMask | ExposureMask | StructureNotifyMask);
        var name_buf: [256]u8 = undefined;
        const n = @min(title.len, name_buf.len - 1);
        @memcpy(name_buf[0..n], title[0..n]);
        name_buf[n] = 0;
        _ = XStoreName(dpy, self.win, @ptrCast(&name_buf));

        self.wm_protocols = XInternAtom(dpy, "WM_PROTOCOLS", 0);
        self.wm_delete = XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        self.atom_clipboard = XInternAtom(dpy, "CLIPBOARD", 0);
        self.atom_utf8 = XInternAtom(dpy, "UTF8_STRING", 0);
        self.atom_targets = XInternAtom(dpy, "TARGETS", 0);
        self.atom_prop = XInternAtom(dpy, "ZZUI_SELECTION", 0);
        self.atom_xdnd_aware = XInternAtom(dpy, "XdndAware", 0);
        self.atom_xdnd_enter = XInternAtom(dpy, "XdndEnter", 0);
        self.atom_xdnd_position = XInternAtom(dpy, "XdndPosition", 0);
        self.atom_xdnd_status = XInternAtom(dpy, "XdndStatus", 0);
        self.atom_xdnd_drop = XInternAtom(dpy, "XdndDrop", 0);
        self.atom_xdnd_finished = XInternAtom(dpy, "XdndFinished", 0);
        self.atom_xdnd_selection = XInternAtom(dpy, "XdndSelection", 0);
        self.atom_xdnd_action_copy = XInternAtom(dpy, "XdndActionCopy", 0);
        self.atom_uri_list = XInternAtom(dpy, "text/uri-list", 0);
        self.atom_drop_prop = XInternAtom(dpy, "ZZUI_DROP", 0);
        // 告诉拖放源：本窗口接受 XDND v5
        var ver = [_]Atom{5};
        _ = XChangeProperty(dpy, self.win, self.atom_xdnd_aware, XA_ATOM, 32, PropModeReplace, @ptrCast(&ver), 1);
        var proto = [_]Atom{self.wm_delete};
        _ = XSetWMProtocols(dpy, self.win, &proto, 1);

        self.gc = XCreateGC(dpy, self.win, 0, null);
        // 同一按键按住时的自动重复：不要成对的 KeyRelease，否则会漏字符
        _ = XkbSetDetectableAutoRepeat(dpy, 1, null);

        self.px_w = width;
        self.px_h = height;
        self.allocSurface();
        self.img = XCreateImage(dpy, vis, depth, ZPixmap, 0, @ptrCast(self.xbuf.ptr), width, height, 32, 0);
        if (self.img == null) return error.PlatformNotImplemented;

        self.loadGlyphs();
        if (show) _ = XMapWindow(dpy, self.win);
        _ = XFlush(dpy);
        return self;
    }

    fn allocSurface(self: *Backend) void {
        const alloc = std.heap.page_allocator;
        self.buf = alloc.alloc(u8, @as(usize, self.px_w) * self.px_h * 4) catch &.{};
        self.xbuf = alloc.alloc(u32, @as(usize, self.px_w) * self.px_h) catch &.{};
        @memset(self.buf, 0);
        @memset(self.xbuf, 0);
    }

    /// 把服务端 `fixed` 字体的 ASCII 字形读成 1-bit 位图。
    fn loadGlyphs(self: *Backend) void {
        const dpy = self.dpy orelse return;
        self.font_id = XLoadFont(dpy, "fixed");
        if (self.font_id == 0) return;
        var vals = XGCValues{ .font = self.font_id };
        const gcx = XCreateGC(dpy, self.win, GCFont, &vals);

        const pm = XCreatePixmap(dpy, self.win, GW * GLYPH_COUNT, GH, 1);
        var pgc_vals = XGCValues{ .font = self.font_id, .foreground = 1, .background = 0 };
        const pgc = XCreateGC(dpy, pm, GCFont | (1 << 2) | (1 << 3), &pgc_vals);
        defer {
            _ = XFreeGC(dpy, pgc);
            _ = XFreeGC(dpy, gcx);
            _ = XFreePixmap(dpy, pm);
        }

        const font = XQueryFont(dpy, self.font_id) orelse return;
        defer _ = XFreeFont(dpy, font);

        var dir: c_int = 0;
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var overall: XCharStruct = std.mem.zeroes(XCharStruct);
        var sample = [_]u8{'M'};
        _ = XTextExtents(font, &sample, 1, &dir, &ascent, &descent, &overall);
        self.glyphs.adv = @intCast(@max(1, XTextWidth(font, &sample, 1)));
        self.glyphs.ascent = @intCast(@min(@as(c_int, GH), @max(@as(c_int, 1), ascent)));
        self.glyphs.descent = @intCast(@min(@as(c_int, GH - 1), @max(@as(c_int, 0), descent)));
        const baseline: c_int = self.glyphs.ascent;

        var c: u8 = GLYPH_FIRST;
        while (c <= GLYPH_LAST) : (c += 1) {
            var ch = [_]u8{c};
            // 注意：GW 是 comptime_int，和 u8 相乘会按 8 位算 → 94*8 直接溢出
            const gx: c_int = @intCast(@as(usize, c - GLYPH_FIRST) * GW);
            _ = XDrawString(dpy, pm, pgc, gx, baseline, &ch, 1);
        }
        _ = XSync(dpy, 0);

        const shot = XGetImage(dpy, pm, 0, 0, GW * GLYPH_COUNT, GH, AllPlanes, ZPixmap) orelse return;
        defer _ = XDestroyImage(shot);
        const shot_data = shot.data orelse return;
        // depth=1 的 ZPixmap：每字节 8 个像素，默认 LSBFirst
        const bpl: usize = @intCast(shot.bytes_per_line);
        var g: usize = 0;
        while (g < GLYPH_COUNT) : (g += 1) {
            var row: usize = 0;
            while (row < GH) : (row += 1) {
                var bits: u8 = 0;
                var col: usize = 0;
                while (col < GW) : (col += 1) {
                    const px = g * GW + col;
                    const byte = shot_data[row * bpl + px / 8];
                    if ((byte >> @intCast(px % 8)) & 1 != 0) bits |= @as(u8, 1) << @intCast(col);
                }
                self.glyphs.bits[g][row] = bits;
            }
        }
        self.glyphs.ok = true;
    }

    fn deallocSurface(self: *Backend) void {
        const alloc = std.heap.page_allocator;
        if (self.buf.len > 0) alloc.free(self.buf);
        if (self.xbuf.len > 0) alloc.free(self.xbuf);
        self.buf = &.{};
        self.xbuf = &.{};
    }

    pub fn deinit(self: *Backend) void {
        if (self.dpy) |dpy| {
            if (self.img) |img| {
                // 置 null：XDestroyImage 只负责释放 XImage 结构，不去 free 我们的像素缓冲
                img.data = null;
                _ = XDestroyImage(img);
            }
            self.img = null;
            if (self.gc != null) _ = XFreeGC(dpy, self.gc);
            if (self.win != 0) _ = XDestroyWindow(dpy, self.win);
            _ = XCloseDisplay(dpy);
            self.dpy = null;
            self.win = 0;
        }
        self.deallocSurface();
    }

    fn nowMs() f64 {
        // 0.17 把 clock_gettime/nanosleep 挪进了 `std.Io`；后端是 Linux 专属，直接用 linux 拐点。
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const sec: f64 = @floatFromInt(ts.sec);
        const nsec: f64 = @floatFromInt(ts.nsec);
        return sec * 1000.0 + nsec / 1_000_000.0;
    }

    pub fn poll(self: *Backend) bool {
        const dpy = self.dpy orelse return false;
        self.input.key_count = 0;
        self.input.chars_len = 0;
        self.input.pressed = false;
        self.input.wheel = 0;
        self.input.click = null;
        self.input.right_click = null;
        // 拖放是「本帧事件」：上一帧解析到的路径在这一帧有效，随后清空
        self.input.dropped = self.drop_active;
        self.drop_active = 0;

        var ev: XEvent = undefined;
        while (XPending(dpy) > 0) {
            if (XNextEvent(dpy, &ev) != 0) break;
            self.handleEvent(ev);
        }
        if (self.closed) return false;
        // 低帧率保护：X 无消息时别把 CPU 打满（用 1ms 超时等 X 连接，空 fd 数组会让 poll 报 EFAULT）
        self.idle(1);
        return true;
    }

    /// 单个 X 事件的处理（`poll` 与剪贴板往返共用，免得两处各写一份）。
    fn handleEvent(self: *Backend, ev: XEvent) void {
        const dpy = self.dpy orelse return;
        switch (ev.type) {
            Expose => {},
            ConfigureNotify => {
                const ce = ev.configure;
                if (ce.width > 0 and ce.height > 0) {
                    const w: u32 = @intCast(ce.width);
                    const h: u32 = @intCast(ce.height);
                    if (w != self.px_w or h != self.px_h) {
                        self.px_w = w;
                        self.px_h = h;
                        self.deallocSurface();
                        self.allocSurface();
                        if (self.img) |img| {
                            img.data = null;
                            _ = XDestroyImage(img);
                        }
                        self.img = null;
                        const scr = XDefaultScreen(dpy);
                        self.img = XCreateImage(dpy, XDefaultVisual(dpy, scr), @intCast(XDefaultDepth(dpy, scr)), ZPixmap, 0, @ptrCast(self.xbuf.ptr), w, h, 32, 0);
                    }
                }
            },
            MotionNotify => {
                const me = ev.motion;
                self.input.mouse = .{ .x = @floatFromInt(me.x), .y = @floatFromInt(me.y) };
                self.input.down = (me.state & Button1Mask) != 0;
            },
            ButtonPress => {
                const be = ev.button;
                self.input.mouse = .{ .x = @floatFromInt(be.x), .y = @floatFromInt(be.y) };
                switch (be.button) {
                    1 => {
                        self.btn1 = true;
                        self.input.down = true;
                        self.input.pressed = true;
                    },
                    3 => self.btn3 = true,
                    4 => self.input.wheel += 1,
                    5 => self.input.wheel -= 1,
                    else => {},
                }
            },
            ButtonRelease => {
                const be = ev.button;
                self.input.mouse = .{ .x = @floatFromInt(be.x), .y = @floatFromInt(be.y) };
                switch (be.button) {
                    1 => {
                        if (self.btn1) {
                            self.input.click = .{ .x = @floatFromInt(be.x), .y = @floatFromInt(be.y) };
                        }
                        self.btn1 = false;
                        self.input.down = false;
                    },
                    3 => {
                        if (self.btn3) self.input.right_click = .{ .x = @floatFromInt(be.x), .y = @floatFromInt(be.y) };
                        self.btn3 = false;
                    },
                    else => {},
                }
            },
            KeyPress => {
                const ke = ev.key;
                var buf: [8]u8 = @splat(0);
                var sym: c_ulong = 0;
                const n = XLookupString(&ke, &buf, buf.len, &sym, null);
                if (mapKeysym(sym)) |k| self.input.addKey(k);
                if (n > 0) {
                    // 只取可打印 ASCII：核心字体画不了别的，别把乱码塞进输入框
                    if (buf[0] >= 32 and buf[0] < 127) self.input.addCharBytes(buf[0..1]);
                }
                self.input.mods = .{
                    .ctrl = (ke.state & ControlMask) != 0,
                    .shift = (ke.state & ShiftMask) != 0,
                    .alt = (ke.state & Mod1Mask) != 0,
                    .win = (ke.state & Mod4Mask) != 0,
                };
            },
            KeyRelease => {
                const ke = ev.key;
                self.input.mods = .{
                    .ctrl = (ke.state & ControlMask) != 0,
                    .shift = (ke.state & ShiftMask) != 0,
                    .alt = (ke.state & Mod1Mask) != 0,
                    .win = (ke.state & Mod4Mask) != 0,
                };
            },
            ClientMessage => {
                const cm = ev.client;
                if (cm.message_type == self.wm_protocols) {
                    if (cm.data.l[0] == @as(c_long, @intCast(self.wm_delete))) self.closed = true;
                } else if (cm.message_type == self.atom_xdnd_position) {
                    self.xdndAccept(cm);
                } else if (cm.message_type == self.atom_xdnd_drop) {
                    self.xdndDrop(cm);
                } else if (cm.message_type == self.atom_xdnd_enter) {
                    self.xdnd_src = @intCast(cm.data.l[0]);
                }
            },
            SelectionNotify => {
                if (ev.selection.property == self.atom_drop_prop) self.readDrop();
            },
            SelectionRequest => self.serveSelection(ev.selreq),
            SelectionClear => {
                if (ev.selection.selection == self.atom_clipboard) self.clip_len = 0;
            },
            DestroyNotify => self.closed = true,
            else => {},
        }
    }

    /// 别人来要剪贴板内容：把文本写进对方指定的 property，再回一个 SelectionNotify。
    fn serveSelection(self: *Backend, rq: XSelectionRequestEvent) void {
        const dpy = self.dpy orelse return;
        var notify = XEvent{ .selection = .{
            .type = SelectionNotify,
            .serial = 0,
            .send_event = 0,
            .display = dpy,
            .requestor = rq.requestor,
            .selection = rq.selection,
            .target = rq.target,
            .property = 0,
            .time = rq.time,
        } };
        const prop: Atom = if (rq.property != 0) rq.property else rq.target;
        if (rq.target == self.atom_targets) {
            var targets = [_]Atom{ self.atom_utf8, XA_STRING, self.atom_targets };
            _ = XChangeProperty(dpy, rq.requestor, prop, XA_ATOM, 32, PropModeReplace, @ptrCast(&targets), targets.len);
            notify.selection.property = prop;
        } else if (rq.target == self.atom_utf8 or rq.target == XA_STRING) {
            _ = XChangeProperty(dpy, rq.requestor, prop, rq.target, 8, PropModeReplace, &self.clip_text, @intCast(self.clip_len));
            notify.selection.property = prop;
        }
        _ = XSendEvent(dpy, rq.requestor, 0, 0, &notify);
        _ = XFlush(dpy);
    }

    pub fn size(self: *Backend) t.Size {
        return .{ .w = @floatFromInt(self.px_w), .h = @floatFromInt(self.px_h) };
    }

    pub fn scale(_: *Backend) f32 {
        return 1;
    }

    pub fn idle(self: *Backend, ms: u32) void {
        const dpy = self.dpy orelse return;
        // 阻塞在 X 连接上，有事件立刻醒（空闲时几乎不占 CPU）
        var fds = [_]std.posix.pollfd{.{
            .fd = XConnectionNumber(dpy),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&fds, @intCast(ms)) catch 0;
    }

    pub fn now(_: *Backend) f64 {
        return nowMs() / 1000.0;
    }

    pub fn pixels(self: *Backend) []u8 {
        return self.buf;
    }

    pub fn saveSurface(self: *Backend, path: []const u8) !void {
        try bmpfile.saveBmp(path, self.buf, self.px_w, self.px_h);
    }

    pub fn drawTextLayer(self: *Backend, ui: *core.Context, layer: u8) void {
        if (!self.glyphs.ok or self.buf.len == 0) return;
        var i: usize = 0;
        while (i < ui.cmd_count) : (i += 1) {
            switch (ui.cmds[i]) {
                .text => |c| {
                    if (c.layer != layer) continue;
                    if (c.emoji) continue; // 彩色 emoji 需要 Xft/fontconfig
                    self.drawTextCmd(c);
                },
                else => {},
            }
        }
    }

    fn drawTextCmd(self: *Backend, c: core.TextCmd) void {
        const gl = self.glyphs;
        const gh: f32 = @floatFromInt(@as(u32, gl.ascent) + gl.descent);
        const k = if (gh > 0) @max(0.5, c.size / gh) else 1;
        const gw: f32 = @floatFromInt(gl.adv);
        var pen: f32 = c.rect.x;
        var idx: usize = 0;
        const clip = c.clip;
        while (idx < c.text.len) {
            const b = c.text[idx];
            if (b < 0x80) {
                idx += 1;
                if (b < GLYPH_FIRST or b > GLYPH_LAST) {
                    pen += gw * k;
                    continue;
                }
                self.blitGlyph(b - GLYPH_FIRST, pen, c.rect.y, k, c.color, clip);
                pen += gw * k;
            } else {
                // 非 ASCII：按 1 em 推进，不画字形（等 Xft）
                const step = utf8Len(b);
                idx += @min(step, c.text.len - idx);
                pen += c.size;
            }
        }
    }

    fn utf8Len(first: u8) usize {
        if (first & 0xE0 == 0xC0) return 2;
        if (first & 0xF0 == 0xE0) return 3;
        if (first & 0xF8 == 0xF0) return 4;
        return 1;
    }

    fn blitGlyph(self: *Backend, g: usize, x: f32, y: f32, k: f32, color: t.Color, clip: ?t.Rect) void {
        const gl = self.glyphs;
        const rows: usize = @as(usize, gl.ascent) + gl.descent;
        const dst_w: usize = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(gl.adv)) * k)));
        const dst_h: usize = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(rows)) * k)));
        const x0: i32 = @intFromFloat(@round(x));
        const y0: i32 = @intFromFloat(@round(y));
        var dy: usize = 0;
        while (dy < dst_h) : (dy += 1) {
            const py: i32 = y0 + @as(i32, @intCast(dy));
            if (py < 0 or py >= @as(i32, @intCast(self.px_h))) continue;
            const sy: usize = @min(rows - 1, dy * rows / dst_h);
            const bits = gl.bits[g][sy];
            var dx: usize = 0;
            while (dx < dst_w) : (dx += 1) {
                const px: i32 = x0 + @as(i32, @intCast(dx));
                if (px < 0 or px >= @as(i32, @intCast(self.px_w))) continue;
                if (clip) |r| {
                    const fx: f32 = @floatFromInt(px);
                    const fy: f32 = @floatFromInt(py);
                    if (fx < r.x or fy < r.y or fx >= r.x + r.w or fy >= r.y + r.h) continue;
                }
                const sx: usize = @min(GW - 1, dx * @as(usize, gl.adv) / dst_w);
                if ((bits >> @intCast(sx)) & 1 == 0) continue;
                const off = (@as(usize, @intCast(py)) * self.px_w + @as(usize, @intCast(px))) * 4;
                self.buf[off] = color.r;
                self.buf[off + 1] = color.g;
                self.buf[off + 2] = color.b;
                self.buf[off + 3] = 255;
            }
        }
    }

    pub fn present(self: *Backend) void {
        const dpy = self.dpy orelse return;
        const img = self.img orelse return;
        const n = @as(usize, self.px_w) * self.px_h;
        if (self.buf.len < n * 4 or self.xbuf.len < n) return;
        // BGRA 字节序 → X 的 0x00RRGGBB：换 R/B
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const off = i * 4;
            const r: u32 = self.buf[off];
            const g: u32 = self.buf[off + 1];
            const b: u32 = self.buf[off + 2];
            self.xbuf[i] = (r << 16) | (g << 8) | b;
        }
        _ = XPutImage(dpy, self.win, self.gc, img, 0, 0, 0, 0, self.px_w, self.px_h);
        _ = XFlush(dpy);
    }

    pub fn measure(self: *Backend, s: []const u8, size_px: f32, bold: bool) t.Size {
        _ = bold;
        const gl = self.glyphs;
        const units = if (gl.ok) @as(f32, @floatFromInt(gl.adv)) else size_px * 0.55;
        const per = if (gl.ok) size_px / @as(f32, @floatFromInt(@as(u32, gl.ascent) + gl.descent)) else 1;
        var w: f32 = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] < 0x80) {
                w += units * per;
                i += 1;
            } else {
                i += @min(utf8Len(s[i]), s.len - i);
                w += size_px;
            }
        }
        return .{ .w = w, .h = size_px * 1.35 };
    }

    /// 列出目录（`files.zig` 的默认数据源）。返回条目数或 -1。
    /// 0.17 的文件 API 都挂在 `std.Io.Dir` 上（`std.fs.cwd()` 已移除），用法与 `bmpfile.zig` 同口径。
    pub fn listDir(_: *Backend, path: []const u8, out: []t.FileEntry, names: []u8, hidden: bool) i32 {
        if (path.len == 0) return -1;
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return -1;
        defer dir.close(io);

        var it = dir.iterate();
        var count: i32 = 0;
        var used: usize = 0;
        while (it.next(io) catch null) |e| {
            if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
            if (!hidden and e.name.len > 0 and e.name[0] == '.') continue;
            if (count >= out.len) break;
            if (used + e.name.len > names.len) break;

            @memcpy(names[used .. used + e.name.len], e.name);
            var fsize: u64 = 0;
            var modified: i64 = 0;
            if (dir.statFile(io, e.name, .{})) |st| {
                fsize = st.size;
                modified = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
            } else |_| {}
            out[@intCast(count)] = .{
                .name = names[used .. used + e.name.len],
                .dir = e.kind == .directory,
                .size = fsize,
                .modified = modified,
            };
            used += e.name.len;
            count += 1;
        }
        return count;
    }

    /// 拖放源在报位置：回一个 `XdndStatus`（接受、动作为 copy）。
    fn xdndAccept(self: *Backend, cm: XClientMessageEvent) void {
        const dpy = self.dpy orelse return;
        const src: Window = @intCast(cm.data.l[0]);
        self.xdnd_src = src;
        var status = XEvent{ .client = .{
            .type = ClientMessage,
            .serial = 0,
            .send_event = 1,
            .display = dpy,
            .window = src,
            .message_type = self.atom_xdnd_status,
            .format = 32,
            .data = .{ .l = .{ @intCast(self.win), 1, 0, 0, @intCast(self.atom_xdnd_action_copy) } },
        } };
        _ = XSendEvent(dpy, src, 0, 0, &status);
        _ = XFlush(dpy);
    }

    /// 松手：把 `text/uri-list` 转成本窗口属性，`SelectionNotify` 里再解析。
    fn xdndDrop(self: *Backend, cm: XClientMessageEvent) void {
        const dpy = self.dpy orelse return;
        const src: Window = @intCast(cm.data.l[0]);
        self.xdnd_src = src;
        const when: c_ulong = @intCast(cm.data.l[2]);
        _ = XConvertSelection(dpy, self.atom_xdnd_selection, self.atom_uri_list, self.atom_drop_prop, self.win, when);
        _ = XFlush(dpy);
    }

    /// 读回 `text/uri-list` → 解析成路径表；给源窗口回 `XdndFinished`。
    fn readDrop(self: *Backend) void {
        const dpy = self.dpy orelse return;
        var actual_type: Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var after: c_ulong = 0;
        var data: ?[*]u8 = null;
        const rc = XGetWindowProperty(dpy, self.win, self.atom_drop_prop, 0, 8192, 1, 0, &actual_type, &actual_format, &nitems, &after, &data);
        var ok = false;
        if (rc == 0 and actual_type != 0) {
            if (data) |d| {
                parseUriList(d[0..@intCast(nitems)], &self.drops);
                ok = self.drops.n > 0;
            }
        }
        if (data) |d| _ = XFree(d);
        self.drop_active = self.drops.n;

        if (self.xdnd_src != 0) {
            var fin = XEvent{ .client = .{
                .type = ClientMessage,
                .serial = 0,
                .send_event = 1,
                .display = dpy,
                .window = self.xdnd_src,
                .message_type = self.atom_xdnd_finished,
                .format = 32,
                .data = .{ .l = .{ @intCast(self.win), if (ok) 1 else 0, @intCast(self.atom_xdnd_action_copy), 0, 0 } },
            } };
            _ = XSendEvent(dpy, self.xdnd_src, 0, 0, &fin);
            _ = XFlush(dpy);
        }
    }

    pub fn droppedFile(self: *Backend, i: usize) ?[]const u8 {
        if (i >= self.drops.n) return null;
        return self.drops.at(i);
    }

    pub fn getClipboard(self: *Backend, out: []u8) usize {
        if (out.len == 0) return 0;
        const dpy = self.dpy orelse return 0;
        // 自己就是 owner：不用往返，直接给本地副本
        if (self.clip_len > 0 and XGetSelectionOwner(dpy, self.atom_clipboard) == self.win) {
            const n = @min(self.clip_len, out.len);
            @memcpy(out[0..n], self.clip_text[0..n]);
            return n;
        }
        // 向别的客户端要：转成 UTF8_STRING 到自己的 property，再从事件里读回来
        _ = XConvertSelection(dpy, self.atom_clipboard, self.atom_utf8, self.atom_prop, self.win, 0);
        _ = XFlush(dpy);
        const deadline = nowMs() + 120.0;
        var ev: XEvent = undefined;
        while (nowMs() < deadline) {
            while (XPending(dpy) > 0) {
                if (XNextEvent(dpy, &ev) != 0) break;
                if (ev.type == SelectionNotify) {
                    const se = ev.selection;
                    if (se.property == 0) return 0; // owner 拒绝
                    var actual_type: Atom = 0;
                    var actual_format: c_int = 0;
                    var nitems: c_ulong = 0;
                    var after: c_ulong = 0;
                    var data: ?[*]u8 = null;
                    const rc = XGetWindowProperty(dpy, self.win, se.property, 0, @intCast(out.len), 1, 0, &actual_type, &actual_format, &nitems, &after, &data);
                    defer {
                        if (data) |d| _ = XFree(d);
                    }
                    if (rc != 0 or actual_type == 0) return 0;
                    if (data) |d| {
                        const n = @min(@as(usize, @intCast(nitems)), out.len);
                        @memcpy(out[0..n], d[0..n]);
                        return n;
                    }
                    return 0;
                }
                self.handleEvent(ev);
            }
            self.idle(4);
        }
        return 0;
    }

    pub fn setClipboard(self: *Backend, text: []const u8) void {
        const n = @min(text.len, self.clip_text.len);
        @memcpy(self.clip_text[0..n], text[0..n]);
        self.clip_len = n;
        if (self.dpy) |dpy| {
            _ = XSetSelectionOwner(dpy, self.atom_clipboard, self.win, 0);
            _ = XFlush(dpy);
        }
    }
};

// ------------------------------------------------------------------ 拖放路径表

/// XDND 一次最多收多少个文件、单个路径最长多少字节（与 Win32 的 `MAX_DROPS`/`DROP_PATH_MAX` 同口径）。
pub const MAX_DROPS = 4;
pub const DROP_PATH_MAX = 260;

pub const DropList = struct {
    paths: [MAX_DROPS][DROP_PATH_MAX]u8 = @splat(@splat(0)),
    lens: [MAX_DROPS]u16 = @splat(0),
    n: u8 = 0,

    pub fn at(self: *const DropList, i: usize) []const u8 {
        return self.paths[i][0..self.lens[i]];
    }

    fn push(self: *DropList, path: []const u8) void {
        if (self.n >= MAX_DROPS or path.len == 0) return;
        const take = @min(path.len, DROP_PATH_MAX);
        const i: usize = self.n;
        @memcpy(self.paths[i][0..take], path[0..take]);
        self.lens[i] = @intCast(take);
        self.n += 1;
    }
};

/// 解析 `text/uri-list`：每行一个 `file://` URI，`#` 开头是注释，支持 `%XX` 转义。
/// 不是 `file://` 的行直接跳过（浏览器拖过来的链接我们也不便处理）。
pub fn parseUriList(text: []const u8, list: *DropList) void {
    var rest = text;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        var line = rest[0..nl];
        rest = if (nl < rest.len) rest[nl + 1 ..] else rest[rest.len..];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0 or line[0] == '#') continue;
        const prefix = "file://";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var body = line[prefix.len..];
        // file:///path（空 host）或 file://localhost/path
        if (std.mem.startsWith(u8, body, "localhost")) body = body["localhost".len..];
        var decoded: [DROP_PATH_MAX]u8 = undefined;
        const n = percentDecode(body, decoded[0..]);
        if (n > 0) list.push(decoded[0..n]);
    }
}

/// `%XX` 解码（UTF-8 按字节处理；非法转义原样保留）。
fn percentDecode(src: []const u8, dst: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < dst.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            const hi = hexNibble(src[i + 1]);
            const lo = hexNibble(src[i + 2]);
            if (hi != null and lo != null) {
                dst[o] = (hi.? << 4) | lo.?;
                o += 1;
                i += 3;
                continue;
            }
        }
        dst[o] = src[i];
        o += 1;
        i += 1;
    }
    return o;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn mapKeysym(sym: c_ulong) ?t.Key {    return switch (sym) {
        0xff08 => .backspace,
        0xff09 => .tab,
        0xff0d, 0xff8d => .enter,
        0xff1b => .escape,
        0xff50 => .home,
        0xff51 => .left,
        0xff52 => .up,
        0xff53 => .right,
        0xff54 => .down,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xff57 => .end,
        0xff63 => .insert,
        0xffff => .delete,
        0x20 => .space,
        0x30...0x39 => @fromBackingInt(@intCast(@as(u8, @intCast(sym)))), // 0..9
        0x61...0x7a => @fromBackingInt(@intCast(@as(u8, @intCast(sym - 0x20)))), // a-z → A-Z
        0x3b => .semicolon,
        0x3d => .equal,
        0x2c => .comma,
        0x2d => .minus,
        0x2e => .period,
        0x2f => .slash,
        0x60 => .tilde,
        0x5b => .bracket_left,
        0x5c => .backslash,
        0x5d => .bracket_right,
        0x27 => .quote,
        0xffbe...0xffc9 => @fromBackingInt(@intCast(@as(u8, @intCast(112 + (sym - 0xffbe))))),
        else => null,
    };
}
