//! 控件画廊：分 5 页展示全部 59 个控件的实际外观。
//! 正常启动开窗口（点页签切换）；`--once` 无窗口渲染当前页；`--shot-N` 用隐藏窗口真渲染第 N 页。
//!
//! **分页不是为了好看**：一页塞满全部控件会超过 `MAX_NODES`（256），
//! 而把容量扩到 512 会让产物多 79 KB（`Context` 变大直接换体积），所以按页分摊。
const std = @import("std");
const zzui = @import("zzui");

const page_names = [_][]const u8{ "Components", "Forms", "Data", "Charts", "Shell", "Feedback", "Dials", "Calendar", "Viz", "Viz B", "Curves", "Grid", "Dock" };

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

    // ---- 反馈页（披露族 + 操作件族）
    banner_open: bool = true,
    cp_open: bool = false,
    cp_anchor: zzui.types.Rect = .{},
    step_done: [3]bool = @splat(false),
    et_expanded: bool = false,
    ec_open: bool = false,
    conf_armed: bool = false,
    conf_since: f64 = 0,
    ie_editing: bool = false,
    ie_caret: usize = 4,
    ie_buf: [32]u8 = @splat(0),
    ie_len: usize = 4,
    scrub_state: zzui.actions.ScrubState = .{},
    scrub_v: f32 = 42,
    rec_combo: zzui.actions.KeyCombo = .{},
    money_state: zzui.actions.MoneyState = .{},
    money_v: f64 = 1299.5,
    react_a: bool = true,
    react_a_n: u32 = 4,
    react_b: bool = false,
    react_b_n: u32 = 1,

    // ---- 工具页（旋钮族 / 代码呈现族 / 月历族 / 时间线族）
    knob_state: zzui.dials.KnobState = .{},
    knob_v: f32 = 40,
    fader_state: zzui.dials.FaderState = .{},
    fader_v: f32 = 0.65,
    meter_state: zzui.dials.LevelMeterState = .{},
    json_state: zzui.codeview.JsonState = .{},
    hex_sel: zzui.codeview.HexSelection = .{},
    cal_month: zzui.month.Date = .{ .year = 2026, .month = 11, .day = 1 },
    cal_sel: zzui.month.Date = .{ .year = 2026, .month = 11, .day = 10 },
    tl_state: zzui.timeline.TimelineState = .{},
    playhead: f32 = 2,
    tl_time: [3]f32 = .{ 1, 3, 5 },
    tl_sel: [3]bool = .{ false, false, false },

    // ---- 可视化页
    viz_pick: i32 = -1,

    // ---- 曲线页
    curve_state: zzui.curves.CurveState = .{},
    curve_count: usize = 3,
    curve_keys: [6]zzui.curves.CurveKey = .{
        .{ .x = 0, .y = 0, .mode = .free, .out_dx = 0.2, .out_dy = 0.1 },
        .{ .x = 0.5, .y = 0.7, .mode = .free, .in_dx = -0.15, .in_dy = 0, .out_dx = 0.15, .out_dy = 0 },
        .{ .x = 1, .y = 1, .mode = .free, .in_dx = -0.2, .in_dy = -0.1 },
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
    },
    grad_state: zzui.curves.GradientState = .{},
    grad_count: usize = 3,
    grad_stops: [6]zzui.curves.GradientStop = .{
        .{ .t = 0, .color = zzui.types.Color.hex(0x2563EB, 255) },
        .{ .t = 0.5, .color = zzui.types.Color.hex(0x0891B2, 255) },
        .{ .t = 1, .color = zzui.types.Color.hex(0xFDE68A, 255) },
        .{ .t = 0, .color = zzui.types.Color.transparent },
        .{ .t = 0, .color = zzui.types.Color.transparent },
        .{ .t = 0, .color = zzui.types.Color.transparent },
    },

    // ---- 网格页
    grid_sel: [4]bool = .{ false, true, false, false },
    grid_state: zzui.grid.GridState = .{},
    grid_sort: zzui.grid.GridSort = .{},
    grid_bufs: [4][32]u8 = .{
        .{ 'a', 'l', 'p', 'h', 'a' } ++ @as([27]u8, @splat(0)),
        .{ 'b', 'e', 't', 'a' } ++ @as([28]u8, @splat(0)),
        .{ 'g', 'a', 'm', 'm', 'a' } ++ @as([27]u8, @splat(0)),
        .{ 'd', 'e', 'l', 't', 'a' } ++ @as([27]u8, @splat(0)),
    },
    grid_lens: [4]usize = .{ 5, 4, 5, 5 },
    tree_nodes: [6]zzui.grid.TreeNode = .{
        .{ .parent = -1, .first_child = 1, .next_sibling = 5, .flags = zzui.grid.TreeFlag.expanded },
        .{ .parent = 0, .first_child = 2, .next_sibling = -1 },
        .{ .parent = 1, .first_child = -1, .next_sibling = 3 },
        .{ .parent = 1, .first_child = -1, .next_sibling = 4 },
        .{ .parent = 1, .first_child = -1, .next_sibling = -1 },
        .{ .parent = -1, .first_child = -1, .next_sibling = -1 },
    },
    tree_state: zzui.grid.TreeTableState = .{},
    path_state: zzui.grid.PathBarState = .{},
    filter_sel: [1]u32 = .{1},
    filter_search: [32]u8 = @splat(0),
    filter_state: zzui.grid.FilterBarState = .{},

    // ---- 停靠页（程序坞 + 面板停靠）
    dock_state: zzui.dock.DockState = .{},
    dock_opened: ?usize = null,
    ds_state: zzui.dockspace.DockspaceState = .{},
    ds_open: [4]bool = .{ true, true, true, true },
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
        zzui.extras.timelineItem(ui, "08:40", "Tests passed", "100 cases, 0 failures");
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

