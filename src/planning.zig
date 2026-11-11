//! 规划视图族（对位 CUI `cui_planning.c`）：看板 / 周历 / 甘特图。
//!
//! 三件都是「一块面板 + 绝对坐标排布」，不用 `column`/`scroll` 拼（那种拼法在
//! defer 顺序、滚动嵌套上踩过两次，绝对定位几何一眼可验）。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **没有弹簧动画**：框架只插值颜色、不做几何位移，拖动/重排一律直接到位；
//! - **看板不做横向滚动**：列按 `opts.width` 铺开，超出面板的部分被裁掉；
//! - **看板卡片高度第二帧才准**（`knownSize` 帧末回填，与弹层同口径），首帧按 64 估；
//! - **周历不做窄屏横向滚动**：天列宽 = 可用宽 / 7（CUI 窄时横滚）；
//! - **甘特图里程碑画成圆点**（框架没有多边形通道，菱形要另开一层不划算）；
//! - 事件/任务的拖拽都是「按下 → 移动超过阈值才算拖」，单击另算。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const strings = @import("strings.zig");
const month = @import("month.zig");
const trace = @import("trace.zig");

pub const Tone = trace.Tone;
pub const Date = month.Date;

const SLOP: f32 = 4;

fn intersect(a: ?t.Rect, b: t.Rect) ?t.Rect {
    const s = a orelse return b;
    const x0 = @max(s.x, b.x);
    const y0 = @max(s.y, b.y);
    const x1 = @min(s.x + s.w, b.x + b.w);
    const y1 = @min(s.y + s.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn clampF(v: f32, lo: f32, hi: f32) f32 {
    if (hi < lo) return lo;
    return if (v < lo) lo else if (v > hi) hi else v;
}

/// 卡片 id → 命中 id。模块内部与测试都用这一个，不要在别处重算。
pub fn cardKey(board_id: u64, card_id: i32) u64 {
    return board_id ^ (core.Context.idOf("kb-card") *% 0xC2B2) ^ (@as(u64, @bitCast(@as(i64, card_id))) *% 0x85EB);
}

/// 周历事件下标 → 命中 id。
pub fn eventKey(cal_id: u64, i: usize) u64 {
    return core.Context.idOf("wev") ^ (i *% 0x9E3779B1) ^ cal_id;
}

/// 甘特任务下标 → 命中 id。
pub fn taskKey(gantt_id: u64, i: usize) u64 {
    return core.Context.idOf("gt") ^ (i *% 0x9E3779B1) ^ gantt_id;
}

/// 按可用宽度裁剪文本（尾部补 "..."）。
/// **文本层按字符串长度画，不会被节点宽裁切**，所以窄栏里的长标题会压到隔壁格子上。
fn fitText(ui: *core.Context, s: []const u8, size: f32, max_w: f32) []const u8 {
    if (s.len == 0 or max_w <= 0) return "";
    if (ui.measureText(s, size).w <= max_w) return s;
    var take: usize = @min(s.len -| 1, 61);
    while (take > 0) : (take -= 1) {
        var n = take;
        while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1; // 不在半个 UTF-8 字符上切
        var buf: [64]u8 = undefined;
        if (n + 3 <= buf.len) {
            @memcpy(buf[0..n], s[0..n]);
            buf[n] = '.';
            buf[n + 1] = '.';
            buf[n + 2] = '.';
            if (ui.measureText(buf[0 .. n + 3], size).w <= max_w) return ui.frameStr(buf[0 .. n + 3]);
        }
    }
    return "";
}

/// 时刻文本（9.5 → "9:30"），结果写进 `buf`。
fn fmtTime(buf: []u8, h: f32) []const u8 {
    const hh: i64 = @intFromFloat(@floor(h));
    const mm: i64 = @intFromFloat(@round((h - @floor(h)) * 60.0));
    const a = num.int(buf, hh);
    var n = a.len;
    if (n + 3 > buf.len) return a;
    buf[n] = ':';
    n += 1;
    if (mm < 10) {
        buf[n] = '0';
        n += 1;
    }
    const b = num.int(buf[n..], mm);
    n += b.len;
    return buf[0..n];
}

// ====================================================================== 看板

pub const CardOpts = struct {
    /// 卡片标题：**只用于拖动时的幽灵条**（卡内容由调用方在 begin/end 之间画）。
    title: []const u8 = "",
};

pub const ColumnOpts = struct {
    /// 标题前的小色点。
    dot: ?t.Color = null,
    /// 上限（> 0 时标题旁显示 `n / limit`，超了标红）。
    limit: i32 = 0,
    width: f32 = 270,
    /// 卡间距（也是「让位」的空隙）。
    card_gap: f32 = 8,
};

pub const BoardOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    height: f32 = 430,
    gap: f32 = 14,
    pad: f32 = 10,
};

pub const KanbanMove = struct {
    card: i32 = -1,
    from_column: i32 = -1,
    to_column: i32 = -1,
    to_index: i32 = 0,
};

pub const KanbanState = struct {
    /// 正在拖的卡 id，-1 = 没在拖。
    drag: i32 = -1,
    from_col: i32 = -1,
    /// 已按下但还没越过阈值。
    press: i32 = -1,
    press_col: i32 = -1,
    press_x: f32 = 0,
    press_y: f32 = 0,
    grab_x: f32 = 0,
    grab_y: f32 = 0,
    drag_w: f32 = 0,
    drag_h: f32 = 0,
    drag_title: []const u8 = "",
    /// 键盘拖动（空格抬起 → 方向键选位 → 回车落下）。
    kbd: bool = false,
    kcol: i32 = 0,
    kidx: i32 = 0,
    /// 上一步算出的落点（`kanbanEnd` 用它给出 move）。
    target_col: i32 = -1,
    target_index: i32 = 0,
};

pub const Board = struct {
    id: u64 = 0,
    st: *KanbanState = undefined,
    opts: BoardOpts = .{},
    rect: t.Rect = .{},
    saved_clip: ?t.Rect = null,
    /// 当前列下标。
    col: i32 = -1,
    /// 当前列里第几张卡。
    card_pos: i32 = 0,
    /// 列数（`kanbanEnd` 才知道总共几列）。
    ncols: i32 = 0,
    col_x: f32 = 0,
    col_w: f32 = 270,
    card_gap: f32 = 8,
    card_y: f32 = 0,
    col_top: f32 = 0,
    col_bottom: f32 = 0,
    /// 本列是不是拖动落点 + 落点序号是否已经定下。
    is_target: bool = false,
    index_set: bool = false,
    hole_y: f32 = 0,
    /// 幽灵条（`kanbanEnd` 画，保证压在其它列之上）。
    ghost: bool = false,
    card_open: bool = false,
    card_scope: core.Scope = undefined,
    card_key: u64 = 0,
    card_rect: t.Rect = .{},
};

/// 开一块看板。`b` 由调用方持有（栈上即可），逐层往 `kanbanEnd` 传；
/// `st` 跨帧保存拖拽状态。
pub fn kanbanBegin(ui: *core.Context, id: []const u8, b: *Board, st: *KanbanState, opts: BoardOpts) void {
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 900;
    const h = if (opts.height > 0) opts.height else 430;
    const rect = ui.reserve(w, h, opts.width <= 0);
    b.* = .{
        .id = core.Context.idOf(id),
        .st = st,
        .opts = opts,
        .rect = rect,
        .saved_clip = ui.clip,
    };
    ui.clip = intersect(ui.clip, rect);
}

/// 看板：列 → 卡片。返回值表示「点了列头的 +」。
pub fn kanbanColumnBegin(ui: *core.Context, b: *Board, title: []const u8, card_count: i32, opts: ColumnOpts) bool {
    b.col += 1;
    b.card_pos = 0;
    b.index_set = false;
    b.is_target = false;
    b.ncols = b.col + 1;
    b.col_w = if (opts.width > 0) opts.width else 270;
    b.card_gap = if (opts.card_gap > 0) opts.card_gap else 8;
    b.col_x = b.rect.x + b.opts.pad + @as(f32, @floatFromInt(b.col)) * (b.col_w + b.opts.gap);
    b.col_top = b.rect.y + b.opts.pad;
    b.col_bottom = b.rect.y + b.rect.h - b.opts.pad;
    b.card_y = b.col_top + 46;

    const st = b.st;
    // 列背景 + 落点高亮
    const col_rect = t.Rect{ .x = b.col_x, .y = b.col_top, .w = b.col_w, .h = @max(80, b.col_bottom - b.col_top) };
    // 这一列是不是落点：拖动中，且指针（或键盘选中的列）落在这一列上
    const pointer_in = ui.input.mouse.x >= col_rect.x and ui.input.mouse.x < col_rect.x + col_rect.w;
    const hit_col = if (st.drag >= 0) (if (st.kbd) b.col == st.kcol else pointer_in) else false;
    if (hit_col) {
        b.is_target = true;
        st.target_col = b.col;
        if (st.kbd) {
            st.target_index = @min(st.kidx, card_count);
            b.index_set = true;
        }
    }
    ui.addBox(col_rect, .{
        .fill = theme.raised,
        .radius = 10,
        .border = if (b.is_target) theme.accent else theme.border,
    });

    // 列头：色点 + 标题 + 计数 + 「+」
    const head_y = b.col_top + 8;
    var hx = b.col_x + 10;
    if (opts.dot) |c| {
        ui.addBox(.{ .x = hx, .y = head_y + 6, .w = 8, .h = 8 }, .{ .fill = c, .radius = 4 });
        hx += 14;
    }
    const over = opts.limit > 0 and card_count > opts.limit;
    ui.addText(.{ .x = hx, .y = head_y, .w = b.col_w - 80, .h = theme.font_small * 1.4 }, title, theme.font_small, theme.text);

    var cb: [24]u8 = undefined;
    var cn: usize = 0;
    const c1 = num.int(cb[0..], card_count);
    cn = c1.len;
    if (opts.limit > 0) {
        cb[cn] = '/';
        cn += 1;
        const c2 = num.int(cb[cn..], opts.limit);
        cn += c2.len;
    }
    const cnt = ui.frameStr(cb[0..cn]);
    const cw = ui.measureText(cnt, theme.font_small).w;
    ui.addText(.{ .x = b.col_x + b.col_w - 44 - cw, .y = head_y, .w = cw + 2, .h = theme.font_small * 1.4 }, cnt, theme.font_small, if (over) theme.danger else theme.secondary);

    // 「+」小按钮（绝对定位，不用按钮控件的流式布局）
    const add_rect = t.Rect{ .x = b.col_x + b.col_w - 34, .y = head_y - 5, .w = 24, .h = 24 };
    const add_key = core.Context.idOf("kb-add") ^ (@as(u64, @bitCast(@as(i64, b.col))) *% 0x9E37);
    const add = ui.interact(add_key, add_rect);
    ui.addBox(add_rect, .{
        .fill = if (add.hover) theme.hover_overlay else theme.surface,
        .radius = 6,
        .border = theme.border,
    });
    const pw = ui.measureText("+", theme.font_body).w;
    ui.addText(.{ .x = add_rect.x + (add_rect.w - pw) / 2, .y = add_rect.y + 2, .w = pw + 2, .h = add_rect.h }, "+", theme.font_body, theme.text);

    // 落点槽位放在第一张卡之前（下面按卡片位置再修正）
    b.hole_y = b.card_y;
    return add.clicked;
}

/// 一张卡：`true` = 点了它。卡内容在 begin/end 之间画（可用常规流式控件）。
pub fn kanbanCardBegin(ui: *core.Context, b: *Board, card_id: i32, opts: CardOpts) bool {
    const st = b.st;
    const key = cardKey(b.id, card_id);
    const w = b.col_w - 20;
    const est_h = if (ui.knownSize(key)) |s| s.h else 64;
    const base_y = b.card_y;

    const dragging_me = st.drag == card_id;
    // 让位：落点列里、落点之后的卡整体下移（拖动中的那张不再占位）
    var shift: f32 = 0;
    if (st.drag >= 0) {
        if (b.is_target and b.index_set and b.card_pos >= st.target_index) shift = st.drag_h + b.card_gap;
        if (dragging_me and st.from_col == b.col) shift = 0;
    } else if (b.is_target) {
        shift = 0;
    }

    if (dragging_me) {
        // 只占位不画：源列留出空位，幽灵条由 kanbanEnd 画在最上面
        b.card_y += est_h + b.card_gap;
        b.card_pos += 1;
        return false;
    }

    // 指针越过这张卡的中线 → 落点就在它前面（只认第一次）
    if (b.is_target and st.drag >= 0 and !st.kbd and !b.index_set) {
        if (ui.input.mouse.y < base_y + est_h * 0.5) {
            st.target_index = b.card_pos;
            b.hole_y = base_y + shift;
            b.index_set = true;
        }
    }

    const rect = t.Rect{ .x = b.col_x + 10, .y = base_y + shift, .w = w, .h = est_h };
    b.card_rect = rect;
    b.card_key = key;
    b.card_open = true;

    const it = ui.interactEx(key, rect, true);
    // 按下 → 记下候选拖动（越过阈值才真的抬起）
    if (it.pressed and st.drag < 0) {
        st.press = card_id;
        st.press_col = b.col;
        st.press_x = ui.input.mouse.x;
        st.press_y = ui.input.mouse.y;
        st.grab_x = ui.input.mouse.x - rect.x;
        st.grab_y = ui.input.mouse.y - rect.y;
        st.drag_w = rect.w;
        st.drag_h = rect.h;
        st.drag_title = if (opts.title.len > 0) opts.title else "";
        st.kbd = false;
    }
    if (it.focused and ui.input.keyPressed(.space) and st.drag < 0) {
        st.drag = card_id;
        st.from_col = b.col;
        st.kbd = true;
        st.kcol = b.col;
        st.kidx = b.card_pos;
        st.drag_w = rect.w;
        st.drag_h = rect.h;
        st.drag_title = if (opts.title.len > 0) opts.title else "";
    }

    b.card_scope = ui.panel(rect, .{
        .fill = theme.surface,
        .radius = 8,
        .border = if (it.hover and st.drag < 0) theme.accent else theme.border,
        .pad = 10,
        .gap = 6,
        .auto_height = true,
        .size_key = key,
    });
    if (it.focused) ui.addBox(rect.inset(-2), .{ .border = theme.accent, .radius = 10 });
    b.card_y = base_y + est_h + b.card_gap;
    b.card_pos += 1;
    return it.clicked and st.drag < 0;
}

pub fn kanbanCardEnd(ui: *core.Context, b: *Board) void {
    _ = ui;
    if (!b.card_open) return;
    b.card_scope.end();
    b.card_open = false;
}

pub fn kanbanColumnEnd(ui: *core.Context, b: *Board) void {
    const st = b.st;
    if (st.drag >= 0 and b.is_target) {
        // 落点在最后一排之后
        if (!b.index_set) {
            st.target_index = b.card_pos;
            b.hole_y = b.card_y;
            b.index_set = true;
        }
        const hole = t.Rect{
            .x = b.col_x + 10,
            .y = b.hole_y,
            .w = b.col_w - 20,
            .h = @max(28, st.drag_h),
        };
        ui.addBox(hole, .{ .fill = theme.withAlpha(theme.accent, 28), .radius = 8, .border = theme.withAlpha(theme.accent, 120) });
        const tw = ui.measureText("Drop here", theme.font_small).w;
        ui.addText(.{ .x = hole.x + (hole.w - tw) / 2, .y = hole.y + hole.h * 0.5 - 8, .w = tw + 2, .h = 16 }, "Drop here", theme.font_small, theme.accent);
    }
    // 列内卡片溢出面板 → 提示（不画滚动条：看板高度由调用方定）
    if (b.card_y > b.col_bottom + 1) {
        const over = b.card_y - b.col_bottom;
        if (over > 20) ui.addText(.{ .x = b.col_x + 10, .y = b.col_bottom - 16, .w = b.col_w - 20, .h = 16 }, "…", theme.font_small, theme.secondary);
    }
}

/// 收尾：返回换位结果（`null` = 没发生拖动落下）。
pub fn kanbanEnd(ui: *core.Context, b: *Board) ?KanbanMove {
    const st = b.st;
    var move: ?KanbanMove = null;

    // 按下后越过阈值 → 真正进入拖动
    if (st.press >= 0 and st.drag < 0) {
        const dx = ui.input.mouse.x - st.press_x;
        const dy = ui.input.mouse.y - st.press_y;
        if (ui.input.down and dx * dx + dy * dy > SLOP * SLOP) {
            st.drag = st.press;
            st.from_col = st.press_col;
            st.target_col = -1;
        }
        if (!ui.input.down) st.press = -1;
    }

    // 指针抬起 → 落下
    if (st.drag >= 0 and !st.kbd and !ui.input.down) {
        if (st.target_col >= 0 and st.target_index >= 0) {
            move = .{ .card = st.drag, .from_column = st.from_col, .to_column = st.target_col, .to_index = st.target_index };
        }
        st.drag = -1;
        st.press = -1;
    }
    // 键盘：方向键选位、回车落下、Esc 取消
    if (st.kbd and st.drag >= 0) {
        if (ui.input.keyPressed(.left)) st.kcol = @max(0, st.kcol - 1);
        if (ui.input.keyPressed(.right)) st.kcol = @min(@max(0, b.ncols - 1), st.kcol + 1);
        if (ui.input.keyPressed(.up)) st.kidx = @max(0, st.kidx - 1);
        if (ui.input.keyPressed(.down)) st.kidx += 1;
        if (ui.input.keyPressed(.escape)) {
            st.drag = -1;
            st.kbd = false;
        }
        if (ui.input.keyPressed(.enter) and st.target_col >= 0) {
            move = .{ .card = st.drag, .from_column = st.from_col, .to_column = st.target_col, .to_index = st.target_index };
            st.drag = -1;
            st.kbd = false;
        }
        ui.requestFrame();
    }

    // 幽灵条：画在所有列之上（本层 overlay 段之后就是文本层）
    if (st.drag >= 0 and !st.kbd) {
        const gx = ui.input.mouse.x - st.grab_x;
        const gy = ui.input.mouse.y - st.grab_y;
        const gr = t.Rect{ .x = gx, .y = gy, .w = st.drag_w, .h = st.drag_h };
        ui.addOverlayBox(gr, .{ .fill = theme.surface, .radius = 8, .border = theme.accent });
        if (st.drag_title.len > 0) {
            ui.addText(.{ .x = gr.x + 10, .y = gr.y + 8, .w = gr.w - 20, .h = theme.font_small * 1.4 }, st.drag_title, theme.font_small, theme.text);
        }
    }

    ui.clip = b.saved_clip;
    return move;
}

// ====================================================================== 周历

pub const CalEvent = struct {
    title: []const u8 = "",
    detail: []const u8 = "",
    /// 0..6，相对 `week_start`。
    day: i32 = 0,
    /// 起止时刻，十进制小时（9.5 = 9:30）。
    start: f32 = 9,
    end: f32 = 10,
    tone: ?Tone = null,
};

pub const WeekOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    height: f32 = 460,
    start_hour: f32 = 7,
    end_hour: f32 = 21,
    hour_height: f32 = 52,
    read_only: bool = false,
    /// 今天（高亮当天列 + now 线）；null = 不画。
    today: ?Date = null,
    /// 当前时刻（十进制小时），配合 `today` 画 now 线。
    now: ?f32 = null,
};

