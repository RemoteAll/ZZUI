//! ZZUI 核心：帧生命周期、节点树、栈式布局、绘制指令。
//! 与 CUI 的对应关系：`begin`/`paint` 对应 `cui_begin_frame`/`cui_end_frame` 的
//! 「节点 → 绘制」两段；输入一律对**上一帧**的矩形做判定（与 CUI 的 `cui__interact` 同口径）。
//!
//! 里程碑 1 的简化（待后续里程碑对齐 CUI）：
//! - 布局在构建时按 row/column 顺序放置（CUI 是帧末统一布局）；
//! - 没有状态回收与动画，控件状态由调用方变量保存（与 CUI 的 immediate mode 一致）；
//! - 节点与绘制指令用定长数组，溢出丢弃并在回归里覆盖容量。
const std = @import("std");
const t = @import("types.zig");
const theme = @import("theme.zig");

pub const NodeKind = enum { box, text };

pub const Node = struct {
    kind: NodeKind = .box,
    rect: t.Rect = .{},
    radius: f32 = 0,
    fill: t.Color = t.Color.transparent,
    border: t.Color = t.Color.transparent,
    border_width: f32 = 0,
    text: []const u8 = "",
    font_size: f32 = theme.font_body,
    text_color: t.Color = theme.text,
};

pub const RectCmd = struct {
    rect: t.Rect,
    radius: f32,
    color: t.Color,
};

pub const TextCmd = struct {
    rect: t.Rect,
    text: []const u8,
    size: f32,
    color: t.Color,
};

pub const LineCmd = struct {
    from: t.Point,
    to: t.Point,
    width: f32,
    color: t.Color,
};

pub const Command = union(enum) {
    rect: RectCmd,
    text: TextCmd,
    line: LineCmd,
};

pub const MAX_NODES = 256;
pub const MAX_COMMANDS = 512;
pub const MAX_DEPTH = 12;
pub const MAX_HITS = 128;
pub const MAX_FOCUS = 64;
pub const MAX_OVERLAYS = 64;
pub const MAX_TEXT_POOL = 8192;

const Frame = struct {
    node: ?usize = null,
    parent: usize = 0,
    dir: t.Direction = .column,
    content_x: f32 = 0,
    content_y: f32 = 0,
    width: f32 = 0,
    pad: f32 = 0,
    gap: f32 = 0,
    /// 下一个子项的主轴起点（不含前一个子项后的 gap）。
    cursor: f32 = 0,
    cross: f32 = 0,
    children: usize = 0,
    /// 绝对定位（浮层面板）：不推进父容器游标。
    absolute: bool = false,
};

const Hit = struct {
    id: u64,
    rect: t.Rect,
    /// 越高越在上层（主树 = 0，浮层从 1 起）。
    layer: u8 = 0,
};

pub const ContainerOpts = struct {
    direction: t.Direction = .column,
    pad: f32 = 0,
    gap: f32 = 0,
    fill: ?t.Color = null,
    radius: f32 = 0,
};

pub const BoxOpts = struct {
    fill: ?t.Color = null,
    radius: f32 = 0,
    border: ?t.Color = null,
    border_width: f32 = 1,
};

pub const Interaction = struct {
    hover: bool = false,
    clicked: bool = false,
    focused: bool = false,
    pressed: bool = false,
    dragging: bool = false,
    activated: bool = false,
};

pub const Scope = struct {
    ui: *Context,
    ended: bool = false,

    pub fn end(self: *Scope) void {
        if (self.ended) return;
        self.ui.close();
        self.ended = true;
    }
};

pub const PanelOpts = struct {
    fill: ?t.Color = null,
    radius: f32 = 0,
    border: ?t.Color = null,
    border_width: f32 = 1,
    pad: f32 = 0,
    gap: f32 = 0,
    dir: t.Direction = .column,
};

pub const OverlayOpts = struct {
    dim: t.Color = .{ .r = 0, .g = 0, .b = 0, .a = 90 },
    id: u64 = 0,
};

/// 浮层作用域：结束后层号回落。
pub const OverlayScope = struct {
    ui: *Context,
    ended: bool = false,

    pub fn end(self: *OverlayScope) void {
        if (self.ended) return;
        self.ui.overlay_layer -= 1;
        self.ended = true;
    }
};