// ------------------------------------------------------------------ 页 5：反馈（披露族 + 操作件族）

fn pageFeedback(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Banner");
    _ = zzui.disclosure.banner(ui, "banner", "Scheduled maintenance tonight 22:00-23:00 UTC.", &st.banner_open, .{ .tone = .warn, .action = "Details" });

    zzui.extras.muted(ui, "Countdown");
    {
        var row = ui.row(.{ .gap = 6 });
        defer row.end();
        zzui.disclosure.countdown(ui, "countdown", 90061, .{});
    }

    zzui.extras.muted(ui, "Onboarding checklist");
    {
        const titles = [_][]const u8{ "Create a project", "Invite a teammate", "Connect a repository" };
        const descs = [_][]const u8{ "Start from a template or an empty folder.", "", "Optional: link GitHub for PR previews." };
        var steps = [_]zzui.disclosure.CheckStep{
            .{ .title = titles[0], .description = descs[0], .action = "Start", .done = st.step_done[0] },
            .{ .title = titles[1], .description = descs[1], .done = st.step_done[1] },
            .{ .title = titles[2], .description = descs[2], .done = st.step_done[2] },
        };
        if (zzui.disclosure.checklist(ui, "checklist", steps[0..], .{ .title = "Getting started", .description = "Three steps to your first build" })) |idx| {
            st.last_pick = @intCast(2000 + idx);
        }
        var i: usize = 0;
        while (i < 3) : (i += 1) st.step_done[i] = steps[i].done;
    }

    zzui.extras.muted(ui, "Expandable text");
    {
        var et = zzui.disclosure.ExpandableTextState{ .expanded = st.et_expanded };
        zzui.disclosure.expandableText(ui, "etext", "ZZUI keeps every widget in caller-owned state: the framework stores no tree, no event queue and no animation cache. That is why a build is under 100 functions per family and the shipped binary stays small.", &et, .{ .lines = 2 });
        st.et_expanded = et.expanded;
    }

    zzui.extras.muted(ui, "Expandable card");
    {
        var ec = zzui.disclosure.ExpandableCardState{ .open = st.ec_open };
        if (zzui.disclosure.expandableCardBegin(ui, "ecard", "Advanced options", &ec, .{ .description = "Shown when collapsed", .badge = "beta", .badge_tone = .accent })) {
            zzui.widgets.text(ui, "Body content appears only while the card is open.");
            _ = zzui.widgets.button(ui, "Apply", .{ .variant = .primary });
        }
        zzui.disclosure.expandableCardEnd(ui);
        st.ec_open = ec.open;
    }

    zzui.extras.muted(ui, "Confirm popover");
    {
        const br = zzui.widgets.buttonEx(ui, "Archive project", .{});
        if (br.clicked) st.cp_open = !st.cp_open;
        st.cp_anchor = br.rect;
        switch (zzui.disclosure.confirmPopover(ui, "cp", st.cp_anchor, &st.cp_open, .{
            .title = "Archive this project?",
            .description = "It can be restored for 30 days.",
            .confirm_label = "Archive",
        })) {
            .confirmed => st.last_pick = 2100,
            .canceled, .dismissed => st.last_pick = 2101,
            .none => {},
        }
    }

    zzui.extras.muted(ui, "Confirm button (needs two clicks)");
    {
        var cs = zzui.actions.ConfirmState{ .armed = st.conf_armed, .since = st.conf_since };
        if (zzui.actions.confirmButton(ui, "Delete project", &cs, .{ .confirm_label = "Click again to delete" })) {
            st.last_pick = 2200;
        }
        st.conf_armed = cs.armed;
        st.conf_since = cs.since;
    }

    zzui.extras.muted(ui, "Inline edit");
    {
        if (st.ie_len == 0) {
            @memcpy(st.ie_buf[0..4], "name");
            st.ie_len = 4;
        }
        var ies = zzui.actions.InlineEditState{ .editing = st.ie_editing, .caret = st.ie_caret };
        const r = zzui.actions.inlineEdit(ui, "inline-edit", &st.ie_buf, &st.ie_len, &ies, .{});
        if (r.committed) st.last_pick = 2300;
        st.ie_editing = ies.editing;
        st.ie_caret = ies.caret;
    }

    zzui.extras.muted(ui, "Scrub field (drag sideways)");
    _ = zzui.actions.scrub(ui, "Opacity", &st.scrub_v, 0, 100, &st.scrub_state, .{ .suffix = "%", .decimals = 0 });

    zzui.extras.muted(ui, "Money input");
    _ = zzui.actions.moneyInput(ui, "money", &st.money_v, &st.money_state, .{ .label = "Amount", .symbol = "$", .hint = "USD" });

    zzui.extras.muted(ui, "Shortcut recorder");
    _ = zzui.actions.shortcutRecorder(ui, "recorder", &st.rec_combo, .{ .width = 220 });

    zzui.extras.muted(ui, "Reactions");
    {
        var items = [_]zzui.actions.Reaction{
            .{ .icon = "+1", .count = st.react_a_n, .active = st.react_a },
            .{ .icon = "heart", .count = st.react_b_n, .active = st.react_b },
        };
        _ = zzui.actions.reactions(ui, "rx", items[0..]);
        st.react_a = items[0].active;
        st.react_a_n = items[0].count;
        st.react_b = items[1].active;
        st.react_b_n = items[1].count;
    }
}

