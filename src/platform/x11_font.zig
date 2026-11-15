//! Linux 侧 TrueType 文本：**运行时** dlopen `libfreetype.so.6`，不引入构建期依赖。
//!
//! 为什么要这一步：X11 后端原来只把服务端 `fixed` 字体的 ASCII 字形读成 1-bit 图集，
//! 非 ASCII（中文/日文/俄文…）一律「按 1 em 推进但不画字形」——界面上的中文是**空白**。
//! 而 Xft/fontconfig 的开发头文件在多数机器上要 `apt install libxft-dev`，
//! 但 `libfreetype.so.6` 是桌面上几乎必装（fontconfig 依赖它）。
//!
//! 所以：**头文件自己声明、库运行时加载**。拿不到库 / 拿不到字体文件时 `Font.open()` 返回 null，
//! 调用方退回原来的核心字体 ASCII 路径（行为不变，绝不假装成功）。
//!
//! 结构体布局按 FreeType 2.x 的**公开 ABI**（`FT_FaceRec` / `FT_GlyphSlotRec` / `FT_Bitmap`），
//! 这几个结构自 2.0 起没动过；只声明用到的字段前缀，后面没声明的部分不读。
const std = @import("std");

// ---------------------------------------------------------------- FreeType 公开类型
const FT_Long = c_long;
const FT_Pos = c_long;
const FT_Fixed = c_long;
const FT_UInt = c_uint;
const FT_Int = c_int;
const FT_Short = c_short;
const FT_UShort = c_ushort;
const FT_Error = c_int;
const FT_ULong = c_ulong;

const FT_LOAD_RENDER: i32 = 4;
const FT_LOAD_TARGET_NORMAL: i32 = 0;

const Generic = extern struct {
    data: ?*anyopaque = null,
    finalizer: ?*anyopaque = null,
};

const BBox = extern struct {
    xMin: FT_Pos = 0,
    yMin: FT_Pos = 0,
    xMax: FT_Pos = 0,
    yMax: FT_Pos = 0,
};

const Bitmap = extern struct {
    rows: c_uint = 0,
    width: c_uint = 0,
    pitch: c_int = 0,
    buffer: ?[*]u8 = null,
    num_grays: c_short = 0,
    pixel_mode: u8 = 0,
    palette_mode: u8 = 0,
    palette: ?*anyopaque = null,
};

const Vector = extern struct {
    x: FT_Pos = 0,
    y: FT_Pos = 0,
};

const GlyphMetrics = extern struct {
    width: FT_Pos = 0,
    height: FT_Pos = 0,
    horiBearingX: FT_Pos = 0,
    horiBearingY: FT_Pos = 0,
    horiAdvance: FT_Pos = 0,
    vertBearingX: FT_Pos = 0,
    vertBearingY: FT_Pos = 0,
    vertAdvance: FT_Pos = 0,
};

/// `FT_GlyphSlotRec` 的前缀（只声明到 `bitmap_top`，后面是 outline 等，用不到）。
const GlyphSlot = extern struct {
    library: ?*anyopaque = null,
    face: ?*anyopaque = null,
    next: ?*anyopaque = null,
    glyph_index: FT_UInt = 0,
    generic: Generic = .{},
    metrics: GlyphMetrics = .{},
    linearHoriAdvance: FT_Fixed = 0,
    linearVertAdvance: FT_Fixed = 0,
    advance: Vector = .{},
    format: c_ulong = 0,
    bitmap: Bitmap = .{},
    bitmap_left: FT_Int = 0,
    bitmap_top: FT_Int = 0,
};

