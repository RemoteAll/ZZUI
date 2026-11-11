//! 开发者视图族：服务可用性条、事件直方图、覆盖率树、blame。
//! 夹具一律放文件级（带 `draw` 的结构体声明在测试函数内部会遮蔽测试里的 `var ui`）。
const std = @import("std");
const core = @import("core.zig");
const devviews = @import("devviews.zig");
const theme = @import("theme.zig");
const types = @import("types.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

fn keysOf(k: types.Key) types.Input {
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = k;
    return .{ .keys = keys, .key_count = 1 };
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

/// 测试里复刻 `devviews.kk`。
fn kkk(key: u64, salt: u64, i: usize) u64 {
    return key ^ (salt +% @as(u64, @intCast(i)));
}

// ------------------------------------------------------------------ 可用性条

var up_days_mixed = [_]f32{ 1.0, 0.995, 0.96, -1, 1.0, 0.5 };
var up_days_many: [120]f32 = @splat(1.0);

const up_services = [_]devviews.UptimeService{
    .{ .name = "api", .days = up_days_mixed[0..] },
    .{ .name = "worker", .days = up_days_many[0..] },
};

const UpF = struct {
    res: devviews.UptimeResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devviews.uptime(ui, "up", up_services[0..], .{
            .last_day = .{ .year = 2026, .month = 11, .day = 9 },
        });
    }
};

test "devviews: uptime colours step through green, amber and red" {
    const green = devviews.uptimeColor(1.0);
    const mixed = devviews.uptimeColor(0.995);
    const amber = devviews.uptimeColor(0.96);
    const red = devviews.uptimeColor(0.5);
    const none = devviews.uptimeColor(-1);
    try std.testing.expectEqual(theme.success, green);
    try std.testing.expect(!std.meta.eql(mixed, green) and !std.meta.eql(mixed, amber));
    try std.testing.expectEqual(theme.warn, amber);
    try std.testing.expectEqual(theme.danger, red);
    try std.testing.expectEqual(theme.border, none);
}

test "devviews: uptime reports the hovered service and day" {
    var ui = core.Context{};
    var f = UpF{};
    frame(&ui, 760, 300, &f, .{});
    try std.testing.expectEqual(@as(i32, -1), f.res.service);
    // 第一根条（最旧那天）
    const bars = ui.lastRect(kkk(core.Context.idOf("up"), 0x7A00, 0)).?;
    const bw: f32 = 14; // 宽屏下被夹到 14
    const gap: f32 = 3;
    hover(&ui, 760, 300, &f, bars.x + bw * 0.5, bars.y + bars.h * 0.5);
    try std.testing.expectEqual(@as(i32, 0), f.res.service);
    try std.testing.expectEqual(@as(i32, 0), f.res.day);
    // 第二根条
    hover(&ui, 760, 300, &f, bars.x + (bw + gap) + bw * 0.5, bars.y + bars.h * 0.5);
    try std.testing.expectEqual(@as(i32, 1), f.res.day);
    try std.testing.expect(!ui.overflowed);
}

test "devviews: uptime keeps only the latest days that fit" {
    var ui = core.Context{};
    var f = UpF{};
    frame(&ui, 240, 300, &f, .{});
    const bars = ui.lastRect(kkk(core.Context.idOf("up"), 0x7A00, 1)).?;
    // 最右边那根 = 最后一天（下标 119）
    hover(&ui, 240, 300, &f, bars.x + bars.w - 2, bars.y + bars.h * 0.5);
    try std.testing.expectEqual(@as(i32, 1), f.res.service);
    try std.testing.expectEqual(@as(i32, 119), f.res.day);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 直方图

var hist_a = [_]f32{ 1, 0, 2, 0, 3 };
var hist_b = [_]f32{ 0, 4, 0, 1, 0 };
const hist_series = [_]devviews.HistogramSeries{
    .{ .name = "error", .counts = hist_a[0..], .tone = .danger },
    .{ .name = "info", .counts = hist_b[0..] },
};

const HistF = struct {
    sel_start: f64 = 0,
    sel_end: f64 = 0,
    res: devviews.TimeHistogramResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devviews.timeHistogram(ui, "hist", 1_700_000_000, 60, 5, hist_series[0..], &self.sel_start, &self.sel_end, .{});
    }
};

test "devviews: the histogram reports the hovered bucket" {
    var ui = core.Context{};
    var f = HistF{};
    frame(&ui, 520, 200, &f, .{});
    try std.testing.expectEqual(@as(i32, -1), f.res.hovered);
    const plot = ui.lastRect(kkk(core.Context.idOf("hist"), 0x4B01, 0)).?;
    const bw = plot.w / 5.0;
    hover(&ui, 520, 200, &f, plot.x + bw * 2.5, plot.y + plot.h * 0.5);
    try std.testing.expectEqual(@as(i32, 2), f.res.hovered);
    try std.testing.expect(!ui.overflowed);
}

test "devviews: dragging the histogram selects a time range and a click clears it" {
    var ui = core.Context{};
    var f = HistF{};
    frame(&ui, 520, 200, &f, .{});
    const plot = ui.lastRect(kkk(core.Context.idOf("hist"), 0x4B01, 0)).?;
    const bw = plot.w / 5.0;
    const y = plot.y + plot.h * 0.5;
    const x0 = plot.x + bw * 0.5;
    const x1 = plot.x + bw * 2.5;
    // 按下第 0 桶
    frame(&ui, 520, 200, &f, .{ .mouse = at(x0, y), .pressed = true, .down = true });
    try std.testing.expectApproxEqAbs(@as(f64, 1_700_000_000 + 30), f.sel_start, 1);
    // 拖到第 2 桶
    frame(&ui, 520, 200, &f, .{ .mouse = at(x1, y), .down = true });
    try std.testing.expect(f.res.selection_changed);
    try std.testing.expect(f.sel_end > f.sel_start);
    try std.testing.expectApproxEqAbs(@as(f64, 1_700_000_000 + 150), f.sel_end, 1);
    // 松开后单击 → 清空选区
    frame(&ui, 520, 200, &f, .{ .mouse = at(x1, y) });
    click(&ui, 520, 200, &f, x1, y);
    try std.testing.expectEqual(@as(f64, 0), f.sel_start);
    try std.testing.expectEqual(@as(f64, 0), f.sel_end);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 覆盖率

const cov_files = [_]devviews.CoverageFile{
    .{ .path = "src/core/layout.zig", .lines = 100, .lines_hit = 90, .branches = 20, .branches_hit = 10, .functions = 5, .functions_hit = 5 },
    .{ .path = "src/core/paint.zig", .lines = 100, .lines_hit = 40, .branches = 10, .branches_hit = 1, .functions = 4, .functions_hit = 1 },
    .{ .path = "tests/a.zig", .lines = 50, .lines_hit = 50, .branches = 0, .branches_hit = 0, .functions = 2, .functions_hit = 2 },
};

const CovF = struct {
    st: devviews.CoverageState = .{},
    res: devviews.CoverageResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devviews.coverage(ui, "cov", cov_files[0..], &self.st, .{ .height = 300 });
    }
};

test "devviews: coverage builds a folder tree and reports the overall percent" {
    var ui = core.Context{};
    var f = CovF{};
    frame(&ui, 760, 400, &f, .{});
    // (90 + 40 + 50) / (100 + 100 + 50) = 72%
    try std.testing.expectApproxEqAbs(@as(f32, 72), f.res.lines, 0.01);
    // 根 + src + core + 两个文件 + tests + 一个文件 = 7 行
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 6)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 7)) == null);
    try std.testing.expect(!ui.overflowed);
}

