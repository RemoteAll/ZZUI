//! 开发面板族：键值编辑器、问题面板、CI 流水线。
//! 夹具一律放文件级（带 `draw` 的结构体声明在测试函数内部会遮蔽测试里的 `var ui`）。
const std = @import("std");
const core = @import("core.zig");
const devtools = @import("devtools.zig");
const month = @import("month.zig");
const types = @import("types.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

fn frame(ui: *core.Context, w: f32, h: f32, st: anytype, input: types.Input) void {
    ui.input = input;
    ui.begin(w, h);
    st.draw(ui);
    ui.paint();
}

fn hover(ui: *core.Context, w: f32, h: f32, st: anytype, x: f32, y: f32) void {
    frame(ui, w, h, st, .{ .mouse = at(x, y) });
    frame(ui, w, h, st, .{ .mouse = at(x, y) });
}

fn click(ui: *core.Context, w: f32, h: f32, st: anytype, x: f32, y: f32) void {
    frame(ui, w, h, st, .{ .mouse = at(x, y) });
    frame(ui, w, h, st, .{ .mouse = at(x, y), .click = at(x, y) });
}

fn kkk(key: u64, salt: u64, i: usize) u64 {
    return key ^ (salt +% @as(u64, @intCast(i)));
}

/// `widgets.input` 的命中 id 是 `idOf(id) ^ 0x7FEB352D`。
fn inputKey(name: []const u8) u64 {
    return core.Context.idOf(name) ^ 0x7FEB352D;
}

// ------------------------------------------------------------------ 键值编辑器

var kv_pairs: [4]devtools.KvPair = @splat(.{});
var kv_count: usize = 2;

const KvF = struct {
    changed: bool = false,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.changed = devtools.kvEditor(ui, "kv", kv_pairs[0..], &kv_count, .{});
    }
};

fn seedKv() void {
    kv_pairs = @splat(.{});
    kv_count = 2;
    kv_pairs[0].setKey("Accept");
    kv_pairs[0].setValue("application/json");
    kv_pairs[1].setKey("X-Token");
    kv_pairs[1].setValue("s3cr3t");
    kv_pairs[1].secret = true;
}

test "devtools: kv problems flag spaces and enabled duplicates only" {
    var pairs: [3]devtools.KvPair = @splat(.{});
    pairs[0].setKey("Accept");
    pairs[1].setKey("Accept");
    try std.testing.expect(devtools.kvProblem(pairs[0..], 0) == null);
    // 重复的键（都启用）
    pairs[1].enabled = true;
    try std.testing.expectEqualStrings("Used twice", devtools.kvProblem(pairs[0..], 1).?);
    // 关掉就不算重复
    pairs[1].enabled = false;
    try std.testing.expect(devtools.kvProblem(pairs[0..], 1) == null);
    // 空格
    pairs[2].setKey("Bad Key");
    try std.testing.expectEqualStrings("Has a space", devtools.kvProblem(pairs[0..], 2).?);
    // 空键不算错
    var empty: [1]devtools.KvPair = @splat(.{});
    try std.testing.expect(devtools.kvProblem(empty[0..], 0) == null);
}

test "devtools: the kv editor draws one row per pair plus a fresh row" {
    seedKv();
    var ui = core.Context{};
    var f = KvF{};
    frame(&ui, 720, 320, &f, .{});
    try std.testing.expect(!f.changed);
    // 第 3 行（下标 2）是空行：键输入框已经登记
    try std.testing.expect(ui.lastRect(inputKey("kv-k0")) != null);
    try std.testing.expect(ui.lastRect(inputKey("kv-k2")) != null);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: clicking the box toggles a pair on or off" {
    seedKv();
    var ui = core.Context{};
    var f = KvF{};
    frame(&ui, 720, 320, &f, .{});
    const box = ui.lastRect(kkk(core.Context.idOf("kv"), 0x100, 0)).?;
    click(&ui, 720, 320, &f, box.x + box.w * 0.5, box.y + box.h * 0.5);
    try std.testing.expect(!kv_pairs[0].enabled);
    try std.testing.expect(f.changed);
    click(&ui, 720, 320, &f, box.x + box.w * 0.5, box.y + box.h * 0.5);
    try std.testing.expect(kv_pairs[0].enabled);
}

