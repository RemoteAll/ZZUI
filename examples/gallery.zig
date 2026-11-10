//! 控件画廊：分 5 页展示全部 59 个控件的实际外观。
//! 正常启动开窗口（点页签切换）；`--once` 无窗口渲染当前页；`--shot-N` 用隐藏窗口真渲染第 N 页。
//!
//! **分页不是为了好看**：一页塞满全部控件会超过 `MAX_NODES`（256），
//! 而把容量扩到 512 会让产物多 79 KB（`Context` 变大直接换体积），所以按页分摊。
const std = @import("std");
const zzui = @import("zzui");

const page_names = [_][]const u8{ "Components", "Forms", "Data", "Charts", "Shell" };

const State = struct {
    page: usize = 0,
    tab: usize = 0,
    seg: usize = 1,
    chip_a: bool = true,
    chip_b: bool = false,
    stars: u8 = 3,
    count: i32 = 4,
    size_idx: usize = 1,
    lo: f32 = 20,
    hi: f32 = 70,
    page_no: usize = 3,
    select_idx: usize = 1,
    select_open: bool = false,
    select_anchor: zzui.types.Rect = .{},
    popover_open: bool = false,
    popover_anchor: zzui.types.Rect = .{},
    ctx_open: bool = false,
    ctx_at: zzui.types.Point = .{},
    pal_open: bool = false,
    pal_query: [64]u8 = @splat(0),
    pal_len: usize = 0,
    pal_caret: usize = 0,
    toast_open: bool = true,
    toast_since: f64 = -1,
    sort: zzui.table.SortState = .{},
    table_sel: ?usize = null,
    tree_sel: ?usize = null,
    tree_open: [2]bool = @splat(true),
    pwd: [64]u8 = @splat(0),
    pwd_len: usize = 0,
    pwd_caret: usize = 0,
    q: [64]u8 = @splat(0),
    q_len: usize = 0,
    q_caret: usize = 0,
    amount: f32 = 3,
    notes: [256]u8 = @splat(0),
    notes_len: usize = 0,
    notes_caret: usize = 0,
    menu_open: ?usize = null,
    doc_tab: usize = 0,
    doc_closed: [3]bool = @splat(false),
    last_pick: u32 = 0,
};

// ------------------------------------------------------------------ 页 0：显示与反馈

fn pageComponents(ui: *zzui.core.Context) void {
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Badges, keys and code", 3);
        {
            var row = ui.row(.{ .gap = 6 });
            defer row.end();
            zzui.extras.badge(ui, "neutral", .neutral);
            zzui.extras.badge(ui, "accent", .accent);
            zzui.extras.badge(ui, "passed", .success);
            zzui.extras.badge(ui, "warning", .warn);
            zzui.extras.badge(ui, "failed", .danger);
        }
        {
            var row = ui.row(.{ .gap = 10 });
            defer row.end();
            zzui.extras.kbd(ui, "Ctrl Shift K");
            _ = zzui.extras.link(ui, "Documentation");
            zzui.extras.code(ui, "zig build test");
        }
    }
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Progress and feedback", 3);
        zzui.extras.progress(ui, 0.42, .{ .label = "Upload" });
        zzui.extras.progress(ui, 0.8, .{ .label = "Indexing", .tone = .success });
        zzui.extras.meter(ui, "CPU", 0.63);
        {
            var row = ui.row(.{ .gap = 16 });
            defer row.end();
            zzui.extras.progressRing(ui, 0.7, 56);
            zzui.extras.spinner(ui, 24);
            zzui.extras.passwordStrength(ui, 3, 4);
        }
        zzui.extras.skeleton(ui, 220, 12);
        zzui.extras.skeleton(ui, 150, 12);
    }
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Empty state and timeline", 3);
        zzui.extras.emptyState(ui, "No projects yet", "Create your first project to get started.");
        zzui.extras.timelineItem(ui, "09:12", "Build finished", "zzui-gallery x64 in 3.4s");
        zzui.extras.timelineItem(ui, "08:40", "Tests passed", "39 cases, 0 failures");
    }
}