pub const WeekState = struct {
    /// 正在拖的事件下标，-1 = 没在拖。
    drag: i32 = -1,
    /// 1 = 整体移动，2 = 拉下边界。
    mode: u8 = 1,
    grab: f32 = 0,
    moved: bool = false,
    press_x: f32 = 0,
    press_y: f32 = 0,
    scroll: f32 = 0,
    /// 上次算出来的可滚范围（滚轮夹取用）。
    max_scroll: f32 = 0,
};

const MAX_LANES = 64;

/// 周历。返回被点击的事件下标（拖拽结束也算一次点击）。
pub fn weekCalendar(
    ui: *core.Context,
    id: []const u8,
    week_start: Date,
    events: []CalEvent,
    st: *WeekState,
    opts: WeekOpts,
) ?usize {
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 720;
    const h = if (opts.height > 0) opts.height else 460;
    const h0 = if (opts.end_hour > opts.start_hour) opts.start_hour else 7;
    const h1 = if (opts.end_hour > opts.start_hour) opts.end_hour else 21;
    const hour_h = if (opts.hour_height > 0) opts.hour_height else 52;
    const narrow = w < 520;
    const gutter: f32 = if (narrow) 44 else 60;
    const header_h: f32 = 52;

    const rect = ui.reserve(w, h, opts.width <= 0);
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 10, .border = theme.border });

    const day_w = @max(28, (rect.w - gutter) / 7);
    const grid_top = rect.y + header_h + 1;
    const grid = t.Rect{ .x = rect.x, .y = grid_top, .w = rect.w, .h = rect.h - header_h - 1 };
    const content_h = (h1 - h0) * hour_h;
    st.max_scroll = @max(0, content_h - grid.h);
    if (st.scroll > st.max_scroll) st.scroll = st.max_scroll;
    if (st.scroll < 0) st.scroll = 0;

    // 滚轮（指针在网格上时）
    const grid_hit = ui.interact(core.Context.idOf(id) ^ 0x5B01, grid);
    if (grid_hit.hover and ui.input.wheel != 0 and st.max_scroll > 0) {
        st.scroll = clampF(st.scroll - ui.input.wheel * 28, 0, st.max_scroll);
    }

    // 今天在高亮时需要知道是第几列
    const base = dateToDays(week_start);
    var today_col: i32 = -1;
    if (opts.today) |td| {
        const d = dateToDays(td) - base;
        if (d >= 0 and d < 7) today_col = d;
    }

    // ---- 表头：星期名 + 日期圆点
    {
        const hx = rect.x + gutter;
        var k: i32 = 0;
        while (k < 7) : (k += 1) {
            const d = dateFromDays(base + k);
            const wd: usize = @intCast(@mod(month.weekdayOf(week_start) + @as(u8, @intCast(k)), 7));
            const is_today = k == today_col;
            const cx = hx + @as(f32, @floatFromInt(k)) * day_w;
            const label = strings.weekdayShort(ui, wd);
            const lw = ui.measureText(label, theme.font_small).w;
            ui.addText(.{ .x = cx + (day_w - lw) / 2, .y = rect.y + 10, .w = lw + 2, .h = 16 }, label, theme.font_small, if (is_today) theme.accent else theme.secondary);
            var db: [4]u8 = undefined;
            const dt = ui.frameStr(num.int(db[0..], d.day));
            const dw = ui.measureText(dt, theme.font_body).w;
            const bubble = t.Rect{ .x = cx + (day_w - 28) / 2, .y = rect.y + 26, .w = 28, .h = 22 };
            if (is_today) ui.addBox(bubble, .{ .fill = theme.accent, .radius = 11 });
            ui.addText(.{ .x = cx + (day_w - dw) / 2, .y = bubble.y + 3, .w = dw + 2, .h = 18 }, dt, theme.font_body, if (is_today) theme.accent_text else theme.text);
        }
        ui.addOverlayLine(.{ .x = rect.x, .y = grid_top - 1 }, .{ .x = rect.x + rect.w, .y = grid_top - 1 }, 1, theme.border);
    }

    // ---- 网格 + 事件（裁到网格内）
    const saved = ui.clip;
    ui.clip = intersect(saved, grid);
    {
        // 今天列底色
        if (today_col >= 0) {
            ui.addBox(.{ .x = rect.x + gutter + @as(f32, @floatFromInt(today_col)) * day_w, .y = grid.y, .w = day_w, .h = grid.h }, .{ .fill = theme.withAlpha(theme.accent, 10) });
        }
        // 小时线（整点 + 半点淡线）与刻度
        var hh: f32 = h0;
        while (hh <= h1 + 0.001) : (hh += 1) {
            const y = grid.y + (hh - h0) * hour_h - st.scroll;
            if (y >= grid.y - 1 and y <= grid.y + grid.h + 1) {
                ui.addOverlayLine(.{ .x = grid.x + gutter, .y = @floor(y) }, .{ .x = grid.x + grid.w, .y = @floor(y) }, 1, theme.border);
                var tb: [8]u8 = undefined;
                const lt = ui.frameStr(fmtTime(tb[0..], hh));
                const lw = ui.measureText(lt, theme.font_small).w;
                ui.addText(.{ .x = grid.x + gutter - 10 - lw, .y = y - theme.font_small * 0.7, .w = lw + 2, .h = 16 }, lt, theme.font_small, theme.secondary);
                const half = y + hour_h * 0.5;
                if (half < grid.y + grid.h) {
                    ui.addOverlayLine(.{ .x = grid.x + gutter, .y = @floor(half) }, .{ .x = grid.x + grid.w, .y = @floor(half) }, 1, theme.hair);
                }
            }
        }
        // 天分隔线
        var k: i32 = 0;
        while (k <= 7) : (k += 1) {
            const x = grid.x + gutter + @as(f32, @floatFromInt(k)) * day_w;
            ui.addOverlayLine(.{ .x = @floor(x), .y = grid.y }, .{ .x = @floor(x), .y = grid.y + grid.h }, 1, if (k == 0 or k == 7) theme.border else theme.hair);
        }
        // now 线
        if (today_col >= 0) {
            if (opts.now) |now| {
                if (now >= h0 and now <= h1) {
                    const y = grid.y + (now - h0) * hour_h - st.scroll;
                    const x0 = grid.x + gutter + @as(f32, @floatFromInt(today_col)) * day_w;
                    ui.addOverlayLine(.{ .x = x0, .y = y }, .{ .x = x0 + day_w, .y = y }, 2, theme.danger);
                    ui.addOverlayBox(.{ .x = x0 - 3, .y = y - 3, .w = 7, .h = 7 }, .{ .fill = theme.danger, .radius = 3.5 });
                }
            }
        }

        // ---- 重叠事件分栏（同一天内按起始顺序各占一列；起点相近的并排、错开的层叠）
        var colk: [MAX_LANES]u8 = @splat(0);
        var ncol: [MAX_LANES]u8 = @splat(1);
        var lanes: [MAX_LANES]bool = @splat(false);
        const n = @min(events.len, MAX_LANES);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = events[i];
            var c: u8 = 0;
            while (c < 8) : (c += 1) {
                var clash = false;
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    const q = events[j];
                    if (q.day == e.day and colk[j] == c and q.start < e.end and e.start < q.end) clash = true;
                }
                if (!clash) break;
            }
            colk[i] = c;
        }
        i = 0;
        while (i < n) : (i += 1) {
            const e = events[i];
            ncol[i] = colk[i] + 1; // 自己那一栏也算
            var j2: usize = 0;
            while (j2 < n) : (j2 += 1) {
                const q = events[j2];
                if (j2 != i and q.day == e.day and q.start < e.end and e.start < q.end) {
                    ncol[i] = @max(ncol[i], colk[j2] + 1);
                    if (@abs(q.start - e.start) < 0.5) lanes[i] = true;
                }
            }
        }

        i = 0;
        while (i < n) : (i += 1) {
            const e = &events[i];
            if (e.day < 0 or e.day > 6 or e.end <= h0 or e.start >= h1) continue;
            const lane_w = (day_w - 6) / @as(f32, @floatFromInt(ncol[i]));
            const cascade = !lanes[i] and ncol[i] > 1;
            var x: f32 = 0;
            var ww: f32 = lane_w;
            if (cascade) {
                const indent = @min(day_w * 0.3, 32) * @as(f32, @floatFromInt(colk[i]));
                x = grid.x + gutter + @as(f32, @floatFromInt(e.day)) * day_w + 3 + indent;
                ww = day_w - 6 - indent;
            } else {
                x = grid.x + gutter + @as(f32, @floatFromInt(e.day)) * day_w + 3 + @as(f32, @floatFromInt(colk[i])) * lane_w;
            }
            const y = grid.y + (@max(e.start, h0) - h0) * hour_h - st.scroll + 1;
            const eh = (@min(e.end, h1) - @max(e.start, h0)) * hour_h - 2;
            if (y + eh < grid.y or y > grid.y + grid.h) continue;
            const er = t.Rect{ .x = x, .y = y, .w = ww - 2, .h = @max(18, eh) };

            const eid = eventKey(core.Context.idOf(id), i);
            const it = ui.interactEx(eid, er, true);
            const tone = trace.toneColor(e.tone orelse .accent);
            const dragging = st.drag == @as(i32, @intCast(i));
            const near_bottom = ui.input.mouse.y > er.y + er.h - 7;

            // 按下 → 候选拖动（拉下边界 / 整体移动）
            if (it.pressed and st.drag < 0 and !opts.read_only) {
                st.drag = @intCast(i);
                st.moved = false;
                st.press_x = ui.input.mouse.x;
                st.press_y = ui.input.mouse.y;
                st.mode = if (near_bottom) 2 else 1;
                st.grab = ui.input.mouse.y - er.y;
            }

            ui.addBox(er, .{
                .fill = theme.withAlpha(tone, if (it.hover and st.drag < 0) 52 else 40),
                .radius = 6,
                .border = if (dragging) theme.accent else null,
            });
            ui.addOverlayBox(.{ .x = er.x + 3, .y = er.y + 4, .w = 3, .h = @max(6, er.h - 8) }, .{ .fill = tone, .radius = 1.5 });

            const short_ev = er.h < 30;
            const tx = er.x + 10;
            const tw = @max(10, er.w - 16);
            const fg = theme.text;
            if (short_ev) {
                ui.addText(.{ .x = tx, .y = er.y + er.h * 0.5 - 8, .w = tw, .h = 16 }, fitText(ui, e.title, theme.font_small, tw), theme.font_small, fg);
            } else {
                ui.addText(.{ .x = tx, .y = er.y + 5, .w = tw, .h = 16 }, fitText(ui, e.title, theme.font_small, tw), theme.font_small, fg);
                // 窄栏只留标题：文本会按给定宽度裁切，半个 "10:0" 比没有更难看
                if (er.h > 34 and er.w > 78) {
                    var tb: [16]u8 = undefined;
                    const tm = ui.frameStr(fmtTime(tb[0..], e.start));
                    if (ui.measureText(tm, theme.font_small).w <= tw) {
                        ui.addText(.{ .x = tx, .y = er.y + 22, .w = tw, .h = 15 }, tm, theme.font_small, theme.secondary);
                    }
                    if (e.detail.len > 0 and er.h > 56 and ui.measureText(e.detail, theme.font_small).w <= tw) {
                        ui.addText(.{ .x = tx, .y = er.y + 37, .w = tw, .h = 15 }, e.detail, theme.font_small, theme.secondary);
                    }
                }
            }
            if (it.focused) ui.addBox(er.inset(-2), .{ .border = theme.accent, .radius = 8 });

            // 键盘：上下挪 15 分钟、左右挪一天；Shift 改结束时刻
            if (it.focused and !opts.read_only) {
                var changed = false;
                var dt: f32 = 0;
                if (ui.input.keyPressed(.down)) dt = 0.25;
                if (ui.input.keyPressed(.up)) dt = -0.25;
                if (dt != 0) {
                    if (ui.input.mods.shift) {
                        e.end = clampF(e.end + dt, e.start + 0.25, h1);
                    } else {
                        const dur = e.end - e.start;
                        e.start = clampF(e.start + dt, h0, h1 - dur);
                        e.end = e.start + dur;
                    }
                    changed = true;
                }
                var dday: i32 = 0;
                if (ui.input.keyPressed(.right)) dday = 1;
                if (ui.input.keyPressed(.left)) dday = -1;
                if (dday != 0) {
                    e.day = std.math.clamp(e.day + dday, 0, 6);
                    changed = true;
                }
                if (changed) ui.requestFrame();
            }
        }

        // ---- 拖拽推进（在事件循环外统一处理，避免边画边改）
        if (st.drag >= 0 and !opts.read_only) {
            const di: usize = @intCast(st.drag);
            if (st.drag < @as(i32, @intCast(n))) {
                const e = &events[di];
                if (ui.input.down) {
                    const dx = ui.input.mouse.x - st.press_x;
                    const dy = ui.input.mouse.y - st.press_y;
                    if (@abs(dx) + @abs(dy) > SLOP) st.moved = true;
                    if (st.moved) {
                        if (st.mode == 1) {
                            const dur = e.end - e.start;
                            const day = @as(i32, @intFromFloat(@floor((ui.input.mouse.x - grid.x - gutter) / day_w)));
                            e.day = std.math.clamp(day, 0, 6);
                            const start = @round(((ui.input.mouse.y - grid.y + st.scroll - st.grab) / hour_h + h0) * 4) / 4;
                            e.start = clampF(start, h0, h1 - dur);
                            e.end = e.start + dur;
                        } else {
                            const end = @round(((ui.input.mouse.y - grid.y + st.scroll) / hour_h + h0) * 4) / 4;
                            e.end = clampF(end, e.start + 0.25, h1);
                        }
                        ui.requestFrame();
                    }
                } else {
                    const clicked = !st.moved;
                    st.drag = -1;
                    st.moved = false;
                    if (clicked) return di;
                }
            } else {
                st.drag = -1;
            }
        }
    }
    ui.clip = saved;

    // 滚动条
    if (st.max_scroll > 0) {
        const th = @max(20, grid.h * grid.h / content_h);
        const ty = grid.y + (grid.h - th) * (st.scroll / st.max_scroll);
        ui.addBox(.{ .x = rect.x + rect.w - 6, .y = ty, .w = 3, .h = th }, .{ .fill = theme.withAlpha(theme.secondary, 110), .radius = 1.5 });
    }
    return null;
}