// ------------------------------------------------------------------ 页 6：工具（旋钮 / 代码 / 月历 / 时间线）

fn pageTools(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Knob / fader / level meter");
    {
        var row = ui.row(.{ .gap = 20 });
        defer row.end();
        _ = zzui.dials.knob(ui, "gain", &st.knob_v, 0, 100, &st.knob_state, .{ .label = "Gain", .unit = "%", .step = 1 });
        const ticks = [_]f32{ 0, 0.5, 1 };
        _ = zzui.dials.fader(ui, "level", &st.fader_v, 0, 1, &st.fader_state, .{ .length = 90, .label = "Level", .ticks = ticks[0..] });
        const levels = [_]f32{ 0.72, 0.31 };
        zzui.dials.levelMeter(ui, "meter", levels[0..], &st.meter_state, .{ .length = 90, .segmented = true });
    }

    zzui.extras.muted(ui, "Code block");
    zzui.codeview.codeBlock(ui, "code", "pub fn main() !void {\n    var ui = Context{};\n    ui.begin(720, 480);\n    _ = widgets.button(&ui, \"Run\", .{});\n}", .{
        .title = "main.zig",
        .lang = "zig",
        .highlight_from = 3,
        .highlight_to = 3,
    });

    zzui.extras.muted(ui, "JSON view (click a triangle)");
    _ = zzui.codeview.jsonView(ui, "json", "{\"name\":\"zzui\",\"version\":\"0.1.0\",\"tags\":[\"ui\",\"zig\",\"small\"],\"nested\":{\"depth\":2}}", &st.json_state, .{});

    zzui.extras.muted(ui, "Hex view");
    _ = zzui.codeview.hexView(ui, "hex", "ZZUI hex view sample: 16 bytes per row, ASCII on the right.", &st.hex_sel, .{ .height = 96 });
}