test "devtools: the secret button flips and the x removes a pair" {
    seedKv();
    var ui = core.Context{};
    var f = KvF{};
    frame(&ui, 720, 320, &f, .{});
    // 第一对不是 secret，点一下变 secret
    const lock = ui.lastRect(kkk(core.Context.idOf("kv"), 0x200, 0)).?;
    try std.testing.expect(!kv_pairs[0].secret);
    click(&ui, 720, 320, &f, lock.x + lock.w * 0.5, lock.y + lock.h * 0.5);
    try std.testing.expect(kv_pairs[0].secret);
    // 删掉第一对 → 计数减一，后面的顶上
    const x = ui.lastRect(kkk(core.Context.idOf("kv"), 0x300, 1)).?;
    click(&ui, 720, 320, &f, x.x + x.w * 0.5, x.y + x.h * 0.5);
    try std.testing.expectEqual(@as(usize, 1), kv_count);
    try std.testing.expectEqualStrings("Accept", kv_pairs[0].keySlice());
    try std.testing.expect(!ui.overflowed);
}

test "devtools: typing in the empty row adds a pair" {
    seedKv();
    var ui = core.Context{};
    var f = KvF{};
    frame(&ui, 720, 320, &f, .{});
    // 点空行的键输入框
    const kid = ui.lastRect(inputKey("kv-k2")).?;
    click(&ui, 720, 320, &f, kid.x + 20, kid.y + kid.h * 0.5);
    // 打一个字符
    var input = types.Input{ .mouse = at(kid.x + 20, kid.y + kid.h * 0.5) };
    input.chars[0] = 'A';
    input.chars_len = 1;
    frame(&ui, 720, 320, &f, input);
    try std.testing.expectEqual(@as(usize, 3), kv_count);
    try std.testing.expectEqualStrings("A", kv_pairs[2].keySlice());
    try std.testing.expect(kv_pairs[2].enabled);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 问题面板

const diag_list = [_]devtools.Diagnostic{
    .{ .severity = .err, .message = "expected ';' after statement", .file = "src/core/layout.zig", .line = 42, .column = 9, .source = "zig", .code = "E0001" },
    .{ .severity = .warning, .message = "unused local constant 'tmp'", .file = "src/core/layout.zig", .line = 88, .source = "zig", .code = "W0042" },
    .{ .severity = .info, .message = "file is not formatted", .file = "src/widgets.zig" },
    .{ .severity = .hint, .message = "consider using a for loop", .file = "src/widgets.zig", .line = 7, .column = 3 },
    .{ .severity = .err, .message = "undefined symbol 'foo'", .file = "tests/core.zig", .line = 12, .column = 1, .source = "zig", .code = "E0002" },
    .{ .severity = .err, .message = "orphan error", .file = "" },
};

const PrbF = struct {
    st: devtools.ProblemsState = .{},
    res: devtools.ProblemsResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devtools.problems(ui, "prb", diag_list[0..], &self.st, .{ .height = 260 });
    }
};