/// `FT_FaceRec` 的前缀（声明到 `charmap`，后面没有了）。
const FaceRec = extern struct {
    num_faces: FT_Long = 0,
    face_index: FT_Long = 0,
    face_flags: FT_Long = 0,
    style_flags: FT_Long = 0,
    num_glyphs: FT_Long = 0,
    family_name: ?[*:0]u8 = null,
    style_name: ?[*:0]u8 = null,
    num_fixed_sizes: FT_Int = 0,
    available_sizes: ?*anyopaque = null,
    num_charmaps: FT_Int = 0,
    charmaps: ?*anyopaque = null,
    generic: Generic = .{},
    bbox: BBox = .{},
    units_per_EM: FT_UShort = 0,
    ascender: FT_Short = 0,
    descender: FT_Short = 0,
    height: FT_Short = 0,
    max_advance_width: FT_Short = 0,
    max_advance_height: FT_Short = 0,
    underline_position: FT_Short = 0,
    underline_thickness: FT_Short = 0,
    glyph: ?*GlyphSlot = null,
    size: ?*anyopaque = null,
    charmap: ?*anyopaque = null,
};

const FnInit = *const fn (*?*anyopaque) callconv(.c) FT_Error;
const FnNewFace = *const fn (?*anyopaque, [*:0]const u8, FT_Long, *?*FaceRec) callconv(.c) FT_Error;
const FnSetPixelSizes = *const fn (?*FaceRec, FT_UInt, FT_UInt) callconv(.c) FT_Error;
const FnLoadChar = *const fn (?*FaceRec, FT_ULong, i32) callconv(.c) FT_Error;
const FnGetCharIndex = *const fn (?*FaceRec, FT_ULong) callconv(.c) FT_UInt;
const FnDoneFace = *const fn (?*FaceRec) callconv(.c) void;
const FnDoneLib = *const fn (?*anyopaque) callconv(.c) void;

// ---------------------------------------------------------------- 字形缓存

/// 每个字形格的边长（像素）。渲染 20 px 时汉字最多 20×20，留 4 px 余量。
pub const CELL = 24;
/// 槽数（**必须是 2 的幂**：用 `cp & (MAX_GLYPHS-1)` 直接映射）。
pub const MAX_GLYPHS = 256;
/// 统一按这个像素尺寸光栅，画的时候按 `size / RENDER_PX` 缩放（与 1-bit 图集同口径）。
pub const RENDER_PX = 20;

pub const Glyph = struct {
    /// 这个槽里存的是哪个码位（0 = 空槽）。
    cp: u21 = 0,
    ok: bool = false,
    w: u8 = 0,
    h: u8 = 0,
    left: i8 = 0,
    top: i8 = 0,
    /// 步进（渲染像素单位）。
    adv: f32 = 0,
};

/// 候选字体文件（按顺序试，第一个能 `FT_New_Face` 成功的就用）。
/// 环境变量 `ZZUI_FONT` 优先（想指定中文字体时就指过去，例如 NotoSansCJK / wqy-microhei）。
const candidates = [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
};

