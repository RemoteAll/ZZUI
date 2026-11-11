//! 规划视图族：看板（点击/拖动换列/键盘）、周历（布局/拖动/只读/分栏）、甘特（点击/拖动/键盘/滚动）。
const std = @import("std");
const core = @import("core.zig");
const month = @import("month.zig");
const planning = @import("planning.zig");
const types = @import("types.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

// ------------------------------------------------------------------ 看板

const KbFixture = struct {
    ui: core.Context = .{},
    board: planning.Board = .{},
    st: planning.KanbanState = .{},
    moved: ?planning.KanbanMove = null,
    clicked: [4]bool = @splat(false),
    add: [3]bool = @splat(false),
    cards: [3][3][]const u8 = .{
        .{ "Design the API", "Write docs", "" },
        .{ "Ship 0.1", "Fix the drag", "Review" },
        .{ "", "", "" },
    },

    /// 一帧：两列（3 张 / 3 张），卡片内容各一行文本。
    fn frame(self: *KbFixture) void {
        self.ui.begin(900, 500);
        planning.kanbanBegin(&self.ui, "board", &self.board, &self.st, .{ .height = 420 });
        var c: usize = 0;
        while (c < 2) : (c += 1) {
            const count: i32 = if (c == 0) 2 else 3;
            self.add[c] = planning.kanbanColumnBegin(&self.ui, &self.board, if (c == 0) "Todo" else "Doing", count, .{ .limit = 3, .width = 260 });
            var k: usize = 0;
            while (k < @as(usize, @intCast(count))) : (k += 1) {
                const id: i32 = @intCast(c * 10 + k);
                const title = self.cards[c][k];
                const hit = planning.kanbanCardBegin(&self.ui, &self.board, id, .{ .title = title });
                if (hit) self.clicked[c] = true;
                if (self.board.card_open) {
                    _ = self.ui.textRun(title, 14, @import("theme.zig").text);
                    planning.kanbanCardEnd(&self.ui, &self.board);
                }
            }
            planning.kanbanColumnEnd(&self.ui, &self.board);
        }
        self.moved = planning.kanbanEnd(&self.ui, &self.board);
        self.ui.paint();
    }
};

test "planning: kanban lays out two columns and keeps cards inside the board" {
    var f = KbFixture{};
    f.frame();
    try std.testing.expect(!f.ui.overflowed);
    try std.testing.expectEqual(@as(i32, -1), f.st.target_col); // 没在拖
    try std.testing.expect(f.st.drag < 0);
    // 卡片的高度第二帧起才准：第一帧是 64 的估计，之后是真高
    const first = f.board.card_y;
    f.frame();
    try std.testing.expect(f.board.card_y > 0);
    try std.testing.expect(first > 0);
}

test "planning: clicking a kanban card is reported" {
    var f = KbFixture{};
    f.frame();
    // 第一张卡的矩形（本帧记录的命中）
    const key = planning.cardKey(core.Context.idOf("board"), 0);
    const r = f.ui.lastRect(key).?;
    f.ui.input = .{ .mouse = at(r.x + 20, r.y + 10), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(r.x + 20, r.y + 10), .click = at(r.x + 20, r.y + 10) };
    f.frame();
    try std.testing.expect(f.clicked[0]);
}

test "planning: dragging a card across columns reports a move" {
    var f = KbFixture{};
    f.frame();
    const key = planning.cardKey(core.Context.idOf("board"), 0);
    const r = f.ui.lastRect(key).?;
    // 按下
    f.ui.input = .{ .mouse = at(r.x + 20, r.y + 10), .pressed = true, .down = true };
    f.frame();
    // 移到第二列（列宽 260 + 间距 14 + 内边距 10）
    f.ui.input = .{ .mouse = at(r.x + 320, r.y + 60), .down = true };
    f.frame();
    try std.testing.expectEqual(@as(i32, 0), f.st.drag);
    // 松手
    f.ui.input = .{ .mouse = at(r.x + 320, r.y + 60), .down = false };
    f.frame();
    try std.testing.expect(f.moved != null);
    const m = f.moved.?;
    try std.testing.expectEqual(@as(i32, 0), m.card);
    try std.testing.expectEqual(@as(i32, 0), m.from_column);
    try std.testing.expectEqual(@as(i32, 1), m.to_column);
    try std.testing.expectEqual(@as(i32, -1), f.st.drag);
}

test "planning: space lifts the focused card and enter drops it" {
    var f = KbFixture{};
    f.frame();
    const key = planning.cardKey(core.Context.idOf("board"), 0);
    // 让第一张卡拿到键盘焦点
    f.ui.focus_id = key;
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .space;
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    f.frame();
    try std.testing.expect(f.st.kbd);
    try std.testing.expectEqual(@as(i32, 0), f.st.drag);
    // → 选到第二列
    keys[0] = .right;
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 1), f.st.kcol);
    // Enter 落下
    keys[0] = .enter;
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    f.frame();
    try std.testing.expect(f.moved != null);
    try std.testing.expectEqual(@as(i32, 1), f.moved.?.to_column);
    try std.testing.expect(!f.st.kbd);
}

