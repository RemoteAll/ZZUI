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

/// 位图指令：**不进 `Command` 联合体**。
/// 原因（实测）：union 尺寸由最大成员决定，多一个 60 字节的 image 成员会把
/// `cmds: [512]Command` 与 `Context` 的拷代码全部抬高一档，hello 实测 **+13.8 KB**。
/// 改走独立数组（`Context.addImage`），体积零增长。
pub const ImageCmd = struct {
    rect: t.Rect,
    pixels: []const u8,
    w: u32,
    h: u32,
    /// > 0 时当圆角遮罩用（头像就是 radius = size/2）。
    radius: f32 = 0,
    /// 裁剪矩形（零尺寸 = 不裁剪）；用 `Rect` 而不是 `?Rect` 可以省 4 字节对齐。
    clip: t.Rect = .{},
    layer: u8 = 0,
};

/// 位图源：调用方持有的 BGRA 缓冲（顶行在前，与 BMP 相同）+ 尺寸。
/// 框架**不解码图片**（不引 stb_image 291 KB 源），只负责缩放与圆角遮罩绘制。
pub const ImageSrc = struct {
    pixels: []const u8,
    w: u32,
    h: u32,
};

pub const Node = struct {
    kind: NodeKind = .box,
    rect: t.Rect = .{},
    radius: f32 = 0,
    fill: t.Color = t.Color.transparent,
    border: t.Color = t.Color.transparent,
    border_width: f32 = 0,
    text: []const u8 = "",
    font_size: f32 = theme.font_body,
    /// 占位：文本节点一律显式给色（默认值必须是编译期常量，主题令牌已成 `var`）。
    text_color: t.Color = t.Color.transparent,
    /// 等宽字体（代码块 / 十六进制视图）。后端按 (size, weight, mono) 缓存字体。
    mono: bool = false,
    /// 粗体（markdown 的 `**bold**` / 标题）。后端按 (size, bold, mono) 缓存字体。
    bold: bool = false,
    /// 斜体（markdown 的 `*italic*`）。测量按正体宽度算（斜体宽度几乎相同）。
    italic: bool = false,
    /// 构建时的裁剪矩形（零尺寸 = 不裁剪）。
    clip: ?t.Rect = null,
    /// 构建时的层号（主树 0，浮层从 1 起）。
    layer: u8 = 0,
};

pub const RectCmd = struct {
    rect: t.Rect,
    radius: f32,
    color: t.Color,
    clip: ?t.Rect = null,
    layer: u8 = 0,
};

pub const TextCmd = struct {
    rect: t.Rect,
    text: []const u8,
    size: f32,
    color: t.Color,
    clip: ?t.Rect = null,
    layer: u8 = 0,
    mono: bool = false,
    bold: bool = false,
    italic: bool = false,
};

pub const LineCmd = struct {
    from: t.Point,
    to: t.Point,
    width: f32,
    color: t.Color,
    clip: ?t.Rect = null,
    layer: u8 = 0,
};

pub const ImageCmdExtra = struct {};

pub const Command = union(enum) {
    rect: RectCmd,
    text: TextCmd,
    line: LineCmd,
};

pub const MAX_NODES = 256;
pub const MAX_COMMANDS = 512;
pub const MAX_DEPTH = 12;
pub const MAX_HITS = 128;
/// Tab 顺序池：dense 页面（两月日历 + 时分选择 + 两个滚轮）实测需要上百个，
/// 64 会把后面的控件静默挤出 Tab 顺序（现在溢出会被 markOverflow 抓到）。
pub const MAX_FOCUS = 128;
pub const MAX_OVERLAYS = 192;
pub const MAX_TEXT_POOL = 8192;
pub const MAX_SCROLLS = 16;
pub const MAX_TIPS = 16;
/// 动效轨道池（`anim.zig` 用）：按 id 存「当前值」，跨帧保留。
/// 16 条够一屏的悬停/选中过渡用；满了就按**最久未使用**淘汰（不会无限增长）。
pub const MAX_TRACKS = 16;
/// 尺寸池：浮层/弹框的上一帧真实尺寸。同时出现的绝对面板就一两个，8 项足够；
/// 每项 24 字节，池越大 `Context` 越大（会连带抬高 `App` 的拷贝代码）。
pub const MAX_SIZES = 8;
/// 位图指令独立通道（不进 `Command` 联合体，原因见 `ImageCmd` 注释）。
/// 8 项是实测过的够用量：一屏里的头像/缩略图场景 3~5 个，
/// 每多一项都会让 `Context` 变大（结构体越大，`App` 的拷贝代码越多）。
pub const MAX_IMAGES = 8;