pub const Context = struct {
    nodes: [MAX_NODES]Node = undefined,
    node_count: usize = 0,
    cmds: [MAX_COMMANDS]Command = undefined,
    cmd_count: usize = 0,
    /// 先于节点绘制？不：overlay 在节点之后绘制（勾、焦点环等）。
    overlays: [MAX_OVERLAYS]Command = undefined,
    overlay_count: usize = 0,
    stack: [MAX_DEPTH]Frame = undefined,
    depth: usize = 0,
    width: f32 = 0,
    height: f32 = 0,
    input: t.Input = .{},
    hits_prev: [MAX_HITS]Hit = undefined,
    hits_prev_n: usize = 0,
    hits_curr: [MAX_HITS]Hit = undefined,
    hits_curr_n: usize = 0,
    focus_prev: [MAX_FOCUS]u64 = undefined,
    focus_prev_n: usize = 0,
    focus_curr: [MAX_FOCUS]u64 = undefined,
    focus_curr_n: usize = 0,
    focus_id: u64 = 0,
    active_id: u64 = 0,
    /// 当前浮层层号（主树 0）；点击只给最上层的命中项。
    overlay_layer: u8 = 0,
    overlay_backdrop_clicked: bool = false,
    click_target: u64 = 0,
    /// 帧内字符串池：控件里拼出来的文本（如数字）要拷进来，否则节点会持有失效的栈切片。
    text_pool: [MAX_TEXT_POOL]u8 = undefined,
    text_pool_len: usize = 0,
    measure_ctx: ?*anyopaque = null,
    measure_fn: *const fn (?*anyopaque, []const u8, f32) t.Size = defaultMeasure,

    // ------------------------------------------------------------ 帧生命周期
    pub fn begin(self: *Context, width: f32, height: f32) void {
        self.hits_prev = self.hits_curr;
        self.hits_prev_n = self.hits_curr_n;
        self.hits_curr_n = 0;
        self.focus_prev = self.focus_curr;
        self.focus_prev_n = self.focus_curr_n;
        self.focus_curr_n = 0;
        self.node_count = 0;
        self.cmd_count = 0;
        self.overlay_count = 0;
        self.text_pool_len = 0;
        self.overlay_layer = 0;
        self.overlay_backdrop_clicked = false;
        if (!self.input.down) self.active_id = 0;
        if (self.input.keyPressed(.tab)) self.advanceFocus();
        // 点击归属：上一帧命中里，包含点击点且层号最高（同层后者胜）的那个。
        self.click_target = 0;
        if (self.input.click) |p| {
            var best_layer: u8 = 0;
            var found = false;
            var i: usize = 0;
            while (i < self.hits_prev_n) : (i += 1) {
                const h = self.hits_prev[i];
                if (!h.rect.contains(p.x, p.y)) continue;
                if (!found or h.layer >= best_layer) {
                    best_layer = h.layer;
                    self.click_target = h.id;
                    found = true;
                }
            }
        }
        self.width = width;
        self.height = height;
        self.stack[0] = .{ .node = null, .parent = 0, .dir = .column, .content_x = 0, .content_y = 0, .width = width };
        self.depth = 1;
    }

    fn advanceFocus(self: *Context) void {
        if (self.focus_prev_n == 0) return;
        var i: usize = 0;
        while (i < self.focus_prev_n) : (i += 1) {
            if (self.focus_prev[i] == self.focus_id) {
                const next = (i + 1) % self.focus_prev_n;
                self.focus_id = self.focus_prev[next];
                return;
            }
        }
        self.focus_id = self.focus_prev[0];
    }

    pub fn measureText(self: *Context, s: []const u8, size: f32) t.Size {
        return self.measure_fn(self.measure_ctx, s, size);
    }

    // ------------------------------------------------------------ 容器
    pub fn column(self: *Context, opts: ContainerOpts) Scope {
        var o = opts;
        o.direction = .column;
        self.open(o);
        return .{ .ui = self };
    }

    pub fn row(self: *Context, opts: ContainerOpts) Scope {
        var o = opts;
        o.direction = .row;
        self.open(o);
        return .{ .ui = self };
    }

    fn open(self: *Context, opts: ContainerOpts) void {
        if (self.depth >= MAX_DEPTH) return;
        const parent = self.stack[self.depth - 1];
        const origin = childOrigin(parent);
        const x = if (parent.dir == .row) parent.content_x + origin else parent.content_x;
        const y = if (parent.dir == .column) parent.content_y + origin else parent.content_y;
        const outer_w = parent.width;
        const content_w = outer_w - opts.pad * 2;
        const node = self.addNode(.{
            .kind = .box,
            .rect = .{ .x = x, .y = y, .w = outer_w, .h = 0 },
            .radius = opts.radius,
            .fill = opts.fill orelse t.Color.transparent,
        });
        self.stack[self.depth] = .{
            .node = node,
            .parent = self.depth - 1,
            .dir = opts.direction,
            .content_x = x + opts.pad,
            .content_y = y + opts.pad,
            .width = if (content_w > 0) content_w else 0,
            .pad = opts.pad,
            .gap = opts.gap,
        };
        self.depth += 1;
    }

    fn close(self: *Context) void {
        if (self.depth <= 1) return;
        self.depth -= 1;
        const f = self.stack[self.depth];
        const main = f.cursor;
        const rect = switch (f.dir) {
            .column => t.Rect{
                .x = f.content_x - f.pad,
                .y = f.content_y - f.pad,
                .w = f.width + f.pad * 2,
                .h = main + f.pad * 2,
            },
            .row => t.Rect{
                .x = f.content_x - f.pad,
                .y = f.content_y - f.pad,
                .w = main + f.pad * 2,
                .h = f.cross + f.pad * 2,
            },
        };
        if (f.node) |n| self.nodes[n].rect = rect;
        if (f.absolute) return;
        const p = &self.stack[f.parent];
        switch (p.dir) {
            .column => advance(p, rect.h, rect.h),
            .row => advance(p, rect.w, rect.h),
        }
    }

    // ------------------------------------------------------------ 叶子
    /// 在父容器里占位并返回矩形。`stretch` 只在 column 里生效（撑满内容宽）。
    pub fn reserve(self: *Context, w: f32, h: f32, stretch: bool) t.Rect {
        const f = &self.stack[self.depth - 1];
        const origin = childOrigin(f.*);
        switch (f.dir) {
            .column => {
                const width = if (stretch) f.width else w;
                const rect = t.Rect{ .x = f.content_x, .y = f.content_y + origin, .w = width, .h = h };
                advance(f, h, h);
                return rect;
            },
            .row => {
                const rect = t.Rect{ .x = f.content_x + origin, .y = f.content_y, .w = w, .h = h };
                advance(f, w, h);
                return rect;
            },
        }
    }

    pub fn addBox(self: *Context, rect: t.Rect, opts: BoxOpts) void {
        _ = self.addNode(.{
            .kind = .box,
            .rect = rect,
            .radius = opts.radius,
            .fill = opts.fill orelse t.Color.transparent,
            .border = opts.border orelse t.Color.transparent,
            .border_width = if (opts.border != null) opts.border_width else 0,
        });
    }

    pub fn addText(self: *Context, rect: t.Rect, s: []const u8, size: f32, color: t.Color) void {
        _ = self.addNode(.{ .kind = .text, .rect = rect, .text = s, .font_size = size, .text_color = color });
    }

    /// 文本占位 + 文本节点。column 里按内容宽自动换行，row 里按测量宽度单行。
    pub fn textRun(self: *Context, s: []const u8, size: f32, color: t.Color) t.Rect {
        const owned = self.frameStr(s);
        const m = self.measureText(owned, size);
        const line_h = if (m.h > 0) m.h else size * 1.35;
        const frame = &self.stack[self.depth - 1];
        if (frame.dir == .row or frame.width <= 0) {
            const rect = self.reserve(m.w, line_h, true);
            self.addText(rect, owned, size, color);
            return rect;
        }
        var lines: [MAX_LINES][]const u8 = undefined;
        const n = wrapText(self, owned, size, frame.width, &lines);
        const total_h = line_h * @as(f32, @floatFromInt(n));
        const rect = self.reserve(0, total_h, true);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.addText(.{
                .x = rect.x,
                .y = rect.y + line_h * @as(f32, @floatFromInt(i)),
                .w = frame.width,
                .h = line_h,
            }, lines[i], size, color);
        }
        return rect;
    }

    /// 把字符串拷进本帧的池子，保证节点里的 slice 直到绘制前都有效（对应 CUI 的 `cui__frame_strdup`）。
    pub fn frameStr(self: *Context, s: []const u8) []const u8 {
        if (self.text_pool_len + s.len > self.text_pool.len) return s;
        const dst = self.text_pool[self.text_pool_len .. self.text_pool_len + s.len];
        @memcpy(dst, s);
        self.text_pool_len += s.len;
        return dst;
    }

    /// 用字符宽度估算的数字文本（不引入 std.fmt，避免体积膨胀）。
    pub fn textIntRun(self: *Context, prefix: []const u8, value: u64, suffix: []const u8, size: f32, color: t.Color) void {
        var buf: [48]u8 = undefined;
        var n: usize = 0;
        for (prefix) |c| {
            if (n < buf.len) {
                buf[n] = c;
                n += 1;
            }
        }
        var digits: [20]u8 = undefined;
        var d: usize = 0;
        var v = value;
        if (v == 0) {
            digits[0] = '0';
            d = 1;
        } else {
            while (v > 0) : (v /= 10) {
                digits[d] = @intCast('0' + (v % 10));
                d += 1;
            }
        }
        while (d > 0) {
            d -= 1;
            if (n < buf.len) {
                buf[n] = digits[d];
                n += 1;
            }
        }
        for (suffix) |c| {
            if (n < buf.len) {
                buf[n] = c;
                n += 1;
            }
        }
        _ = self.textRun(buf[0..n], size, color);
    }

    // ------------------------------------------------------------ 输入
    /// 对**上一帧**的矩形判定点击；同时记录本帧矩形供下一帧使用。
    pub fn interact(self: *Context, id: u64, rect: t.Rect) Interaction {
        return self.interactEx(id, rect, false);
    }

    /// `focusable` 的控件会进入 Tab 顺序，并响应空格/回车激活。
    pub fn interactEx(self: *Context, id: u64, rect: t.Rect, focusable: bool) Interaction {
        if (focusable and self.focus_curr_n < MAX_FOCUS) {
            self.focus_curr[self.focus_curr_n] = id;
            self.focus_curr_n += 1;
        }
        if (self.hits_curr_n < MAX_HITS) {
            self.hits_curr[self.hits_curr_n] = .{ .id = id, .rect = rect, .layer = self.overlay_layer };
            self.hits_curr_n += 1;
        }
        var out = Interaction{};
        out.hover = rect.contains(self.input.mouse.x, self.input.mouse.y);
        out.focused = focusable and self.focus_id == id;
        if (self.input.pressed and out.hover) self.active_id = id;
        out.dragging = self.active_id == id and self.input.down;
        out.pressed = self.active_id == id and self.input.down;
        out.clicked = self.click_target == id;
        if (out.clicked) self.focus_id = id;
        out.activated = out.focused and (self.input.keyPressed(.space) or self.input.keyPressed(.enter));
        return out;
    }

    // ------------------------------------------------------------ 浮层
    /// 开始一个浮层：遮罩全窗口（层号 +1），之后的控件都算浮层。
    pub fn beginOverlay(self: *Context, opts: OverlayOpts) OverlayScope {
        self.overlay_layer +|= 1;
        const full = t.Rect{ .x = 0, .y = 0, .w = self.width, .h = self.height };
        const hit = self.interactEx(opts.id ^ 0xBACC0FFEE, full, false);
        self.overlay_backdrop_clicked = hit.clicked;
        self.addBox(full, .{ .fill = opts.dim });
        return .{ .ui = self };
    }

    pub fn overlayBackdropClicked(self: *Context) bool {
        return self.overlay_backdrop_clicked;
    }

    /// 绝对定位面板：节点矩形就是 rect，内部内容从 rect + pad 开始；不推进父容器游标。
    pub fn panel(self: *Context, rect: t.Rect, opts: PanelOpts) Scope {
        if (self.depth >= MAX_DEPTH) return .{ .ui = self };
        const node = self.addNode(.{
            .kind = .box,
            .rect = rect,
            .radius = opts.radius,
            .fill = opts.fill orelse t.Color.transparent,
            .border = opts.border orelse t.Color.transparent,
            .border_width = if (opts.border != null) opts.border_width else 0,
        });
        const content_w = rect.w - opts.pad * 2;
        self.stack[self.depth] = .{
            .node = node,
            .parent = self.depth - 1,
            .dir = opts.dir,
            .content_x = rect.x + opts.pad,
            .content_y = rect.y + opts.pad,
            .width = if (content_w > 0) content_w else 0,
            .pad = opts.pad,
            .gap = opts.gap,
            .absolute = true,
        };
        self.depth += 1;
        return .{ .ui = self };
    }

    pub fn idOf(label: []const u8) u64 {
        // FNV-1a 64
        var h: u64 = 0xcbf29ce484222325;
        for (label) |c| {
            h ^= c;
            h *%= 0x100000001b3;
        }
        return h;
    }

    // ------------------------------------------------------------ 绘制
    pub fn paint(self: *Context) void {
        var i: usize = 0;
        while (i < self.node_count) : (i += 1) {
            const n = self.nodes[i];
            switch (n.kind) {
                .box => {
                    if (n.fill.a > 0) {
                        self.push(.{ .rect = .{ .rect = n.rect, .radius = n.radius, .color = n.fill } });
                    }
                    if (n.border_width > 0 and n.border.a > 0) self.pushBorder(n.rect, n.border_width, n.border);
                },
                .text => {
                    self.push(.{ .text = .{ .rect = n.rect, .text = n.text, .size = n.font_size, .color = n.text_color } });
                },
            }
        }
        i = 0;
        while (i < self.overlay_count) : (i += 1) {
            self.push(self.overlays[i]);
        }
    }

    /// 覆盖层线段：在节点之后绘制（勾、焦点环等）。
    pub fn addOverlayLine(self: *Context, from: t.Point, to: t.Point, width: f32, color: t.Color) void {
        if (self.overlay_count >= MAX_OVERLAYS) return;
        self.overlays[self.overlay_count] = .{ .line = .{ .from = from, .to = to, .width = width, .color = color } };
        self.overlay_count += 1;
    }

    fn pushBorder(self: *Context, r: t.Rect, w: f32, c: t.Color) void {
        self.push(.{ .rect = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = w }, .radius = 0, .color = c } });
        self.push(.{ .rect = .{ .rect = .{ .x = r.x, .y = r.y + r.h - w, .w = r.w, .h = w }, .radius = 0, .color = c } });
        self.push(.{ .rect = .{ .rect = .{ .x = r.x, .y = r.y, .w = w, .h = r.h }, .radius = 0, .color = c } });
        self.push(.{ .rect = .{ .rect = .{ .x = r.x + r.w - w, .y = r.y, .w = w, .h = r.h }, .radius = 0, .color = c } });
    }

    fn push(self: *Context, cmd: Command) void {
        if (self.cmd_count >= MAX_COMMANDS) return;
        self.cmds[self.cmd_count] = cmd;
        self.cmd_count += 1;
    }

    fn addNode(self: *Context, n: Node) usize {
        if (self.node_count >= MAX_NODES) return MAX_NODES - 1;
        self.nodes[self.node_count] = n;
        self.node_count += 1;
        return self.node_count - 1;
    }
};