// ------------------------------------------------------------------ 周历

const WEEK = month.Date{ .year = 2026, .month = 11, .day = 9 }; // 周一

const WeekFixture = struct {
    ui: core.Context = .{},
    st: planning.WeekState = .{},
    events: [4]planning.CalEvent = .{
        .{ .title = "Standup", .day = 0, .start = 9, .end = 10 },
        .{ .title = "Review", .day = 2, .start = 14, .end = 16, .tone = .success },
        .{ .title = "Design", .day = 2, .start = 14, .end = 15, .tone = .warn },
        .{ .title = "", .day = 3, .start = 11, .end = 12 },
    },
    clicked: ?usize = null,

    fn frame(self: *WeekFixture, n: usize, opts: planning.WeekOpts) void {
        self.ui.begin(760, 520);
        self.clicked = planning.weekCalendar(&self.ui, "week", WEEK, self.events[0..n], &self.st, opts);
        self.ui.paint();
    }
};

test "planning: week calendar renders events and reports a click" {
    var f = WeekFixture{};
    f.frame(4, .{});
    try std.testing.expect(!f.ui.overflowed);
    // "Standup" 在周一 9:00，网格从 7:00 起、每小时 52px
    const eid = planning.eventKey(core.Context.idOf("week"), 0);
    const r = f.ui.lastRect(eid).?;
    try std.testing.expect(r.w > 10 and r.h > 30);
    f.ui.input = .{ .mouse = at(r.x + 10, r.y + 8), .pressed = true, .down = true };
    f.frame(4, .{});
    f.ui.input = .{ .mouse = at(r.x + 10, r.y + 8), .click = at(r.x + 10, r.y + 8) };
    f.frame(4, .{});
    try std.testing.expectEqual(@as(?usize, 0), f.clicked);
}

test "planning: dragging an event moves it to another day and snaps to 15 minutes" {
    var f = WeekFixture{};
    f.frame(4, .{});
    const eid = planning.eventKey(core.Context.idOf("week"), 0);
    const r = f.ui.lastRect(eid).?;
    // 按下（离底边远 → 整体移动）
    f.ui.input = .{ .mouse = at(r.x + 10, r.y + 8), .pressed = true, .down = true };
    f.frame(4, .{});
    // 拖到周三、往下 1 小时（52px）
    const day_w = (760.0 - 60.0) / 7.0;
    f.ui.input = .{ .mouse = at(r.x + 10 + day_w * 2, r.y + 8 + 52), .down = true };
    f.frame(4, .{});
    try std.testing.expectEqual(@as(i32, 2), f.events[0].day);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), f.events[0].start, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), f.events[0].end, 0.01);
    f.ui.input = .{ .mouse = at(r.x + 10, r.y + 8), .down = false };
    f.frame(4, .{});
    try std.testing.expectEqual(@as(i32, -1), f.st.drag);
}

test "planning: read-only week calendar refuses to drag" {
    var f = WeekFixture{};
    f.frame(4, .{ .read_only = true });
    const eid = planning.eventKey(core.Context.idOf("week"), 0);
    const r = f.ui.lastRect(eid).?;
    f.ui.input = .{ .mouse = at(r.x + 10, r.y + 8), .pressed = true, .down = true };
    f.frame(4, .{ .read_only = true });
    f.ui.input = .{ .mouse = at(r.x + 300, r.y + 200), .down = true };
    f.frame(4, .{ .read_only = true });
    try std.testing.expectEqual(@as(i32, -1), f.st.drag);
    try std.testing.expectEqual(@as(i32, 0), f.events[0].day);
}

test "planning: overlapping week events split their day into lanes" {
    var f = WeekFixture{};
    f.frame(4, .{});
    const base = core.Context.idOf("week");
    const a = f.ui.lastRect(planning.eventKey(base, 1)).?; // Review 14:00-16:00
    const b = f.ui.lastRect(planning.eventKey(base, 2)).?; // Design 14:00-15:00
    const day_w = (760.0 - 60.0) / 7.0;
    // 两件同时开始 → 并排，各自占不到一天宽的一半
    try std.testing.expect(a.w < day_w * 0.55);
    try std.testing.expect(b.w < day_w * 0.55);
    try std.testing.expect(a.x > 0 and b.x > a.x);
}

// ------------------------------------------------------------------ 甘特图