test "devviews: folding a folder hides its rows" {
    var ui = core.Context{};
    var f = CovF{};
    frame(&ui, 760, 400, &f, .{});
    const src_row = ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 1)).?;
    click(&ui, 760, 400, &f, src_row.x + 6, src_row.y + 10);
    frame(&ui, 760, 400, &f, .{});
    // 折叠后只剩 根 + src + tests + a.zig
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 3)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 4)) == null);
    // 再点一下展开
    click(&ui, 760, 400, &f, src_row.x + 6, src_row.y + 10);
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 4)) != null);
    try std.testing.expect(!ui.overflowed);
}

test "devviews: clicking a column title sorts the tree" {
    var ui = core.Context{};
    var f = CovF{};
    frame(&ui, 760, 400, &f, .{});
    // 默认按名字升序：第 4 行是 src/core/layout.zig（文件 0）
    var row = ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 3)).?;
    click(&ui, 760, 400, &f, row.x + 40, row.y + 10);
    frame(&ui, 760, 400, &f, keysOf(.enter));
    try std.testing.expectEqual(@as(i32, 0), f.res.activated);
    // 点两次「Lines」表头 → 降序：第 3 行变成 tests/a.zig（文件 2）
    const lines_head = ui.lastRect(kkk(core.Context.idOf("cov"), 0x5E00, 1)).?;
    click(&ui, 760, 400, &f, lines_head.x + 10, lines_head.y + 10);
    click(&ui, 760, 400, &f, lines_head.x + 10, lines_head.y + 10);
    try std.testing.expectEqual(@as(u8, 1), f.st.sort_col);
    try std.testing.expectEqual(@as(u8, 1), f.st.sort_desc);
    frame(&ui, 760, 400, &f, .{});
    row = ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 2)).?;
    click(&ui, 760, 400, &f, row.x + 40, row.y + 10);
    frame(&ui, 760, 400, &f, keysOf(.enter));
    try std.testing.expectEqual(@as(i32, 2), f.res.activated);
    try std.testing.expect(!ui.overflowed);
}