test "devtools: the problems panel counts, groups and reports what is shown" {
    var ui = core.Context{};
    var f = PrbF{};
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expectEqual(@as(i32, 6), f.res.shown);
    try std.testing.expectEqual(@as(i32, -1), f.res.selected);
    // 3 个文件 + 6 条诊断 = 9 行
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("prb"), 0x9300, 5)) != null);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: the severity toggles and the filter narrow the list" {
    var ui = core.Context{};
    var f = PrbF{};
    frame(&ui, 760, 400, &f, .{});
    // 关掉 error → 剩 3 条
    const err_chip = ui.lastRect(kkk(core.Context.idOf("prb"), 0x9100, 0)).?;
    click(&ui, 760, 400, &f, err_chip.x + err_chip.w * 0.5, err_chip.y + 10);
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expectEqual(@as(i32, 3), f.res.shown);
    // 搜索 "unused"
    f.st.query_len = 6;
    @memcpy(f.st.query[0..6], "unused");
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expectEqual(@as(i32, 1), f.res.shown);
    // 全部关掉 → 0
    f.st.show = .{ false, false, false, false };
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expectEqual(@as(i32, 0), f.res.shown);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: a file header folds its diagnostics away" {
    var ui = core.Context{};
    var f = PrbF{};
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("prb"), 0x9300, 1)) != null);
    // 折叠 "src/core/layout.zig"（第 0 组）
    const head = ui.lastRect(kkk(core.Context.idOf("prb"), 0x9200, 0)).?;
    click(&ui, 760, 400, &f, head.x + 30, head.y + 10);
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("prb"), 0x9300, 0)) == null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("prb"), 0x9300, 1)) == null);
    // 别的组还在
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("prb"), 0x9300, 2)) != null);
    // 再点展开
    click(&ui, 760, 400, &f, head.x + 30, head.y + 10);
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("prb"), 0x9300, 0)) != null);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: clicking a diagnostic selects it and a double click activates it" {
    var ui = core.Context{};
    var f = PrbF{};
    frame(&ui, 760, 400, &f, .{});
    const row = ui.lastRect(kkk(core.Context.idOf("prb"), 0x9300, 2)).?;
    click(&ui, 760, 400, &f, row.x + 80, row.y + 10);
    try std.testing.expectEqual(@as(i32, 2), f.res.selected);
    try std.testing.expectEqual(@as(i32, -1), f.res.activated);
    click(&ui, 760, 400, &f, row.x + 80, row.y + 10);
    try std.testing.expectEqual(@as(i32, 2), f.res.activated);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: an empty problems panel says so" {
    const Empty = struct {
        st: devtools.ProblemsState = .{},
        res: devtools.ProblemsResult = .{},
        fn draw(self: *@This(), ui: *core.Context) void {
            self.res = devtools.problems(ui, "prb0", &.{}, &self.st, .{});
        }
    };
    var ui = core.Context{};
    var f = Empty{};
    frame(&ui, 600, 200, &f, .{});
    try std.testing.expectEqual(@as(i32, 0), f.res.shown);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 流水线

const pipe_stages = [_][]const u8{ "build", "test", "deploy" };
const pipe_jobs = [_]devtools.PipelineJob{
    .{ .name = "linux-x64", .stage = 0, .status = .passed, .duration = 48 },
    .{ .name = "windows-x64", .stage = 0, .status = .passed, .duration = 61 },
    .{ .name = "unit", .stage = 1, .status = .passed, .duration = 124 },
    .{ .name = "e2e", .stage = 1, .status = .running, .duration = 35 },
    .{ .name = "publish", .stage = 2, .status = .pending },
    .{ .name = "smoke", .stage = 2, .status = .failed, .duration = 9, .allow_failure = true },
};

const PlF = struct {
    sel: i32 = -1,
    res: devtools.PipelineResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devtools.pipeline(ui, "pl", pipe_stages[0..], pipe_jobs[0..], .{ .selected = &self.sel });
    }
};

test "devtools: the pipeline draws every stage and job" {
    var ui = core.Context{};
    var f = PlF{};
    frame(&ui, 860, 300, &f, .{});
    try std.testing.expectEqual(@as(i32, -1), f.res.clicked);
    var i: usize = 0;
    while (i < pipe_jobs.len) : (i += 1) {
        try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("pl"), 0x8100, i)) != null);
    }
    try std.testing.expect(!ui.overflowed);
}

test "devtools: clicking a job reports it and writes the selection" {
    var ui = core.Context{};
    var f = PlF{};
    frame(&ui, 860, 300, &f, .{});
    const card = ui.lastRect(kkk(core.Context.idOf("pl"), 0x8100, 3)).?;
    click(&ui, 860, 300, &f, card.x + 20, card.y + card.h * 0.5);
    try std.testing.expectEqual(@as(i32, 3), f.res.clicked);
    try std.testing.expectEqual(@as(i32, 3), f.sel);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: a narrow pipeline stacks the stages top to bottom" {
    var ui = core.Context{};
    var f = PlF{};
    frame(&ui, 420, 420, &f, .{});
    const build = ui.lastRect(kkk(core.Context.idOf("pl"), 0x8100, 0)).?;
    const test_job = ui.lastRect(kkk(core.Context.idOf("pl"), 0x8100, 2)).?;
    try std.testing.expect(test_job.y > build.y + build.h);
    try std.testing.expectApproxEqAbs(build.x, test_job.x, 0.5);
    try std.testing.expect(!ui.overflowed);
    // 宽屏时同一阶段的行首并排
    frame(&ui, 900, 300, &f, .{});
    const wide_build = ui.lastRect(kkk(core.Context.idOf("pl"), 0x8100, 0)).?;
    const wide_test = ui.lastRect(kkk(core.Context.idOf("pl"), 0x8100, 2)).?;
    try std.testing.expect(wide_test.x > wide_build.x + wide_build.w - 2);
    try std.testing.expectApproxEqAbs(wide_build.y, wide_test.y, 1.0);
}