fn dateToDays(d: Date) i32 {
    return @intCast(month.daysFromCivil(d));
}

fn dateFromDays(days: i32) Date {
    return month.fromDays(days);
}

// ====================================================================== 甘特图

pub const GanttTask = struct {
    name: []const u8 = "",
    owner: []const u8 = "",
    /// 起点/终点（天序号，0 = origin 当天；终点不含）。
    start: i32 = 0,
    end: i32 = 1,
    /// 0..1
    progress: f32 = 0,
    tone: ?Tone = null,
    /// 依赖的任务下标，-1 = 无。
    depends_on: i32 = -1,
    milestone: bool = false,
};

pub const GanttOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    day_width: f32 = 30,
    row_height: f32 = 40,
    /// 今天（天序号，相对 origin）；-1 = 不画。
    today: i32 = -1,
    read_only: bool = false,
    /// 左侧任务列宽（窄于 480 自动收窄）。
    list_width: f32 = 230,
};

pub const GanttState = struct {
    /// 正在拖的任务下标 + 模式（1 整体、2 左边界、3 右边界）。
    drag: i32 = -1,
    mode: u8 = 1,
    press_x: f32 = 0,
    moved: bool = false,
    orig_start: i32 = 0,
    orig_end: i32 = 1,
    scroll: f32 = 0,
    max_scroll: f32 = 0,
};