const GanttFixture = struct {
    ui: core.Context = .{},
    st: planning.GanttState = .{},
    tasks: [4]planning.GanttTask = .{
        .{ .name = "Design", .owner = "ann", .start = 0, .end = 4, .progress = 1.0 },
        .{ .name = "Build", .owner = "bo", .start = 2, .end = 8, .progress = 0.5, .depends_on = 0, .tone = .info },
        .{ .name = "Ship", .start = 8, .end = 9, .milestone = true, .depends_on = 1, .tone = .success },
        .{ .name = "Retro", .start = 10, .end = 12, .progress = 0, .tone = .warn },
    },
    clicked: ?usize = null,

    fn frame(self: *GanttFixture, opts: planning.GanttOpts) void {
        self.ui.begin(860, 400);
        self.clicked = planning.gantt(&self.ui, "gantt", self.tasks[0..], WEEK, 14, &self.st, opts);
        self.ui.paint();
    }
};

test "planning: gantt renders rows and reports a click" {
    var f = GanttFixture{};
    f.frame(.{ .today = 3 });
    try std.testing.expect(!f.ui.overflowed);
    const tid = planning.taskKey(core.Context.idOf("gantt"), 0);
    const r = f.ui.lastRect(tid).?;
    try std.testing.expect(r.w > 60);
    f.ui.input = .{ .mouse = at(r.x + r.w * 0.5, r.y + r.h * 0.5), .pressed = true, .down = true };
    f.frame(.{ .today = 3 });
    f.ui.input = .{ .mouse = at(r.x + r.w * 0.5, r.y + r.h * 0.5), .click = at(r.x + r.w * 0.5, r.y + r.h * 0.5) };
    f.frame(.{ .today = 3 });
    try std.testing.expectEqual(@as(?usize, 0), f.clicked);
}

test "planning: dragging a gantt bar moves the task by whole days" {
    var f = GanttFixture{};
    f.frame(.{});
    const tid = planning.taskKey(core.Context.idOf("gantt"), 0);
    const r = f.ui.lastRect(tid).?;
    f.ui.input = .{ .mouse = at(r.x + r.w * 0.5, r.y + r.h * 0.5), .pressed = true, .down = true };
    f.frame(.{});
    // 往右拖 3 天（30px/天 = 90px）
    f.ui.input = .{ .mouse = at(r.x + r.w * 0.5 + 90, r.y + r.h * 0.5), .down = true };
    f.frame(.{});
    try std.testing.expectEqual(@as(i32, 3), f.tasks[0].start);
    try std.testing.expectEqual(@as(i32, 7), f.tasks[0].end);
    f.ui.input = .{ .mouse = at(r.x, r.y), .down = false };
    f.frame(.{});
    try std.testing.expectEqual(@as(i32, -1), f.st.drag);
}

test "planning: dragging the right edge of a gantt bar changes its end" {
    var f = GanttFixture{};
    f.frame(.{});
    const tid = planning.taskKey(core.Context.idOf("gantt"), 0);
    const r = f.ui.lastRect(tid).?;
    // 按在右边界 3px 以内 → 改长度
    f.ui.input = .{ .mouse = at(r.x + r.w - 3, r.y + r.h * 0.5), .pressed = true, .down = true };
    f.frame(.{});
    try std.testing.expectEqual(@as(u8, 3), f.st.mode);
    f.ui.input = .{ .mouse = at(r.x + r.w - 3 + 60, r.y + r.h * 0.5), .down = true };
    f.frame(.{});
    try std.testing.expectEqual(@as(i32, 0), f.tasks[0].start); // 起点不动
    try std.testing.expectEqual(@as(i32, 6), f.tasks[0].end);
}

test "planning: keyboard moves a gantt task a day, shift changes its length" {
    var f = GanttFixture{};
    f.frame(.{});
    f.ui.focus_id = planning.taskKey(core.Context.idOf("gantt"), 0);
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .right;
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    f.frame(.{});
    try std.testing.expectEqual(@as(i32, 1), f.tasks[0].start);
    try std.testing.expectEqual(@as(i32, 5), f.tasks[0].end);

    f.ui.input = .{ .keys = keys, .key_count = 1, .mods = .{ .shift = true } };
    f.frame(.{});
    try std.testing.expectEqual(@as(i32, 1), f.tasks[0].start); // Shift 只改终点
    try std.testing.expectEqual(@as(i32, 6), f.tasks[0].end);
}

test "planning: gantt clamps horizontal scroll to the content" {
    var f = GanttFixture{};
    // 14 天 × 30px = 420 < 时间轴宽 → 没得滚
    f.frame(.{});
    try std.testing.expectEqual(@as(f32, 0), f.st.max_scroll);
    // 60 天 → 有得滚，滚轮夹到上限
    f.ui.begin(860, 400);
    _ = planning.gantt(&f.ui, "gantt", f.tasks[0..], WEEK, 60, &f.st, .{});
    f.ui.paint();
    try std.testing.expect(f.st.max_scroll > 0);
    f.st.scroll = 1e6;
    f.ui.begin(860, 400);
    _ = planning.gantt(&f.ui, "gantt", f.tasks[0..], WEEK, 60, &f.st, .{});
    f.ui.paint();
    try std.testing.expect(f.st.scroll <= f.st.max_scroll);
}
