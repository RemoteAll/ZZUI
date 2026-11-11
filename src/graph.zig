//! 图族（对位 CUI `cui_graph.c`）：提交图（分支泳道）与依赖图（分层 + 缩放平移）。
//!
//! **提交图** `commitGraph`：每行一条提交，左侧分支泳道（合并画成环），右侧 refs 徽标 +
//! 首行消息 + 作者 + 日期 + 短哈希。上下键移动、回车激活、滚轮滚动、点击选中。
//!
//! **依赖图** `depGraph`：节点按层排布（同一层内按邻居重心排几轮），滚轮缩放、拖拽平移、
//! 点击选中、悬停高亮「它依赖谁 / 谁依赖它」，`F` 适配、`+`/`-` 缩放、`Esc` 清选中。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **提交图不做几何缓存**（CUI 把泳道算好存起来并带析构）：这里每帧线性走一遍，
//!   几百上千行是毫秒级，换来零分配。泳道连接线用**直线段**而不是 S 曲线 ——
//!   S 曲线要 8 段折线，15 行 × 12 泳道会顶穿 `MAX_COMMANDS` 的指令预算。
//! - **依赖图不做绕行航点**（CUI 给跨层边在每层插一个航点绕开节点）：这里跨层边一条三点折线直接过。
//! - **固定容量**：依赖图 `MAX_NODES = 64` / `MAX_EDGES = 128`，超出部分不进布局，
//!   由 `Result.overflow` 显式告知（不静默丢弃）。
//! - 没有光标形状通道，所以没有手型 / 移动光标。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const trace = @import("trace.zig");

pub const Tone = trace.Tone;

// ====================================================================== 提交图

/// 泳道数上限（更宽的历史共用最后一条）。
pub const LANES = 12;
const ROW_H: f32 = 30;
const LANE_W: f32 = 14;
/// 窄于这个宽度就不画作者与日期。
const NARROW: f32 = 560;

pub const Commit = struct {
    hash: []const u8 = "",
    /// 只显示第一行。
    message: []const u8 = "",
    author: []const u8 = "",
    /// 已格式化好的时间（"2 hours ago" / "Mar 3"）。
    date: []const u8 = "",
    /// "main, origin/main, tag: v1.2"（逗号分隔，可为空）。
    refs: []const u8 = "",
    /// 父提交在数组里的行号，-1 = 无（父提交必须排在后面）。
    parent: [2]i32 = .{ -1, -1 },
};

pub const CommitOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    height: f32 = 320,
};

pub const CommitResult = struct {
    clicked: i32 = -1,
    activated: i32 = -1,
    hovered: i32 = -1,
};

pub const CommitState = struct {
    sel: i32 = -1,
    scroll: f32 = 0,
    max_scroll: f32 = 0,
};

pub const LaneRow = struct {
    lane: i8 = 0,
    /// 上方每条泳道进来后落在哪条（-1 = 无）。
    in: [LANES]i8 = @splat(-1),
    /// 下方每条泳道从哪条出发（-1 = 无）。
    out: [LANES]i8 = @splat(-1),
    /// 从本条提交往下并进已有泳道的额外连线。
    join: [2]i8 = .{ -1, -1 },
    merge: bool = false,
};

/// 泳道状态机：逐行推进（调用方决定存不存 `LaneRow`）。
const Lanes = struct {
    cur: [LANES]i32 = @splat(-1),
    lanes: usize = 1,

    fn step(self: *Lanes, commits: []const Commit, i: usize, r: *LaneRow) void {
        r.* = .{};
        const ii: i32 = @intCast(i);
        const n: i32 = @intCast(commits.len);
        var lane: i32 = -1;
        for (0..LANES) |j| {
            if (self.cur[j] == ii) {
                lane = @intCast(j);
                break;
            }
        }
        if (lane < 0) {
            lane = -1;
            for (0..LANES) |j| {
                if (self.cur[j] < 0) {
                    lane = @intCast(j);
                    break;
                }
            }
        }
        if (lane < 0) lane = LANES - 1;
        r.lane = @intCast(lane);

        var next = self.cur;
        var from_commit: [LANES]bool = @splat(false);
        for (0..LANES) |j| {
            r.in[j] = if (self.cur[j] < 0) -1 else if (self.cur[j] == ii) @intCast(lane) else @intCast(j);
            next[j] = if (self.cur[j] == ii) -1 else self.cur[j];
        }
        var nj: usize = 0;
        for (0..2) |k| {
            const p = commits[i].parent[k];
            if (p <= ii or p >= n) continue;
            if (k == 1) r.merge = true;
            var wait: i32 = -1;
            for (0..LANES) |j| {
                if (next[j] == p) {
                    wait = @intCast(j);
                    break;
                }
            }
            if (wait >= 0) { // 已有泳道在等这个父提交：并进去
                if (nj < 2) {
                    r.join[nj] = @intCast(wait);
                    nj += 1;
                }
                continue;
            }
            var f: i32 = if (next[@intCast(lane)] < 0) lane else -1;
            if (f < 0) {
                for (0..LANES) |j| {
                    if (next[j] < 0) {
                        f = @intCast(j);
                        break;
                    }
                }
            }
            if (f < 0) f = LANES - 1;
            next[@intCast(f)] = p;
            from_commit[@intCast(f)] = true;
        }
        for (0..LANES) |j| {
            r.out[j] = if (next[j] < 0) -1 else if (from_commit[j]) @intCast(lane) else @intCast(j);
            if (next[j] >= 0 or self.cur[j] >= 0) self.lanes = @max(self.lanes, j + 1);
            self.cur[j] = next[j];
        }
        self.lanes = @max(self.lanes, @as(usize, @intCast(lane)) + 1);
    }
};