// ------------------------------------------------------------------ 页 1：表单与导航

fn pageForms(ui: *zzui.core.Context, st: *State) void {
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Navigation", 3);
        zzui.controls.tabs(ui, "tabs", &.{ "Overview", "Activity", "Settings" }, &st.tab);
        zzui.controls.segmented(ui, "seg", &.{ "Day", "Week", "Month" }, &st.seg);
        _ = zzui.controls.breadcrumb(ui, &.{ "Home", "Projects", "ZZUI" }, 2);
        {
            var row = ui.row(.{ .gap = 8 });
            defer row.end();
            _ = zzui.controls.chip(ui, "alpha", &st.chip_a);
            _ = zzui.controls.chip(ui, "beta", &st.chip_b);
        }
    }
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Selection", 3);
        {
            var row = ui.row(.{ .gap = 16 });
            defer row.end();
            zzui.controls.rating(ui, "rating", &st.stars, 5);
            zzui.controls.stepper(ui, "count", &st.count, 0, 99);
            zzui.controls.pagination(ui, "pages", &st.page_no, 12);
        }
        zzui.controls.radioGroup(ui, "sizes", &.{ "Small", "Medium", "Large" }, &st.size_idx);
        zzui.controls.rangeSlider(ui, "range", &st.lo, &st.hi, 0, 100);
    }
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Text editing", 3);
        _ = zzui.widgets.input(ui, "pwd", st.pwd[0..], &st.pwd_len, &st.pwd_caret, .{ .password = true, .placeholder = "Password" });
        _ = zzui.textedit.search(ui, "q", st.q[0..], &st.q_len, &st.q_caret, .{ .placeholder = "Search components" });
        _ = zzui.textedit.number(ui, "num", &st.amount, .{ .label = "Quantity", .min = 0, .max = 20, .step = 1, .suffix = "pcs" });
        _ = zzui.textedit.textarea(ui, "ta", st.notes[0..], &st.notes_len, &st.notes_caret, .{ .rows = 3, .placeholder = "Notes..." });
    }
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Side navigation", 3);
        _ = zzui.controls.navItem(ui, "Dashboard", true);
        _ = zzui.controls.navItem(ui, "Reports", false);
        _ = zzui.controls.navItem(ui, "Settings", false);
    }
}

// ------------------------------------------------------------------ 页 2：表格

fn pageData(ui: *zzui.core.Context, st: *State) void {
    var card = zzui.extras.card(ui, .{});
    defer card.end();
    zzui.widgets.heading(ui, "Service table", 3);

    const cols = [_]zzui.table.Column{
        .{ .label = "Service", .width = 0 },
        .{ .label = "Status", .width = 96 },
        .{ .label = "Latency", .width = 88, .text_align = .end, .sortable = true },
    };
    const data = [_][3][]const u8{
        .{ "api-gateway", "running", "18 ms" },
        .{ "auth-service", "running", "24 ms" },
        .{ "billing", "degraded", "310 ms" },
        .{ "search", "running", "42 ms" },
        .{ "worker-1", "stopped", "-" },
        .{ "worker-2", "running", "55 ms" },
    };
    {
        // 表格必须用块限定作用域：`end()` 之前的构建都属于表格内部
        var tbl = zzui.table.begin(ui, "svc", cols[0..], &st.sort, .{ .height = 4 * 32 });
        defer tbl.end();
        for (data, 0..) |cells, i| {
            var r = tbl.row(i, st.table_sel != null and st.table_sel.? == i);
            r.text(0, cells[0], zzui.theme.text);
            r.text(1, cells[1], if (std.mem.eql(u8, cells[1], "running")) zzui.theme.success else if (std.mem.eql(u8, cells[1], "degraded")) zzui.theme.warn else zzui.theme.danger);
            r.text(2, cells[2], zzui.theme.secondary);
            if (r.clicked) st.table_sel = if (st.table_sel != null and st.table_sel.? == i) null else i;
        }
    }

    zzui.widgets.heading(ui, "Tree table", 3);
    const tcols = [_]zzui.table.Column{ .{ .label = "Path", .width = 0 }, .{ .label = "Size", .width = 90, .text_align = .end } };
    const nodes = [_]struct { depth: u8, has: bool, label: []const u8, size: []const u8 }{
        .{ .depth = 0, .has = true, .label = "src", .size = "" },
        .{ .depth = 1, .has = false, .label = "core.zig", .size = "12 KB" },
        .{ .depth = 1, .has = true, .label = "widgets", .size = "" },
        .{ .depth = 2, .has = false, .label = "button.zig", .size = "4 KB" },
    };
    {
        var tree = zzui.table.begin(ui, "tree", tcols[0..], &st.sort, .{ .height = 4 * 32 + 8 });
        defer tree.end();
        for (nodes, 0..) |node, i| {
            const visible = switch (i) {
                0 => true,
                1, 2 => st.tree_open[0],
                else => st.tree_open[0] and st.tree_open[1],
            };
            if (!visible) continue;
            var tn = zzui.table.TreeRow{
                .depth = node.depth,
                .has_children = node.has,
                .expanded = if (i == 0) st.tree_open[0] else st.tree_open[1],
            };
            const res = zzui.table.treeRow(&tree, i, &tn, node.label, st.tree_sel != null and st.tree_sel.? == i);
            if (res.toggled) {
                if (i == 0) {
                    st.tree_open[0] = tn.expanded;
                } else {
                    st.tree_open[1] = tn.expanded;
                }
            }
            if (node.size.len > 0) res.row.text(1, node.size, zzui.theme.secondary);
            if (res.row.clicked and !res.toggled) st.tree_sel = i;
        }
    }
}

