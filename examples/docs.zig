//! 文档、可视化与规划族示例：markdown / diff / 火焰图 / 追踪 / 编辑器 / 看板·周历·甘特（九页）。
//! 单独一个产物是为了**体积分账**：几族代码约 34 KB，塞进 gallery 会把那个产物顶穿
//! 335 KB 门槛（实测 gallery 13 页 334,336 B 时再挂 markdown + diff → 366,080 B）。
//!
//! `--once` 无窗口渲染第 0 页；`--shot-0` / `--shot-1` / `--shot-2` 用隐藏窗口真渲染对应页。
const std = @import("std");
const zzui = @import("zzui");

const page_names = [_][]const u8{ "Markdown", "Diff", "Flame", "Tour", "Regex", "Files", "Trace", "Editor", "Planning", "Terminal", "Social", "Graph", "Nodes", "Emoji", "AI", "Dev", "Panels", "Client" };

const notes_md =
    "# Release 2.4\n" ++
    "\n" ++
    "Renders **native content** every frame, *no copy kept*. Lists, tasks and code blocks work too.\n" ++
    "\n" ++
    "- [x] Tag the release\n" ++
    "- [ ] Publish the notes\n" ++
    "- Nested list:\n" ++
    "  - `inline code`\n" ++
    "  - ~~struck~~ text and a [link](https://example.com/notes)\n" ++
    "\n" ++
    "```zig\nconst MarkdownResult = struct { link: ?[]const u8 };\n```\n" ++
    "\n" ++
    "| key | value |\n" ++
    "|-----|-------|\n" ++
    "| size | 12 |\n" ++
    "| mode | dark |\n" ++
    "\n" ++
    "> Quoted text keeps a rule on the left.\n" ++
    "\n" ++
    "---\n" ++
    "\n" ++
    "Last paragraph after the rule.\n";

const diff_old =
    "fn main() void {\n" ++
    "    const x = 1;\n" ++
    "    const y = 2;\n" ++
    "    print(x + y);\n" ++
    "}\n" ++
    "\n" ++
    "fn helper() void {\n" ++
    "    return;\n" ++
    "}\n" ++
    "\n" ++
    "fn tail() void {}\n";

const diff_new =
    "fn main() void {\n" ++
    "    const x = 1;\n" ++
    "    const y = 40;\n" ++
    "    print(x + y);\n" ++
    "    print(\"done\");\n" ++
    "}\n" ++
    "\n" ++
    "fn helper() void {\n" ++
    "    return;\n" ++
    "}\n" ++
    "\n" ++
    "fn tail() void {}\n";

const State = struct {
    page: usize = 0,
    diff_current: i32 = -1,
    last_link: [128]u8 = @splat(0),
    last_link_len: usize = 0,
    tasks_toggled: u32 = 0,
    /// markdown 的文本是可写的：任务框切换直接改这份缓冲（`applyTask`）。
    notes: [notes_md.len]u8 = notes_md.*,
    flame_view: zzui.flame.View = .{},
    flame_selected: i32 = -1,
    /// 引导当前步骤（-1 = 未开始）。
    tour_step: i32 = -1,
    /// 正则测试器：模式与文本（调用方持有，可编辑）。
    re_pattern: [32]u8 = re_pat.* ++ @as([32 - re_pat.len]u8, @splat(0)),
    re_pattern_len: usize = re_pat.len,
    re_caret: usize = re_pat.len,
    re_text: [re_sample.len]u8 = re_sample.*,
    re_text_len: usize = re_sample.len,
    rt: zzui.regextester.TesterState = .{},
    /// 文件浏览器（真实目录：Win32 后端枚举，null 后端返回 -1）
    fb_path: zzui.files.Path = .{},
    fb: zzui.files.State = .{},
    picked: [128]u8 = @splat(0),
    picked_len: usize = 0,
    /// 追踪视图（时间轴 + 轨道）与网络瀑布
    tr_tracks: [3]zzui.trace.Track = .{ .{ .name = "main" }, .{ .name = "worker" }, .{ .name = "gc" } },
    tr_view: zzui.trace.View = .{},
    tr_sel: i32 = -1,
    tr_state: zzui.trace.State = .{},
    wf_sel: i32 = -1,
    /// 代码编辑器（文本由我们持有，组件就地编辑）
    ed_text: [editor_src.len]u8 = editor_src.*,
    ed_len: usize = editor_src.len,
    ed: zzui.editor.EditorState = .{},
    ed_status: [96]u8 = @splat(0),
    ed_status_len: usize = 0,
    /// 规划族：看板 / 周历 / 甘特（`plan_kind` 切换）
    plan_kind: usize = 0,
    kb: zzui.planning.Board = .{},
    kb_st: zzui.planning.KanbanState = .{},
    wk_st: zzui.planning.WeekState = .{},
    gt_st: zzui.planning.GanttState = .{},
    plan_last: [64]u8 = @splat(0),
    plan_last_len: usize = 0,
    /// 终端（输出缓冲由我们持有）
    term_text: [4096]u8 = undefined,
    term_lines: [128]zzui.terminal.Line = @splat(.{}),
    term_buf: zzui.terminal.Buffer = .{},
    term_st: zzui.terminal.State = .{},
    term_ready: bool = false,
    term_last: [64]u8 = @splat(0),
    term_last_len: usize = 0,
    /// 会话族（评论串 / 在线头像组 / 点赞状态）
    soc_comments: zzui.social.CommentState = .{},
    soc_pres: zzui.social.PresenceState = .{},
    soc_likes: [3]i32 = .{ 4, 1, 0 },
    soc_liked: [3]bool = .{ false, false, true },
    soc_last: [64]u8 = @splat(0),
    soc_last_len: usize = 0,
    /// 节点编辑器（节点位置与连线由我们持有，控件只画与报事件）
    nd_st: zzui.nodes.State = .{},
    nd_view: zzui.nodes.View = .{},
    nd_nodes: [nd_node_data.len]NdNode = nd_node_data,
    nd_links: [8]NdLink = .{
        .{ .id = 100, .from = 11, .to = 21 },
        .{ .id = 101, .from = 22, .to = 31 },
        .{ .id = 102, .from = 32, .to = 41 },
        .{ .id = 0, .from = 0, .to = 0 },
        .{ .id = 0, .from = 0, .to = 0 },
        .{ .id = 0, .from = 0, .to = 0 },
        .{ .id = 0, .from = 0, .to = 0 },
        .{ .id = 0, .from = 0, .to = 0 },
    },
    nd_link_n: usize = 3,
    nd_next_link: i32 = 200,
    nd_last: [72]u8 = @splat(0),
    nd_last_len: usize = 0,
    /// emoji 选择器（肤色与最近使用由我们持有）
    em_st: zzui.emoji.State = .{},
    em_tone: u8 = 0,
    em_recent: [96]u8 = @splat(0),
    em_recent_len: usize = 0,
    /// 图族：提交图（泳道）+ 依赖图（分层/缩放平移）
    gr_cs: zzui.graph.CommitState = .{},
    gr_ds: zzui.graph.DepState = .{},
    gr_topdown: bool = false,
    gr_last: [64]u8 = @splat(0),
    gr_last_len: usize = 0,
    /// AI 界面族（推理折叠 / 工具调用 / 计划 / 回复操作 / 模型 / 输入框 / 语音球）
    ai_rz: zzui.ai.ReasoningState = .{},
    ai_tc: [2]zzui.ai.ToolCallState = .{ .{}, .{} },
    ai_vote: i8 = 0,
    ai_mp: zzui.ai.ModelPickerState = .{},
    ai_model: usize = 0,
    ai_cmp: zzui.ai.ComposerState = .{},
    ai_voice: zzui.ai.VoiceState = .idle,
    ai_last: [80]u8 = @splat(0),
    ai_last_len: usize = 0,
    /// 开发者视图（覆盖率树 / blame 的跨帧状态，直方图选区由我们持有）
    dv_cov: zzui.devviews.CoverageState = .{},
    dv_bl: zzui.devviews.BlameState = .{},
    dv_sel0: f64 = 0,
    dv_sel1: f64 = 0,
    dv_last: [80]u8 = @splat(0),
    dv_last_len: usize = 0,
    /// 开发面板（键值对内容、问题面板状态、流水线选中）
    dt_kv: [4]zzui.devtools.KvPair = @splat(.{}),
    dt_kv_n: usize = 0,
    dt_kv_ready: bool = false,
    dt_prb: zzui.devtools.ProblemsState = .{},
    dt_pl_sel: i32 = -1,
    dt_last: [80]u8 = @splat(0),
    dt_last_len: usize = 0,
    /// 客户端调试面板（调用栈 / 请求栏 / 开关矩阵 / API 浏览）
    dp_stk: zzui.devpanels.StackTraceState = .{},
    dp_flg: zzui.devpanels.FeatureFlagsState = .{},
    dp_api: zzui.devpanels.ApiExplorerState = .{},
    dp_api_sel: i32 = -1,
    dp_method: zzui.devpanels.Method = .get,
    dp_url: [256]u8 = @splat(0),
    dp_url_len: usize = 0,
    dp_caret: usize = 0,
    dp_loading: bool = false,
    dp_ready: bool = false,
    dp_last: [96]u8 = @splat(0),
    dp_last_len: usize = 0,
};