test "devtools: a stage mixing passed, failed and running renders without panic" {
    const mixed = [_]devtools.PipelineJob{
        .{ .name = "a", .stage = 0, .status = .passed },
        .{ .name = "b", .stage = 0, .status = .failed },
        .{ .name = "c", .stage = 0, .status = .running },
    };
    var ui = core.Context{};
    const Agg = struct {
        jobs: []const devtools.PipelineJob,
        fn draw(self: *@This(), u: *core.Context) void {
            _ = devtools.pipeline(u, "pl2", pipe_stages[0..1], self.jobs, .{});
        }
    };
    var a = Agg{ .jobs = mixed[0..] };
    frame(&ui, 700, 200, &a, .{});
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 查询构建

const qb_fields = [_]devtools.QueryField{
    .{ .name = "status", .type = .choice, .choices = &.{ "open", "closed" } },
    .{ .name = "age", .type = .number },
    .{ .name = "title", .type = .text },
    .{ .name = "urgent", .type = .boolean },
};

var qb_nodes: [8]devtools.QueryNode = @splat(.{});
var qb_count: usize = 1;

const QbFixture = struct {
    changed: bool = false,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.changed = devtools.queryBuilder(ui, "qb", qb_fields[0..], qb_nodes[0..], &qb_count, .{});
    }
};

fn seedQuery() void {
    qb_nodes = @splat(.{});
    qb_count = 4;
    qb_nodes[0] = .{ .group = true };
    qb_nodes[1] = .{ .depth = 1, .field = 1, .op = 2 };
    qb_nodes[1].setValue("3");
    qb_nodes[2] = .{ .depth = 1, .field = 3, .op = 0 };
    qb_nodes[3] = .{ .depth = 1, .field = 0, .op = 0 };
    qb_nodes[3].setValue("open");
}

test "devtools: query operators per field type" {
    try std.testing.expectEqualStrings("contains", devtools.queryOpName(.text, 2).?);
    try std.testing.expect(devtools.queryOpName(.text, 6) == null);
    try std.testing.expect(devtools.queryOpName(.text, -1) == null);
    try std.testing.expectEqualStrings("<=", devtools.queryOpName(.number, 5).?);
    try std.testing.expectEqualStrings("is not", devtools.queryOpName(.choice, 1).?);
    try std.testing.expectEqualStrings("is false", devtools.queryOpName(.boolean, 1).?);
}

test "devtools: query text writes rules joined by and" {
    seedQuery();
    var buf: [160]u8 = undefined;
    const s = devtools.queryText(qb_fields[0..], qb_nodes[0..4], buf[0..]);
    try std.testing.expectEqualStrings("age > 3 and urgent is true and status is open", s);
}

test "devtools: query text parenthesises nested groups" {
    var nodes: [5]devtools.QueryNode = @splat(.{});
    nodes[0] = .{ .group = true };
    nodes[1] = .{ .group = true, .any = true, .depth = 1 };
    nodes[2] = .{ .depth = 2, .field = 1, .op = 2 };
    nodes[2].setValue("10");
    nodes[3] = .{ .depth = 2, .field = 3, .op = 1 };
    nodes[4] = .{ .depth = 1, .field = 0, .op = 0 };
    nodes[4].setValue("open");
    var buf: [200]u8 = undefined;
    const s = devtools.queryText(qb_fields[0..], nodes[0..5], buf[0..]);
    try std.testing.expectEqualStrings("(age > 10 or urgent is false) and status is open", s);
}

