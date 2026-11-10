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

/// 与 Win32 虚拟键码对齐；其它平台后端映射到同一组值。
pub const Key = enum(u8) {
    unknown = 0,
    backspace = 8,
    tab = 9,
    enter = 13,
    escape = 27,
    space = 32,
    end = 35,
    home = 36,
    left = 37,
    up = 38,
    right = 39,
    down = 40,
    delete = 46,
};

/// 每帧输入快照。`click` 只在「按下并在同一控件内抬起」的那一帧出现在这里。
pub const Input = struct {
    mouse: Point = .{},
    down: bool = false,
    /// 本帧刚按下（用于建立鼠标捕获）。
    pressed: bool = false,
    click: ?Point = null,
    quit: bool = false,
    keys: [8]Key = @splat(.unknown),
    key_count: u8 = 0,
    /// 本帧输入的 UTF-8 字节（来自 WM_CHAR 或测试注入）。
    chars: [64]u8 = @splat(0),
    chars_len: u8 = 0,

    pub fn addKey(self: *Input, k: Key) void {
        if (self.key_count < self.keys.len) {
            self.keys[self.key_count] = k;
            self.key_count += 1;
        }
    }

    pub fn addCharBytes(self: *Input, bytes: []const u8) void {
        if (self.chars_len + bytes.len > self.chars.len) return;
        @memcpy(self.chars[self.chars_len .. self.chars_len + bytes.len], bytes);
        self.chars_len += @intCast(bytes.len);
    }

    pub fn charsSlice(self: *const Input) []const u8 {
        return self.chars[0..self.chars_len];
    }

    pub fn keyPressed(self: Input, k: Key) bool {
        var i: usize = 0;
        while (i < self.key_count) : (i += 1) {
            if (self.keys[i] == k) return true;
        }
        return false;
    }
};