// ------------------------------------------------------------------ 页 7：月历与时间线

fn pageCalendar(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Month calendar");
    {
        const events = [_]zzui.month.MonthEvent{
            .{ .title = "Release", .start = .{ .year = 2026, .month = 11, .day = 10 }, .tone = .accent },
            .{ .title = "Review", .start = .{ .year = 2026, .month = 11, .day = 18 }, .tone = .warn },
        };
        _ = zzui.month.monthCalendar(ui, "cal", &st.cal_month, events[0..], .{
            .selected = &st.cal_sel,
            .cell_height = 48,
            .today = .{ .year = 2026, .month = 11, .day = 10 },
        });
    }

    zzui.extras.muted(ui, "Timeline editor");
    {
        var keys = [_]zzui.timeline.TimelineKey{
            .{ .time = st.tl_time[0], .selected = st.tl_sel[0] },
            .{ .time = st.tl_time[1], .selected = st.tl_sel[1] },
            .{ .time = st.tl_time[2], .selected = st.tl_sel[2] },
        };
        var tracks = [_]zzui.timeline.TimelineTrack{.{ .name = "Position", .keys = keys[0..] }};
        _ = zzui.timeline.timelineEditor(ui, "timeline", tracks[0..], &st.playhead, &st.tl_state, .{ .height = 110, .time_max = 8 });
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            st.tl_time[i] = keys[i].time;
            st.tl_sel[i] = keys[i].selected;
        }
    }
}

// ------------------------------------------------------------------ 页 8：可视化（网格与条形）