pub fn commitLanes(commits: []const Commit, out: []LaneRow) usize {
    var state = Lanes{};
    const n = @min(commits.len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) state.step(commits, i, &out[i]);
    return state.lanes;
}

fn laneColor(k: usize) t.Color {
    return switch (k % 6) {
        0 => theme.accent,
        1 => trace.toneColor(.success),
        2 => trace.toneColor(.warn),
        3 => trace.toneColor(.violet),
        4 => trace.toneColor(.info),
        else => trace.toneColor(.teal),
    };
}

fn laneX(rect: t.Rect, lane: i32) f32 {
    return rect.x + 10 + @as(f32, @floatFromInt(@max(lane, 0))) * LANE_W;
}

/// 泳道连线：同泳道的竖直段用细矩形（走矩形预算），跨泳道的斜线走线段预算（有上限）。
fn drawLink(ui: *core.Context, x0: f32, y0: f32, x1: f32, y1: f32, c: t.Color, budget: *usize) void {
    if (budget.* == 0) return;
    budget.* -= 1;
    if (@abs(x1 - x0) < 0.5) {
        ui.addBox(.{ .x = x0 - 0.75, .y = @min(y0, y1), .w = 1.5, .h = @max(1, @abs(y1 - y0)) }, .{ .fill = c });
    } else {
        ui.addOverlayLine(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 }, 1.5, c);
    }
}

/// refs 拆成徽标：`tag: v1.2` 用紫、带 `/` 的远端分支用中性、其余用成功色。
fn drawRefs(ui: *core.Context, x0: f32, y: f32, refs: []const u8, budget: *usize) f32 {
    if (refs.len == 0 or budget.* == 0) return x0;
    var x = x0;
    var it = std.mem.splitScalar(u8, refs, ',');
    var guard: usize = 0;
    while (it.next()) |raw| {
        if (guard >= 8 or budget.* == 0) break;
        guard += 1;
        const item = std.mem.trim(u8, raw, " ");
        if (item.len == 0) continue;
        const is_tag = std.mem.startsWith(u8, item, "tag: ");
        const label = if (is_tag) item[5..] else item;
        const is_remote = !is_tag and std.mem.indexOfScalar(u8, label, '/') != null;
        const tone: Tone = if (is_tag) .violet else if (is_remote) .neutral else .success;
        const tc = trace.toneColor(tone);
        const mw = ui.measureText(label, theme.font_small).w + 12;
        if (x + mw > x0 + 360) break; // 一行里的徽标总宽有上限，避免把消息挤没
        ui.addBox(.{ .x = x, .y = y + 2, .w = mw, .h = 16 }, .{ .fill = theme.withAlpha(tc, 40), .radius = 8 });
        ui.addText(.{ .x = x + 6, .y = y + 3, .w = mw - 8, .h = 14 }, label, theme.font_small, tc);
        x += mw + 4;
        budget.* -= 1;
    }
    return x;
}