test "devviews: a double click activates a file row" {
    var ui = core.Context{};
    var f = CovF{};
    frame(&ui, 760, 400, &f, .{});
    const row = ui.lastRect(kkk(core.Context.idOf("cov"), 0xD00, 4)).?; // src/core/paint.zig
    const x = row.x + 60;
    const y = row.y + 10;
    click(&ui, 760, 400, &f, x, y);
    click(&ui, 760, 400, &f, x, y);
    try std.testing.expectEqual(@as(i32, 1), f.res.activated); // src/core/paint.zig
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ Blame

const blame_lines = [_][]const u8{
    "const std = @import(\"std\");",
    "",
    "pub fn main() void {",
    "    std.debug.print(\"hi\\n\", .{});",
    "}",
};
const blame_map = [_]i32{ 0, 0, 1, 1, 2 };
const blame_commits = [_]devviews.BlameCommit{
    .{ .hash = "91cbf17e2d", .author = "Ada", .summary = "首版", .time = 1_700_000_000 },
    .{ .hash = "5d0f2a98c1", .author = "Bo", .summary = "加入打印", .time = 1_700_500_000 },
    .{ .hash = "a02d9c1440", .author = "Cy", .summary = "收尾", .time = 1_701_000_000 },
};

const BlF = struct {
    st: devviews.BlameState = .{},
    res: devviews.BlameResult = .{},
    lang: []const u8 = "zig",
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devviews.blame(ui, "bl", blame_lines[0..], blame_map[0..], blame_commits[0..], &self.st, .{
            .height = 200,
            .lang = self.lang,
            .now = 1_702_000_000,
        });
    }
};

test "devviews: blame reports hover and click on a commit" {
    var ui = core.Context{};
    var f = BlF{};
    frame(&ui, 760, 300, &f, .{ .mouse = at(740, 290) });
    try std.testing.expectEqual(@as(i32, -1), f.res.hovered);
    // 第 3 行起属于提交 1
    const row = ui.lastRect(kkk(core.Context.idOf("bl"), 0xB10, 2)).?;
    hover(&ui, 760, 300, &f, row.x + 20, row.y + 8);
    try std.testing.expectEqual(@as(i32, 1), f.res.hovered);
    try std.testing.expectEqual(@as(i32, 1), f.st.hovered);
    click(&ui, 760, 300, &f, row.x + 20, row.y + 8);
    try std.testing.expectEqual(@as(i32, 1), f.res.clicked);
    try std.testing.expect(!ui.overflowed);
}

test "devviews: blame narrows to initials and still works without a language" {
    var ui = core.Context{};
    var f = BlF{};
    f.lang = "";
    frame(&ui, 400, 300, &f, .{});
    // 5 行都在
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("bl"), 0xB10, 4)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("bl"), 0xB10, 5)) == null);
    const row = ui.lastRect(kkk(core.Context.idOf("bl"), 0xB10, 0)).?;
    hover(&ui, 400, 300, &f, row.x + 20, row.y + 8);
    try std.testing.expectEqual(@as(i32, 0), f.res.hovered);
    try std.testing.expect(!ui.overflowed);
}
