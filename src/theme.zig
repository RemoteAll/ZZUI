//! 主题令牌（对应 CUI 的 theme tokens：中性表面、一个强调色、细边框）。
//!
//! **浅色 / 深色两套调色板 + 运行时切换 + 过渡动画**（对位 CUI 的 `cui_set_theme`：
//! `setMode` 瞬切，`animateTo` / `step` 逐帧插值；插值走 **OKLCH 感知空间**，不会中途发灰）。
//!
//! **为什么令牌是 `var` 而不是 `const`**：131 个控件全都直接写 `theme.bg` 这类令牌，
//! 改成 `theme.cur().bg` 要动几百处调用点（还容易漏）。用模块级 `var` 让调用点**零改动**
//! 就能切主题；代价是令牌从编译期常量变成运行时加载（体积实测见 `docs/决策记录.md`）。
//! 颜色**只在 `setMode` / 动画推进时整体替换**，不会出现半套配色。
const std = @import("std");
const t = @import("types.zig");

pub const Mode = enum { light, dark };

/// 一套调色板。字段名必须与下面的模块级令牌**一一对应**（`setMode` 按名字批量赋值）。
pub const Palette = struct {
    bg: t.Color,
    text: t.Color,
    secondary: t.Color,
    surface: t.Color,
    border: t.Color,
    accent: t.Color,
    accent_active: t.Color,
    accent_text: t.Color,
    track: t.Color,
    hover_overlay: t.Color,
    /// 浅强调底（徽标、选中行、分段控件激活态）。
    accent_bg: t.Color,
    /// 比页面底再亮一档（菜单栏、表头、状态栏、停靠底板）。
    raised: t.Color,
    /// 斑马行。
    row_alt: t.Color,
    /// 细分隔线（比 border 更轻）。
    hair: t.Color,
    /// 反色浮层（toast / tooltip）：背景与其上的文字**成对**存在，不能拿 text 当底。
    overlay_bg: t.Color,
    overlay_fg: t.Color,
    success: t.Color,
    success_bg: t.Color,
    warn: t.Color,
    warn_bg: t.Color,
    danger: t.Color,
    danger_bg: t.Color,
};

pub const light = Palette{
    .bg = t.Color.hex(0xFFFFFF, 255),
    .text = t.Color.hex(0x1F2328, 255),
    .secondary = t.Color.hex(0x6B7280, 255),
    .surface = t.Color.hex(0xF3F4F6, 255),
    .border = t.Color.hex(0xD0D7DE, 255),
    .accent = t.Color.hex(0x2563EB, 255),
    .accent_active = t.Color.hex(0x1D4ED8, 255),
    .accent_text = t.Color.hex(0xFFFFFF, 255),
    .track = t.Color.hex(0xD9DEE5, 255),
    .hover_overlay = t.Color.hex(0x000000, 16),
    .accent_bg = t.Color.hex(0xE8EFFD, 255),
    .raised = t.Color.hex(0xF7F8FA, 255),
    .row_alt = t.Color.hex(0xFAFBFC, 255),
    .hair = t.Color.hex(0xEDF0F3, 255),
    .overlay_bg = t.Color.hex(0x1F2328, 255),
    .overlay_fg = t.Color.hex(0xFFFFFF, 255),
    .success = t.Color.hex(0x15803D, 255),
    .success_bg = t.Color.hex(0xE8F6EC, 255),
    .warn = t.Color.hex(0xB45309, 255),
    .warn_bg = t.Color.hex(0xFDF3E0, 255),
    .danger = t.Color.hex(0xB91C1C, 255),
    .danger_bg = t.Color.hex(0xFDECEC, 255),
};