/// 正则测试器的样本文本。
const re_sample =
    "Release 2.4 (2026-11-11)\n" ++
    "Contact: dev@example.com or ops@example.com\n" ++
    "Build: zig build -Doptimize=ReleaseSmall\n" ++
    "Tag: v2.4.0, commit 91cbf17\n";

/// 页面默认填好的模式：两个命名分组，能直接看到分组名与色块。
const re_pat = "(?<user>[a-z]+)@(?<host>[a-z.]+)";

/// 一段合成 profile：main → parse/render → 各自的子调用（火焰图用）。
const flame_spans = [_]zzui.flame.Span{
    .{ .name = "main", .start = 0.0, .end = 16.0, .depth = 0 },
    .{ .name = "parse", .start = 0.0, .end = 6.4, .depth = 1 },
    .{ .name = "render", .start = 6.4, .end = 16.0, .depth = 1 },
    .{ .name = "lex", .start = 0.0, .end = 3.1, .depth = 2 },
    .{ .name = "ast", .start = 3.1, .end = 6.4, .depth = 2 },
    .{ .name = "layout", .start = 6.4, .end = 9.2, .depth = 2 },
    .{ .name = "paint", .start = 9.2, .end = 15.4, .depth = 2 },
    .{ .name = "raster", .start = 9.2, .end = 13.8, .depth = 3 },
    .{ .name = "blit", .start = 13.8, .end = 15.4, .depth = 3 },
    .{ .name = "text", .start = 9.2, .end = 11.0, .depth = 4 },
    .{ .name = "glyphs", .start = 11.0, .end = 13.8, .depth = 4 },
};

/// 三条轨道（main / worker / gc）的追踪：同一时间轴上错开的嵌套 span。
const trace_spans = [_]zzui.trace.Span{
    .{ .name = "frame", .start = 0.0, .end = 9.6, .track = 0, .depth = 0 },
    .{ .name = "update", .start = 0.2, .end = 4.0, .track = 0, .depth = 1 },
    .{ .name = "render", .start = 4.2, .end = 9.4, .track = 0, .depth = 1 },
    .{ .name = "layout", .start = 4.2, .end = 6.0, .track = 0, .depth = 2 },
    .{ .name = "paint", .start = 6.0, .end = 9.4, .track = 0, .depth = 2 },
    .{ .name = "decode", .start = 1.0, .end = 5.6, .track = 1, .depth = 0 },
    .{ .name = "inflate", .start = 1.4, .end = 3.2, .track = 1, .depth = 1 },
    .{ .name = "upload", .start = 3.2, .end = 5.6, .track = 1, .depth = 1 },
    .{ .name = "sweep", .start = 2.4, .end = 3.1, .track = 2, .depth = 0 },
    .{ .name = "mark", .start = 7.0, .end = 7.8, .track = 2, .depth = 0 },
};

const trace_markers = [_]zzui.trace.Marker{
    .{ .name = "GC", .time = 3.1, .tone = .warn },
    .{ .name = "deploy", .time = 8.4, .tone = .info },
};

/// 编辑器里的示例源码（可编辑）。
const editor_src =
    "const std = @import(\"std\");\n" ++
    "\n" ++
    "/// Frames a value and draws it.\n" ++
    "pub fn frame(ui: *Context, label: []const u8) void {\n" ++
    "    const pad = 8; // points\n" ++
    "    if (label.len == 0) return;\n" ++
    "    ui.addBox(rect(pad), .{ .radius = 6 });\n" ++
    "    ui.addText(rect(pad), label, 13, theme.text);\n" ++
    "}\n" ++
    "\n" ++
    "fn rect(pad: f32) Rect {\n" ++
    "    return .{ .x = pad, .y = pad, .w = 64, .h = 20 };\n" ++
    "}\n";

/// 规划族示例数据：周日历的事件与甘特图的任务。
const plan_week = zzui.month.Date{ .year = 2026, .month = 11, .day = 9 }; // 周一

const plan_cols = [_][]const u8{ "Todo", "Doing", "Done" };

const plan_cards = [_][]const []const u8{
    &.{ "Write the port notes", "Collect CUI screenshots" },
    &.{"Kanban drag and drop"},
    &.{ "Trace view landed", "Editor landed", "Regex tester landed" },
};

const plan_events = [_]zzui.planning.CalEvent{
    .{ .title = "Standup", .day = 0, .start = 9.0, .end = 9.5, .tone = .accent },
    .{ .title = "Design review", .detail = "Planning views", .day = 2, .start = 10.0, .end = 12.0, .tone = .info },
    .{ .title = "Port review", .detail = "kanban + gantt", .day = 3, .start = 14.0, .end = 15.5, .tone = .warn },
    .{ .title = "Release 0.4", .detail = "cut the tag", .day = 4, .start = 15.0, .end = 16.5, .tone = .success },
    .{ .title = "Retro", .day = 6, .start = 17.0, .end = 18.0, .tone = .violet },
};

const plan_tasks = [_]zzui.planning.GanttTask{
    .{ .name = "Design", .owner = "ann", .start = 0, .end = 4, .progress = 1.0, .tone = .accent },
    .{ .name = "Kanban", .owner = "bo", .start = 2, .end = 8, .progress = 0.6, .depends_on = 0, .tone = .info },
    .{ .name = "Week", .owner = "cy", .start = 3, .end = 9, .progress = 0.3, .depends_on = 0, .tone = .teal },
    .{ .name = "Gantt", .owner = "di", .start = 6, .end = 12, .progress = 0.1, .depends_on = 1, .tone = .warn },
    .{ .name = "Ship", .start = 13, .end = 14, .milestone = true, .depends_on = 3, .tone = .success },
};

/// 一次页面加载的请求（含一条 404）。
const net_requests = [_]zzui.trace.NetRequest{
    .{ .name = "/index.html", .method = "GET", .status = 200, .type = "document", .size = 8_412, .start = 0.00, .timing = .{ 0, 0.012, 0.028, 0.052, 0.120, 0.045 } },
    .{ .name = "/app.js", .method = "GET", .status = 200, .type = "script", .size = 96_512, .start = 0.24, .timing = .{ 0.02, 0, 0.030, 0.046, 0.085, 0.140 } },
    .{ .name = "/app.css", .method = "GET", .status = 200, .type = "stylesheet", .size = 12_880, .start = 0.26, .timing = .{ 0.01, 0, 0.026, 0.040, 0.062, 0.038 } },
    .{ .name = "/api/session", .method = "POST", .status = 201, .type = "json", .size = 640, .start = 0.62, .timing = .{ 0, 0, 0.024, 0.044, 0.210, 0.012 } },
    .{ .name = "/logo.png", .method = "GET", .status = 404, .type = "image", .size = 0, .start = 0.88, .timing = .{ 0, 0.010, 0.022, 0.038, 0.048, 0.004 } },
    .{ .name = "/fonts/inter.woff2", .method = "GET", .status = 200, .type = "font", .size = 34_208, .start = 1.05, .timing = .{ 0.02, 0, 0.034, 0.052, 0.076, 0.126 } },
};

/// 客户端调试页的异常调用栈（顶部帧带源码，中间是一段库帧）。
const dp_src = [_][]const u8{
    "  const user = data.user;",
    "  return user.name;",
    "}",
};

const dp_frames = [_]zzui.devpanels.StackFrame{
    .{ .function = "renderProfile", .file = "src/profile.ts", .line = 41, .column = 10, .source = dp_src[0..], .source_first = 40 },
    .{ .function = "readField", .file = "node_modules/runtime/field.js", .line = 12, .external = true },
    .{ .function = "invoke", .file = "node_modules/runtime/invoke.js", .line = 88, .external = true },
    .{ .function = "main", .file = "src/main.ts", .line = 7, .column = 3 },
};