fn pageViz(ui: *zzui.core.Context, st: *State) void {
    const items = [_]zzui.viz.VizItem{
        .{ .label = "Search", .value = 48 },
        .{ .label = "Direct", .value = 31 },
        .{ .label = "Social", .value = 21 },
    };
    const values = [_]f32{ 2, 5, 9, 4, 7, 1, 8, 3, 6, 5, 9, 2 };
    const hours = [_][]const u8{ "00", "04", "08", "12", "16", "20" };
    const days = [_][]const u8{ "Mon", "Tue" };

    zzui.extras.muted(ui, "Heatmap (click a cell)");
    if (zzui.viz.heatmap(ui, "hm", values[0..], 2, 6, .{ .row_labels = days[0..], .col_labels = hours[0..2].*[0..], .cell = 30 })) |idx| {
        st.viz_pick = @intCast(idx);
    }

    zzui.extras.muted(ui, "Calendar heatmap");
    _ = zzui.viz.calendarHeatmap(ui, "chm", .{ .year = 2026, .month = 11, .day = 2 }, values[0..], .{ .cell = 14 });

    zzui.extras.muted(ui, "Treemap / funnel");
    {
        var row = ui.row(.{ .gap = 16 });
        defer row.end();
        _ = zzui.viz.treemap(ui, "tm", items[0..], .{ .width = 240, .height = 110 });
        _ = zzui.viz.funnel(ui, "fn", items[0..], .{ .width = 240, .height = 110 });
    }

    zzui.extras.muted(ui, "Split bar");
    _ = zzui.viz.splitBar(ui, "sb", items[0..], .{});

    zzui.extras.muted(ui, "Bar list");
    _ = zzui.viz.barList(ui, "bl", items[0..], .{ .max_rows = 3 });

    zzui.extras.muted(ui, "Waffle");
    _ = zzui.viz.waffle(ui, "wf", items[0..], .{ .cell = 12 });

    zzui.widgets.textInt(ui, "last pick = ", @intCast(if (st.viz_pick < 0) 0 else st.viz_pick), "");
}

// ------------------------------------------------------------------ 页 9：可视化（形状与趋势）

fn pageVizB(ui: *zzui.core.Context, st: *State) void {
    _ = st;
    const axes = [_][]const u8{ "speed", "power", "range", "cost", "size" };
    const a_vals = [_]f32{ 4, 3, 5, 2, 4 };
    const b_vals = [_]f32{ 2, 5, 3, 4, 2 };
    const series = [_]zzui.viz.Series{
        .{ .name = "model A", .values = a_vals[0..] },
        .{ .name = "model B", .values = b_vals[0..] },
    };
    const pts = [_]zzui.viz.Vec2{ .{ .x = 1, .y = 2 }, .{ .x = 2.5, .y = 4 }, .{ .x = 4, .y = 3 }, .{ .x = 5, .y = 6 } };
    const pts2 = [_]zzui.viz.Vec2{ .{ .x = 1.5, .y = 1 }, .{ .x = 3, .y = 2.5 }, .{ .x = 4.5, .y = 5 } };
    const sizes = [_]f32{ 1, 3, 2, 4 };
    const sseries = [_]zzui.viz.ScatterSeries{
        .{ .name = "run 1", .points = pts[0..], .sizes = sizes[0..] },
        .{ .name = "run 2", .points = pts2[0..] },
    };
    const nodes = [_][]const u8{ "visits", "signups", "paid" };
    const links = [_]zzui.viz.SankeyLink{
        .{ .from = 0, .to = 1, .value = 40 },
        .{ .from = 1, .to = 2, .value = 12 },
    };
    const rings = [_]zzui.viz.VizItem{
        .{ .label = "move", .value = 0.82 },
        .{ .label = "exercise", .value = 0.55 },
        .{ .label = "stand", .value = 0.95 },
    };
    const candles = [_]zzui.viz.Candle{
        .{ .open = 100, .high = 106, .low = 98, .close = 104, .volume = 120 },
        .{ .open = 104, .high = 108, .low = 101, .close = 102, .volume = 90 },
        .{ .open = 102, .high = 105, .low = 97, .close = 99, .volume = 140 },
        .{ .open = 99, .high = 103, .low = 96, .close = 102, .volume = 110 },
        .{ .open = 102, .high = 110, .low = 101, .close = 108, .volume = 160 },
    };

    zzui.extras.muted(ui, "Radar chart");
    zzui.viz.radarChart(ui, "rd", series[0..], axes[0..], .{ .size = 200 });

    zzui.extras.muted(ui, "Scatter / bubble");
    zzui.viz.scatterChart(ui, "sc", sseries[0..], .{ .height = 150, .x_label = "x", .y_label = "y" });

    zzui.extras.muted(ui, "Rings / gauge / sankey");
    {
        var row = ui.row(.{ .gap = 20 });
        defer row.end();
        zzui.viz.activityRings(ui, "ar", rings[0..], .{ .size = 110, .center = "0.82", .caption = "move", .legend = true });
        zzui.viz.radialGauge(ui, "rg", 72, 0, 100, .{ .label = "load", .unit = "%", .size = 130, .target = 80, .show_target = true });
        zzui.viz.sankey(ui, "sk", nodes[0..], links[0..], .{ .width = 240, .height = 120 });
    }

    zzui.extras.muted(ui, "Candlestick");
    _ = zzui.viz.candlestick(ui, "cd", candles[0..], .{ .height = 170 });
}