/// 深色：中性偏蓝的暗底 + 提亮一档的强调色（暗底上原来的 #2563EB 对比度不够）。
pub const dark = Palette{
    .bg = t.Color.hex(0x15171A, 255),
    .text = t.Color.hex(0xE6E8EB, 255),
    .secondary = t.Color.hex(0x9BA3AE, 255),
    .surface = t.Color.hex(0x1E2227, 255),
    .border = t.Color.hex(0x2E343B, 255),
    .accent = t.Color.hex(0x3B82F6, 255),
    .accent_active = t.Color.hex(0x2563EB, 255),
    .accent_text = t.Color.hex(0xFFFFFF, 255),
    .track = t.Color.hex(0x2A3037, 255),
    .hover_overlay = t.Color.hex(0xFFFFFF, 18),
    .accent_bg = t.Color.hex(0x1E2A44, 255),
    .raised = t.Color.hex(0x1B1F24, 255),
    .row_alt = t.Color.hex(0x191D22, 255),
    .hair = t.Color.hex(0x262C33, 255),
    .overlay_bg = t.Color.hex(0x2A3037, 255),
    .overlay_fg = t.Color.hex(0xE6E8EB, 255),
    .success = t.Color.hex(0x3FB950, 255),
    .success_bg = t.Color.hex(0x12301C, 255),
    .warn = t.Color.hex(0xD29922, 255),
    .warn_bg = t.Color.hex(0x2E2413, 255),
    .danger = t.Color.hex(0xF85149, 255),
    .danger_bg = t.Color.hex(0x3A1A1C, 255),
};

// ---- 运行时令牌（调用点直接写 `theme.bg`，不需要知道当前模式）
pub var bg = light.bg;
pub var text = light.text;
pub var secondary = light.secondary;
pub var surface = light.surface;
pub var border = light.border;
pub var accent = light.accent;
pub var accent_active = light.accent_active;
pub var accent_text = light.accent_text;
pub var track = light.track;
pub var hover_overlay = light.hover_overlay;
pub var accent_bg = light.accent_bg;
pub var raised = light.raised;
pub var row_alt = light.row_alt;
pub var hair = light.hair;
pub var overlay_bg = light.overlay_bg;
pub var overlay_fg = light.overlay_fg;
pub var success = light.success;
pub var success_bg = light.success_bg;
pub var warn = light.warn;
pub var warn_bg = light.warn_bg;
pub var danger = light.danger;
pub var danger_bg = light.danger_bg;

/// 当前模式（默认浅色；改动只走 `setMode` / `toggle`）。
pub var mode: Mode = .light;

/// 取某套调色板（不改当前状态，供「预览另一套配色」用）。
pub fn palette(m: Mode) Palette {
    return switch (m) {
        .light => light,
        .dark => dark,
    };
}

/// 切换（或显式设置）主题：**整包替换**，不会出现半套配色。
/// 若动画正在跑，`setMode` 会**立刻收尾**（跳到目标色），不做插值。
pub fn setMode(m: Mode) void {
    const p = palette(m);
    // Zig 0.17 的反射：`field_names` 与 `field_types` 平行数组（0.14 的 `fields` 已移除）
    inline for (@typeInfo(Palette).@"struct".field_names) |name| {
        @field(@This(), name) = @field(p, name);
    }
    mode = m;
    anim_t = 1;
}

/// 浅 ↔ 深。
pub fn toggle() void {
    setMode(if (mode == .light) .dark else .light);
}

// ------------------------------------------------------------------ 主题过渡动画
//
// 对位 CUI 的「主题切换过渡」：**逐帧把 22 个令牌从当前值混到目标调色板**。
// 由 `App.next` 每帧调 `step(dt)`（令牌是 `var`，控件每帧现读，所以只要令牌变了画面就跟着变）。
// 注意：`setAccent` 改的 accent 系列会被过渡覆盖回目标调色板的 accent —— 要保留自定义强调色时，
// 过渡结束后再调一次 `setAccent`（文档里写明，不做隐式记忆）。

var anim_from: Palette = light;
var anim_to: Palette = light;
var anim_t: f32 = 1;
var anim_dur: f32 = 0.18;

/// 当前 22 个令牌（拷出来当过渡起点）。
fn currentPalette() Palette {
    var p: Palette = light;
    inline for (@typeInfo(Palette).@"struct".field_names) |name| {
        @field(p, name) = @field(@This(), name);
    }
    return p;
}