/// 三个环境上的两枚开关（灰度用百分数）。
const dp_envs = [_][]const u8{ "dev", "staging", "prod" };

var dp_flags = [_]zzui.devpanels.FeatureFlag{
    .{ .key = "new-checkout", .description = "Single page checkout", .on = @splat(false), .rollout = @splat(100) },
    .{ .key = "fast-search", .description = "Vector search backend", .on = @splat(false), .rollout = @splat(100) },
};

fn dpInitFlags() void {
    dp_flags[0].on[0] = true;
    dp_flags[0].on[1] = true;
    dp_flags[0].rollout[1] = 25;
    dp_flags[1].on[0] = true;
    dp_flags[1].rollout[0] = 50;
}

/// API 浏览的端点（含一条废弃的与一条无参数的）。
const dp_params_users = [_]zzui.devpanels.ApiParam{
    .{ .name = "id", .in = "path", .type = "string", .required = true, .description = "user id" },
    .{ .name = "expand", .in = "query", .type = "string", .description = "relations to inline" },
};

const dp_endpoints = [_]zzui.devpanels.ApiEndpoint{
    .{ .method = "GET", .path = "/users/{id}", .summary = "Read a user", .tag = "Users", .params = dp_params_users[0..] },
    .{ .method = "DELETE", .path = "/users/{id}", .summary = "Delete a user", .tag = "Users", .deprecated = true },
    .{ .method = "POST", .path = "/orders", .summary = "Create an order", .tag = "Orders" },
    .{ .method = "GET", .path = "/orders/{id}/items", .summary = "List order items", .tag = "Orders" },
};