const ScrollState = struct {
    id: u64 = 0,
    offset: f32 = 0,
    content_h: f32 = 0,
    /// 最近一次被用到的时间（池满时按它淘汰，见 `scrollState`）。
    used: f64 = 0,
};

const TipState = struct {
    id: u64 = 0,
    start: f64 = 0,
    /// 最近一次被用到的时间（池满时按它淘汰）。
    used: f64 = 0,
};

const SizeState = struct {
    id: u64 = 0,
    w: f32 = 0,
    h: f32 = 0,
    /// 最近一次被用到的时间（池满时按它淘汰）。
    used: f64 = 0,
};

/// 一条动画轨道：`value` 是当前插值值（一般 0..1），`last` 用于算 dt，`used` 用于淘汰。
pub const AnimTrack = struct {
    id: u64 = 0,
    value: f32 = 0,
    last: f64 = 0,
    used: f64 = 0,
};

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
    /// 绝对面板的高度按内容确定（浮层弹框/提示不用预先估高度）。
    auto_h: bool = false,
    /// 非 0 时把本帧量到的真实尺寸回填进尺寸池（下一帧 `knownSize` 读它定位）。
    size_key: u64 = 0,
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
    /// 容器描边（卡片/分组框/分段控件底座都要用）。
    border: ?t.Color = null,
    border_width: f32 = 1,
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
    /// 高度由内容决定（`rect.h` 被忽略），浮层弹框用。
    auto_height: bool = false,
    /// 非 0 时**帧末**把真实尺寸回填进尺寸池；下一帧 `knownSize` 用它定位置。
    /// 这是「帧末统一布局」在立即模式里的形态：本帧画完才知道多高，下一帧才排得上。
    size_key: u64 = 0,
};

pub const OverlayOpts = struct {
    /// null = 不加遮罩；alpha=0 也不会画。
    dim: ?t.Color = .{ .r = 0, .g = 0, .b = 0, .a = 90 },
    id: u64 = 0,
    /// false = 遮罩不接收点击（tooltip 这类纯展示浮层）。
    hit: bool = true,
};