fn childOrigin(f: Frame) f32 {
    return if (f.children > 0) f.cursor + f.gap else f.cursor;
}

fn advance(f: *Frame, main: f32, cross: f32) void {
    f.cursor = childOrigin(f.*) + main;
    f.children += 1;
    if (cross > f.cross) f.cross = cross;
}

fn defaultMeasure(_: ?*anyopaque, s: []const u8, size: f32) t.Size {
    const n: f32 = @floatFromInt(s.len);
    return .{ .w = n * size * 0.55, .h = size * 1.35 };
}

pub const MAX_LINES = 32;

fn utf8Len(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

fn decodeCp(s: []const u8) u21 {
    return std.unicode.utf8Decode(s) catch 0;
}

fn breakable(cp: u21, next: u21) bool {
    if (cp == ' ' or cp == '-' or cp == '/') return true;
    if (cp >= 0x2E80) return true; // CJK 与全角字符后
    if (next >= 0x2E80) return true; // CJK 前
    return false;
}

/// 贪心换行：优先在空格 / 连字符 / CJK 边界断行；单个超长词按字符硬断。
pub fn wrapText(ui: *Context, s: []const u8, size: f32, max_w: f32, out: *[MAX_LINES][]const u8) usize {
    if (s.len == 0) {
        out[0] = s;
        return 1;
    }
    if (max_w <= 0 or ui.measureText(s, size).w <= max_w) {
        out[0] = s;
        return 1;
    }
    var n: usize = 0;
    var start: usize = 0;
    while (start < s.len and n < out.len) {
        var i = start;
        var fit_end = start;
        var last_break = start;
        while (i < s.len) {
            const clen = utf8Len(s[i]);
            const cand_end = i + clen;
            if (cand_end > s.len) break;
            if (ui.measureText(s[start..cand_end], size).w > max_w) break;
            fit_end = cand_end;
            const cp = decodeCp(s[i..cand_end]);
            var next: u21 = 0;
            if (cand_end < s.len) {
                const nlen = utf8Len(s[cand_end]);
                if (cand_end + nlen <= s.len) next = decodeCp(s[cand_end .. cand_end + nlen]);
            }
            if (breakable(cp, next)) last_break = cand_end;
            i = cand_end;
        }
        var end = fit_end;
        if (end == start) {
            end = start + utf8Len(s[start]);
            if (end > s.len) end = s.len;
        } else if (last_break > start and last_break < fit_end and fit_end < s.len) {
            end = last_break;
        }
        out[n] = s[start..end];
        n += 1;
        start = end;
        while (start < s.len and s[start] == ' ') start += 1;
    }
    if (n == 0) {
        out[0] = s;
        return 1;
    }
    return n;
}

// ---------------------------------------------------------------- 单元测试
test "column stacks children with gap and padding" {
    var ui = Context{};
    ui.begin(400, 300);
    var col = ui.column(.{ .pad = 16, .gap = 8 });
    const r1 = ui.reserve(120, 20, false);
    const r2 = ui.reserve(120, 30, false);
    col.end();
    ui.paint();

    // 子项：第一个从 pad 处开始，第二个在 20 + gap 8 之后
    try std.testing.expectApproxEqAbs(@as(f32, 16), r1.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 44), r2.y, 0.001);

    // 容器（节点 0）：宽撑满父容器，高 = 20 + 8 + 30 + 2 * 16
    const box = ui.nodes[0].rect;
    try std.testing.expectApproxEqAbs(@as(f32, 400), box.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 90), box.h, 0.001);
}

test "row lays out along x and closes with cross height" {
    var ui = Context{};
    ui.begin(400, 300);
    var row = ui.row(.{ .gap = 10 });
    const r1 = ui.reserve(50, 20, false);
    const r2 = ui.reserve(30, 40, false);
    row.end();
    ui.paint();

    try std.testing.expectApproxEqAbs(@as(f32, 0), r1.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 60), r2.x, 0.001);

    const box = ui.nodes[0].rect;
    try std.testing.expectApproxEqAbs(@as(f32, 90), box.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), box.h, 0.001);
}

test "click is matched against last frame rect" {
    var ui = Context{};
    ui.begin(400, 300);
    const rect = ui.reserve(100, 30, false);
    const id = Context.idOf("button");
    _ = ui.interact(id, rect);
    ui.paint();

    // 下一帧：点击落在上一帧矩形内
    ui.input = .{ .mouse = .{ .x = 10, .y = 10 }, .click = .{ .x = 10, .y = 10 } };
    ui.begin(400, 300);
    const r2 = ui.interact(id, rect);
    try std.testing.expect(r2.clicked);
}
