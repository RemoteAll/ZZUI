//! ZZUI 共享基础类型：平台层与核心层共用，不含任何平台 API。
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn hex(v: u32, alpha: u8) Color {
        return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v), .a = alpha };
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }

    pub fn inset(self: Rect, d: f32) Rect {
        const w = self.w - d * 2;
        const h = self.h - d * 2;
        return .{ .x = self.x + d, .y = self.y + d, .w = if (w > 0) w else 0, .h = if (h > 0) h else 0 };
    }
};

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,
};

pub const Direction = enum { row, column };

pub const Variant = enum { primary, secondary, ghost };

/// 每帧输入快照。`click` 只在「按下并在同一控件内抬起」的那一帧出现在这里。
pub const Input = struct {
    mouse: Point = .{},
    down: bool = false,
    click: ?Point = null,
    quit: bool = false,
};