fn build(ui: *zzui.core.Context, st: *State) void {
    var col = ui.column(.{ .pad = 24, .gap = 14 });
    defer col.end();

    zzui.widgets.heading(ui, "Docs", 2);
    zzui.widgets.secondary(ui, "Markdown renders every frame; the diff is line level with folding.");
    zzui.controls.tabs(ui, "docs-pages", page_names[0..], &st.page);

    var body = ui.scroll(.{ .id = "docs-body", .height = ui.height - 190, .gap = 14 });
    defer body.end();

    if (st.page == 0) {
        const r = zzui.markdown.markdown(ui, "notes", st.notes[0..], .{});
        if (r.link) |url| {
            const n = @min(url.len, st.last_link.len);
            @memcpy(st.last_link[0..n], url[0..n]);
            st.last_link_len = n;
        }
        if (zzui.markdown.applyTask(st.notes[0..], r)) st.tasks_toggled += 1;
        if (st.last_link_len > 0) {
            zzui.extras.muted(ui, ui.frameStr(st.last_link[0..st.last_link_len]));
        }
        if (st.tasks_toggled > 0) zzui.widgets.textInt(ui, "task toggles = ", @intCast(st.tasks_toggled), "");
    } else if (st.page == 1) {
        const r = zzui.diff.diffView(ui, "dv", diff_old, diff_new, &st.diff_current, .{
            .old_title = "before.zig",
            .new_title = "after.zig",
            .height = 260,
        });
        zzui.widgets.textInt(ui, "changes = ", @intCast(r.changes), "");
        zzui.widgets.textInt(ui, "current = ", @intCast(@max(r.current, 0)), "");
    } else if (st.page == 2) {
        var spans: [flame_spans.len]zzui.flame.Span = flame_spans;
        zzui.flame.sortSpans(spans[0..]);
        _ = zzui.flame.flameGraph(ui, "fl", spans[0..], &st.flame_view, &st.flame_selected, .{
            .width = 0,
            .row_height = 22,
        });
        zzui.widgets.textInt(ui, "selected = ", @intCast(@max(st.flame_selected, 0)), "");
        zzui.extras.muted(ui, "wheel zooms, drag pans, click selects, double-click zooms to a span, Home fits");
    } else if (st.page == 3) {
        zzui.extras.muted(ui, "Guided tour: a spotlight on one control at a time (Esc ends it)");
        if (zzui.widgets.button(ui, "Start the tour", .{ .variant = .primary })) st.tour_step = 0;
        zzui.widgets.separator(ui);
        _ = zzui.widgets.button(ui, "Export", .{});
        var on = true;
        zzui.widgets.checkbox(ui, "Auto save", &on);
        _ = zzui.widgets.input(ui, "Project name", &st.re_pattern, &st.re_pattern_len, &st.re_caret, .{ .placeholder = "my-project" });
    } else if (st.page == 4) {
        zzui.extras.muted(ui, "Regex tester: pattern + i/m/s flags + highlighted sample + match list");
        const r = zzui.regextester.tester(
            ui,
            "docs-rt",
            st.re_pattern[0..],
            &st.re_pattern_len,
            &st.re_caret,
            st.re_text[0..],
            &st.re_text_len,
            &st.rt,
            .{ .height = 150 },
        );
        if (r.err) |e| zzui.extras.badge(ui, e, .danger);
        if (!r.valid and r.err == null) zzui.extras.muted(ui, "type a pattern to see matches");
    } else if (st.page == 6) {
        zzui.extras.muted(ui, "Trace: wheel zooms, drag pans, Shift+drag measures, double-click zooms to a span, click a lane name to fold it");
        var spans: [trace_spans.len]zzui.trace.Span = trace_spans;
        zzui.trace.sortSpans(spans[0..]);
        const tr = zzui.trace.traceView(ui, "docs-tr", st.tr_tracks[0..], spans[0..], &st.tr_view, &st.tr_sel, &st.tr_state, .{
            .markers = trace_markers[0..],
        });
        if (tr.selection_changed) zzui.extras.muted(ui, "a span is selected: Enter zooms to it, Esc clears it");
        _ = zzui.trace.waterfall(ui, "docs-wf", net_requests[0..], .{
            .selected = &st.wf_sel,
            .dom_loaded = 0.72,
            .loaded = 1.28,
            .height = 300,
        });
    } else if (st.page == 7) {
        zzui.extras.muted(ui, "Code editor: editable, line numbers, highlighting, marks, Ctrl+F find");
        var row = ui.row(.{ .gap = 8 });
        if (zzui.widgets.button(ui, "Go to line 5", .{})) zzui.editor.gotoLine(&st.ed, 5, 5);
        if (zzui.widgets.button(ui, "Find 'rect'", .{})) zzui.editor.find(&st.ed, "rect");
        if (zzui.widgets.button(ui, "Select line 1", .{})) zzui.editor.select(&st.ed, 0, 36);
        row.end();
        const marks = [_]zzui.editor.TextMark{
            .{ .start = @intCast(std.mem.indexOf(u8, editor_src, "frame") orelse 0), .end = @intCast((std.mem.indexOf(u8, editor_src, "frame") orelse 0) + 5), .color = 1 },
            .{ .start = @intCast(std.mem.indexOf(u8, editor_src, "radius") orelse 0), .end = @intCast((std.mem.indexOf(u8, editor_src, "radius") orelse 0) + 6), .color = 2 },
        };
        const r = zzui.editor.codeEditor(ui, "docs-ed", st.ed_text[0..], &st.ed_len, &st.ed, .{
            .lang = "zig",
            .height = 300,
            .marks = marks[0..],
            .placeholder = "Type code here",
        });
        var sb: [96]u8 = undefined;
        const status = std.fmt.bufPrint(sb[0..], "Ln {d}, Col {d}  -  {d} lines, {d} bytes  -  {d} matches", .{
            r.line, r.column, r.line_count, r.length, r.find_matches,
        }) catch "";
        zzui.extras.muted(ui, ui.frameStr(status));
        if (r.bracket_match >= 0) zzui.extras.muted(ui, "bracket pair found next to the caret");
    } else if (st.page == 8) {
        zzui.extras.muted(ui, "Planning: kanban (drag a card across columns), week calendar (drag an event) and gantt (drag a bar or its edges)");
        const kinds = [_][]const u8{ "Kanban", "Week", "Gantt" };
        zzui.controls.segmented(ui, "plan-kind", kinds[0..], &st.plan_kind);
        if (st.plan_kind == 0) {
            zzui.planning.kanbanBegin(ui, "docs-kb", &st.kb, &st.kb_st, .{ .height = 380, .width = 0 });
            var c: usize = 0;
            while (c < plan_cols.len) : (c += 1) {
                const cards = plan_cards[c];
                // 主题令牌是运行时的 var，颜色在这里取（不放 comptime 常量表）
                const dot: ?zzui.types.Color = switch (c) {
                    0 => zzui.theme.secondary,
                    1 => zzui.theme.accent,
                    else => zzui.theme.success,
                };
                _ = zzui.planning.kanbanColumnBegin(ui, &st.kb, plan_cols[c], @intCast(cards.len), .{
                    .dot = dot,
                    .limit = 4,
                    .width = 220,
                });
                var k: usize = 0;
                while (k < cards.len) : (k += 1) {
                    const cid: i32 = @intCast(c * 10 + k);
                    const hit = zzui.planning.kanbanCardBegin(ui, &st.kb, cid, .{ .title = cards[k] });
                    if (hit) {
                        const n = @min(cards[k].len, st.plan_last.len);
                        @memcpy(st.plan_last[0..n], cards[k][0..n]);
                        st.plan_last_len = n;
                    }
                    if (st.kb.card_open) {
                        _ = ui.textRun(cards[k], zzui.theme.font_body, zzui.theme.text);
                        zzui.planning.kanbanCardEnd(ui, &st.kb);
                    }
                }
                zzui.planning.kanbanColumnEnd(ui, &st.kb);
            }
            if (zzui.planning.kanbanEnd(ui, &st.kb)) |m| {
                var sb: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(sb[0..], "card {d}: column {d} -> {d} at {d}", .{ m.card, m.from_column, m.to_column, m.to_index }) catch "moved";
                const n = @min(msg.len, st.plan_last.len);
                @memcpy(st.plan_last[0..n], msg[0..n]);
                st.plan_last_len = n;
            }
        } else if (st.plan_kind == 1) {
            var ev = plan_events;
            const hit = zzui.planning.weekCalendar(ui, "docs-wk", plan_week, ev[0..], &st.wk_st, .{
                .height = 420,
                .today = .{ .year = 2026, .month = 11, .day = 11 },
                .now = 13.5,
            });
            if (hit) |i| {
                const n = @min(ev[i].title.len, st.plan_last.len);
                @memcpy(st.plan_last[0..n], ev[i].title[0..n]);
                st.plan_last_len = n;
            }
        } else {
            var tasks = plan_tasks;
            const hit = zzui.planning.gantt(ui, "docs-gt", tasks[0..], plan_week, 16, &st.gt_st, .{
                .today = 3,
                .row_height = 38,
            });
            if (hit) |i| {
                const n = @min(tasks[i].name.len, st.plan_last.len);
                @memcpy(st.plan_last[0..n], tasks[i].name[0..n]);
                st.plan_last_len = n;
            }
        }
        if (st.plan_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.plan_last[0..st.plan_last_len]));
    } else if (st.page == 9) {
        zzui.extras.muted(ui, "Terminal: ANSI colours, tabs, \"\\r\" in-place redraw, block bars; type a command and press Enter (Ctrl+C / Ctrl+L work)");
        if (!st.term_ready) {
            zzui.terminal.init(&st.term_buf, &st.term_text, &st.term_lines);
            zzui.terminal.write(&st.term_buf, "\x1b[2m$ \x1b[0mzig build -Doptimize=ReleaseSmall\n");
            zzui.terminal.write(&st.term_buf, "   Compiling zzui v0.4.0\n");
            zzui.terminal.write(&st.term_buf, "    Finished \x1b[32mrelease\x1b[0m in 2.34s\n");
            zzui.terminal.write(&st.term_buf, "\nDownloading \x1b[36m[1/3]\x1b[0m \xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x91\xe2\x96\x91\xe2\x96\x91\xe2\x96\x91\xe2\x96\x91\xe2\x96\x91 40%");
            zzui.terminal.write(&st.term_buf, "\rDownloading \x1b[36m[3/3]\x1b[0m \xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88 100%\n");
            zzui.terminal.write(&st.term_buf, "\x1b[32m✓\x1b[0m 3 tests passed\n");
            zzui.terminal.write(&st.term_buf, "\x1b[33mwarn\x1b[0m: unused variable `tmp`\n");
            zzui.terminal.write(&st.term_buf, "\x1b[1;31merror\x1b[0m: expected `;` after statement\n");
            zzui.terminal.write(&st.term_buf, "  \x1b[4msee build.zig:42\x1b[0m\n");
            st.term_ready = true;
        }
        const r = zzui.terminal.terminal(ui, "docs-term", &st.term_buf, &st.term_st, .{ .height = 340 });
        if (r.command) |cmd| {
            const msg = std.fmt.bufPrint(st.term_last[0..], "ran: {s}", .{cmd}) catch "ran";
            st.term_last_len = msg.len;
            // 真实终端里这一步是把命令交给进程；演示里直接回一行输出
            zzui.terminal.write(&st.term_buf, "> ");
            zzui.terminal.write(&st.term_buf, cmd);
            zzui.terminal.write(&st.term_buf, "\n");
        }
        if (r.interrupt) {
            const msg = "interrupt (Ctrl+C)";
            @memcpy(st.term_last[0..msg.len], msg);
            st.term_last_len = msg.len;
        }
        if (r.copy) |sel| {
            const msg = std.fmt.bufPrint(st.term_last[0..], "copy {d} bytes: {s}", .{ sel.len, sel }) catch "copy";
            st.term_last_len = msg.len;
        }
        if (st.term_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.term_last[0..st.term_last_len]));
    } else if (st.page == 10) {
        zzui.extras.muted(ui, "Social: chat bubbles, a divider, the typing indicator, a comment thread (like / reply) and a presence row");
        {
            var who = ui.row(.{ .gap = 10 });
            zzui.social.presence(ui, "docs-who", soc_users[0..], 4, 28, &st.soc_pres);
            who.end();
        }
        zzui.social.chatDivider(ui, "Today");
        zzui.social.chatMessage(ui, "Morning! The social family is in: bubbles, comments and presence.", .{ .author = "Ada", .time = "09:12" });
        zzui.social.chatMessage(ui, "Presence avatars overlap until you hover them.", .{ .author = "Ada", .grouped = true });
        zzui.social.chatMessage(ui, "Looks good - shipping the docs page now.", .{ .mine = true, .status = "Read", .time = "09:14" });
        zzui.social.typingIndicator(ui, "Ada");
        zzui.widgets.separator(ui);
        for (soc_thread, 0..) |c, i| {
            const flags = zzui.social.comment(ui, c.id, c.author, c.text, &st.soc_comments, .{
                .time = c.time,
                .depth = c.depth,
                .badge = c.badge,
                .likes = &st.soc_likes[i],
                .liked = &st.soc_liked[i],
            });
            if (flags != 0) {
                const msg = std.fmt.bufPrint(st.soc_last[0..], "{s}: {s}", .{ c.id, if (flags & zzui.social.COMMENT_LIKE != 0) "like" else "reply" }) catch "action";
                st.soc_last_len = msg.len;
            }
        }
        if (st.soc_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.soc_last[0..st.soc_last_len]));
    } else if (st.page == 11) {
        zzui.extras.muted(ui, "Graph: commit lanes (click / arrows / enter) and a dependency graph (wheel zooms, drag pans, F fits)");
        const r = zzui.graph.commitGraph(ui, "docs-commits", gr_commits[0..], &st.gr_cs, .{ .height = 210 });
        var sb: [72]u8 = undefined;
        var note: []const u8 = "";
        if (r.activated >= 0) {
            const c = gr_commits[@intCast(r.activated)];
            note = std.fmt.bufPrint(sb[0..], "activate {s} - {s}", .{ c.hash[0..7], c.message }) catch "activate";
        }
        {
            var bar = ui.row(.{ .gap = 8 });
            if (zzui.widgets.button(ui, if (st.gr_topdown) "Top down" else "Left to right", .{})) st.gr_topdown = !st.gr_topdown;
            if (zzui.widgets.button(ui, "Focus core", .{})) st.gr_ds.sel = 0;
            bar.end();
        }
        const d = zzui.graph.depGraph(ui, "docs-deps", gr_nodes[0..], gr_edges[0..], &st.gr_ds, .{ .height = 300, .top_down = st.gr_topdown });
        if (note.len == 0) {
            note = std.fmt.bufPrint(sb[0..], "picked {d}, zoom {d}%", .{
                d.clicked,
                @as(i32, @intFromFloat(st.gr_ds.zoom * 100)),
            }) catch "picked";
        }
        const n = @min(note.len, st.gr_last.len);
        @memcpy(st.gr_last[0..n], note[0..n]);
        st.gr_last_len = n;
        if (st.gr_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.gr_last[0..st.gr_last_len]));
    } else if (st.page == 12) {
        zzui.extras.muted(ui, "Nodes: drag cards, drag from a pin to wire them, Shift/Ctrl adds, Delete removes, Alt+drag pans");
        if (zzui.nodes.editorBegin(ui, "docs-nodes", &st.nd_st, &st.nd_view, .{ .height = 470, .minimap = true })) {
            for (&st.nd_nodes) |*nd| {
                _ = zzui.nodes.nodeBegin(ui, &st.nd_st, nd.id, &nd.x, &nd.y, nd.title, .{});
                if (nd.in_pin != 0) _ = zzui.nodes.nodeInput(ui, &st.nd_st, nd.in_pin, "in", .{ .type = 1 });
                if (nd.id == 1) {
                    // 内容宿主：里面的控件按 100% 布局，指针会被反缩放映射
                    zzui.nodes.contentBegin(ui, &st.nd_st, 34);
                    _ = zzui.widgets.button(ui, "Load", .{});
                    zzui.nodes.contentEnd(ui, &st.nd_st);
                }
                if (nd.out_pin != 0) _ = zzui.nodes.nodeOutput(ui, &st.nd_st, nd.out_pin, "out", .{ .type = 1 });
                zzui.nodes.nodeEnd(ui, &st.nd_st);
            }
            for (st.nd_links[0..st.nd_link_n]) |l| _ = zzui.nodes.nodeLink(ui, &st.nd_st, l.id, l.from, l.to);

            var from_pin: i32 = 0;
            var to_pin: i32 = 0;
            while (zzui.nodes.linkCreated(&st.nd_st, &from_pin, &to_pin)) {
                if (st.nd_link_n < st.nd_links.len) {
                    st.nd_links[st.nd_link_n] = .{ .id = st.nd_next_link, .from = from_pin, .to = to_pin };
                    st.nd_link_n += 1;
                    st.nd_next_link += 1;
                }
                const msg = std.fmt.bufPrint(st.nd_last[0..], "link {d} -> {d}", .{ from_pin, to_pin }) catch "link";
                st.nd_last_len = msg.len;
            }
            var dead_link: i32 = 0;
            while (zzui.nodes.linkRemoved(&st.nd_st, &dead_link)) {
                var i: usize = 0;
                while (i < st.nd_link_n) : (i += 1) {
                    if (st.nd_links[i].id != dead_link) continue;
                    st.nd_links[i] = st.nd_links[st.nd_link_n - 1];
                    st.nd_link_n -= 1;
                    break;
                }
                const msg = std.fmt.bufPrint(st.nd_last[0..], "removed link {d}", .{dead_link}) catch "removed";
                st.nd_last_len = msg.len;
            }
            var dead_node: i32 = 0;
            while (zzui.nodes.nodeDeleted(&st.nd_st, &dead_node)) {
                var i: usize = 0;
                while (i < st.nd_nodes.len) : (i += 1) {
                    if (st.nd_nodes[i].id != dead_node) continue;
                    var k = i;
                    while (k + 1 < st.nd_nodes.len) : (k += 1) st.nd_nodes[k] = st.nd_nodes[k + 1];
                    st.nd_nodes[st.nd_nodes.len - 1] = .{ .id = 0, .x = 0, .y = 0, .title = "", .in_pin = 0, .out_pin = 0 };
                    break;
                }
                const msg = std.fmt.bufPrint(st.nd_last[0..], "removed node {d}", .{dead_node}) catch "removed";
                st.nd_last_len = msg.len;
            }
            zzui.nodes.editorEnd(ui, &st.nd_st);
        }
        var note_buf: [72]u8 = undefined;
        if (st.nd_last_len == 0) {
            const msg = std.fmt.bufPrint(note_buf[0..], "selected {d} card(s), zoom {d}%", .{
                zzui.nodes.selectedCount(&st.nd_st),
                @as(i32, @intFromFloat(st.nd_view.zoom * 100)),
            }) catch "nodes";
            st.nd_last_len = msg.len;
            @memcpy(st.nd_last[0..msg.len], msg);
        }
        zzui.extras.muted(ui, ui.frameStr(st.nd_last[0..st.nd_last_len]));
    } else if (st.page == 13) {
        zzui.extras.muted(ui, "Emoji: the platform font draws them - the picker has search, group tabs, recents, skin tones and a preview");
        {
            var samples = ui.row(.{ .gap = 10 });
            zzui.emoji.emoji(ui, "\u{1F600}", 26);
            zzui.emoji.emoji(ui, "\u{1F44D}", 32);
            zzui.emoji.emoji(ui, "\u{1F680}", 38);
            zzui.emoji.emoji(ui, "\u{2764}\u{FE0F}", 30);
            zzui.emoji.emoji(ui, "\u{1F1E8}\u{1F1F3}", 30);
            samples.end();
        }
        _ = zzui.emoji.picker(ui, "docs-emoji", &st.em_st, .{
            .width = 360,
            .height = 250,
            .tone = &st.em_tone,
            .recent = st.em_recent[0..],
            .recent_len = &st.em_recent_len,
        });
        if (st.em_recent_len > 0) {
            var recents = ui.row(.{ .gap = 6 });
            var it = std.mem.splitScalar(u8, st.em_recent[0..st.em_recent_len], ' ');
            var guard: usize = 0;
            while (it.next()) |item| {
                if (item.len == 0 or guard >= 10) break;
                guard += 1;
                zzui.emoji.emoji(ui, item, 22);
            }
            recents.end();
        }
    } else if (st.page == 14) {
        zzui.extras.muted(ui, "AI surfaces: reasoning fold, tool calls, plan rail, sources + inline citations, context ring, response actions, suggestions, model picker, composer and a voice orb");
        _ = zzui.ai.reasoningBegin(ui, "docs-rz", &st.ai_rz, .{ .seconds = 14 });
        zzui.widgets.secondary(ui, "The plan below is derived from the tool results, so every step can point at the call that produced it.");
        zzui.ai.reasoningEnd(ui, &st.ai_rz);
        zzui.ai.toolCall(ui, "docs-tc0", &st.ai_tc[0], "web.search", .{
            .status = .done,
            .detail = "5 results",
            .input = "{\"q\":\"zig immediate mode ui\"}",
            .output = "{\"hits\":5,\"top\":\"ziglang.org\"}",
            .seconds = 3,
        });
        zzui.ai.toolCall(ui, "docs-tc1", &st.ai_tc[1], "repo.read", .{ .status = .running, .detail = "src/ai.zig", .seconds = 1 });
        _ = zzui.ai.agentPlan(ui, "docs-plan", ai_plan[0..], .{ .title = "Port cui_ai.c" });
        zzui.ai.agentStatus(ui, "Drafting the AI page", .{ .status = .running, .seconds = 42 });
        zzui.widgets.separator(ui);
        {
            var row = ui.row(.{ .gap = 14 });
            zzui.ai.contextMeter(ui, "docs-ctx", .{ .used = 96_400, .limit = 128_000 });
            const flags = zzui.ai.responseActions(ui, "docs-ra", &st.ai_vote, .{});
            if (flags != 0) {
                var nb: [40]u8 = undefined;
                const msg = std.fmt.bufPrint(nb[0..], "response actions = {d}, vote = {d}", .{ flags, st.ai_vote }) catch "actions";
                @memcpy(st.ai_last[0..msg.len], msg);
                st.ai_last_len = msg.len;
            }
            row.end();
        }
        {
            var row = ui.row(.{ .gap = 6 });
            zzui.widgets.secondary(ui, "Immediate mode keeps the state in your own structs");
            _ = zzui.ai.citation(ui, 1, ai_sources[0]);
            _ = zzui.ai.citation(ui, 2, ai_sources[1]);
            row.end();
        }
        const picked = zzui.ai.sourceList(ui, "docs-src", ai_sources[0..]);
        if (picked >= 0) {
            const n = @min(ai_sources[@intCast(picked)].title.len, st.ai_last.len);
            @memcpy(st.ai_last[0..n], ai_sources[@intCast(picked)].title[0..n]);
            st.ai_last_len = n;
        }
        const sugg = zzui.ai.promptSuggestions(ui, "docs-sugg", ai_suggestions[0..], 2);
        if (sugg >= 0) {
            const n = @min(ai_suggestions[@intCast(sugg)].title.len, st.ai_last.len);
            @memcpy(st.ai_last[0..n], ai_suggestions[@intCast(sugg)].title[0..n]);
            st.ai_last_len = n;
        }
        zzui.widgets.separator(ui);
        {
            var row = ui.row(.{ .gap = 12 });
            _ = zzui.ai.modelPicker(ui, "docs-mp", &st.ai_mp, ai_models[0..], &st.ai_model, false);
            const orb_hit = zzui.ai.voiceOrb(ui, "docs-orb", st.ai_voice, 0.65, 56);
            if (orb_hit) {
                st.ai_voice = switch (st.ai_voice) {
                    .idle => .listening,
                    .listening => .thinking,
                    .thinking => .speaking,
                    .speaking => .idle,
                };
                const msg = "voice orb clicked";
                @memcpy(st.ai_last[0..msg.len], msg);
                st.ai_last_len = msg.len;
            }
            row.end();
        }
        const cflags = zzui.ai.chatComposer(ui, "docs-cmp", &st.ai_cmp, ai_models[0..], &st.ai_model, &st.ai_mp, .{
            .attachments = ai_attach[0..],
            .busy = st.ai_voice == .thinking,
        });
        if (cflags != 0) {
            var nb: [40]u8 = undefined;
            const msg = std.fmt.bufPrint(nb[0..], "composer flags = {d}", .{cflags}) catch "composer";
            @memcpy(st.ai_last[0..msg.len], msg);
            st.ai_last_len = msg.len;
        }
        if (st.ai_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.ai_last[0..st.ai_last_len]));
    } else if (st.page == 15) {
        zzui.extras.muted(ui, "Dev views: uptime bars, stacked event histogram (drag to select), coverage tree (fold / sort / activate) and a blame gutter with an age heat bar");
        const up = zzui.devviews.uptime(ui, "docs-up", dv_services[0..], .{ .last_day = .{ .year = 2026, .month = 11, .day = 11 } });
        if (up.service >= 0) {
            var nb: [48]u8 = undefined;
            const msg = std.fmt.bufPrint(nb[0..], "uptime: {s} day {d}", .{ dv_services[@intCast(up.service)].name, up.day }) catch "uptime";
            @memcpy(st.dv_last[0..msg.len], msg);
            st.dv_last_len = msg.len;
        }
        zzui.widgets.separator(ui);
        const hres = zzui.devviews.timeHistogram(ui, "docs-hist", 1_700_006_400, 3600, dv_buckets, dv_series[0..], &st.dv_sel0, &st.dv_sel1, .{ .height = 150 });
        if (hres.selection_changed) {
            var nb: [56]u8 = undefined;
            const msg = std.fmt.bufPrint(nb[0..], "histogram: selected {d}..{d}", .{ @as(i64, @intFromFloat(st.dv_sel0)), @as(i64, @intFromFloat(st.dv_sel1)) }) catch "histogram";
            @memcpy(st.dv_last[0..msg.len], msg);
            st.dv_last_len = msg.len;
        }
        zzui.widgets.separator(ui);
        const cov = zzui.devviews.coverage(ui, "docs-cov", dv_cov_files[0..], &st.dv_cov, .{ .height = 240 });
        if (cov.activated >= 0) {
            const n = @min(dv_cov_files[@intCast(cov.activated)].path.len, st.dv_last.len);
            @memcpy(st.dv_last[0..n], dv_cov_files[@intCast(cov.activated)].path[0..n]);
            st.dv_last_len = n;
        }
        zzui.widgets.separator(ui);
        const bl = zzui.devviews.blame(ui, "docs-bl", dv_bl_lines[0..], dv_bl_map[0..], dv_bl_commits[0..], &st.dv_bl, .{
            .height = 200,
            .lang = "zig",
            .now = 1_702_000_000,
        });
        if (bl.clicked >= 0) {
            const msg = dv_bl_commits[@intCast(bl.clicked)].summary;
            const n = @min(msg.len, st.dv_last.len);
            @memcpy(st.dv_last[0..n], msg[0..n]);
            st.dv_last_len = n;
        }
        if (st.dv_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.dv_last[0..st.dv_last_len]));
    } else if (st.page == 16) {
        zzui.extras.muted(ui, "Dev panels: key-value editor (empty row adds a pair, * marks secrets), problems panel (severity chips, filter, fold by file) and a CI pipeline (click a job)");
        if (!st.dt_kv_ready) {
            st.dt_kv[0].setKey("Accept");
            st.dt_kv[0].setValue("application/json");
            st.dt_kv[1].setKey("Authorization");
            st.dt_kv[1].setValue("Bearer 3f0a91c2");
            st.dt_kv[1].secret = true;
            st.dt_kv[2].setKey("X-Trace");
            st.dt_kv[2].setValue("1");
            st.dt_kv[2].enabled = false;
            st.dt_kv_n = 3;
            st.dt_kv_ready = true;
        }
        if (zzui.devtools.kvEditor(ui, "docs-kv", st.dt_kv[0..], &st.dt_kv_n, .{})) {
            var nb: [40]u8 = undefined;
            const msg = std.fmt.bufPrint(nb[0..], "kv changed: {d} pairs", .{st.dt_kv_n}) catch "kv";
            @memcpy(st.dt_last[0..msg.len], msg);
            st.dt_last_len = msg.len;
        }
        zzui.widgets.separator(ui);
        const pr = zzui.devtools.problems(ui, "docs-prb", dt_diags[0..], &st.dt_prb, .{ .height = 230 });
        if (pr.activated >= 0) {
            const msg = dt_diags[@intCast(pr.activated)].message;
            const n = @min(msg.len, st.dt_last.len);
            @memcpy(st.dt_last[0..n], msg[0..n]);
            st.dt_last_len = n;
        }
        zzui.widgets.separator(ui);
        const pl = zzui.devtools.pipeline(ui, "docs-pl", dt_stages[0..], dt_jobs[0..], .{ .selected = &st.dt_pl_sel });
        if (pl.clicked >= 0) {
            const msg = dt_jobs[@intCast(pl.clicked)].name;
            const n = @min(msg.len, st.dt_last.len);
            @memcpy(st.dt_last[0..n], msg[0..n]);
            st.dt_last_len = n;
        }
        if (st.dt_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.dt_last[0..st.dt_last_len]));
    } else if (st.page == 17) {
        zzui.extras.muted(ui, "Client panels: stack (click a frame), request bar (Enter sends), flags and an API browser");
        if (!st.dp_ready) {
            dpInitFlags();
            st.dp_ready = true;
            st.dp_stk.open = 0;
            st.dp_api.open = 0;
            const u = "https://api.example.com/users?page=2&expand=orders";
            @memcpy(st.dp_url[0..u.len], u);
            st.dp_url_len = u.len;
            st.dp_caret = u.len;
        }
        const sk = zzui.devpanels.stackTrace(ui, "docs-stk", dp_frames[0..], &st.dp_stk, .{
            .title = "TypeError",
            .message = "Cannot read properties of undefined",
            .lang = "typescript",
        });
        if (sk.copy) {
            const msg = "trace copied to clipboard";
            @memcpy(st.dp_last[0..msg.len], msg);
            st.dp_last_len = msg.len;
        } else if (sk.clicked >= 0) {
            const msg = dp_frames[@intCast(sk.clicked)].function;
            const n = @min(msg.len, st.dp_last.len);
            @memcpy(st.dp_last[0..n], msg[0..n]);
            st.dp_last_len = n;
        }
        zzui.widgets.separator(ui);
        const rq = zzui.devpanels.requestBar(ui, "docs-rq", &st.dp_method, st.dp_url[0..], &st.dp_url_len, &st.dp_caret, .{ .loading = st.dp_loading });
        if (rq.send) {
            const msg = "sending GET " ++ "/users";
            const n = @min(msg.len, st.dp_last.len);
            @memcpy(st.dp_last[0..n], msg[0..n]);
            st.dp_last_len = n;
        }
        if (rq.cancel) st.dp_loading = false;
        zzui.devpanels.responseStatus(ui, 200, 0.042, 8_412);
        zzui.devpanels.responseStatus(ui, 404, 0.118, 0);
        if (st.dp_url_len > 0) {
            var pairs: [8]zzui.devtools.KvPair = @splat(.{});
            const n = zzui.devpanels.urlParams(st.dp_url[0..st.dp_url_len], pairs[0..]);
            zzui.widgets.textInt(ui, "query params = ", @intCast(n), "");
        }
        zzui.widgets.separator(ui);
        const fl = zzui.devpanels.featureFlags(ui, "docs-flag", dp_flags[0..], dp_envs[0..], &st.dp_flg, .{ .height = 116 });
        if (fl.flag >= 0) {
            var nb: [72]u8 = undefined;
            const msg = std.fmt.bufPrint(nb[0..], "{s} @ {s}", .{ dp_flags[@intCast(fl.flag)].key, dp_envs[@intCast(fl.env)] }) catch "flag";
            @memcpy(st.dp_last[0..msg.len], msg);
            st.dp_last_len = msg.len;
        }
        zzui.widgets.separator(ui);
        const ap = zzui.devpanels.apiExplorer(ui, "docs-api", dp_endpoints[0..], &st.dp_api, .{ .height = 230, .selected = &st.dp_api_sel });
        if (ap.try_it >= 0) {
            var nb: [96]u8 = undefined;
            const e = dp_endpoints[@intCast(ap.try_it)];
            const msg = std.fmt.bufPrint(nb[0..], "try it: {s} {s}", .{ e.method, e.path }) catch "try it";
            @memcpy(st.dp_last[0..msg.len], msg);
            st.dp_last_len = msg.len;
        } else if (ap.clicked >= 0) {
            const msg = dp_endpoints[@intCast(ap.clicked)].path;
            const n = @min(msg.len, st.dp_last.len);
            @memcpy(st.dp_last[0..n], msg[0..n]);
            st.dp_last_len = n;
        }
        if (st.dp_last_len > 0) zzui.extras.muted(ui, ui.frameStr(st.dp_last[0..st.dp_last_len]));
    } else {
        zzui.extras.muted(ui, "File browser: double-click a folder to enter it, ^ goes up, R reloads");
        if (st.fb_path.isEmpty()) st.fb_path.set(if (@import("builtin").os.tag == .windows) "C:/Windows" else "/");
        const r = zzui.files.fileBrowser(ui, "docs-fb", &st.fb_path, &st.fb, .{ .height = 320 });
        if (r.picked) |name| {
            const n = @min(name.len, st.picked.len);
            @memcpy(st.picked[0..n], name[0..n]);
            st.picked_len = n;
        }
        if (st.picked_len > 0) {
            zzui.extras.muted(ui, ui.frameStr(st.picked[0..st.picked_len]));
        } else {
            zzui.widgets.textInt(ui, "n = ", @intCast(st.fb.n), "");
        }
    }
}

