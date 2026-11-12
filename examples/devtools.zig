//! 开发者工具族示例（对位 CUI `cui_devtools.c` 的四个交互块）：
//! 查询构建、cron 定时选择、测试树、键位图。
//! 单独一个产物是为了**体积分账**：这四块约 25 KB，塞进 docs 会把那个产物顶穿门槛。
//!
//! `--once` 无窗口渲染第 0 页；`--shot-0` … `--shot-3` 用隐藏窗口真渲染对应页。
const std = @import("std");
const zzui = @import("zzui");

const page_names = [_][]const u8{ "Query", "Schedule", "Tests", "Keymap" };

// ---------------------------------------------------------------- 查询构建

const qb_fields = [_]zzui.devtools.QueryField{
    .{ .name = "status", .type = .choice, .choices = &.{ "open", "closed", "merged" } },
    .{ .name = "age", .type = .number },
    .{ .name = "title", .type = .text },
    .{ .name = "urgent", .type = .boolean },
};

const Record = struct {
    status: []const u8,
    age: []const u8,
    title: []const u8,
    urgent: []const u8,
};

const qb_records = [_]Record{
    .{ .status = "open", .age = "3", .title = "fix the raster clip", .urgent = "true" },
    .{ .status = "open", .age = "12", .title = "log viewer tail", .urgent = "false" },
    .{ .status = "closed", .age = "40", .title = "old build script", .urgent = "false" },
};

// ---------------------------------------------------------------- 定时

const sch_seed = "0 9 * * 1-5";
const sch_seed2 = "30 9 * * 1-5";

// ---------------------------------------------------------------- 测试树

const tests = [_]zzui.devtools.TestItem{
    .{ .name = "core", .depth = 0 },
    .{ .name = "raster rounds corners", .depth = 1, .status = .passed, .duration = 0.42 },
    .{ .name = "clip intersects nodes", .depth = 1, .status = .passed, .duration = 0.18 },
    .{ .name = "scroll keeps one offset", .depth = 1, .status = .failed, .duration = 1.24, .message = "expected 100, got 200 (double advance)" },
    .{ .name = "widgets", .depth = 0 },
    .{ .name = "button reports a rect", .depth = 1, .status = .passed, .duration = 0.07 },
    .{ .name = "menu flips upward", .depth = 1, .status = .skipped },
    .{ .name = "input masks secrets", .depth = 1, .status = .passed, .duration = 0.31 },
    .{ .name = "platform", .depth = 0 },
    .{ .name = "win32 window opens", .depth = 1, .status = .passed, .duration = 2.4 },
    .{ .name = "linux backend", .depth = 1, .status = .canceled },
    .{ .name = "headless bitmap", .depth = 1, .status = .running, .duration = 0.9 },
};

// ---------------------------------------------------------------- 键位图

const km_cats = [_][]const u8{ "File", "Edit", "View", "Run" };

const km_bindings = [_]zzui.devtools.KeymapBinding{
    .{ .combo = .{ .key = .escape }, .action = "Close panel", .category = 2 },
    .{ .combo = .{ .key = .f5 }, .action = "Run", .category = 3 },
    .{ .combo = .{ .key = .S, .mods = .{ .ctrl = true } }, .action = "Save", .category = 0 },
    .{ .combo = .{ .key = .S, .mods = .{ .ctrl = true } }, .action = "Save as", .category = 0 },
    .{ .combo = .{ .key = .P, .mods = .{ .ctrl = true } }, .action = "Quick open", .category = 2 },
    .{ .combo = .{ .key = .F, .mods = .{ .ctrl = true } }, .action = "Find", .category = 1 },
    .{ .combo = .{ .key = .Z, .mods = .{ .ctrl = true } }, .action = "Undo", .category = 1 },
    .{ .combo = .{ .key = .slash, .mods = .{ .ctrl = true } }, .action = "Comment", .category = 1 },
    .{ .combo = .{ .key = .tab, .mods = .{ .ctrl = true } }, .action = "Next tab", .category = 2 },
    .{ .combo = .{ .key = .W, .mods = .{ .ctrl = true, .shift = true } }, .action = "Close tab", .category = 2 },
};

const State = struct {
    page: usize = 0,
    // 查询
    qb_nodes: [16]zzui.devtools.QueryNode = @splat(.{}),
    qb_count: usize = 0,
    // 定时
    cron: [32]u8 = @splat(0),
    cron2: [32]u8 = @splat(0),
    sch: zzui.devtools.ScheduleState = .{},
    sch2: zzui.devtools.ScheduleState = .{},
    seeded: bool = false,
    // 测试树
    tx: zzui.devtools.TestExplorerState = .{},
    // 键位图
    km: zzui.devtools.KeymapState = .{},
    km_last: [64]u8 = @splat(0),
    km_last_len: usize = 0,
};

fn seed(st: *State) void {
    if (st.seeded) return;
    st.seeded = true;
    // 查询：status is open and age > 3
    st.qb_nodes[0] = .{ .group = true };
    st.qb_nodes[1] = .{ .depth = 1, .field = 0, .op = 0 };
    st.qb_nodes[1].setValue("open");
    st.qb_nodes[2] = .{ .depth = 1, .field = 1, .op = 2 };
    st.qb_nodes[2].setValue("3");
    st.qb_count = 3;
    @memcpy(st.cron[0..sch_seed.len], sch_seed);
    @memcpy(st.cron2[0..sch_seed2.len], sch_seed2);
}