// ------------------------------------------------------------------ 页 10：曲线与渐变

fn pageCurves(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Curve editor (drag keys, Shift+click adds, Alt+click toggles bezier)");
    _ = zzui.curves.curveEditor(ui, "cv", st.curve_keys[0..], &st.curve_count, &st.curve_state, .{ .height = 200, .x_label = "Time", .y_label = "Value" });

    zzui.extras.muted(ui, "Gradient editor (drag stops, Shift+click adds)");
    _ = zzui.curves.gradientEditor(ui, "gr", st.grad_stops[0..], &st.grad_count, &st.grad_state, .{ .width = 260 });

    zzui.extras.muted(ui, "Sampled value");
    {
        const y = zzui.curves.curveEval(st.curve_keys[0..st.curve_count], 0.25);
        var buf: [24]u8 = undefined;
        const txt = zzui.num.fixed(&buf, y, 3);
        _ = zzui.widgets.text(ui, txt);
    }
}

// ------------------------------------------------------------------ 页 11：数据网格 / 树表 / 面包屑 / 筛选条

const grid_cols = [_]zzui.grid.GridColumn{
    .{ .title = "Name", .width = 160, .sortable = true },
    .{ .title = "Kind", .width = 0 },
    .{ .title = "Size", .width = 90, .text_align = .end, .sortable = true },
    .{ .title = "Owner", .width = 120, .priority = 1 },
};

const grid_rows = [_][3][]const u8{
    .{ "alpha", "file", "12 KB" },
    .{ "beta", "folder", "--" },
    .{ "gamma", "file", "4 MB" },
    .{ "delta", "link", "512 B" },
};

fn treeLabel2(_: []const zzui.grid.TreeNode, i: usize) []const u8 {
    return switch (i) {
        0 => "src",
        1 => "widgets",
        2 => "button.zig",
        3 => "input.zig",
        4 => "slider.zig",
        5 => "README.md",
        else => "?",
    };
}