/// 会话族的示例数据：在线用户与评论串。
const soc_users = [_]zzui.social.PresenceUser{
    .{ .name = "Ada" },
    .{ .name = "Bo", .color = .{ .r = 0x30, .g = 0xa4, .b = 0x6c, .a = 255 } },
    .{ .name = "Cy" },
    .{ .name = "Di", .idle = true },
    .{ .name = "Ed" },
    .{ .name = "Fay" },
};

const soc_thread = [_]struct { id: []const u8, author: []const u8, text: []const u8, depth: i32, time: []const u8, badge: []const u8 }{
    .{ .id = "c1", .author = "Ada Lovelace", .text = "The planning page landed: kanban, week calendar and gantt all share one layout pass now.", .depth = 0, .time = "10:02", .badge = "Author" },
    .{ .id = "c2", .author = "Bo Chen", .text = "Nice. Does the week calendar split overlapping events into lanes?", .depth = 1, .time = "10:05", .badge = "" },
    .{ .id = "c3", .author = "Ada Lovelace", .text = "Yes: same start goes side by side, 30 minutes apart cascades.", .depth = 1, .time = "10:06", .badge = "" },
};

/// 提交图示例（父提交必须排在后面）。
const gr_commits = [_]zzui.graph.Commit{
    .{ .hash = "91cbf17e2d", .message = "Graph family: commit lanes + dependency graph", .author = "Ada", .date = "2 hours ago", .refs = "main", .parent = .{ 1, 2 } },
    .{ .hash = "5d0f2a98c1", .message = "Social page and comment thread", .author = "Bo", .date = "yesterday", .parent = .{ 3, -1 } },
    .{ .hash = "e7104bb332", .message = "Terminal ANSI parsing + viewport", .author = "Ada", .date = "yesterday", .refs = "origin/main", .parent = .{ 3, -1 } },
    .{ .hash = "a02d9c1440", .message = "Planning: kanban / week / gantt", .author = "Cy", .date = "2 days ago", .parent = .{ 4, -1 } },
    .{ .hash = "77fe10c8b9", .message = "Pickers, upload and media families", .author = "Bo", .date = "3 days ago", .refs = "tag: v0.4.0", .parent = .{ 5, -1 } },
    .{ .hash = "3c8871ad20", .message = "Editor, tour, strings, regex, files", .author = "Ada", .date = "4 days ago", .parent = .{ -1, -1 } },
};

