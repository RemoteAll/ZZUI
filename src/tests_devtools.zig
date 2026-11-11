//! 开发面板族：键值编辑器、问题面板、CI 流水线。
//! 夹具一律放文件级（带 `draw` 的结构体声明在测试函数内部会遮蔽测试里的 `var ui`）。
const std = @import("std");
const core = @import("core.zig");
const devtools = @import("devtools.zig");
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