pub const Font = struct {
    lib: std.DynLib,
    handle: ?*anyopaque,
    face: *FaceRec,
    pixels: []u8,
    /// 函数指针存下来：每个字形都 `dlsym` 一次太亏。
    load_char: FnLoadChar,
    get_index: FnGetCharIndex,
    slots: [MAX_GLYPHS]Glyph = @splat(.{}),
    /// 字体设计单位的 ascent / units_per_EM（用于算基线）。
    ascent_ratio: f32 = 0.8,
    /// 字体族名（调试/日志用；指向 font 内部字符串，不释放）。
    family: []const u8 = "",

    /// 打开库 + 找一款字体 + 固定到 `RENDER_PX`。任一步失败返回 null（调用方退回 ASCII 路径）。
    pub fn open() ?Font {
        var lib = std.DynLib.open("libfreetype.so.6") catch return null;
        const init = lib.lookup(FnInit, "FT_Init_FreeType") orelse return null;
        const new_face = lib.lookup(FnNewFace, "FT_New_Face") orelse return null;
        const set_size = lib.lookup(FnSetPixelSizes, "FT_Set_Pixel_Sizes") orelse return null;
        const load_char = lib.lookup(FnLoadChar, "FT_Load_Char") orelse return null;
        const get_index = lib.lookup(FnGetCharIndex, "FT_Get_Char_Index") orelse return null;

        var handle: ?*anyopaque = null;
        if (init(&handle) != 0) return null;

        var face: ?*FaceRec = null;
        // 环境变量优先：先试它，失败了再走内置列表
        if (envFontPath()) |p| {
            if (new_face(handle, p, 0, &face) != 0) face = null;
        }
        if (face == null) {
            for (candidates) |path| {
                var buf: [512]u8 = undefined;
                if (path.len >= buf.len) continue;
                @memcpy(buf[0..path.len], path);
                buf[path.len] = 0;
                if (new_face(handle, buf[0..path.len :0], 0, &face) == 0) break;
                face = null;
            }
        }
        const f = face orelse return null;
        if (set_size(f, 0, RENDER_PX) != 0) return null;

        const alloc = std.heap.page_allocator;
        const px = alloc.alloc(u8, MAX_GLYPHS * CELL * CELL) catch return null;
        @memset(px, 0);

        var self = Font{
            .lib = lib,
            .handle = handle,
            .face = f,
            .pixels = px,
            .load_char = load_char,
            .get_index = get_index,
        };
        const upem: f32 = @floatFromInt(@max(f.units_per_EM, 1));
        self.ascent_ratio = @as(f32, @floatFromInt(f.ascender)) / upem;
        if (f.family_name) |n| self.family = std.mem.span(n);
        return self;
    }

    pub fn close(self: *Font) void {
        if (self.lib.lookup(FnDoneFace, "FT_Done_Face")) |done| done(self.face);
        if (self.lib.lookup(FnDoneLib, "FT_Done_FreeType")) |done| done(self.handle);
        if (self.pixels.len > 0) std.heap.page_allocator.free(self.pixels);
        self.pixels = &.{};
    }

    /// `size` 像素下的基线偏移（从文本矩形顶部量）。
    pub fn ascent(self: *const Font, size: f32) f32 {
        return size * self.ascent_ratio;
    }

    fn cell(self: *Font, slot: usize) []u8 {
        return self.pixels[slot * CELL * CELL ..][0 .. CELL * CELL];
    }

    /// 取（必要时光栅化）某码位的字形。缺字形时返回一个 `ok == false` 的记录（步进按半个 em）。
    pub fn glyph(self: *Font, cp: u21) *Glyph {
        const slot = @as(usize, cp) & (MAX_GLYPHS - 1);
        const g = &self.slots[slot];
        if (g.cp == cp and g.ok) return g;
        g.* = .{ .cp = cp, .adv = @as(f32, RENDER_PX) * 0.5 };
        if (cp == 0) return g;
        const idx = self.get_index(self.face, cp);
        if (idx == 0) return g; // 字体里没有这个字形
        if (self.load_char(self.face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) return g;
        const fg = self.face.glyph orelse return g;
        const bm = fg.bitmap;
        const adv26: f32 = @floatFromInt(fg.advance.x);
        g.adv = adv26 / 64.0;
        if (bm.buffer == null or bm.width == 0 or bm.rows == 0) {
            g.ok = true; // 空白字形（空格）：有步进就行
            return g;
        }
        const w: usize = @min(@as(usize, bm.width), CELL);
        const h: usize = @min(@as(usize, bm.rows), CELL);
        const src = bm.buffer.?;
        const pitch: usize = if (bm.pitch < 0) 0 else @intCast(bm.pitch);
        const dst = self.cell(slot);
        @memset(dst, 0);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            @memcpy(dst[y * CELL .. y * CELL + w], src[y * pitch .. y * pitch + w]);
        }
        g.w = @intCast(w);
        g.h = @intCast(h);
        g.left = @intCast(@max(@min(fg.bitmap_left, 127), -128));
        g.top = @intCast(@max(@min(fg.bitmap_top, 127), -128));
        g.ok = true;
        return g;
    }

    /// 这段 UTF-8 在 `size` 像素下的宽度。
    pub fn measure(self: *Font, s: []const u8, size: f32) f32 {
        const k = size / @as(f32, RENDER_PX);
        var w: f32 = 0;
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const e = @min(i + n, s.len);
            const cp = std.unicode.utf8Decode(s[i..e]) catch 0xFFFD;
            w += self.glyph(cp).adv * k;
            i = e;
        }
        return w;
    }

    /// 把一段文本画进 BGRA 缓冲（带 alpha 混合）。`(x, baseline_y)` 是基线起点。
    pub fn draw(
        self: *Font,
        buf: []u8,
        buf_w: u32,
        buf_h: u32,
        s: []const u8,
        x: f32,
        baseline_y: f32,
        size: f32,
        color: @import("../types.zig").Color,
        clip: ?@import("../types.zig").Rect,
    ) void {
        const k = size / @as(f32, RENDER_PX);
        var pen = x;
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const e = @min(i + n, s.len);
            const cp = std.unicode.utf8Decode(s[i..e]) catch 0xFFFD;
            const g = self.glyph(cp);
            if (g.ok and g.w > 0) {
                const slot = @as(usize, cp) & (MAX_GLYPHS - 1);
                self.blit(self.cell(slot), g, buf, buf_w, buf_h, pen, baseline_y, k, color, clip);
            }
            pen += g.adv * k;
            i = e;
        }
    }

    fn blit(
        self: *Font,
        src: []const u8,
        g: *const Glyph,
        buf: []u8,
        buf_w: u32,
        buf_h: u32,
        pen_x: f32,
        baseline_y: f32,
        k: f32,
        color: @import("../types.zig").Color,
        clip: ?@import("../types.zig").Rect,
    ) void {
        _ = self;
        const sw: usize = g.w;
        const sh: usize = g.h;
        if (sw == 0 or sh == 0) return;
        const dst_w: usize = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(sw)) * k)));
        const dst_h: usize = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(sh)) * k)));
        const x0: i32 = @intFromFloat(@round(pen_x + @as(f32, @floatFromInt(g.left)) * k));
        const y0: i32 = @intFromFloat(@round(baseline_y - @as(f32, @floatFromInt(g.top)) * k));
        var dy: usize = 0;
        while (dy < dst_h) : (dy += 1) {
            const py: i32 = y0 + @as(i32, @intCast(dy));
            if (py < 0 or py >= @as(i32, @intCast(buf_h))) continue;
            const sy: usize = @min(sh - 1, dy * sh / dst_h);
            var dx: usize = 0;
            while (dx < dst_w) : (dx += 1) {
                const px: i32 = x0 + @as(i32, @intCast(dx));
                if (px < 0 or px >= @as(i32, @intCast(buf_w))) continue;
                if (clip) |r| {
                    const fx: f32 = @floatFromInt(px);
                    const fy: f32 = @floatFromInt(py);
                    if (fx < r.x or fy < r.y or fx >= r.x + r.w or fy >= r.y + r.h) continue;
                }
                const sx: usize = @min(sw - 1, dx * sw / dst_w);
                const a: u32 = src[sy * CELL + sx];
                if (a == 0) continue;
                const off = (@as(usize, @intCast(py)) * buf_w + @as(usize, @intCast(px))) * 4;
                const ia: u32 = 255 - a;
                buf[off] = @intCast((@as(u32, color.r) * a + @as(u32, buf[off]) * ia) / 255);
                buf[off + 1] = @intCast((@as(u32, color.g) * a + @as(u32, buf[off + 1]) * ia) / 255);
                buf[off + 2] = @intCast((@as(u32, color.b) * a + @as(u32, buf[off + 2]) * ia) / 255);
                buf[off + 3] = 255;
            }
        }
    }
};

/// 读 `ZZUI_FONT`（要 null 结尾的 C 串：用静态缓冲）。
/// 0.17 的 `std.posix` 里已经没有 `getenv` 了，直接用 libc 的（Linux 上本来就链了 libc）。
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

var g_env_buf: [512]u8 = @splat(0);

fn envFontPath() ?[*:0]const u8 {
    const raw = getenv("ZZUI_FONT") orelse return null;
    const v = std.mem.span(raw);
    if (v.len == 0 or v.len >= g_env_buf.len) return null;
    @memcpy(g_env_buf[0..v.len], v);
    g_env_buf[v.len] = 0;
    return g_env_buf[0..v.len :0];
}