/// 依赖图示例：分层 + 菱形分支（graph / tests 同层，最后汇到 app）。
const gr_nodes = [_]zzui.graph.DepNode{
    .{ .label = "theme", .detail = "tokens", .tone = .neutral },
    .{ .label = "core", .detail = "immediate UI" },
    .{ .label = "render", .detail = "software raster", .tone = .info },
    .{ .label = "widgets", .detail = "153 controls" },
    .{ .label = "graph", .detail = "this page", .tone = .accent },
    .{ .label = "tests", .detail = "337 cases", .tone = .warn },
    .{ .label = "app", .tone = .success },
};

const gr_edges = [_]zzui.graph.DepEdge{
    .{ .from = 0, .to = 1 },
    .{ .from = 1, .to = 2 },
    .{ .from = 1, .to = 3 },
    .{ .from = 2, .to = 3 },
    .{ .from = 3, .to = 4 },
    .{ .from = 3, .to = 5 },
    .{ .from = 4, .to = 6 },
    .{ .from = 5, .to = 6 },
};

/// 节点编辑器的示例数据（位置可变，所以放在 State 里）。
const NdNode = struct { id: i32, x: f32, y: f32, title: []const u8, in_pin: i32, out_pin: i32 };
const NdLink = struct { id: i32, from: i32, to: i32 };
const nd_node_data = [_]NdNode{
    .{ .id = 1, .x = 24, .y = 24, .title = "Image", .in_pin = 0, .out_pin = 11 },
    .{ .id = 2, .x = 320, .y = 30, .title = "Blur", .in_pin = 21, .out_pin = 22 },
    .{ .id = 3, .x = 320, .y = 230, .title = "Mixer", .in_pin = 31, .out_pin = 32 },
    .{ .id = 4, .x = 24, .y = 230, .title = "Output", .in_pin = 41, .out_pin = 0 },
};