/// 提交图。返回点击 / 激活 / 悬停的行号（-1 = 无）。
pub fn commitGraph(
    ui: *core.Context,
    id: []const u8,
    commits: []const Commit,
    st: *CommitState,
    opts: CommitOpts,
) CommitResult {
    var res = CommitResult{};
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 640;
    const h = if (opts.height > 0) opts.height else 320;
    const rect = ui.reserve(w, h, opts.width <= 0);
    ui.addBox(rect, .{ .fill = theme.surface, .radius = theme.radius_control, .border = theme.border });
    const narrow = rect.w < NARROW;

    const n = commits.len;
    if (st.sel >= @as(i32, @intCast(n))) st.sel = -1;

    // 内容高与滚动
    const content_h = @as(f32, @floatFromInt(n)) * ROW_H;
    st.max_scroll = @max(0, content_h - rect.h + 8);
    const list_id = core.Context.idOf(id) ^ 0xC01D;
    const hit = ui.interactEx(list_id, rect, true);
    if (hit.hover and ui.input.wheel != 0) {
        st.scroll = std.math.clamp(st.scroll - ui.input.wheel * ROW_H * 2, 0, st.max_scroll);
    }
    st.scroll = std.math.clamp(st.scroll, 0, st.max_scroll);
    const scroll_before = st.scroll;

    // 键盘：上下 / Home / End / Enter
    if (hit.focused and n > 0) {
        const cur = st.sel;
        var to = cur;
        if (ui.input.keyPressed(.down)) to = if (cur < 0) 0 else @min(@as(i32, @intCast(n)) - 1, cur + 1);
        if (ui.input.keyPressed(.up)) to = if (cur < 0) 0 else @max(0, cur - 1);
        if (ui.input.keyPressed(.home)) to = 0;
        if (ui.input.keyPressed(.end)) to = @intCast(n - 1);
        if (to != cur and to >= 0) {
            st.sel = to;
            // 滚进视口
            const y = @as(f32, @floatFromInt(to)) * ROW_H;
            if (y < st.scroll) st.scroll = y;
            if (y + ROW_H > st.scroll + rect.h) st.scroll = y + ROW_H - rect.h;
            st.scroll = std.math.clamp(st.scroll, 0, st.max_scroll);
        }
        if (ui.input.keyPressed(.enter) and st.sel >= 0) res.activated = st.sel;
    }

    // 先扫一遍算泳道总数（画之前要知道左边留多宽）
    var lanes = Lanes{};
    {
        var tmp = LaneRow{};
        var i: usize = 0;
        while (i < n) : (i += 1) lanes.step(commits, i, &tmp);
    }
    const shown_lanes = @min(lanes.lanes, LANES);
    const graph_w = 20 + @as(f32, @floatFromInt(shown_lanes - 1)) * LANE_W;

    // 再扫一遍：可见的行画出来
    const saved = ui.clip;
    ui.clip = .{ .x = rect.x, .y = rect.y + 2, .w = rect.w, .h = rect.h - 4 };
    if (n == 0) {
        const label = "No commits";
        const m = ui.measureText(label, theme.font_body);
        ui.addText(.{ .x = rect.x + (rect.w - m.w) / 2, .y = rect.y + rect.h / 2 - 8, .w = m.w + 2, .h = 18 }, label, theme.font_body, theme.secondary);
    } else {
        var state = Lanes{};
        var row = LaneRow{};
        var budget: usize = 160; // 一段行内最多画多少段（防顶穿节点预算）
        var lane_budget: usize = 96; // 泳道连线总段数上限（斜线是浮层线段）
        var i: usize = 0;
        while (i < n) : (i += 1) {
            state.step(commits, i, &row);
            const ry = rect.y + @as(f32, @floatFromInt(i)) * ROW_H - st.scroll;
            if (ry + ROW_H < rect.y or ry > rect.y + rect.h) continue;
            const c = commits[i];
            const rid = core.Context.idOf(id) ^ (@as(u64, @intCast(i)) *% 0xC0DE);
            const rr = ui.interact(rid, .{ .x = rect.x, .y = ry, .w = rect.w, .h = ROW_H });
            if (rr.clicked) {
                st.sel = @intCast(i);
                res.clicked = @intCast(i);
            }
            if (rr.hover) res.hovered = @intCast(i);
            const selected = st.sel == @as(i32, @intCast(i));
            if (selected) {
                ui.addBox(.{ .x = rect.x, .y = ry, .w = rect.w, .h = ROW_H }, .{ .fill = theme.accent_bg });
            } else if (rr.hover) {
                ui.addBox(.{ .x = rect.x, .y = ry, .w = rect.w, .h = ROW_H }, .{ .fill = theme.track });
            }

            // ---- 泳道（进入 / 离开 / 并入）
            const mid = ry + ROW_H * 0.5;
            const bot = ry + ROW_H;
            var j: usize = 0;
            while (j < LANES) : (j += 1) {
                if (row.in[j] >= 0) {
                    drawLink(ui, laneX(rect, @intCast(j)), ry, laneX(rect, row.in[j]), mid, laneColor(j), &lane_budget);
                }
                if (row.out[j] >= 0) {
                    drawLink(ui, laneX(rect, row.out[j]), mid, laneX(rect, @intCast(j)), bot, laneColor(j), &lane_budget);
                }
            }
            for (0..2) |k| {
                if (row.join[k] >= 0) {
                    drawLink(ui, laneX(rect, row.lane), mid, laneX(rect, row.join[k]), bot, laneColor(@intCast(row.join[k])), &lane_budget);
                }
            }
            // ---- 提交点（合并是环）
            const cx = laneX(rect, row.lane);
            const ck = laneColor(@intCast(row.lane));
            if (selected) ui.addBox(.{ .x = cx - 6.5, .y = mid - 6.5, .w = 13, .h = 13 }, .{ .fill = theme.withAlpha(ck, 70), .radius = 6.5 });
            ui.addBox(.{ .x = cx - 4.5, .y = mid - 4.5, .w = 9, .h = 9 }, .{ .fill = ck, .radius = 4.5 });
            if (row.merge) ui.addBox(.{ .x = cx - 2.2, .y = mid - 2.2, .w = 4.4, .h = 4.4 }, .{ .fill = theme.surface, .radius = 2.2 });

            // ---- 内容：refs + 消息（+ 作者 / 日期 / 哈希）
            var x = rect.x + graph_w + 12;
            const ty = ry + (ROW_H - 16) / 2;
            if (budget > 0) {
                const nx = drawRefs(ui, x, ty, c.refs, &budget);
                if (nx > x) x = nx + 2;
            }
            const hash_w: f32 = 58;
            const meta_w: f32 = if (narrow) 0 else 120 + 88;
            const msg_w = @max(60, rect.x + rect.w - 10 - x - hash_w - meta_w - 8);
            if (budget > 0) {
                const line_end = std.mem.indexOfScalar(u8, c.message, '\n') orelse c.message.len;
                const text = c.message[0..line_end];
                ui.addText(.{ .x = x, .y = ty, .w = msg_w, .h = 16 }, fitText(ui, text, theme.font_small, msg_w), theme.font_small, theme.text);
                budget -= 1;
            }
            if (!narrow) {
                const ax = rect.x + rect.w - 10 - hash_w - 88 - 120;
                if (c.author.len > 0) ui.addText(.{ .x = ax, .y = ty, .w = 116, .h = 16 }, fitText(ui, c.author, theme.font_small, 116), theme.font_small, theme.secondary);
                if (c.date.len > 0) ui.addText(.{ .x = ax + 120, .y = ty, .w = 84, .h = 16 }, fitText(ui, c.date, theme.font_small, 84), theme.font_small, theme.secondary);
            }
            if (c.hash.len > 0) {
                const hl = @min(c.hash.len, 7);
                ui.addMonoText(.{ .x = rect.x + rect.w - 10 - hash_w, .y = ty, .w = hash_w, .h = 16 }, c.hash[0..hl], theme.font_small, theme.secondary);
            }
        }
    }
    ui.clip = saved;

    // 滚动条
    if (st.max_scroll > 0.5) {
        const th = @max(24, rect.h * rect.h / content_h);
        const ty = rect.y + (rect.h - th) * (st.scroll / st.max_scroll);
        ui.addBox(.{ .x = rect.x + rect.w - 6, .y = ty, .w = 3, .h = th }, .{ .fill = theme.withAlpha(theme.secondary, 120), .radius = 1.5 });
    }
    if (st.scroll != scroll_before) ui.requestFrame();
    return res;
}