fn build(ui: *zzui.core.Context, st: *State) void {
    seed(st);
    var col = ui.column(.{ .pad = 24, .gap = 14 });
    defer col.end();

    zzui.widgets.heading(ui, "Dev tools", 2);
    zzui.widgets.secondary(ui, "Query builder, cron schedule, test tree and keyboard map.");
    zzui.controls.tabs(ui, "dev-pages", page_names[0..], &st.page);

    var body = ui.scroll(.{ .id = "dev-body", .height = ui.height - 190, .gap = 14 });
    defer body.end();

    if (st.page == 0) {
        zzui.extras.muted(ui, "Conditions nest: group ALL/ANY, add conditions, remove with x. Values are case-insensitive.");
        _ = zzui.devtools.queryBuilder(ui, "ex-qb", qb_fields[0..], st.qb_nodes[0..], &st.qb_count, .{});
        var buf: [200]u8 = undefined;
        const sentence = zzui.devtools.queryText(qb_fields[0..], st.qb_nodes[0..st.qb_count], buf[0..]);
        zzui.widgets.separator(ui);
        zzui.widgets.secondary(ui, "Records:");
        zzui.extras.code(ui, ui.frameStr(sentence));
        for (qb_records) |r| {
            const vals = [_]?[]const u8{ r.status, r.age, r.title, r.urgent };
            const hit = zzui.devtools.queryMatch(qb_fields[0..], st.qb_nodes[0..st.qb_count], vals[0..]);
            zzui.extras.badge(ui, r.title, if (hit) .success else .neutral);
        }
    } else if (st.page == 1) {
        zzui.extras.muted(ui, "Six friendly modes write a five-field cron expression; the next runs are counted from a fixed clock.");
        _ = zzui.devtools.schedulePicker(ui, "ex-sch", st.cron[0..], &st.sch, .{
            .now = 1_704_067_200,
            .utc_offset_min = 480,
            .next_count = 4,
        });
        zzui.widgets.separator(ui);
        zzui.widgets.secondary(ui, "A second instance keeps its own state:");
        _ = zzui.devtools.schedulePicker(ui, "ex-sch2", st.cron2[0..], &st.sch2, .{
            .now = 1_704_067_200,
            .utc_offset_min = 480,
            .next_count = 3,
        });
    } else if (st.page == 2) {
        zzui.extras.muted(ui, "Suites fold, failures show their message, the toolbar runs and filters. Click a row, Enter activates.");
        const r = zzui.devtools.testExplorer(ui, "ex-tx", tests[0..], &st.tx, .{ .height = 360 });
        var sb: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(sb[0..], "passed {d} / failed {d} / skipped {d} / total {d}", .{
            r.passed, r.failed, r.skipped, r.total,
        }) catch "tests";
        zzui.extras.muted(ui, ui.frameStr(msg));
        if (r.activated >= 0) zzui.extras.badge(ui, tests[@intCast(r.activated)].name, .accent);
        if (r.run >= 0) zzui.extras.badge(ui, "run requested", .warn);
    } else {
        zzui.extras.muted(ui, "Every key shows its action for the chosen modifiers; duplicated combinations are flagged. Hover a key for all bindings, click to rebind.");
        const r = zzui.devtools.keymap(ui, "ex-km", km_bindings[0..], &st.km, .{ .categories = km_cats[0..] });
        if (r.clicked != .unknown) {
            const name = zzui.actions.keyName(r.clicked);
            const n = @min(name.len, st.km_last.len);
            @memcpy(st.km_last[0..n], name[0..n]);
            st.km_last_len = n;
        }
        if (st.km_last_len > 0) zzui.extras.badge(ui, ui.frameStr(st.km_last[0..st.km_last_len]), .accent);
    }
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--dark")) zzui.theme.setMode(.dark);
    if (hasFlag(cmdline, "--once")) return runOnce();
    if (hasFlag(cmdline, "--shot-3")) return runShot(3);
    if (hasFlag(cmdline, "--shot-2")) return runShot(2);
    if (hasFlag(cmdline, "--shot-1")) return runShot(1);
    if (hasFlag(cmdline, "--shot")) return runShot(0);

    var st = State{};
    var app = zzui.App.init(.{ .title = "ZZUI dev tools", .width = 900, .height = 860 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(900, 860) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    build(&app.ui, &st);
    app.end();
    if (app.ui.overflowed) return 8;
    zzui.bmpfile.saveBmp("zzui-devtools.bmp", app.backend.pixels(), 900, 860) catch return 4;
    return 0;
}

fn runShot(page: usize) i32 {
    var app = zzui.App.init(.{ .title = "ZZUI dev tools shot", .width = 900, .height = 860, .show = false }) catch return 5;
    defer app.deinit();
    var st = State{};
    st.page = page;
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        if (!app.next()) return 6;
        build(&app.ui, &st);
        app.end();
    }
    var buf: [64]u8 = @splat(0);
    const name = shotName(buf[0..], page);
    app.saveSurface(name) catch return 7;
    return 0;
}

fn shotName(buf: []u8, page: usize) []const u8 {
    var tmp: [48]u8 = undefined;
    const base = std.fmt.bufPrint(tmp[0..], "zzui-devtools-p{d}.bmp", .{page}) catch "zzui-devtools.bmp";
    @memcpy(buf[0..base.len], base);
    return buf[0..base.len];
}

fn hasFlag(cmd: [*:0]u16, flag: []const u8) bool {
    var i: usize = 0;
    while (cmd[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < flag.len and cmd[i + j] != 0 and cmd[i + j] == @as(u16, flag[j])) : (j += 1) {}
        if (j == flag.len) return true;
    }
    return false;
}