const ai_plan = [_]zzui.ai.PlanStep{
    .{ .title = "Read cui_ai.c", .status = .done },
    .{ .title = "Map the 13 APIs", .status = .done },
    .{ .title = "Write src/ai.zig", .status = .running, .detail = "composer + voice orb" },
    .{ .title = "Run the regression", .status = .pending },
};

const ai_sources = [_]zzui.ai.Source{
    .{ .title = "Zig language reference", .url = "https://ziglang.org/documentation", .snippet = "Comptime runs at compile time..." },
    .{ .title = "Immediate mode GUI", .url = "https://caseymuratori.com/blog_0001", .snippet = "UI as a pure function of state." },
};

const ai_suggestions = [_]zzui.ai.PromptSuggestion{
    .{ .icon = "?", .title = "Explain this page", .detail = "Walk through every control" },
    .{ .icon = "+", .title = "Add a widget", .detail = "Pick the nearest CUI control" },
    .{ .icon = "!", .title = "Shrink the binary", .detail = "Find the cheap wins" },
    .{ .icon = "*", .title = "Run the tests", .detail = "375 cases in one command" },
};

const ai_models = [_]zzui.ai.Model{
    .{ .name = "DeepSeek V4.1 Flash", .detail = "fast, 128k context", .badge = "fast" },
    .{ .name = "DeepSeek V4.1 Pro", .detail = "deeper reasoning, slower" },
};

const ai_attach = [_][]const u8{ "ai.zig", "cui_ai.c" };

// ---- 开发者视图（第 16 页）的示例数据

const dv_days_a = [_]f32{ 1.0, 1.0, 0.998, 0.991, 1.0, 0.972, 1.0, 1.0, 0.996, -1, 1.0, 0.93, 0.999, 1.0 };
const dv_days_b = [_]f32{ 1.0, 0.999, 1.0, 1.0, 0.988, 1.0, 1.0, 0.999, 1.0, 1.0, 0.994, 1.0, 1.0, 1.0 };
const dv_services = [_]zzui.devviews.UptimeService{
    .{ .name = "api", .days = dv_days_a[0..] },
    .{ .name = "worker", .days = dv_days_b[0..] },
    .{ .name = "db-proxy", .days = dv_days_b[0..] },
};

