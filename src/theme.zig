//! 主题令牌（对应 CUI 的 theme tokens：中性表面、一个强调色、细边框）。
//! 里程碑 1 只有浅色；深色与过渡在后续里程碑补齐。
const t = @import("types.zig");

pub const bg = t.Color.hex(0xFFFFFF, 255);
pub const text = t.Color.hex(0x1F2328, 255);
pub const secondary = t.Color.hex(0x6B7280, 255);
pub const surface = t.Color.hex(0xF3F4F6, 255);
pub const border = t.Color.hex(0xD0D7DE, 255);
pub const accent = t.Color.hex(0x2563EB, 255);
pub const accent_active = t.Color.hex(0x1D4ED8, 255);
pub const accent_text = t.Color.hex(0xFFFFFF, 255);
pub const track = t.Color.hex(0xD9DEE5, 255);
pub const hover_overlay = t.Color.hex(0x000000, 16);

pub const radius_control: f32 = 8;
pub const radius_pill: f32 = 999;

pub const font_body: f32 = 14;
pub const font_heading: f32 = 24;
pub const font_small: f32 = 12;