// ------------------------------------------------------------------ 页 3：浮层与图表

fn pageCharts(ui: *zzui.core.Context, st: *State) void {
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Overlays", 3);
        {
            var row = ui.row(.{ .gap = 12 });
            defer row.end();
            st.select_anchor = zzui.overlay.selectField(ui, "fruit", &.{ "Apple", "Banana", "Cherry" }, &st.select_idx, &st.select_open, .{});
            const pb = zzui.widgets.buttonEx(ui, "Popover", .{});
            if (pb.clicked) st.popover_open = true;
            st.popover_anchor = pb.rect;
            if (zzui.widgets.button(ui, "Command palette", .{})) st.pal_open = true;
        }
        zzui.extras.muted(ui, "Right-click the line below for a context menu.");

        const hit_id = zzui.core.Context.idOf("ctx-area") ^ 0xC7C7;
        const zone = ui.reserve(0, 26, true);
        const it = ui.interactEx(hit_id, zone, false);
        if (it.hover) ui.addBox(zone, .{ .fill = zzui.theme.surface, .radius = 6 });
        if (ui.input.right_click) |p| {
            if (zone.contains(p.x, p.y)) {
                st.ctx_open = true;
                st.ctx_at = p;
            }
        }
    }
    {
        var card = zzui.extras.card(ui, .{});
        defer card.end();
        zzui.widgets.heading(ui, "Charts", 3);

        zzui.extras.muted(ui, "Sparkline");
        const spark = [_]f32{ 4, 6, 5, 9, 7, 11, 10, 14, 12, 16, 15, 19 };
        zzui.charts.sparkline(ui, &spark, .{ .height = 30, .fill = true });

        zzui.extras.muted(ui, "Line chart");
        const a = [_]f32{ 12, 18, 15, 22, 20, 28, 26, 31 };
        const b = [_]f32{ 8, 11, 14, 13, 18, 17, 22, 24 };
        const series = [_]zzui.charts.Series{
            .{ .values = &a, .color = zzui.theme.accent, .label = "Requests" },
            .{ .values = &b, .color = zzui.theme.success, .label = "Errors" },
        };
        zzui.charts.lineChart(ui, &series, .{ .height = 130 });

        zzui.extras.muted(ui, "Bar chart");
        const c = [_]f32{ 5, 8, 6, 10, 7, 9 };
        const bs = [_]zzui.charts.Series{.{ .values = &c, .color = zzui.theme.accent }};
        zzui.charts.barChart(ui, &bs, .{ .height = 110 });

        {
            var row = ui.row(.{ .gap = 24 });
            defer row.end();
            const donut = [_]f32{ 42, 26, 18, 14 };
            const labels = [_][]const u8{ "API", "Auth", "Worker", "Other" };
            const cols = [_]zzui.types.Color{ zzui.theme.accent, zzui.theme.success, zzui.theme.warn, zzui.theme.danger };
            zzui.charts.donutChart(ui, &donut, &labels, &cols, .{ .size = 110, .center_label = "100" });
            zzui.charts.gauge(ui, 0.68, .{ .size = 130, .label = "CPU" });
        }
    }
}