test "devtools: query matching covers text, number, choice, bool and nesting" {
    seedQuery();
    const yes = [_]?[]const u8{ "open", "5", "a log", "true" };
    try std.testing.expect(devtools.queryMatch(qb_fields[0..], qb_nodes[0..4], yes[0..]));
    const no_age = [_]?[]const u8{ "open", "2", "a log", "true" };
    try std.testing.expect(!devtools.queryMatch(qb_fields[0..], qb_nodes[0..4], no_age[0..]));
    const no_status = [_]?[]const u8{ "closed", "5", "a log", "true" };
    try std.testing.expect(!devtools.queryMatch(qb_fields[0..], qb_nodes[0..4], no_status[0..]));

    // 嵌套 any 组
    qb_nodes = @splat(.{});
    qb_nodes[0] = .{ .group = true };
    qb_nodes[1] = .{ .group = true, .any = true, .depth = 1 };
    qb_nodes[2] = .{ .depth = 2, .field = 1, .op = 2 };
    qb_nodes[2].setValue("10");
    qb_nodes[3] = .{ .depth = 2, .field = 3, .op = 1 };
    qb_nodes[4] = .{ .depth = 1, .field = 0, .op = 0 };
    qb_nodes[4].setValue("open");
    const nested_true = [_]?[]const u8{ "open", "20", "x", "false" };
    try std.testing.expect(devtools.queryMatch(qb_fields[0..], qb_nodes[0..5], nested_true[0..]));
    const nested_false = [_]?[]const u8{ "open", "5", "x", "true" };
    try std.testing.expect(!devtools.queryMatch(qb_fields[0..], qb_nodes[0..5], nested_false[0..]));

    // 空查询匹配一切
    try std.testing.expect(devtools.queryMatch(qb_fields[0..], qb_nodes[0..0], yes[0..]));
}

test "devtools: query builder adds a condition and flips all/any" {
    qb_nodes = @splat(.{});
    qb_count = 1;
    qb_nodes[0] = .{ .group = true };
    var ui = core.Context{};
    var f = QbFixture{};
    frame(&ui, 720, 320, &f, .{});
    try std.testing.expect(!ui.overflowed);

    const qkey = core.Context.idOf("qb");
    const add_id = core.Context.idOf("+ Condition") ^ 0x9E3779B97F4A7C15 ^ kkk(qkey, 0xB500, 0);
    const btn = ui.lastRect(add_id).?;
    click(&ui, 720, 320, &f, btn.x + btn.w * 0.5, btn.y + btn.h * 0.5);
    try std.testing.expectEqual(@as(usize, 2), qb_count);
    try std.testing.expect(qb_nodes[1].depth == 1);
    try std.testing.expect(!qb_nodes[1].group);

    // All → Any
    const jid = core.Context.idOf("qb#join0") ^ (0x5E9 + 1);
    const seg = ui.lastRect(jid).?;
    frame(&ui, 720, 320, &f, .{});
    click(&ui, 720, 320, &f, seg.x + seg.w * 0.5, seg.y + seg.h * 0.5);
    try std.testing.expect(qb_nodes[0].any);
}

// ------------------------------------------------------------------ cron / 定时选择

fn utc(y: i32, m: u8, d: u8, hh: i64) i64 {
    return month.daysFromCivil(.{ .year = y, .month = m, .day = d }) * 86400 + hh * 3600;
}

test "devtools: cron next handles steps, weekdays, months and names" {
    const base = utc(2024, 1, 1, 0);
    try std.testing.expectEqual(base + 15 * 60, devtools.cronNext("*/15 * * * *", base, 0).?);
    try std.testing.expectEqual(base + 9 * 3600, devtools.cronNext("0 9 * * 1-5", base, 0).?);
    try std.testing.expectEqual(utc(2024, 2, 1, 0), devtools.cronNext("0 0 1 * *", base, 0).?);
    try std.testing.expectEqual(base + 9 * 3600, devtools.cronNext("0 9 * JAN-MAR mon", base, 0).?);
    // UTC+8：09:00 当地时间 = 01:00 UTC
    try std.testing.expectEqual(base + 3600, devtools.cronNext("0 9 * * *", base, 480).?);
    // 非法表达式
    try std.testing.expect(devtools.cronNext("0 0 * *", base, 0) == null);
    try std.testing.expect(devtools.cronNext("60 0 * * *", base, 0) == null);
    try std.testing.expect(devtools.cronNext("0 0 31 2 *", base, 0) == null);
}

test "devtools: cron describe writes a sentence" {
    var ui = core.Context{};
    ui.begin(400, 300);
    try std.testing.expectEqualStrings("Every 15 minutes", devtools.cronDescribe(&ui, "*/15 * * * *").?);
    try std.testing.expectEqualStrings("Every weekday at 09:00", devtools.cronDescribe(&ui, "0 9 * * 1-5").?);
    try std.testing.expectEqualStrings("Every weekend at 09:00", devtools.cronDescribe(&ui, "0 9 * * 0,6").?);
    try std.testing.expectEqualStrings("Every day at 09:00", devtools.cronDescribe(&ui, "0 9 * * *").?);
    try std.testing.expectEqualStrings("On day 1 of every month at 00:00", devtools.cronDescribe(&ui, "0 0 1 * *").?);
    try std.testing.expectEqualStrings("Every minute", devtools.cronDescribe(&ui, "* * * * *").?);
    try std.testing.expect(devtools.cronDescribe(&ui, "nope") == null);
}