const dv_buckets = 24;
const dv_errors = [_]f32{ 0, 0, 1, 0, 0, 2, 1, 0, 0, 0, 3, 1, 0, 0, 0, 1, 2, 0, 0, 4, 1, 0, 0, 0 };
const dv_warns = [_]f32{ 2, 1, 3, 2, 1, 4, 2, 1, 3, 2, 5, 3, 1, 2, 2, 3, 4, 2, 1, 6, 3, 2, 1, 2 };
const dv_infos = [_]f32{ 9, 7, 11, 8, 6, 12, 9, 7, 10, 8, 14, 11, 7, 8, 9, 10, 12, 8, 6, 15, 10, 9, 7, 8 };
const dv_series = [_]zzui.devviews.HistogramSeries{
    .{ .name = "error", .counts = dv_errors[0..], .tone = .danger },
    .{ .name = "warn", .counts = dv_warns[0..], .tone = .warn },
    .{ .name = "info", .counts = dv_infos[0..], .tone = .info },
};

const dv_cov_files = [_]zzui.devviews.CoverageFile{
    .{ .path = "src/core/layout.zig", .lines = 1240, .lines_hit = 1188, .branches = 210, .branches_hit = 186, .functions = 42, .functions_hit = 40 },
    .{ .path = "src/core/render.zig", .lines = 860, .lines_hit = 731, .branches = 140, .branches_hit = 98, .functions = 28, .functions_hit = 25 },
    .{ .path = "src/widgets.zig", .lines = 1540, .lines_hit = 1109, .branches = 320, .branches_hit = 190, .functions = 61, .functions_hit = 44 },
    .{ .path = "src/devviews.zig", .lines = 720, .lines_hit = 302, .branches = 96, .branches_hit = 31, .functions = 19, .functions_hit = 9 },
    .{ .path = "tests/core.zig", .lines = 480, .lines_hit = 474, .branches = 0, .branches_hit = 0, .functions = 12, .functions_hit = 12 },
    .{ .path = "tests/render.zig", .lines = 365, .lines_hit = 350, .branches = 24, .branches_hit = 18, .functions = 9, .functions_hit = 9 },
};

const dv_bl_lines = [_][]const u8{
    "//! 软件光栅：BGRA 上的圆角矩形 / 线段 / 裁剪。",
    "const std = @import(\"std\");",
    "const types = @import(\"types.zig\");",
    "",
    "pub fn fillRect(px: []u8, w: usize, h: usize, r: types.Rect, c: types.Color) void {",
    "    const x0: usize = @intFromFloat(r.x);",
    "    const y0: usize = @intFromFloat(r.y);",
    "    var y = y0;",
    "    while (y < h and y < y0 + @as(usize, @intFromFloat(r.h))) : (y += 1) {",
    "        var x = x0;",
    "        while (x < w and x < x0 + @as(usize, @intFromFloat(r.w))) : (x += 1) {",
    "            const o = (y * w + x) * 4;",
    "            px[o] = c.b;",
    "            px[o + 1] = c.g;",
    "            px[o + 2] = c.r;",
    "            px[o + 3] = c.a;",
    "        }",
    "    }",
    "}",
};
const dv_bl_map = [_]i32{ 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 };
const dv_bl_commits = [_]zzui.devviews.BlameCommit{
    .{ .hash = "3f0a91c2e7", .author = "Ada", .summary = "光栅：圆角与线段", .time = 1_690_000_000 },
    .{ .hash = "b71d4c88a0", .author = "Bo", .summary = "加上裁剪与覆盖层", .time = 1_700_200_000 },
    .{ .hash = "e05c2fa319", .author = "Cy", .summary = "修 fillRect 的边界", .time = 1_701_800_000 },
};

// ---- 开发面板（第 17 页）的示例数据

const dt_diags = [_]zzui.devtools.Diagnostic{
    .{ .severity = .err, .message = "expected ';' after statement", .file = "src/core/layout.zig", .line = 42, .column = 9, .source = "zig", .code = "E0001" },
    .{ .severity = .warning, .message = "unused local constant 'tmp'", .file = "src/core/layout.zig", .line = 88, .source = "zig", .code = "W0042" },
    .{ .severity = .err, .message = "undefined symbol 'fooBar'", .file = "src/widgets.zig", .line = 512, .column = 5, .source = "zig", .code = "E0002" },
    .{ .severity = .info, .message = "file is not formatted", .file = "src/widgets.zig" },
    .{ .severity = .warning, .message = "shadows declaration of 'count'", .file = "src/devviews.zig", .line = 233, .column = 9, .source = "zig", .code = "W0017" },
    .{ .severity = .hint, .message = "consider a for loop instead", .file = "tests/core.zig", .line = 7, .column = 3 },
    .{ .severity = .err, .message = "unreachable after return", .file = "tests/core.zig", .line = 64, .column = 11, .source = "zig", .code = "E0009" },
};

const dt_stages = [_][]const u8{ "build", "test", "package", "deploy" };
const dt_jobs = [_]zzui.devtools.PipelineJob{
    .{ .name = "linux-x64", .stage = 0, .status = .passed, .duration = 48 },
    .{ .name = "windows-x64", .stage = 0, .status = .passed, .duration = 61 },
    .{ .name = "unit", .stage = 1, .status = .passed, .duration = 124 },
    .{ .name = "e2e", .stage = 1, .status = .running, .duration = 35 },
    .{ .name = "musl-tar", .stage = 2, .status = .passed, .duration = 12 },
    .{ .name = "win-zip", .stage = 2, .status = .pending },
    .{ .name = "canary", .stage = 3, .status = .pending },
    .{ .name = "smoke", .stage = 3, .status = .failed, .duration = 9, .allow_failure = true },
};

/// 引导在页面内容之后跑（它要压在所有东西之上）。
fn buildOverlays(ui: *zzui.core.Context, st: *State) void {
    if (st.page != 3 or st.tour_step < 0) return;
    const tile_id = zzui.core.Context.idOf("Export") ^ 0x9E3779B97F4A7C15;
    const steps = [_]zzui.tour.Step{
        .{ .target = tile_id, .title = "Export", .body = "Saves the current project as a zip you can share." },
        .{ .title = "That's it", .body = "A centered card with no target works too." },
    };
    _ = zzui.tour.tour(ui, "docs-tour", steps[0..], &st.tour_step, .{ .width = 280 });
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--dark")) zzui.theme.setMode(.dark);
    if (hasFlag(cmdline, "--once")) return runOnce();
    if (hasFlag(cmdline, "--shot-17")) return runShot(17);
    if (hasFlag(cmdline, "--shot-16")) return runShot(16);
    if (hasFlag(cmdline, "--shot-15")) return runShot(15);
    if (hasFlag(cmdline, "--shot-14")) return runShot(14);
    if (hasFlag(cmdline, "--shot-13")) return runShot(13);
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
    var app = zzui.App.init(.{ .title = "ZZUI docs", .width = 760, .height = 1000 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
        buildOverlays(&app.ui, &st);
        app.end();
    }
    return 0;
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(760, 1000) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    build(&app.ui, &st);
    buildOverlays(&app.ui, &st);
    app.end();
    if (app.ui.overflowed) return 8;
    zzui.bmpfile.saveBmp("zzui-docs.bmp", app.backend.pixels(), 760, 1000) catch return 4;
    return 0;
}

fn runShot(page: usize) i32 {
    var app = zzui.App.init(.{ .title = "ZZUI docs shot", .width = 760, .height = 1000, .show = false }) catch return 5;
    defer app.deinit();
    var st = State{};
    st.page = page;
    // 截图时把引导直接打开，否则只能拍到未启动的样子
    if (page == 3) st.tour_step = 0;
    var n: usize = 0;
    while (n < 3) : (n += 1) {
        if (!app.next()) return 6;
        build(&app.ui, &st);
        buildOverlays(&app.ui, &st);
        app.end();
    }
    var buf: [64]u8 = @splat(0);
    const name = shotName(buf[0..], page);
    app.saveSurface(name) catch return 7;
    return 0;
}

fn shotName(buf: []u8, page: usize) []const u8 {
    var tmp: [48]u8 = undefined;
    const base = std.fmt.bufPrint(tmp[0..], "zzui-docs-p{d}.bmp", .{page}) catch "zzui-docs.bmp";
    @memcpy(buf[0..base.len], base);
    return buf[0..base.len];
}

/// 命令行开关匹配（与 `pickers.zig` / `gallery.zig` 同口径：ASCII 直接比 u16）。
fn hasFlag(cmd: [*:0]u16, flag: []const u8) bool {
    var i: usize = 0;
    while (cmd[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < flag.len and cmd[i + j] != 0 and cmd[i + j] == @as(u16, flag[j])) : (j += 1) {}
        if (j == flag.len) return true;
    }
    return false;
}