fn pageGrid(ui: *zzui.core.Context, st: *State) void {
    const segments = [_][]const u8{ "root", "src", "widgets" };

    zzui.extras.muted(ui, "Path bar (click a segment; click the last one or empty space to type)");
    _ = zzui.grid.pathBar(ui, "pb", segments[0..], &st.path_state, .{ .icon = ">" });

    zzui.extras.muted(ui, "Filter bar");
    const opt_status = [_][]const u8{ "open", "closed" };
    const fields = [_]zzui.grid.FilterField{.{ .name = "Status", .options = opt_status[0..] }};
    _ = zzui.grid.filterBar(ui, "fb", fields[0..], st.filter_sel[0..], &st.filter_search, &st.filter_state, 620);

    zzui.extras.muted(ui, "Data grid (drag column edges, Shift+click a cell to edit, Ctrl/Shift click rows)");
    if (zzui.grid.dataGridBegin(ui, "dg", grid_cols[0..], grid_rows.len, st.grid_sel[0..], &st.grid_state, .{
        .checkboxes = true,
        .sort = &st.grid_sort,
        .height = 200,
    })) {
        for (grid_rows, 0..) |row_data, i| {
            if (zzui.grid.dataGridRow(ui, i)) |row| {
                const cell0 = row.cell(0);
                if (st.grid_state.editing_row == @as(i32, @intCast(i)) and st.grid_state.editing_col == 0) {
                    _ = row.edit(0, &st.grid_bufs[i], &st.grid_lens[i]);
                } else {
                    row.text(0, st.grid_bufs[i][0..st.grid_lens[i]], zzui.theme.text);
                    // 给可编辑单元格留出命中区（Shift+点击进入编辑）
                    _ = row.edit(0, &st.grid_bufs[i], &st.grid_lens[i]);
                }
                row.text(1, row_data[1], zzui.theme.secondary);
                row.text(2, row_data[2], zzui.theme.secondary);
                row.text(3, "ops", zzui.theme.secondary);
                _ = cell0;
            }
        }
        zzui.grid.dataGridEnd(ui);
    }

    zzui.extras.muted(ui, "Tree table (click a triangle to expand)");
    if (zzui.grid.treeTableBegin(ui, "tt", grid_cols[0..], st.tree_nodes[0..], &st.tree_state, .{
        .labelFn = treeLabel2,
        .height = 180,
    })) {
        while (zzui.grid.treeTableRow(ui, &st.tree_state)) |ni| {
            _ = ni;
        }
        zzui.grid.treeTableEnd(ui);
    }

    zzui.extras.muted(ui, "Selected rows");
    var count: u32 = 0;
    for (st.grid_sel) |v| {
        if (v) count += 1;
    }
    zzui.widgets.textInt(ui, "selected = ", count, "");
}

// ------------------------------------------------------------------ 页 12：停靠

fn pageDock(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Dock (hover magnifies the icon, click opens the app, badge + running dot)");
    zzui.dock.dockBegin(ui, "gal-dock", &st.dock_state, .{ .size = 44, .magnify = 1.35 });
    if (zzui.dock.dockItem(ui, "gal-dock", "F", "Finder", .{})) st.dock_opened = 0;
    if (zzui.dock.dockItem(ui, "gal-dock", "T", "Terminal", .{ .running = true })) st.dock_opened = 1;
    if (zzui.dock.dockItem(ui, "gal-dock", "M", "Mail", .{ .badge = 7 })) st.dock_opened = 2;
    zzui.dock.dockSeparator(ui);
    if (zzui.dock.dockItem(ui, "gal-dock", "X", "Trash", .{})) st.dock_opened = 3;
    zzui.dock.dockEnd(ui);
    if (st.dock_opened) |i| zzui.widgets.textInt(ui, "last opened = icon ", @intCast(i), "");

    zzui.extras.muted(ui, "Dockspace (drag the splitters, click tabs, close with the tab x)");
    zzui.dockspace.begin(ui, "gal-ds", &st.ds_state, .{ .height = 360, .min_w = 120, .min_h = 80 });
    if (zzui.dockspace.panelBegin(ui, &st.ds_state, "Scene", &st.ds_open[0])) {
        zzui.widgets.heading(ui, "Scene tree", 3);
        zzui.widgets.text(ui, "- World");
        zzui.widgets.text(ui, "  - Main Camera");
        zzui.widgets.text(ui, "  - Directional Light");
        zzui.dockspace.panelEnd(ui);
    }
    if (zzui.dockspace.panelBegin(ui, &st.ds_state, "Viewport", &st.ds_open[1])) {
        zzui.widgets.heading(ui, "Viewport", 3);
        zzui.extras.muted(ui, "Tab strip above switches panels; drag the splitter on the edge.");
        zzui.extras.meter(ui, "GPU frame 13.9 ms", 0.72);
        zzui.dockspace.panelEnd(ui);
    }
    if (zzui.dockspace.panelBegin(ui, &st.ds_state, "Console", &st.ds_open[2])) {
        zzui.widgets.heading(ui, "Console", 3);
        zzui.extras.muted(ui, "> zig build");
        zzui.extras.muted(ui, "> build succeeded in 3.4s");
        zzui.dockspace.panelEnd(ui);
    }
    if (zzui.dockspace.panelBegin(ui, &st.ds_state, "Inspector", &st.ds_open[3])) {
        zzui.widgets.heading(ui, "Inspector", 3);
        zzui.widgets.checkbox(ui, "Visible", &st.chip_a);
        zzui.widgets.separator(ui);
        zzui.widgets.slider(ui, "Opacity", &st.hi, 0, 300);
        zzui.dockspace.panelEnd(ui);
    }
    var layout_buf: [256]u8 = @splat(0);
    const ln = zzui.dockspace.save(&st.ds_state, &layout_buf);
    zzui.extras.muted(ui, "saved layout:");
    zzui.extras.code(ui, ui.frameStr(layout_buf[0..ln]));
    zzui.dockspace.end(ui);
}