/// 四通道插值（含 alpha）；`mix` 那道接口会把 alpha 固定成 255，过渡不能那么干。
fn mixRgba(a: t.Color, b: t.Color, k: f32) t.Color {
    // 走 OKLCH：深浅互切时中间帧不发灰（实测对比见 docs/决策记录.md）
    return mixOklch(a, b, k);
}

fn applyMix(k: f32) void {
    inline for (@typeInfo(Palette).@"struct".field_names) |name| {
        @field(@This(), name) = mixRgba(@field(anim_from, name), @field(anim_to, name), k);
    }
}

fn smooth(k: f32) f32 {
    // smoothstep：两端慢、中间快，比线性更像原生切换
    const q = @min(@max(k, 0), 1);
    return q * q * (3 - 2 * q);
}

/// 带过渡地切到 `m`（`seconds <= 0` 用默认 0.18s）。主题模式**立刻**记成目标，颜色逐帧混过去。
pub fn animateTo(m: Mode, seconds: f32) void {
    if (m == mode and anim_t >= 1) return;
    anim_from = currentPalette();
    anim_to = palette(m);
    mode = m;
    anim_dur = if (seconds > 0) seconds else 0.18;
    anim_t = 0;
    applyMix(0);
}

/// 带过渡地浅 ↔ 深。
pub fn toggleAnimated(seconds: f32) void {
    animateTo(if (mode == .light) .dark else .light, seconds);
}

/// 推进过渡；返回是否还在动（调用方据此决定要不要继续出帧）。
pub fn step(dt: f32) bool {
    if (anim_t >= 1) return false;
    anim_t = @min(1, anim_t + @max(dt, 0) / anim_dur);
    applyMix(smooth(anim_t));
    return anim_t < 1;
}

/// 是否正在过渡。
pub fn isAnimating() bool {
    return anim_t < 1;
}

pub fn isDark() bool {
    return mode == .dark;
}

/// 改透明度（保留 RGB）：叠加层、面积填充这类需要半透明的地方用。
pub fn withAlpha(c: t.Color, a: u8) t.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

/// 两色按 `k`（0 = a，1 = b）混合，alpha 取 255。
pub fn mix(a: t.Color, b: t.Color, k: f32) t.Color {
    const q = @min(@max(k, 0), 1);
    const ar: f32 = @floatFromInt(a.r);
    const ag: f32 = @floatFromInt(a.g);
    const ab: f32 = @floatFromInt(a.b);
    const br: f32 = @floatFromInt(b.r);
    const bgg: f32 = @floatFromInt(b.g);
    const bb: f32 = @floatFromInt(b.b);
    return .{
        .r = @intFromFloat(ar * (1 - q) + br * q),
        .g = @intFromFloat(ag * (1 - q) + bgg * q),
        .b = @intFromFloat(ab * (1 - q) + bb * q),
        .a = 255,
    };
}

// ------------------------------------------------------------------ OKLCH 感知色彩空间
//
// 对位 CUI 的 OKLCH 支持。用途有两个：
// 1) `mixOklch` 做**感知均匀**的两色插值（红 → 蓝经过紫，而不是 sRGB 直线上的发灰褐）；
// 2) 主题过渡用它，深浅互切时中间帧不发"脏"。
// 精度：sRGB u8 往返误差 ≤ 1（标准矩阵 + sRGB 传输函数，越界只做裁剪，不做色域映射）。

pub const Oklch = struct { l: f32 = 0, c: f32 = 0, h: f32 = 0, a: u8 = 255 };

const tau: f32 = 6.2831855;