var sch_buf: [32]u8 = @splat(0);
var sch_state = devtools.ScheduleState{};

const SchFixture = struct {
    res: devtools.ScheduleResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devtools.schedulePicker(ui, "sch", sch_buf[0..], &sch_state, .{ .now = 1_704_067_200 });
    }
};

fn seedSchedule(text: []const u8) void {
    sch_buf = @splat(0);
    sch_state = .{};
    @memcpy(sch_buf[0..text.len], text);
}

test "devtools: schedule picker reads the expression into its controls" {
    seedSchedule("*/15 * * * *");
    var ui = core.Context{};
    var f = SchFixture{};
    frame(&ui, 720, 400, &f, .{});
    try std.testing.expectEqual(@as(u8, 0), sch_state.mode);
    try std.testing.expectEqual(@as(i32, 15), sch_state.every);
    try std.testing.expect(f.res.valid);
    try std.testing.expectEqual(@as(i64, 1_704_068_100), f.res.next);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: picking a mode rewrites the cron expression" {
    seedSchedule("*/15 * * * *");
    var ui = core.Context{};
    var f = SchFixture{};
    frame(&ui, 720, 400, &f, .{});
    // 第 3 个分段 = Daily
    const sid = core.Context.idOf("sch#mode") ^ (0x5E9 + 2);
    const seg = ui.lastRect(sid).?;
    click(&ui, 720, 400, &f, seg.x + seg.w * 0.5, seg.y + seg.h * 0.5);
    try std.testing.expectEqual(@as(u8, 2), sch_state.mode);
    try std.testing.expectEqualStrings("0 9 * * *", sch_buf[0..devtoolsZlen(sch_buf[0..])]);
    try std.testing.expect(f.res.changed);
    try std.testing.expectEqual(@as(i64, 1_704_099_600), f.res.next);
}

fn devtoolsZlen(buf: []const u8) usize {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) i += 1;
    return i;
}

// ------------------------------------------------------------------ 测试树

const tx_items = [_]devtools.TestItem{
    .{ .name = "core", .depth = 0 },
    .{ .name = "adds", .depth = 1, .status = .passed, .duration = 0.5 },
    .{ .name = "subtracts", .depth = 1, .status = .failed, .duration = 1.2, .message = "expected 1 got 2" },
    .{ .name = "ui", .depth = 0 },
    .{ .name = "click", .depth = 1, .status = .skipped },
};

const TxFixture = struct {
    st: devtools.TestExplorerState = .{},
    res: devtools.TestExplorerResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devtools.testExplorer(ui, "tx", tx_items[0..], &self.st, .{ .height = 220 });
    }
};

test "devtools: test explorer sums suites and counts tests" {
    var ui = core.Context{};
    var f = TxFixture{};
    frame(&ui, 900, 420, &f, .{});
    try std.testing.expectEqual(@as(i32, 1), f.res.passed);
    try std.testing.expectEqual(@as(i32, 1), f.res.failed);
    try std.testing.expectEqual(@as(i32, 1), f.res.skipped);
    try std.testing.expectEqual(@as(i32, 3), f.res.total);
    const key = core.Context.idOf("tx");
    var i: usize = 0;
    while (i < tx_items.len) : (i += 1) {
        try std.testing.expect(ui.lastRect(kkk(key, 0x9200, i)) != null);
    }
    try std.testing.expect(!ui.overflowed);
}

test "devtools: filtering hides tests but keeps their suite" {
    var ui = core.Context{};
    var f = TxFixture{};
    frame(&ui, 900, 420, &f, .{});
    const q = "sub";
    @memcpy(f.st.query[0..q.len], q);
    f.st.query_len = q.len;
    frame(&ui, 900, 420, &f, .{});
    const key = core.Context.idOf("tx");
    try std.testing.expect(ui.lastRect(kkk(key, 0x9200, 0)) != null); // 套件仍在
    try std.testing.expect(ui.lastRect(kkk(key, 0x9200, 1)) == null); // adds 被过滤
    try std.testing.expect(ui.lastRect(kkk(key, 0x9200, 2)) != null); // subtracts 命中
    try std.testing.expectEqual(@as(i32, 3), f.res.total); // 计数仍是全部测试
}