// ------------------------------------------------------------------ 页面装配

fn build(ui: *zzui.core.Context, st: *State) void {
    var col = ui.column(.{ .pad = 24, .gap = 14 });
    defer col.end();

    zzui.widgets.heading(ui, "Component gallery", 2);
    zzui.widgets.secondary(ui, "113 components across fourteen families. Switch pages with the tabs.");
    zzui.controls.tabs(ui, "gallery-pages", page_names[0..], &st.page);

    var body = ui.scroll(.{ .id = "gallery-body", .height = ui.height - 190, .gap = 14 });
    defer body.end();

    switch (st.page) {
        0 => pageComponents(ui),
        1 => pageForms(ui, st),
        2 => pageData(ui, st),
        3 => pageCharts(ui, st),
        4 => pageShell(ui, st),
        5 => pageFeedback(ui, st),
        6 => pageTools(ui, st),
        7 => pageCalendar(ui, st),
        8 => pageViz(ui, st),
        9 => pageVizB(ui, st),
        10 => pageCurves(ui, st),
        11 => pageGrid(ui, st),
        else => pageDock(ui, st),
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
    if (hasFlag(cmdline, "--shot-12")) return runShot(12);
    if (hasFlag(cmdline, "--shot-11")) return runShot(11);
    if (hasFlag(cmdline, "--shot-10")) return runShot(10);
    if (hasFlag(cmdline, "--shot-9")) return runShot(9);
    if (hasFlag(cmdline, "--shot-8")) return runShot(8);
    if (hasFlag(cmdline, "--shot-7")) return runShot(7);
    if (hasFlag(cmdline, "--shot-6")) return runShot(6);
    if (hasFlag(cmdline, "--shot-5")) return runShot(5);
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

/// 输出文件名：`zzui-gallery-p<N>.bmp`（手工拼，避免引入 fmt；支持两位数页码）。
fn shotName(buf: []u8, page: usize) []const u8 {
    const prefix = "zzui-gallery-p";
    @memcpy(buf[0..prefix.len], prefix);
    var n: usize = prefix.len;
    if (page >= 10) {
        buf[n] = '0' + @as(u8, @intCast(page / 10));
        n += 1;
    }
    buf[n] = '0' + @as(u8, @intCast(page % 10));
    n += 1;
    @memcpy(buf[n .. n + 4], ".bmp");
    n += 4;
    return buf[0..n];
}

/// 隐藏窗口真渲染（含系统字体文本）第 `page` 页。
fn runShot(page: usize) i32 {
    var app = zzui.App.init(.{ .title = "ZZUI gallery shot", .width = 720, .height = 1000, .show = false }) catch return 5;
    defer app.deinit();
    if (!app.next()) return 6;
    var st = State{ .page = page };
    // 第一帧还在用估算宽度（字体尚未挂上），排版会偏；第二帧用真实测量才准。
    build(&app.ui, &st);
    buildOverlays(&app.ui, &st);
    app.end();
    if (!app.next()) return 6;
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