fn srgbToLinear(v: u8) f32 {
    const s = @as(f32, @floatFromInt(v)) / 255.0;
    return if (s <= 0.04045) s / 12.92 else std.math.pow(f32, (s + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(v: f32) u8 {
    const q = @min(@max(v, 0), 1);
    const s = if (q <= 0.0031308) q * 12.92 else 1.055 * std.math.pow(f32, q, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(@min(@max(s, 0), 1) * 255));
}

/// sRGB → OKLCH（`h` 归一到 0..1，与 `colorpicker` 的 HSV 口径一致）。
pub fn toOklch(c: t.Color) Oklch {
    const r = srgbToLinear(c.r);
    const g = srgbToLinear(c.g);
    const b = srgbToLinear(c.b);

    const l0 = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m0 = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s0 = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    const l_ = std.math.cbrt(l0);
    const m_ = std.math.cbrt(m0);
    const s_ = std.math.cbrt(s0);

    const ok_l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    const ok_a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    const ok_b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

    const chroma = @sqrt(ok_a * ok_a + ok_b * ok_b);
    var hue = std.math.atan2(ok_b, ok_a) / tau;
    if (hue < 0) hue += 1;
    // 极小色度（灰阶）的色相没有意义，归一成 0，免得插值里出现随机色相
    if (chroma < 0.0005) hue = 0;
    return .{ .l = ok_l, .c = chroma, .h = hue, .a = c.a };
}

/// OKLCH → sRGB（越界通道裁剪到 0..255）。
pub fn fromOklch(o: Oklch) t.Color {
    const ang = o.h * tau;
    const ok_a = o.c * @cos(ang);
    const ok_b = o.c * @sin(ang);

    const l_ = o.l + 0.3963377774 * ok_a + 0.2158037573 * ok_b;
    const m_ = o.l - 0.1055613458 * ok_a - 0.0638541728 * ok_b;
    const s_ = o.l - 0.0894841775 * ok_a - 1.2914855480 * ok_b;

    const l0 = l_ * l_ * l_;
    const m0 = m_ * m_ * m_;
    const s0 = s_ * s_ * s_;

    const r = 4.0767416621 * l0 - 3.3077115913 * m0 + 0.2309699292 * s0;
    const g = -1.2684380046 * l0 + 2.6097574011 * m0 - 0.3413193965 * s0;
    const b = -0.0041960863 * l0 - 0.7034186147 * m0 + 1.7076147010 * s0;

    return .{ .r = linearToSrgb(r), .g = linearToSrgb(g), .b = linearToSrgb(b), .a = o.a };
}

/// 感知均匀混色：明度/彩度线性插值，色相走**最短弧**，alpha 线性。
pub fn mixOklch(a: t.Color, b: t.Color, k: f32) t.Color {
    const q = @min(@max(k, 0), 1);
    const x = toOklch(a);
    const y = toOklch(b);
    var dh = y.h - x.h;
    if (dh > 0.5) dh -= 1 else if (dh < -0.5) dh += 1;
    const al: f32 = @floatFromInt(a.a);
    const bl: f32 = @floatFromInt(b.a);
    return fromOklch(.{
        .l = x.l + (y.l - x.l) * q,
        .c = x.c + (y.c - x.c) * q,
        .h = @mod(x.h + dh * q, 1.0),
        .a = @intFromFloat(@round(al + (bl - al) * q)),
    });
}

/// 换强调色（accent / accent_active / accent_text / accent_bg 一起算）。
/// 注意：`setMode` 会整包重置令牌，切换主题后要重设。
pub fn setAccent(c: t.Color) void {
    accent = c;
    accent_active = mix(c, t.Color.hex(0x000000, 255), 0.18);
    const luma = (0.2126 * @as(f32, @floatFromInt(c.r)) + 0.7152 * @as(f32, @floatFromInt(c.g)) + 0.0722 * @as(f32, @floatFromInt(c.b))) / 255.0;
    accent_text = if (luma > 0.6) t.Color.hex(0x111111, 255) else t.Color.hex(0xffffff, 255);
    accent_bg = withAlpha(c, if (isDark()) 48 else 32);
}

// ---- 与配色无关的尺寸令牌（保持 `const`：编译期常量更省）
pub const radius_control: f32 = 8;
pub const radius_pill: f32 = 999;

pub const font_body: f32 = 14;
pub const font_heading: f32 = 24;
pub const font_small: f32 = 12;