pub const ScrollOpts = struct {
    /// 用于跨帧保存滚动位置；同一页面里必须唯一。
    id: []const u8 = "scroll",
    height: f32 = 200,
    pad: f32 = 0,
    gap: f32 = 0,
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

/// 滚动视口作用域：结束时夹取偏移、恢复裁剪、画滚动条、推进父容器。
pub const ScrollScope = struct {
    ui: *Context,
    id: u64 = 0,
    rect: t.Rect = .{},
    old_clip: ?t.Rect = null,
    bar_w: f32 = 6,
    ended: bool = false,

    pub fn end(self: *ScrollScope) void {
        if (self.ended) return;
        self.ended = true;
        const ui = self.ui;
        if (ui.depth <= 1) return;
        ui.depth -= 1;
        const f = ui.stack[ui.depth];
        const content_h = f.cursor + f.pad * 2;
        const st = ui.scrollState(self.id);
        st.content_h = content_h;
        const max_off = if (content_h > self.rect.h) content_h - self.rect.h else 0;
        if (st.offset < 0) st.offset = 0;
        if (st.offset > max_off) st.offset = max_off;
        ui.clip = self.old_clip;

        if (max_off > 0) {
            const track_x = self.rect.x + self.rect.w - self.bar_w;
            const thumb_h = self.rect.h * (self.rect.h / content_h);
            const tpos = if (max_off > 0) st.offset / max_off else 0;
            const thumb_y = self.rect.y + (self.rect.h - thumb_h) * tpos;
            ui.addBox(.{ .x = track_x, .y = self.rect.y, .w = self.bar_w, .h = self.rect.h }, .{ .fill = theme.surface, .radius = self.bar_w / 2 });
            ui.addBox(.{ .x = track_x, .y = thumb_y, .w = self.bar_w, .h = thumb_h }, .{ .fill = theme.border, .radius = self.bar_w / 2 });
        }

        const p = &ui.stack[f.parent];
        switch (p.dir) {
            .column => advance(p, self.rect.h, self.rect.h),
            .row => advance(p, self.rect.w, self.rect.h),
        }
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
    /// 位图指令（独立通道）：`render.renderImages` 每层调用一次。
    images: [MAX_IMAGES]ImageCmd = undefined,
    image_count: usize = 0,
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
    /// 浮层层号（主树 0）；点击只给最上层的命中项。
    overlay_layer: u8 = 0,
    /// `cmds` 里「节点指令」与「覆盖层指令」的分界：前段在 `render` 画，后段在 `renderOverlays` 画。
    /// 分两段是因为位图（`renderImages`）夹在中间：覆盖层必须能压在位图**之上**。
    overlay_base: usize = 0,
    overlay_backdrop_clicked: bool = false,
    click_target: u64 = 0,
    /// 当前裁剪矩形（null = 不裁剪）。
    clip: ?t.Rect = null,
    /// 本帧用到的最大层号（供按层渲染）。
    max_layer: u8 = 0,
    /// 滚动状态跨帧保留（不进 begin 重置）。
    scrolls: [MAX_SCROLLS]ScrollState = @splat(.{}),
    scroll_n: usize = 0,
    /// 上一帧确定的「最内层悬停滚动区」（滚轮只给它）。
    wheel_target: u64 = 0,
    /// 本帧登记的最内层滚动区（下次 begin 时生效）。
    wheel_target_next: u64 = 0,
    /// 本帧滚轮是否已被某个滚动区消费。
    wheel_used: bool = false,
    /// 本帧是否发生过容量溢出（节点/指令/线段/命中）——静默截断会让界面「莫名少画」，必须能查。
    overflowed: bool = false,
    /// 本帧是否还需要继续出帧（有动画在跑 / 有定时器在等）。
    /// `App.next` 用它做**空闲节流**：不置位且没按住鼠标时，后端直接阻塞到有输入。
    need_frame: bool = false,
    /// 悬停开始时间（tooltip 用），跨帧保留。
    tips: [MAX_TIPS]TipState = @splat(.{}),
    tip_n: usize = 0,
    /// 绝对面板的上一帧真实尺寸（`PanelOpts.size_key` 帧末回填），跨帧保留、有界、LRU。
    sizes: [MAX_SIZES]SizeState = @splat(.{}),
    size_n: usize = 0,
    /// 动画轨道（`anim.zig`），跨帧保留、有界。
    tracks: [MAX_TRACKS]AnimTrack = @splat(.{}),
    track_n: usize = 0,
    /// 本帧时间（秒），由 App 每帧写入。
    time: f64 = 0,
    /// 界面文案表（`strings.zig`）：月名/星期名/「今天」。null = 英文。
    /// 只存指针（调用方持有表），每帧读取 —— 换语言就是一次调用。
    strings: ?*const @import("strings.zig").Strings = null,
    /// 帧内字符串池：控件里拼出来的文本（如数字）要拷进来，否则节点会持有失效的栈切片。
    text_pool: [MAX_TEXT_POOL]u8 = undefined,
    text_pool_len: usize = 0,
    measure_ctx: ?*anyopaque = null,
    measure_fn: *const fn (?*anyopaque, []const u8, f32, bool) t.Size = defaultMeasure,

    // ------------------------------------------------------------ 帧生命周期
    /// 置位溢出标记；Debug 构建额外打印来源（发布构建不留字符串）。
    fn markOverflow(self: *Context, where: []const u8) void {
        self.overflowed = true;
        if (@import("builtin").mode == .debug) std.debug.print("[zzui] capacity overflow: {s}\n", .{where});
    }

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
        self.image_count = 0;
        self.text_pool_len = 0;
        self.overlay_layer = 0;
        self.overlay_backdrop_clicked = false;
        self.max_layer = 0;
        self.overflowed = false;
        self.need_frame = false;
        self.clip = null;
        self.wheel_target = self.wheel_target_next;
        self.wheel_target_next = 0;
        self.wheel_used = false;
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
        return self.measure_fn(self.measure_ctx, s, size, false);
    }

    /// 量文本（可指定粗体；粗体与常规的宽度不同，markdown 换行必须用同一档量）。
    pub fn measureTextStyled(self: *Context, s: []const u8, size: f32, bold: bool) t.Size {
        return self.measure_fn(self.measure_ctx, s, size, bold);
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
            .border = opts.border orelse t.Color.transparent,
            .border_width = if (opts.border != null) opts.border_width else 0,
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
        if (f.absolute) {
            // 绝对面板保留给定矩形，不推进父容器游标；auto_h 时按内容补高度
            if (f.auto_h) {
                const h = f.cursor + f.pad * 2;
                if (f.node) |n| {
                    self.nodes[n].rect.h = h;
                    if (f.size_key != 0) self.rememberSize(f.size_key, self.nodes[n].rect.w, h);
                }
            } else if (f.size_key != 0) {
                if (f.node) |n| self.rememberSize(f.size_key, self.nodes[n].rect.w, self.nodes[n].rect.h);
            }
            return;
        }
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

    /// 粗体文本（markdown 的 `**bold**` / 标题）：只有字重不同，其余同 `addText`。
    pub fn addBoldText(self: *Context, rect: t.Rect, s: []const u8, size: f32, color: t.Color) void {
        _ = self.addNode(.{ .kind = .text, .rect = rect, .text = s, .font_size = size, .text_color = color, .bold = true });
    }

    /// 富文本（markdown 的行内样式）：可同时指定粗体/斜体。
    pub fn addRichText(self: *Context, rect: t.Rect, s: []const u8, size: f32, color: t.Color, bold: bool, italic: bool) void {
        _ = self.addNode(.{ .kind = .text, .rect = rect, .text = s, .font_size = size, .text_color = color, .bold = bold, .italic = italic });
    }

    /// 画位图（BGRA，顶行在前）。`radius > 0` 时做圆角/圆形遮罩（头像就是 radius = 边长/2）。
    /// 框架**不解码**图片格式：像素由调用方提供（解码是应用层的选择，避免把 291 KB 的
    /// stb_image 拖进产物）。位图走**独立通道**，不进 `Command` 联合体（见 `ImageCmd` 注释）。
    pub fn addImage(self: *Context, rect: t.Rect, src: ImageSrc, radius: f32) void {
        if (src.w == 0 or src.h == 0 or src.pixels.len < @as(usize, src.w) * src.h * 4) return;
        if (self.image_count >= MAX_IMAGES) {
            self.markOverflow("images");
            return;
        }
        self.images[self.image_count] = .{
            .rect = rect,
            .pixels = src.pixels,
            .w = src.w,
            .h = src.h,
            .radius = radius,
            .clip = self.clip orelse .{},
            .layer = self.overlay_layer,
        };
        self.image_count += 1;
    }

    /// 等宽文本（代码块 / 十六进制视图）：只有字体族不同，其余同 `addText`。
    pub fn addMonoText(self: *Context, rect: t.Rect, s: []const u8, size: f32, color: t.Color) void {
        _ = self.addNode(.{ .kind = .text, .rect = rect, .text = s, .font_size = size, .text_color = color, .mono = true });
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
        if (focusable) {
            if (self.focus_curr_n < MAX_FOCUS) {
                self.focus_curr[self.focus_curr_n] = id;
                self.focus_curr_n += 1;
            } else self.markOverflow("focus");
        }
        if (self.hits_curr_n < MAX_HITS) {
            self.hits_curr[self.hits_curr_n] = .{ .id = id, .rect = rect, .layer = self.overlay_layer };
            self.hits_curr_n += 1;
        } else self.markOverflow("hits");
        var out = Interaction{};
        out.hover = rect.contains(self.input.mouse.x, self.input.mouse.y);
        out.focused = focusable and self.focus_id == id;
        if (self.input.pressed and out.hover) self.active_id = id;
        out.dragging = self.active_id == id and self.input.down;
        // `pressed` = **本帧刚刚按下**（只 true 一帧）；按住期间只能用 `dragging`。
        // 曾经这里是 `active_id == id and down`（拖动期间恒 true），
        // 导致「记录拖动起点」的控件每帧把起点重写成当前鼠标 → 位移恒 0（拖不动）。
        // 滚轮 / 刻度尺 / 签名板 / 图片查看器 / 裁剪框一共踩了五次，故从语义上根治。
        out.pressed = self.input.pressed and out.hover and self.active_id == id;
        out.clicked = self.click_target == id;
        if (out.clicked) self.focus_id = id;
        out.activated = out.focused and (self.input.keyPressed(.space) or self.input.keyPressed(.enter));
        return out;
    }

    // ------------------------------------------------------------ 浮层
    /// 开始一个浮层：遮罩全窗口（层号 +1），之后的控件都算浮层。
    pub fn beginOverlay(self: *Context, opts: OverlayOpts) OverlayScope {
        self.overlay_layer +|= 1;
        if (self.overlay_layer > self.max_layer) self.max_layer = self.overlay_layer;
        const full = t.Rect{ .x = 0, .y = 0, .w = self.width, .h = self.height };
        if (opts.hit) {
            const hit = self.interactEx(opts.id ^ 0xBACC0FFEE, full, false);
            self.overlay_backdrop_clicked = hit.clicked;
        } else {
            self.overlay_backdrop_clicked = false;
        }
        if (opts.dim) |d| {
            if (d.a > 0) self.addBox(full, .{ .fill = d });
        }
        return .{ .ui = self };
    }

    pub fn overlayBackdropClicked(self: *Context) bool {
        return self.overlay_backdrop_clicked;
    }

    /// 结束当前浮层（不依赖 `OverlayScope` 的场景，如 `overlay.zig` 的 begin/end 对）。
    pub fn endOverlay(self: *Context) void {
        if (self.overlay_layer > 0) self.overlay_layer -= 1;
    }

    /// 结束当前绝对定位面板（`panel()` 的配对调用）。
    pub fn endPanel(self: *Context) void {
        self.close();
    }

    /// 本帧已登记的命中矩形（控件建完即可查询，供菜单/浮层定位）。
    pub fn lastRect(self: *Context, id: u64) ?t.Rect {
        var i: usize = 0;
        while (i < self.hits_curr_n) : (i += 1) {
            if (self.hits_curr[i].id == id) return self.hits_curr[i].rect;
        }
        return null;
    }

    /// 上一帧该 id 的命中矩形（滚动区 hover 判定用：输入一律对上一帧判定）。
    pub fn prevHitRect(self: *Context, id: u64) ?t.Rect {
        var i: usize = 0;
        while (i < self.hits_prev_n) : (i += 1) {
            if (self.hits_prev[i].id == id) return self.hits_prev[i].rect;
        }
        return null;
    }

    /// 悬停计时（tooltip 用）：返回该 id 的首次悬停时间，首次调用时记录当前时间。
    /// 池满时按**最久未使用**淘汰 —— 原来满了就直接不记，第 17 个 tooltip 永远不出现。
    pub fn hoverStart(self: *Context, id: u64) f64 {
        var i: usize = 0;
        while (i < self.tip_n) : (i += 1) {
            if (self.tips[i].id == id) {
                self.tips[i].used = self.time;
                return self.tips[i].start;
            }
        }
        if (self.tip_n < self.tips.len) {
            self.tips[self.tip_n] = .{ .id = id, .start = self.time, .used = self.time };
            self.tip_n += 1;
            return self.time;
        }
        var oldest: usize = 0;
        for (self.tips, 0..) |tp, k| {
            if (tp.used < self.tips[oldest].used) oldest = k;
        }
        self.tips[oldest] = .{ .id = id, .start = self.time, .used = self.time };
        return self.time;
    }

    pub fn hoverReset(self: *Context, id: u64) void {
        var i: usize = 0;
        while (i < self.tip_n) : (i += 1) {
            if (self.tips[i].id == id) {
                self.tips[i] = self.tips[self.tip_n - 1];
                self.tip_n -= 1;
                return;
            }
        }
    }

    /// 上一帧回填的真实尺寸（没量过则 null）。`key` 为 0 恒返回 null。
    /// 用途：浮层/弹框本帧结束才知道内容多高，下一帧用真值定位（不再靠 `estimate_h` 猜）。
    pub fn knownSize(self: *Context, key: u64) ?t.Size {
        if (key == 0) return null;
        var i: usize = 0;
        while (i < self.size_n) : (i += 1) {
            if (self.sizes[i].id == key) {
                self.sizes[i].used = self.time;
                return .{ .w = self.sizes[i].w, .h = self.sizes[i].h };
            }
        }
        return null;
    }

    /// 帧末回填尺寸（`PanelOpts.size_key` 会自动调；手动量过内容高度时也可直接用）。
    /// 池满按**最久未使用**淘汰：不能静默丢弃，否则新浮层永远首帧估值（位置偏差无法自校正）。
    pub fn rememberSize(self: *Context, key: u64, w: f32, h: f32) void {
        if (key == 0) return;
        var i: usize = 0;
        while (i < self.size_n) : (i += 1) {
            if (self.sizes[i].id == key) {
                self.sizes[i] = .{ .id = key, .w = w, .h = h, .used = self.time };
                return;
            }
        }
        if (self.size_n < self.sizes.len) {
            self.sizes[self.size_n] = .{ .id = key, .w = w, .h = h, .used = self.time };
            self.size_n += 1;
            return;
        }
        var oldest: usize = 0;
        for (self.sizes, 0..) |s, k| {
            if (s.used < self.sizes[oldest].used) oldest = k;
        }
        self.sizes[oldest] = .{ .id = key, .w = w, .h = h, .used = self.time };
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
            .auto_h = opts.auto_height,
            .size_key = opts.size_key,
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
                        self.push(.{ .rect = .{ .rect = n.rect, .radius = n.radius, .color = n.fill, .clip = n.clip, .layer = n.layer } });
                    }
                    if (n.border_width > 0 and n.border.a > 0) self.pushBorder(n.rect, n.border_width, n.border, n.clip, n.layer);
                },
                .text => {
                    self.push(.{ .text = .{ .rect = n.rect, .text = n.text, .size = n.font_size, .color = n.text_color, .clip = n.clip, .layer = n.layer, .mono = n.mono, .bold = n.bold, .italic = n.italic } });
                },
            }
        }
        // 覆盖层接在节点之后：`render` 只画前段，`renderOverlays` 画后段（位图之后）。
        self.overlay_base = self.cmd_count;
        i = 0;
        while (i < self.overlay_count) : (i += 1) {
            self.push(self.overlays[i]);
        }
    }

    fn pushOverlay(self: *Context, cmd: Command) void {
        if (self.overlay_count >= MAX_OVERLAYS) {
            self.markOverflow("overlays");
            return;
        }
        self.overlays[self.overlay_count] = cmd;
        self.overlay_count += 1;
    }

    /// 覆盖层线段：在位图**之后**绘制（勾、焦点环、裁剪框等）。
    pub fn addOverlayLine(self: *Context, from: t.Point, to: t.Point, width: f32, color: t.Color) void {
        self.pushOverlay(.{ .line = .{ .from = from, .to = to, .width = width, .color = color, .clip = self.clip, .layer = self.overlay_layer } });
    }

    /// 覆盖层矩形：与 `addOverlayLine` 同一条「位图之后」的通道。
    /// **不要用 `addBox` 往位图上压东西** —— 位图走独立通道、在矩形之后绘制，`addBox` 会被盖掉。
    pub fn addOverlayBox(self: *Context, rect: t.Rect, opts: BoxOpts) void {
        const layer = self.overlay_layer;
        if (opts.fill) |f| {
            if (f.a > 0) self.pushOverlay(.{ .rect = .{ .rect = rect, .radius = opts.radius, .color = f, .clip = self.clip, .layer = layer } });
        }
        if (opts.border) |b| {
            const w = if (opts.border_width > 0) opts.border_width else 1;
            if (b.a > 0) {
                self.pushOverlay(.{ .rect = .{ .rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = w }, .radius = 0, .color = b, .clip = self.clip, .layer = layer } });
                self.pushOverlay(.{ .rect = .{ .rect = .{ .x = rect.x, .y = rect.y + rect.h - w, .w = rect.w, .h = w }, .radius = 0, .color = b, .clip = self.clip, .layer = layer } });
                self.pushOverlay(.{ .rect = .{ .rect = .{ .x = rect.x, .y = rect.y, .w = w, .h = rect.h }, .radius = 0, .color = b, .clip = self.clip, .layer = layer } });
                self.pushOverlay(.{ .rect = .{ .rect = .{ .x = rect.x + rect.w - w, .y = rect.y, .w = w, .h = rect.h }, .radius = 0, .color = b, .clip = self.clip, .layer = layer } });
            }
        }
    }

    fn pushBorder(self: *Context, r: t.Rect, w: f32, c: t.Color, clip: ?t.Rect, layer: u8) void {
        self.push(.{ .rect = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = w }, .radius = 0, .color = c, .clip = clip, .layer = layer } });
        self.push(.{ .rect = .{ .rect = .{ .x = r.x, .y = r.y + r.h - w, .w = r.w, .h = w }, .radius = 0, .color = c, .clip = clip, .layer = layer } });
        self.push(.{ .rect = .{ .rect = .{ .x = r.x, .y = r.y, .w = w, .h = r.h }, .radius = 0, .color = c, .clip = clip, .layer = layer } });
        self.push(.{ .rect = .{ .rect = .{ .x = r.x + r.w - w, .y = r.y, .w = w, .h = r.h }, .radius = 0, .color = c, .clip = clip, .layer = layer } });
    }

    fn push(self: *Context, cmd: Command) void {
        if (self.cmd_count >= MAX_COMMANDS) {
            self.markOverflow("commands");
            return;
        }
        self.cmds[self.cmd_count] = cmd;
        self.cmd_count += 1;
    }

    fn addNode(self: *Context, n: Node) usize {
        if (self.node_count >= MAX_NODES) {
            self.markOverflow("nodes");
            return MAX_NODES - 1;
        }
        var node = n;
        node.clip = self.clip;
        node.layer = self.overlay_layer;
        self.nodes[self.node_count] = node;
        self.node_count += 1;
        return self.node_count - 1;
    }

    /// 取（或建）某个滚动区的状态。池满时按**最久未使用**淘汰；
    /// 原来满了直接返回槽 0，等于让两个滚动区**共用同一个偏移**（页面上第 17 个滚动区一滚，
    /// 第一个就跟着跳），是实打实的串味 bug。
    fn scrollState(self: *Context, id: u64) *ScrollState {
        var i: usize = 0;
        while (i < self.scroll_n) : (i += 1) {
            if (self.scrolls[i].id == id) {
                self.scrolls[i].used = self.time;
                return &self.scrolls[i];
            }
        }
        if (self.scroll_n < self.scrolls.len) {
            self.scrolls[self.scroll_n] = .{ .id = id, .used = self.time };
            self.scroll_n += 1;
            return &self.scrolls[self.scroll_n - 1];
        }
        var oldest: usize = 0;
        for (self.scrolls, 0..) |sc, k| {
            if (sc.used < self.scrolls[oldest].used) oldest = k;
        }
        self.scrolls[oldest] = .{ .id = id, .used = self.time };
        return &self.scrolls[oldest];
    }

    /// 某滚动区当前偏移（供虚拟列表与测试查询）。
    pub fn scrollOffset(self: *Context, id: []const u8) f32 {
        const key = Context.idOf(id);
        var i: usize = 0;
        while (i < self.scroll_n) : (i += 1) {
            if (self.scrolls[i].id == key) return self.scrolls[i].offset;
        }
        return 0;
    }

    /// 直接设定滚动偏移（对位 CUI `cui_scroll_to`：程序化滚到某处，如"跳到最新"）。
    /// 实际夹取在下一帧 `scroll` 里按内容高完成。
    pub fn scrollTo(self: *Context, id: []const u8, offset: f32) void {
        const st = self.scrollState(Context.idOf(id));
        st.offset = if (offset > 0) offset else 0;
    }

    /// 声明「本帧之后还需要继续出帧」（动画在跑、定时器在等）。
    /// 不调它、也没按住鼠标时，`App.next` 会让后端**阻塞到有输入**，不再空转烧 CPU。
    pub fn requestFrame(self: *Context) void {
        self.need_frame = true;
    }

    /// 滚动视口：滚轮滚动、子节点裁剪到视口，结束时画滚动条。
    pub fn scroll(self: *Context, opts: ScrollOpts) ScrollScope {
        const rect = self.reserve(0, opts.height, true);
        const id = Context.idOf(opts.id);
        const st = self.scrollState(id);
        const hit = self.interactEx(id ^ 0x5C011, rect, false);
        // 滚轮：用**上一帧**矩形判 hover（嵌套滚动区才不会因为父滚动刚把内容移到自己下方就抢走滚轮）；
        // 并且一帧只让一个滚动区消费滚轮（最内层优先：子节点后构建，登记会覆盖父）。
        const prev = self.prevHitRect(id ^ 0x5C011) orelse rect;
        const over_prev = prev.contains(self.input.mouse.x, self.input.mouse.y);
        if (over_prev) self.wheel_target_next = id;
        const wheel_allowed = !self.wheel_used and (self.wheel_target == 0 or self.wheel_target == id);
        if (over_prev and wheel_allowed and self.input.wheel != 0) {
            st.offset -= self.input.wheel * 32;
            if (st.offset < 0) st.offset = 0;
            self.wheel_used = true;
        } else if (hit.hover and wheel_allowed and self.wheel_target == id and self.input.wheel != 0) {
            // 首帧没有上一帧矩形时也能滚（否则鼠标首次进入得等一帧）
            st.offset -= self.input.wheel * 32;
            if (st.offset < 0) st.offset = 0;
            self.wheel_used = true;
        }

        const old_clip = self.clip;
        self.clip = intersectClip(old_clip, rect);
        self.addBox(rect, .{ .fill = theme.bg });

        if (self.depth < MAX_DEPTH) {
            const bar_w: f32 = 6;
            const content_w = rect.w - opts.pad * 2 - bar_w;
            self.stack[self.depth] = .{
                .node = null,
                .parent = self.depth - 1,
                .dir = .column,
                .content_x = rect.x + opts.pad,
                .content_y = rect.y + opts.pad - st.offset,
                .width = if (content_w > 0) content_w else 0,
                .pad = opts.pad,
                .gap = opts.gap,
                .absolute = true,
            };
            self.depth += 1;
        }
        return .{ .ui = self, .id = id, .rect = rect, .old_clip = old_clip };
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

fn defaultMeasure(_: ?*anyopaque, s: []const u8, size: f32, bold: bool) t.Size {
    const n: f32 = @floatFromInt(s.len);
    const em: f32 = if (bold) 0.58 else 0.55;
    return .{ .w = n * size * em, .h = size * 1.35 };
}

/// 裁剪求交：null 表示无裁剪；完全不相交返回 null。
fn intersectClip(a: ?t.Rect, b: t.Rect) ?t.Rect {
    const b_on = b.w > 0 and b.h > 0;
    if (a) |ra| {
        if (!b_on) return ra;
        const x0 = if (ra.x > b.x) ra.x else b.x;
        const y0 = if (ra.y > b.y) ra.y else b.y;
        const x1 = if (ra.x + ra.w < b.x + b.w) ra.x + ra.w else b.x + b.w;
        const y1 = if (ra.y + ra.h < b.y + b.h) ra.y + ra.h else b.y + b.h;
        const w = x1 - x0;
        const h = y1 - y0;
        if (w <= 0 or h <= 0) return null;
        return .{ .x = x0, .y = y0, .w = w, .h = h };
    }
    return if (b_on) b else null;
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