// ------------------------------------------------------------------ 页 4：应用外壳

fn pageShell(ui: *zzui.core.Context, st: *State) void {
    const file_items = [_]zzui.widgets.MenuItem{
        .{ .label = "New" },
        .{ .label = "Open..." },
        .{ .label = "Save" },
        .{ .label = "Close" },
    };
    const edit_items = [_]zzui.widgets.MenuItem{
        .{ .label = "Undo" },
        .{ .label = "Redo" },
        .{ .label = "Cut", .enabled = false },
    };
    const help_items = [_]zzui.widgets.MenuItem{
        .{ .label = "Documentation" },
        .{ .label = "About ZZUI" },
    };
    const menus = [_]zzui.chrome.MenuDef{
        .{ .label = "File", .items = file_items[0..] },
        .{ .label = "Edit", .items = edit_items[0..] },
        .{ .label = "Help", .items = help_items[0..] },
    };

    zzui.extras.muted(ui, "Menu bar");
    if (zzui.chrome.menuBar(ui, "menubar", menus[0..], &st.menu_open, .{})) |pick| {
        st.last_pick = @intCast(pick.menu * 100 + pick.item);
    }

    zzui.extras.muted(ui, "Toolbar");
    zzui.chrome.toolbarBegin(ui, .{});
    if (zzui.chrome.toolbarButton(ui, "New")) st.last_pick = 900;
    if (zzui.chrome.toolbarButton(ui, "Open")) st.last_pick = 901;
    if (zzui.chrome.toolbarButton(ui, "Save")) st.last_pick = 902;
    zzui.chrome.toolbarSeparator(ui);
    if (zzui.chrome.toolbarButton(ui, "Undo")) st.last_pick = 903;
    if (zzui.chrome.toolbarButton(ui, "Redo")) st.last_pick = 904;
    zzui.chrome.toolbarSpacer(ui, 24);
    if (zzui.chrome.toolbarButton(ui, "Run")) st.last_pick = 905;
    zzui.chrome.toolbarEnd(ui);

    zzui.extras.muted(ui, "Document tabs");
    const tabs = [_]zzui.chrome.DocTab{
        .{ .label = "main.zig" },
        .{ .label = "core.zig", .dirty = true },
        .{ .label = "README.md" },
    };
    _ = zzui.chrome.docTabs(ui, "doctabs", tabs[0..], &st.doc_tab, .{});

    zzui.extras.muted(ui, "Status bar");
    const left = [_]zzui.chrome.StatusItem{ .{ .label = "Ready" }, .{ .label = "main.zig" } };
    const right = [_]zzui.chrome.StatusItem{
        .{ .label = "UTF-8" },
        .{ .label = "Ln 12, Col 4" },
        .{ .label = "Zig 0.17", .kind = .accent, .clickable = true },
    };
    if (zzui.chrome.statusBar(ui, "statusbar", left[0..], right[0..], .{})) |pick| {
        st.last_pick = @intCast(1000 + pick.index);
    }

    zzui.extras.muted(ui, "Last action");
    zzui.widgets.textInt(ui, "action id = ", st.last_pick, "");
}

// ------------------------------------------------------------------ 页面装配