/// 甘特图。返回被点击的任务下标。
pub fn gantt(
    ui: *core.Context,
    id: []const u8,
    tasks: []GanttTask,
    origin: Date,
    days: i32,
    st: *GanttState,
    opts: GanttOpts,
) ?usize {
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 760;
    const dw = if (opts.day_width > 0) opts.day_width else 30;
    const rh = if (opts.row_height > 0) opts.row_height else 40;
    const n_days = @max(1, days);
    const head_h: f32 = 52;
    const slim = w < 480;
    const list_w = if (slim) @min(128, opts.list_width) else opts.list_width;
    const total_h = head_h + @as(f32, @floatFromInt(tasks.len)) * rh;

    const rect = ui.reserve(w, total_h, opts.width <= 0);
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 10, .border = theme.border });

    const list = t.Rect{ .x = rect.x, .y = rect.y, .w = list_w, .h = rect.h };
    const tl = t.Rect{ .x = rect.x + list_w + 1, .y = rect.y, .w = rect.w - list_w - 1, .h = rect.h };
    const content_w = @as(f32, @floatFromInt(n_days)) * dw;
    st.max_scroll = @max(0, content_w - tl.w);
    if (st.scroll > st.max_scroll) st.scroll = st.max_scroll;
    if (st.scroll < 0) st.scroll = 0;

    const tl_hit = ui.interact(core.Context.idOf(id) ^ 0x6A01, tl);
    if (tl_hit.hover and ui.input.wheel != 0 and st.max_scroll > 0) {
        st.scroll = clampF(st.scroll - ui.input.wheel * 24, 0, st.max_scroll);
    }

    const base = dateToDays(origin);
    const first_wd: usize = @intCast(@mod(base + 3, 7));

    // ---- 左侧任务列
    {
        ui.addBox(.{ .x = list.x, .y = list.y, .w = list.w, .h = head_h }, .{ .fill = theme.raised, .radius = 10 });
        ui.addBox(.{ .x = list.x, .y = list.y + 10, .w = list.w, .h = head_h - 10 }, .{ .fill = theme.raised });
        ui.addText(.{ .x = list.x + 14, .y = list.y + head_h - 24, .w = list.w - 20, .h = 18 }, "Task", theme.font_small, theme.secondary);
        var k: usize = 0;
        while (k < tasks.len) : (k += 1) {
            const ty = list.y + head_h + @as(f32, @floatFromInt(k)) * rh;
            if (ty + rh < list.y or ty > list.y + list.h) continue;
            const tone = trace.toneColor(tasks[k].tone orelse .accent);
            if (st.drag == @as(i32, @intCast(k))) {
                ui.addBox(.{ .x = list.x, .y = ty, .w = list.w, .h = rh }, .{ .fill = theme.accent_bg });
            }
            ui.addBox(.{ .x = list.x + 12, .y = ty + rh * 0.5 - 4, .w = 8, .h = 8 }, .{ .fill = tone, .radius = if (tasks[k].milestone) 1 else 4 });
            const name_w = list.w - (if (slim) @as(f32, 40) else @as(f32, 70));
            ui.addText(.{ .x = list.x + 26, .y = ty + rh * 0.5 - 8, .w = name_w, .h = 18 }, fitText(ui, tasks[k].name, theme.font_small, name_w - 4), theme.font_small, theme.text);
            if (!slim and tasks[k].owner.len > 0) {
                const ow = ui.measureText(tasks[k].owner, theme.font_small).w;
                ui.addText(.{ .x = list.x + list.w - 12 - ow, .y = ty + rh * 0.5 - 8, .w = ow + 2, .h = 16 }, tasks[k].owner, theme.font_small, theme.secondary);
            }
            ui.addOverlayLine(.{ .x = list.x, .y = @floor(ty + rh) }, .{ .x = list.x + list.w, .y = @floor(ty + rh) }, 1, theme.hair);
        }
        ui.addOverlayLine(.{ .x = list.x + list.w, .y = list.y }, .{ .x = list.x + list.w, .y = list.y + list.h }, 1, theme.border);
    }

    // ---- 右侧时间轴（裁到 tl 内）
    const saved = ui.clip;
    ui.clip = intersect(saved, tl);
    {
        // 表头：月份行 + 日号行
        ui.addBox(.{ .x = tl.x, .y = tl.y, .w = tl.w, .h = head_h }, .{ .fill = theme.raised });
        ui.addBox(.{ .x = tl.x, .y = tl.y + 10, .w = tl.w, .h = head_h - 10 }, .{ .fill = theme.raised });
        var mstart: i32 = 0;
        while (mstart < n_days) {
            const d = dateFromDays(base + mstart);
            var left: i32 = 0;
            while (mstart + left < n_days and dateFromDays(base + mstart + left).month == d.month) left += 1;
            const mx = tl.x + @as(f32, @floatFromInt(mstart)) * dw - st.scroll;
            if (@as(f32, @floatFromInt(left)) * dw > 30) {
                const label = strings.monthShort(ui, d.month);
                ui.addText(.{ .x = mx + 4, .y = tl.y + 4, .w = @as(f32, @floatFromInt(left)) * dw - 6, .h = 16 }, label, theme.font_small, theme.secondary);
            }
            mstart += left;
        }
        var dd: i32 = 0;
        while (dd < n_days) : (dd += 1) {
            const x = tl.x + @as(f32, @floatFromInt(dd)) * dw - st.scroll;
            if (x + dw < tl.x or x > tl.x + tl.w) continue;
            const cd = dateFromDays(base + dd);
            const wd = (first_wd + @as(usize, @intCast(@mod(dd, 7)))) % 7;
            const is_today = dd == opts.today;
            var dbb: [4]u8 = undefined;
            const dt = ui.frameStr(num.int(dbb[0..], cd.day));
            const tw = ui.measureText(dt, theme.font_small).w;
            ui.addText(.{ .x = x + (dw - tw) / 2, .y = tl.y + 26, .w = tw + 2, .h = 16 }, dt, theme.font_small, if (is_today) theme.danger else if (wd >= 5) theme.secondary else theme.text);
        }
        ui.addOverlayLine(.{ .x = tl.x, .y = tl.y + head_h }, .{ .x = tl.x + tl.w, .y = tl.y + head_h }, 1, theme.border);

        // 周末底色 + 日分隔线 + 行线
        const body = t.Rect{ .x = tl.x, .y = tl.y + head_h + 1, .w = tl.w, .h = tl.h - head_h - 1 };
        dd = 0;
        while (dd < n_days) : (dd += 1) {
            const x = tl.x + @as(f32, @floatFromInt(dd)) * dw - st.scroll;
            const wd = (first_wd + @as(usize, @intCast(@mod(dd, 7)))) % 7;
            if (wd >= 5) {
                ui.addBox(.{ .x = x, .y = body.y, .w = dw, .h = body.h }, .{ .fill = theme.withAlpha(theme.secondary, 10) });
            }
            if (wd == 0) ui.addOverlayLine(.{ .x = @floor(x), .y = body.y }, .{ .x = @floor(x), .y = body.y + body.h }, 1, theme.border);
        }
        var r: usize = 1;
        while (r < tasks.len) : (r += 1) {
            const y = body.y + @as(f32, @floatFromInt(r)) * rh;
            ui.addOverlayLine(.{ .x = body.x, .y = @floor(y) }, .{ .x = body.x + body.w, .y = @floor(y) }, 1, theme.hair);
        }
        // 今天竖线
        if (opts.today >= 0 and opts.today < n_days) {
            const x = tl.x + (@as(f32, @floatFromInt(opts.today)) + 0.5) * dw - st.scroll;
            ui.addOverlayLine(.{ .x = @floor(x), .y = body.y }, .{ .x = @floor(x), .y = body.y + body.h }, 2, theme.danger);
        }

        // 依赖折线（先画线，条压在线上）
        for (tasks, 0..) |tk, kk| {
            const dep = tk.depends_on;
            if (dep < 0 or dep >= @as(i32, @intCast(tasks.len)) or dep == @as(i32, @intCast(kk))) continue;
            const a = tasks[@intCast(dep)];
            const x0 = tl.x + @as(f32, @floatFromInt(a.end)) * dw - st.scroll;
            const y0 = body.y + (@as(f32, @floatFromInt(dep)) + 0.5) * rh;
            const x1 = tl.x + @as(f32, @floatFromInt(tk.start)) * dw - st.scroll;
            const y1 = body.y + (@as(f32, @floatFromInt(kk)) + 0.5) * rh;
            const xm = x0 + 8;
            const c = theme.withAlpha(theme.secondary, 150);
            ui.addOverlayLine(.{ .x = x0, .y = y0 }, .{ .x = xm, .y = y0 }, 1.4, c);
            if (x1 - 10 >= xm) {
                ui.addOverlayLine(.{ .x = xm, .y = y0 }, .{ .x = xm, .y = y1 }, 1.4, c);
                ui.addOverlayLine(.{ .x = xm, .y = y1 }, .{ .x = x1 - 2, .y = y1 }, 1.4, c);
            } else {
                const ym = y0 + (if (y1 > y0) rh * 0.5 else -rh * 0.5);
                ui.addOverlayLine(.{ .x = xm, .y = y0 }, .{ .x = xm, .y = ym }, 1.4, c);
                ui.addOverlayLine(.{ .x = xm, .y = ym }, .{ .x = x1 - 10, .y = ym }, 1.4, c);
                ui.addOverlayLine(.{ .x = x1 - 10, .y = ym }, .{ .x = x1 - 10, .y = y1 }, 1.4, c);
                ui.addOverlayLine(.{ .x = x1 - 10, .y = y1 }, .{ .x = x1 - 2, .y = y1 }, 1.4, c);
            }
            // 箭头（两笔，代替多边形）
            ui.addOverlayLine(.{ .x = x1 - 1, .y = y1 }, .{ .x = x1 - 6, .y = y1 - 3.5 }, 1.4, c);
            ui.addOverlayLine(.{ .x = x1 - 1, .y = y1 }, .{ .x = x1 - 6, .y = y1 + 3.5 }, 1.4, c);
        }

        // 任务条
        for (tasks, 0..) |*tk, kk| {
            const row_y = body.y + @as(f32, @floatFromInt(kk)) * rh;
            const bh = rh - 16;
            var bx = tl.x + @as(f32, @floatFromInt(tk.start)) * dw - st.scroll + 2;
            var bw = @max(dw - 4, @as(f32, @floatFromInt(tk.end - tk.start)) * dw - 4);
            if (tk.milestone) {
                bw = bh + 4;
                bx = tl.x + @as(f32, @floatFromInt(tk.start)) * dw - st.scroll - bw * 0.5;
            }
            const br = t.Rect{ .x = bx, .y = row_y + 8, .w = bw, .h = bh };
            if (br.x + br.w < tl.x or br.x > tl.x + tl.w) continue;

            const tid = taskKey(core.Context.idOf(id), kk);
            const it = ui.interactEx(tid, br, true);
            const tone = trace.toneColor(tk.tone orelse .accent);
            const near_l = it.hover and ui.input.mouse.x < br.x + 7 and !tk.milestone;
            const near_r = it.hover and ui.input.mouse.x > br.x + br.w - 7 and !tk.milestone;
            if (it.pressed and st.drag < 0 and !opts.read_only) {
                st.drag = @intCast(kk);
                st.moved = false;
                st.press_x = ui.input.mouse.x;
                st.orig_start = tk.start;
                st.orig_end = tk.end;
                st.mode = if (near_l) 2 else if (near_r) 3 else 1;
            }
            // 键盘：左右挪一天，Shift 改长度
            if (it.focused and !opts.read_only) {
                var dd2: i32 = 0;
                if (ui.input.keyPressed(.right)) dd2 = 1;
                if (ui.input.keyPressed(.left)) dd2 = -1;
                if (dd2 != 0) {
                    const len = tk.end - tk.start;
                    if (ui.input.mods.shift) {
                        if (!tk.milestone) tk.end = std.math.clamp(tk.end + dd2, tk.start + 1, n_days);
                    } else {
                        tk.start = std.math.clamp(tk.start + dd2, 0, n_days - len);
                        tk.end = tk.start + len;
                    }
                    ui.requestFrame();
                }
            }

            if (tk.milestone) {
                ui.addBox(br, .{ .fill = tone, .radius = @min(br.w, br.h) * 0.5 });
            } else {
                ui.addBox(br, .{ .fill = theme.withAlpha(tone, if (it.hover) 90 else 70), .radius = 5, .border = if (st.drag == @as(i32, @intCast(kk))) theme.accent else null });
                const pr = clampF(tk.progress, 0, 1);
                if (pr > 0) {
                    const saved2 = ui.clip;
                    ui.clip = intersect(saved2, br);
                    ui.addBox(.{ .x = br.x, .y = br.y, .w = @max(2, br.w * pr), .h = br.h }, .{ .fill = theme.withAlpha(tone, 170), .radius = 5 });
                    ui.clip = saved2;
                }
                if (br.w > 60) {
                    ui.addText(.{ .x = br.x + 8, .y = br.y + br.h * 0.5 - 8, .w = br.w - 16, .h = 16 }, fitText(ui, tk.name, theme.font_small, br.w - 16), theme.font_small, if (pr > 0.5) theme.accent_text else theme.text);
                }
            }
            if (it.focused) ui.addBox(br.inset(-2), .{ .border = theme.accent, .radius = 7 });
        }

        // 拖拽推进
        if (st.drag >= 0 and !opts.read_only and st.drag < @as(i32, @intCast(tasks.len))) {
            const tk = &tasks[@intCast(st.drag)];
            if (ui.input.down) {
                if (@abs(ui.input.mouse.x - st.press_x) > SLOP) st.moved = true;
                if (st.moved) {
                    const dd2: i32 = @intFromFloat(@round((ui.input.mouse.x - st.press_x) / dw));
                    const len = st.orig_end - st.orig_start;
                    switch (st.mode) {
                        2 => tk.start = std.math.clamp(st.orig_start + dd2, 0, st.orig_end - 1),
                        3 => tk.end = std.math.clamp(st.orig_end + dd2, st.orig_start + 1, n_days),
                        else => {
                            tk.start = std.math.clamp(st.orig_start + dd2, 0, n_days - len);
                            tk.end = tk.start + len;
                        },
                    }
                    ui.requestFrame();
                }
            }
        }
    }
    ui.clip = saved;

    // 横向滚动条
    if (st.max_scroll > 0) {
        const th = @max(20, tl.w * tl.w / content_w);
        const tx = tl.x + (tl.w - th) * (st.scroll / st.max_scroll);
        ui.addBox(.{ .x = tx, .y = rect.y + rect.h - 4, .w = th, .h = 3 }, .{ .fill = theme.withAlpha(theme.secondary, 110), .radius = 1.5 });
    }

    // 拖拽松手：单击算点击
    if (st.drag >= 0 and !ui.input.down) {
        const idx = st.drag;
        const moved = st.moved;
        st.drag = -1;
        st.moved = false;
        if (!moved) return @intCast(idx);
    }
    return null;
}
