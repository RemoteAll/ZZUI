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

/// 与 Win32 虚拟键码**数值一致**（后端只需按 VK 直接转换，见 `fromVirtualKey`）；
/// 其它平台后端映射到同一组值。字母/数字/F 键是快捷键录制与展示必需的。
pub const Key = enum(u8) {
    unknown = 0,
    backspace = 8,
    tab = 9,
    enter = 13,
    escape = 27,
    space = 32,
    page_up = 33,
    page_down = 34,
    end = 35,
    home = 36,
    left = 37,
    up = 38,
    right = 39,
    down = 40,
    insert = 45,
    delete = 46,

    digit0 = 48,
    digit1 = 49,
    digit2 = 50,
    digit3 = 51,
    digit4 = 52,
    digit5 = 53,
    digit6 = 54,
    digit7 = 55,
    digit8 = 56,
    digit9 = 57,

    A = 65,
    B = 66,
    C = 67,
    D = 68,
    E = 69,
    F = 70,
    G = 71,
    H = 72,
    I = 73,
    J = 74,
    K = 75,
    L = 76,
    M = 77,
    N = 78,
    O = 79,
    P = 80,
    Q = 81,
    R = 82,
    S = 83,
    T = 84,
    U = 85,
    V = 86,
    W = 87,
    X = 88,
    Y = 89,
    Z = 90,

    f1 = 112,
    f2 = 113,
    f3 = 114,
    f4 = 115,
    f5 = 116,
    f6 = 117,
    f7 = 118,
    f8 = 119,
    f9 = 120,
    f10 = 121,
    f11 = 122,
    f12 = 123,

    semicolon = 186,
    equal = 187,
    comma = 188,
    minus = 189,
    period = 190,
    slash = 191,
    tilde = 192,
    bracket_left = 219,
    backslash = 220,
    bracket_right = 221,
    quote = 222,

    pub fn fromVirtualKey(vk: u32) Key {
        return switch (vk) {
            8, 9, 13, 27, 32, 33, 34, 35, 36, 37, 38, 39, 40, 45, 46 => @fromBackingInt(@intCast(@as(u8, @intCast(vk)))),
            48...57, 65...90, 112...123 => @fromBackingInt(@intCast(@as(u8, @intCast(vk)))),
            186, 187, 188, 189, 190, 191, 192, 219, 220, 221, 222 => @fromBackingInt(@intCast(@as(u8, @intCast(vk)))),
            else => .unknown,
        };
    }
};

/// 修饰键快照（快捷键录制与展示用）。
pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    win: bool = false,

    pub fn any(self: Mods) bool {
        return self.ctrl or self.shift or self.alt or self.win;
    }
};

/// 每帧输入快照。`click` 只在「按下并在同一控件内抬起」的那一帧出现在这里。
pub const Input = struct {
    mouse: Point = .{},
    down: bool = false,
    /// 本帧刚按下（用于建立鼠标捕获）。
    pressed: bool = false,
    /// 本帧滚轮增量（正数向上）。
    wheel: f32 = 0,
    click: ?Point = null,
    /// 本帧右键释放的位置（上下文菜单用；Win32 WM_RBUTTONUP）。
    right_click: ?Point = null,
    /// 本帧拖入窗口的文件数（路径用 `App.droppedFile(i)` 取，不在 Input 里拷贝，
    /// 因为 Input 是每帧按值拷贝的，内联路径缓冲会让拷贝变大很多）。
    dropped: u8 = 0,
    quit: bool = false,
    keys: [8]Key = @splat(.unknown),
    key_count: u8 = 0,
    /// 本帧修饰键快照（后端每帧读取）。
    mods: Mods = .{},
    /// 本帧输入的 UTF-8 字节（来自 WM_CHAR 或测试注入）。
    chars: [64]u8 = @splat(0),
    chars_len: u8 = 0,

    pub fn addKey(self: *Input, k: Key) void {
        if (self.key_count < self.keys.len) {
            self.keys[self.key_count] = k;
            self.key_count += 1;
        }
    }

    /// 本帧按下的第一个**非修饰键**（录制快捷键用；没有则 null）。
    pub fn firstTypedKey(self: *const Input) ?Key {
        var i: usize = 0;
        while (i < self.key_count) : (i += 1) {
            const k = self.keys[i];
            if (k != .unknown) return k;
        }
        return null;
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