/// 按可用宽度裁文本（尾部 "..."，UTF-8 安全）。
fn fitText(ui: *core.Context, s: []const u8, size: f32, max_w: f32) []const u8 {
    if (s.len == 0 or max_w <= 0) return "";
    if (ui.measureText(s, size).w <= max_w) return s;
    var take: usize = @min(s.len -| 1, 40);
    while (take > 0) : (take -= 1) {
        var n = take;
        while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
        var buf: [48]u8 = undefined;
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

// ====================================================================== 依赖图

pub const MAX_NODES = 64;
pub const MAX_EDGES = 128;
const DEP_GAP_X: f32 = 56;
const DEP_GAP_Y: f32 = 18;
const DEP_PAD: f32 = 24;
const NODE_H: f32 = 34;
const DETAIL_H: f32 = 14;

pub const DepNode = struct {
    label: []const u8 = "",
    /// 第二行小字（可空）。
    detail: []const u8 = "",
    tone: ?Tone = null,
};

pub const DepEdge = struct { from: i32 = 0, to: i32 = 0 };

pub const DepOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    height: f32 = 360,
    /// 从上到下分层（默认从左到右）。
    top_down: bool = false,
};

pub const DepResult = struct {
    clicked: i32 = -1,
    activated: i32 = -1,
    hovered: i32 = -1,
    /// 节点/边超出固定容量（`MAX_NODES` / `MAX_EDGES`）。
    overflow: bool = false,
};

const Box = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

pub const DepState = struct {
    /// 布局缓存键（节点/边/方向变了才重算）。
    key: u64 = 0,
    valid: bool = false,
    n: usize = 0,
    m: usize = 0,
    nlayers: usize = 0,
    box: [MAX_NODES]Box = @splat(.{}),
    gw: f32 = 0,
    gh: f32 = 0,
    /// 视图：图上的 (0,0) 落在面板左上角偏移 (px, py) 处。
    px: f32 = 0,
    py: f32 = 0,
    zoom: f32 = 1,
    fit: bool = true,
    mode: u8 = 0, // 0 空闲 / 1 按下 / 2 平移
    press_x: f32 = 0,
    press_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    press_node: i32 = -1,
    sel: i32 = -1,
    // 布局临时区（也放在状态里，省栈）
    from: [MAX_EDGES]i32 = @splat(-1),
    to: [MAX_EDGES]i32 = @splat(-1),
    back: [MAX_EDGES]bool = @splat(false),
    layer: [MAX_NODES]i32 = @splat(0),
    lorder: [MAX_NODES]i32 = @splat(0),
    pos: [MAX_NODES]f32 = @splat(0),
    indeg: [MAX_NODES]i32 = @splat(0),
    queue: [MAX_NODES]i32 = @splat(0),
    mark: [MAX_NODES]u8 = @splat(0),
    stack: [MAX_NODES]i32 = @splat(0),
    iter: [MAX_NODES]i32 = @splat(0),
    lit: [MAX_NODES]u8 = @splat(0),
};

fn depKey(nodes: []const DepNode, edges: []const DepEdge, top_down: bool, ui: *core.Context) u64 {
    var h: u64 = 0xCBF29CE484222325;
    h = (h ^ nodes.len) *% 0x100000001B3;
    h = (h ^ edges.len) *% 0x100000001B3;
    h = (h ^ @as(u64, if (top_down) 1 else 0)) *% 0x100000001B3;
    for (nodes) |nd| {
        const w: u64 = @intFromFloat(ui.measureText(nd.label, theme.font_small).w * 4);
        h = (h ^ (w + nd.label.len)) *% 0x100000001B3;
        h = (h ^ nd.detail.len) *% 0x100000001B3;
    }
    for (edges) |e| h = (h ^ (@as(u64, @bitCast(@as(i64, e.from))) *% 31 +% @as(u64, @bitCast(@as(i64, e.to))))) *% 0x100000001B3;
    return h;
}

/// 分层布局：去掉成环的回边 → 最长路径分层 → 层内按邻居重心排（几轮）→ 坐标。
fn depLayout(ui: *core.Context, s: *DepState, nodes: []const DepNode, edges: []const DepEdge, top_down: bool) void {
    s.n = 0;
    s.m = 0;
    s.gw = 0;
    s.gh = 0;
    const n = @min(nodes.len, MAX_NODES);
    if (n == 0) return;

    // 合法边
    var m: usize = 0;
    for (edges) |e| {
        if (m >= MAX_EDGES) break;
        if (e.from < 0 or e.from >= @as(i32, @intCast(n))) continue;
        if (e.to < 0 or e.to >= @as(i32, @intCast(n))) continue;
        if (e.from == e.to) continue;
        s.from[m] = e.from;
        s.to[m] = e.to;
        m += 1;
    }
    s.m = m;

    // 回边：DFS 时指向「还在栈上」的节点
    s.mark = @splat(0);
    s.back = @splat(false);
    var root: usize = 0;
    while (root < n) : (root += 1) {
        if (s.mark[root] != 0) continue;
        var sp: usize = 0;
        s.stack[0] = @intCast(root);
        s.iter[0] = 0;
        sp = 1;
        s.mark[root] = 1;
        while (sp > 0) {
            const v = s.stack[sp - 1];
            if (s.iter[sp - 1] < @as(i32, @intCast(m))) {
                const k: usize = @intCast(s.iter[sp - 1]);
                s.iter[sp - 1] += 1;
                if (s.from[k] != v) continue;
                const w = s.to[k];
                if (s.mark[@intCast(w)] == 1) {
                    s.back[k] = true;
                } else if (s.mark[@intCast(w)] == 0) {
                    s.mark[@intCast(w)] = 1;
                    s.stack[sp] = w;
                    s.iter[sp] = 0;
                    sp += 1;
                }
            } else {
                s.mark[@intCast(v)] = 2;
                sp -= 1;
            }
        }
    }

    // 最长路径分层（Kahn）
    s.indeg = @splat(0);
    for (0..m) |k| {
        if (!s.back[k]) s.indeg[@intCast(s.to[k])] += 1;
    }
    var qh: usize = 0;
    var qt: usize = 0;
    for (0..n) |v| {
        s.layer[v] = 0;
        if (s.indeg[v] == 0) {
            s.queue[qt] = @intCast(v);
            qt += 1;
        }
    }
    while (qh < qt) : (qh += 1) {
        const v = s.queue[qh];
        for (0..m) |k| {
            if (s.back[k] or s.from[k] != v) continue;
            const w = s.to[k];
            if (s.layer[@intCast(w)] < s.layer[@intCast(v)] + 1) s.layer[@intCast(w)] = s.layer[@intCast(v)] + 1;
            s.indeg[@intCast(w)] -= 1;
            if (s.indeg[@intCast(w)] == 0) {
                s.queue[qt] = w;
                qt += 1;
            }
        }
    }
    var nlayers: usize = 1;
    for (0..n) |v| nlayers = @max(nlayers, @as(usize, @intCast(s.layer[v] + 1)));
    s.nlayers = nlayers;

    // 层内初始顺序 + 重心排序
    var count: [MAX_NODES]usize = @splat(0);
    for (0..n) |v| {
        const L: usize = @intCast(s.layer[v]);
        s.pos[v] = @floatFromInt(count[L]);
        count[L] += 1;
    }
    var sweep: usize = 0;
    while (sweep < 4) : (sweep += 1) {
        var sum: [MAX_NODES]f32 = @splat(0);
        var deg: [MAX_NODES]f32 = @splat(0);
        for (0..m) |k| {
            const a: usize = @intCast(s.from[k]);
            const b: usize = @intCast(s.to[k]);
            sum[b] += s.pos[a];
            deg[b] += 1;
            sum[a] += s.pos[b];
            deg[a] += 1;
        }
        for (0..n) |v| {
            if (deg[v] > 0) s.pos[v] = s.pos[v] * 0.25 + 0.75 * (sum[v] / deg[v]);
        }
        // 每层按 pos 排序 → 重排行号
        var L: usize = 0;
        while (L < nlayers) : (L += 1) {
            var c: usize = 0;
            for (0..n) |v| {
                if (s.layer[v] == @as(i32, @intCast(L))) {
                    s.lorder[c] = @intCast(v);
                    c += 1;
                }
            }
            // 插入排序（层内元素很少）
            var a: usize = 1;
            while (a < c) : (a += 1) {
                const x = s.lorder[a];
                var b2: usize = a;
                while (b2 > 0 and s.pos[@intCast(s.lorder[b2 - 1])] > s.pos[@intCast(x)]) : (b2 -= 1) s.lorder[b2] = s.lorder[b2 - 1];
                s.lorder[b2] = x;
            }
            for (0..c) |r| s.pos[@intCast(s.lorder[r])] = @floatFromInt(r);
        }
    }

    // 坐标：层沿主轴依次排开，层内居中
    var lsize: [MAX_NODES]f32 = @splat(0);
    var lthick: [MAX_NODES]f32 = @splat(0);
    for (0..n) |v| {
        const L: usize = @intCast(s.layer[v]);
        const lw = ui.measureText(nodes[v].label, theme.font_small).w;
        const dw = if (nodes[v].detail.len > 0) ui.measureText(nodes[v].detail, theme.font_small).w else 0;
        const bw = std.math.clamp(@max(lw, dw) + 34, 72, 220);
        const bh = NODE_H + (if (nodes[v].detail.len > 0) DETAIL_H else 0);
        s.box[v] = .{ .x = 0, .y = 0, .w = bw, .h = bh };
        const along = if (top_down) bw else bh;
        const across = if (top_down) bh else bw;
        lsize[L] += along + DEP_GAP_Y;
        lthick[L] = @max(lthick[L], across);
    }
    var longest: f32 = 0;
    for (0..nlayers) |L| {
        if (lsize[L] > 0) lsize[L] -= DEP_GAP_Y;
        longest = @max(longest, lsize[L]);
    }
    var at: f32 = 0;
    var lpos: [MAX_NODES]f32 = @splat(0);
    for (0..nlayers) |L| {
        lpos[L] = at;
        at += lthick[L] + DEP_GAP_X;
    }
    var L: usize = 0;
    while (L < nlayers) : (L += 1) {
        var c: usize = 0;
        for (0..n) |v| {
            if (s.layer[v] == @as(i32, @intCast(L))) {
                s.lorder[c] = @intCast(v);
                c += 1;
            }
        }
        var a: usize = 1;
        while (a < c) : (a += 1) {
            const x = s.lorder[a];
            var b2: usize = a;
            while (b2 > 0 and s.pos[@intCast(s.lorder[b2 - 1])] > s.pos[@intCast(x)]) : (b2 -= 1) s.lorder[b2] = s.lorder[b2 - 1];
            s.lorder[b2] = x;
        }
        var cur = (longest - lsize[L]) * 0.5;
        for (0..c) |r| {
            const v: usize = @intCast(s.lorder[r]);
            if (top_down) {
                s.box[v].x = cur;
                s.box[v].y = lpos[L] + (lthick[L] - s.box[v].h) * 0.5;
                cur += s.box[v].w + DEP_GAP_Y;
            } else {
                s.box[v].y = cur;
                s.box[v].x = lpos[L] + (lthick[L] - s.box[v].w) * 0.5;
                cur += s.box[v].h + DEP_GAP_Y;
            }
        }
    }
    for (0..n) |v| {
        s.gw = @max(s.gw, s.box[v].x + s.box[v].w);
        s.gh = @max(s.gh, s.box[v].y + s.box[v].h);
    }
    s.n = n;
    s.valid = true;
}

fn depFit(s: *DepState, rect: t.Rect) void {
    if (s.gw <= 0 or s.gh <= 0 or rect.w <= 0) {
        s.zoom = 1;
        s.px = DEP_PAD;
        s.py = DEP_PAD;
        return;
    }
    const z = @min((rect.w - 2 * DEP_PAD) / s.gw, (rect.h - 2 * DEP_PAD) / s.gh);
    s.zoom = std.math.clamp(z, 0.2, 1.0);
    s.px = (rect.w - s.gw * s.zoom) * 0.5;
    s.py = (rect.h - s.gh * s.zoom) * 0.5;
}

fn depZoomAt(s: *DepState, nz: f32, x: f32, y: f32) void {
    const z = std.math.clamp(nz, 0.2, 2.5);
    const gx = (x - s.px) / s.zoom;
    const gy = (y - s.py) / s.zoom;
    s.zoom = z;
    s.px = x - gx * z;
    s.py = y - gy * z;
}

fn depHit(s: *DepState, rect: t.Rect, mx: f32, my: f32) i32 {
    var v: usize = s.n;
    while (v > 0) {
        v -= 1;
        const b = s.box[v];
        const x = rect.x + s.px + b.x * s.zoom;
        const y = rect.y + s.py + b.y * s.zoom;
        if (mx >= x and mx <= x + b.w * s.zoom and my >= y and my <= y + b.h * s.zoom) return @intCast(v);
    }
    return -1;
}

/// 方向键：沿边（主轴）或同层内（跨轴）移动。
fn depStep(s: *DepState, edges: []const DepEdge, sel: i32, dx: i32, dy: i32, top_down: bool) i32 {
    if (sel < 0 or sel >= @as(i32, @intCast(s.n))) return if (s.n > 0) 0 else -1;
    const along = if (top_down) dy != 0 else dx != 0;
    const dir = if (top_down) dy else dx;
    const a = s.box[@intCast(sel)];
    var best: i32 = -1;
    var bd: f32 = 1e30;
    if (along) {
        for (edges) |e| {
            const o = if (dir > 0) (if (e.from == sel) e.to else @as(i32, -1)) else (if (e.to == sel) e.from else @as(i32, -1));
            if (o < 0 or o >= @as(i32, @intCast(s.n))) continue;
            const b = s.box[@intCast(o)];
            const d = if (top_down) @abs(b.x - a.x) else @abs(b.y - a.y);
            if (d < bd) {
                bd = d;
                best = o;
            }
        }
        return if (best >= 0) best else sel;
    }
    const across = if (top_down) dx else dy;
    var v: usize = 0;
    while (v < s.n) : (v += 1) {
        if (v == @as(usize, @intCast(sel))) continue;
        if (s.layer[v] != s.layer[@intCast(sel)]) continue;
        const b = s.box[v];
        const d = if (top_down) b.x - a.x else b.y - a.y;
        if ((across > 0 and d > 0 and d < bd) or (across < 0 and d < 0 and -d < bd)) {
            bd = @abs(d);
            best = @intCast(v);
        }
    }
    return if (best >= 0) best else sel;
}

fn portOf(s: *DepState, rect: t.Rect, v: i32, out: bool, top_down: bool) t.Point {
    const b = s.box[@intCast(v)];
    const x = rect.x + s.px + (b.x + (if (top_down) b.w * 0.5 else if (out) b.w else 0)) * s.zoom;
    const y = rect.y + s.py + (b.y + (if (top_down) (if (out) b.h else 0) else b.h * 0.5)) * s.zoom;
    return .{ .x = x, .y = y };
}

/// 依赖图。返回点击 / 激活 / 悬停的节点下标（-1 = 无）。
pub fn depGraph(
    ui: *core.Context,
    id: []const u8,
    nodes: []const DepNode,
    edges: []const DepEdge,
    st: *DepState,
    opts: DepOpts,
) DepResult {
    var res = DepResult{};
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 640;
    const h = if (opts.height > 0) opts.height else 360;
    const rect = ui.reserve(w, h, opts.width <= 0);
    res.overflow = nodes.len > MAX_NODES or edges.len > MAX_EDGES;

    const key = depKey(nodes, edges, opts.top_down, ui);
    if (!st.valid or st.key != key) {
        depLayout(ui, st, nodes, edges, opts.top_down);
        st.key = key;
        st.fit = true;
    }
    if (st.sel >= @as(i32, @intCast(st.n))) st.sel = -1;
    if (st.fit) {
        depFit(st, rect);
        st.fit = false;
    }

    // ---- 交互：滚轮缩放 / Shift 平移、拖拽平移、点击、键盘
    const hit = ui.interactEx(core.Context.idOf(id) ^ 0x6A90, rect, true);
    const mx = ui.input.mouse.x - rect.x;
    const my = ui.input.mouse.y - rect.y;
    if (hit.hover and ui.input.wheel != 0) {
        if (ui.input.mods.shift) {
            st.px += ui.input.wheel * 40;
        } else {
            depZoomAt(st, st.zoom * std.math.pow(f32, 1.12, ui.input.wheel), mx, my);
        }
        ui.requestFrame();
    }
    if (hit.pressed) {
        st.mode = 1;
        st.press_x = ui.input.mouse.x;
        st.press_y = ui.input.mouse.y;
        st.last_x = st.press_x;
        st.last_y = st.press_y;
        st.press_node = depHit(st, rect, ui.input.mouse.x, ui.input.mouse.y);
    }
    if (st.mode == 1 and ui.input.down) {
        const dx = ui.input.mouse.x - st.press_x;
        const dy = ui.input.mouse.y - st.press_y;
        if (dx * dx + dy * dy > 9) st.mode = 2;
    }
    if (st.mode == 2) {
        st.px += ui.input.mouse.x - st.last_x;
        st.py += ui.input.mouse.y - st.last_y;
        st.last_x = ui.input.mouse.x;
        st.last_y = ui.input.mouse.y;
        ui.requestFrame();
    }
    if (st.mode != 0 and !ui.input.down) {
        if (st.mode == 1 and st.press_node >= 0) {
            st.sel = st.press_node;
            res.clicked = st.press_node;
            if (hit.activated) res.activated = st.press_node;
        }
        st.mode = 0;
    }
    if (hit.focused) {
        var to = st.sel;
        if (ui.input.keyPressed(.right)) to = depStep(st, edges, to, 1, 0, opts.top_down);
        if (ui.input.keyPressed(.left)) to = depStep(st, edges, to, -1, 0, opts.top_down);
        if (ui.input.keyPressed(.down)) to = depStep(st, edges, to, 0, 1, opts.top_down);
        if (ui.input.keyPressed(.up)) to = depStep(st, edges, to, 0, -1, opts.top_down);
        if (to != st.sel and to >= 0) st.sel = to;
        if (ui.input.keyPressed(.enter) and st.sel >= 0) res.activated = st.sel;
        if (ui.input.keyPressed(.equal)) depZoomAt(st, st.zoom * 1.25, rect.w * 0.5, rect.h * 0.5);
        if (ui.input.keyPressed(.minus)) depZoomAt(st, st.zoom / 1.25, rect.w * 0.5, rect.h * 0.5);
        if (ui.input.keyPressed(.F) and !ui.input.mods.ctrl) depFit(st, rect);
        if (ui.input.keyPressed(.escape)) st.sel = -1;
    }
    const hover: i32 = if (hit.hover and st.mode != 2) depHit(st, rect, ui.input.mouse.x, ui.input.mouse.y) else -1;
    res.hovered = hover;

    // ---- 高亮：焦点节点 + 它的邻居
    st.lit = @splat(0);
    const focus: i32 = if (hover >= 0) hover else st.sel;
    if (focus >= 0 and focus < @as(i32, @intCast(st.n))) {
        st.lit[@intCast(focus)] = 1;
        var k: usize = 0;
        while (k < st.m) : (k += 1) {
            const a = st.from[k];
            const b = st.to[k];
            if (a == focus and st.lit[@intCast(b)] == 0) st.lit[@intCast(b)] = 2;
            if (b == focus and st.lit[@intCast(a)] == 0) st.lit[@intCast(a)] = 2;
        }
    }
    const any_lit = focus >= 0;

    // ---- 画
    ui.addBox(rect, .{ .fill = if (theme.isDark()) theme.bg else theme.track, .radius = 10, .border = theme.border });
    const saved = ui.clip;
    ui.clip = .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 };
    // 边：两段折线近似 S 曲线（跨层直连，不做绕行）
    var drawn: usize = 0;
    var k: usize = 0;
    while (k < st.m and drawn < 24) : (k += 1) { // 每条边 5 段线段，浮层预算只够画这么多
        const a = st.from[k];
        const b = st.to[k];
        const lit = any_lit and ((st.lit[@intCast(a)] == 1 and st.lit[@intCast(b)] != 0) or (st.lit[@intCast(b)] == 1 and st.lit[@intCast(a)] != 0));
        const c = if (lit) theme.accent else theme.withAlpha(theme.secondary, if (any_lit) 70 else 140);
        const p0 = portOf(st, rect, a, true, opts.top_down);
        const p1 = portOf(st, rect, b, false, opts.top_down);
        if (opts.top_down) {
            const midy = (p0.y + p1.y) * 0.5;
            ui.addOverlayLine(.{ .x = p0.x, .y = p0.y }, .{ .x = p0.x, .y = midy }, if (lit) 2 else 1.25, c);
            ui.addOverlayLine(.{ .x = p0.x, .y = midy }, .{ .x = p1.x, .y = midy }, if (lit) 2 else 1.25, c);
            ui.addOverlayLine(.{ .x = p1.x, .y = midy }, .{ .x = p1.x, .y = p1.y }, if (lit) 2 else 1.25, c);
            // 箭头（两笔）
            ui.addOverlayLine(.{ .x = p1.x, .y = p1.y }, .{ .x = p1.x - 4, .y = p1.y - 6 }, 1.5, c);
            ui.addOverlayLine(.{ .x = p1.x, .y = p1.y }, .{ .x = p1.x + 4, .y = p1.y - 6 }, 1.5, c);
        } else {
            const midx = (p0.x + p1.x) * 0.5;
            ui.addOverlayLine(.{ .x = p0.x, .y = p0.y }, .{ .x = midx, .y = p0.y }, if (lit) 2 else 1.25, c);
            ui.addOverlayLine(.{ .x = midx, .y = p0.y }, .{ .x = midx, .y = p1.y }, if (lit) 2 else 1.25, c);
            ui.addOverlayLine(.{ .x = midx, .y = p1.y }, .{ .x = p1.x, .y = p1.y }, if (lit) 2 else 1.25, c);
            ui.addOverlayLine(.{ .x = p1.x, .y = p1.y }, .{ .x = p1.x - 6, .y = p1.y - 4 }, 1.5, c);
            ui.addOverlayLine(.{ .x = p1.x, .y = p1.y }, .{ .x = p1.x - 6, .y = p1.y + 4 }, 1.5, c);
        }
        drawn += 1;
    }
    // 节点
    var v: usize = 0;
    while (v < st.n) : (v += 1) {
        const b = st.box[v];
        const br = t.Rect{
            .x = rect.x + st.px + b.x * st.zoom,
            .y = rect.y + st.py + b.y * st.zoom,
            .w = b.w * st.zoom,
            .h = b.h * st.zoom,
        };
        if (br.x > rect.x + rect.w or br.y > rect.y + rect.h or br.x + br.w < rect.x or br.y + br.h < rect.y) continue;
        const dim = any_lit and st.lit[v] == 0;
        const tone = trace.toneColor(nodes[v].tone orelse .neutral);
        const is_sel = st.sel == @as(i32, @intCast(v));
        ui.addBox(br, .{
            .fill = if (is_sel) theme.accent_bg else theme.surface,
            .radius = 6,
            .border = if (is_sel) theme.accent else if (st.lit[v] == 2) theme.withAlpha(theme.accent, 110) else theme.border,
            .border_width = if (is_sel) 2 else 1,
        });
        ui.addBox(.{ .x = br.x + 10 * st.zoom, .y = br.y + (if (nodes[v].detail.len > 0) 15 else br.h * 0.5) * st.zoom - 3.5 * st.zoom, .w = 7 * st.zoom, .h = 7 * st.zoom }, .{
            .fill = if (dim) theme.withAlpha(tone, 90) else tone,
            .radius = 3.5 * st.zoom,
        });
        const fs = theme.font_small * st.zoom;
        if (fs >= 5) {
            const lx = br.x + 22 * st.zoom;
            const lw = br.w - 26 * st.zoom;
            const ty = if (nodes[v].detail.len > 0) br.y + 8 * st.zoom else br.y + (br.h - fs * 1.4) * 0.5;
            ui.addText(.{ .x = lx, .y = ty, .w = lw, .h = fs * 1.6 }, fitText(ui, nodes[v].label, fs, lw), fs, if (dim) theme.secondary else theme.text);
            if (nodes[v].detail.len > 0 and fs >= 6) {
                ui.addText(.{ .x = lx, .y = ty + fs * 1.45, .w = lw, .h = fs * 1.4 }, fitText(ui, nodes[v].detail, fs * 0.92, lw), fs * 0.92, theme.secondary);
            }
        }
    }
    if (st.n == 0) {
        const label = "No nodes";
        const m = ui.measureText(label, theme.font_small);
        ui.addText(.{ .x = rect.x + (rect.w - m.w) / 2, .y = rect.y + rect.h / 2 - 8, .w = m.w + 2, .h = 18 }, label, theme.font_small, theme.secondary);
    }
    ui.clip = saved;
    if (hit.focused) ui.addBox(rect.inset(-1), .{ .border = theme.accent, .radius = 10 });
    return res;
}