test "devtools: folding a suite hides its tests" {
    var ui = core.Context{};
    var f = TxFixture{};
    frame(&ui, 900, 420, &f, .{});
    const key = core.Context.idOf("tx");
    const chev = ui.lastRect(kkk(key, 0x9400, 0)).?;
    click(&ui, 900, 420, &f, chev.x + chev.w * 0.5, chev.y + chev.h * 0.5);
    try std.testing.expectEqual(@as(usize, 1), f.st.nfolded);
    frame(&ui, 900, 420, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(key, 0x9200, 1)) == null);
    try std.testing.expect(ui.lastRect(kkk(key, 0x9200, 2)) == null);
    try std.testing.expect(ui.lastRect(kkk(key, 0x9200, 3)) != null);
}

test "devtools: selecting a test then Enter activates it" {
    var ui = core.Context{};
    var f = TxFixture{};
    frame(&ui, 900, 420, &f, .{});
    const key = core.Context.idOf("tx");
    const row = ui.lastRect(kkk(key, 0x9200, 2)).?;
    click(&ui, 900, 420, &f, row.x + 120, row.y + row.h * 0.5);
    try std.testing.expectEqual(@as(i32, 2), f.st.sel);
    var inp = types.Input{ .mouse = at(row.x + 120, row.y + row.h * 0.5) };
    inp.addKey(.enter);
    frame(&ui, 900, 420, &f, inp);
    try std.testing.expectEqual(@as(i32, 2), f.res.activated);
}

// ------------------------------------------------------------------ 键位图

const km_bindings = [_]devtools.KeymapBinding{
    .{ .combo = .{ .key = .escape }, .action = "Close panel", .category = 0 },
    .{ .combo = .{ .key = .S, .mods = .{ .ctrl = true } }, .action = "Save", .category = 0 },
    .{ .combo = .{ .key = .S, .mods = .{ .ctrl = true } }, .action = "Save as", .category = 1 },
    .{ .combo = .{ .key = .P, .mods = .{ .ctrl = true } }, .action = "Print", .category = 0 },
    .{ .combo = .{ .key = .f5 }, .action = "Run", .category = 2 },
};

const km_cats = [_][]const u8{ "File", "Edit", "Run" };

const KmFixture = struct {
    st: devtools.KeymapState = .{},
    res: devtools.KeymapResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devtools.keymap(ui, "km", km_bindings[0..], &self.st, .{ .categories = km_cats[0..] });
    }
};

test "devtools: keymap counts conflicts and draws the keyboard" {
    var ui = core.Context{};
    var f = KmFixture{};
    frame(&ui, 900, 600, &f, .{});
    try std.testing.expectEqual(@as(i32, 1), f.res.conflicts);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("km"), 0x4B3A, 0)) != null);
    try std.testing.expect(!ui.overflowed);
}

test "devtools: clicking a key reports it" {
    var ui = core.Context{};
    var f = KmFixture{};
    frame(&ui, 900, 600, &f, .{});
    const kb = ui.lastRect(kkk(core.Context.idOf("km"), 0x4B3A, 0)).?;
    // 键盘按 15 键宽排布（900px 宽时装得下导航区 → 18.5），Esc 在左上角第一格
    const avail: f32 = 900;
    const u: f32 = @min(46, avail / 18.5);
    const x0: f32 = @max(0, (avail - 18.5 * u) * 0.5);
    const kx = kb.x + x0 + 2 + (u - 4) * 0.5;
    const ky = kb.y + 2 + (u - 4) * 0.5;
    click(&ui, 900, 600, &f, kx, ky);
    try std.testing.expectEqual(types.Key.escape, f.res.clicked);
}

test "devtools: switching the modifier set changes what is shown" {
    var ui = core.Context{};
    var f = KmFixture{};
    frame(&ui, 900, 600, &f, .{});
    const sid = core.Context.idOf("km#mods") ^ (0x5E9 + 1);
    const seg = ui.lastRect(sid).?;
    click(&ui, 900, 600, &f, seg.x + seg.w * 0.5, seg.y + seg.h * 0.5);
    try std.testing.expect(f.st.mods.ctrl);
    try std.testing.expect(!f.st.mods.shift);
}