fn build(ui: *zzui.core.Context, st: *State) void {
    var col = ui.column(.{ .pad = 24, .gap = 14 });
    defer col.end();

    zzui.widgets.heading(ui, "Component gallery", 2);
    zzui.widgets.secondary(ui, "59 components across seven families. Switch pages with the tabs.");
    zzui.controls.tabs(ui, "gallery-pages", page_names[0..], &st.page);

    var body = ui.scroll(.{ .id = "gallery-body", .height = ui.height - 190, .gap = 14 });
    defer body.end();

    switch (st.page) {
        0 => pageComponents(ui),
        1 => pageForms(ui, st),
        2 => pageData(ui, st),
        3 => pageCharts(ui, st),
        else => pageShell(ui, st),
    }
}

/// 浮层（菜单/浮框/命令面板/提示条）必须在页面内容之后构建。
fn buildOverlays(ui: *zzui.core.Context, st: *State) void {
    _ = zzui.overlay.selectPopup(ui, "fruit", st.select_anchor, &.{ "Apple", "Banana", "Cherry" }, &st.select_idx, &st.select_open, .{});
    if (zzui.overlay.popoverBegin(ui, "pop", st.popover_anchor, &st.popover_open, .{ .width = 220 })) {
        zzui.widgets.heading(ui, "Popover", 3);
        zzui.extras.muted(ui, "Anchored to the button, closes on outside click.");
        if (zzui.widgets.button(ui, "Got it", .{ .variant = .primary })) st.popover_open = false;
        zzui.overlay.popoverEnd(ui);
    }
    _ = zzui.overlay.commandPalette(ui, "pal", st.pal_query[0..], &st.pal_len, &st.pal_caret, &.{
        "Build project",
        "Run tests",
        "Open settings",
        "Toggle theme",
        "Reload window",
        "Show logs",
    }, &st.pal_open, .{});
    _ = zzui.overlay.contextMenu(ui, "ctx", &.{
        .{ .label = "Copy" },
        .{ .label = "Paste" },
        .{ .label = "Delete" },
    }, &st.ctx_open, st.ctx_at);
    _ = zzui.overlay.toast(ui, "toast", "Saved to disk", &st.toast_open, &st.toast_since, .{ .kind = .success, .ttl = 0 });
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--once")) return runOnce();
    if (hasFlag(cmdline, "--shot-4")) return runShot(4);
    if (hasFlag(cmdline, "--shot-3")) return runShot(3);
    if (hasFlag(cmdline, "--shot-2")) return runShot(2);
    if (hasFlag(cmdline, "--shot-1")) return runShot(1);
    if (hasFlag(cmdline, "--shot")) return runShot(0);

    var st = State{};
    var app = zzui.App.init(.{ .title = "ZZUI gallery", .width = 720, .height = 1000 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        buildOverlays(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(720, 1000) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    build(&app.ui, &st);
    buildOverlays(&app.ui, &st);
    app.end();
    // 容量溢出会让控件「莫名少画」：直接以失败码带出，回归能发现
    if (app.ui.overflowed) return 8;
    zzui.bmpfile.saveBmp("zzui-gallery.bmp", app.backend.pixels(), 720, 1000) catch return 4;
    return 0;
}

/// 输出文件名：`zzui-gallery-p<N>.bmp`（手工拼，避免引入 fmt）。
fn shotName(buf: []u8, page: usize) []const u8 {
    const prefix = "zzui-gallery-p";
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '0' + @as(u8, @intCast(@min(page, 9)));
    @memcpy(buf[prefix.len + 1 .. prefix.len + 5], ".bmp");
    return buf[0 .. prefix.len + 5];
}

/// 隐藏窗口真渲染（含系统字体文本）第 `page` 页。
fn runShot(page: usize) i32 {
    var app = zzui.App.init(.{ .title = "ZZUI gallery shot", .width = 720, .height = 1000, .show = false }) catch return 5;
    defer app.deinit();
    if (!app.next()) return 6;
    var st = State{ .page = page };
    build(&app.ui, &st);
    buildOverlays(&app.ui, &st);
    app.end();
    if (app.ui.overflowed) return 8;

    var name_buf: [24]u8 = @splat(0);
    app.saveSurface(shotName(&name_buf, page)) catch return 7;
    return 0;
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
