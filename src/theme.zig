//! 主题令牌（对应 CUI 的 theme tokens：中性表面、一个强调色、细边框）。
//!
//! **浅色 / 深色两套调色板 + 运行时切换**（对位 CUI 的 `cui_set_theme`；过渡动画不做）。
//!
//! **为什么令牌是 `var` 而不是 `const`**：131 个控件全都直接写 `theme.bg` 这类令牌，
//! 改成 `theme.cur().bg` 要动几百处调用点（还容易漏）。用模块级 `var` 让调用点**零改动**
//! 就能切主题；代价是令牌从编译期常量变成运行时加载（体积实测见 `docs/决策记录.md`）。
//! 颜色**只在 `setMode` 里整体替换**，不会出现半套配色。
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
pub fn setMode(m: Mode) void {
    const p = palette(m);
    // Zig 0.17 的反射：`field_names` 与 `field_types` 平行数组（0.14 的 `fields` 已移除）
    inline for (@typeInfo(Palette).@"struct".field_names) |name| {
        @field(@This(), name) = @field(p, name);
    }
    mode = m;
}

/// 浅 ↔ 深。
pub fn toggle() void {
    setMode(if (mode == .light) .dark else .light);
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
