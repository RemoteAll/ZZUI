//! 文档与可视化族示例：markdown / diff / 火焰图（三页）。
//! 单独一个产物是为了**体积分账**：几族代码约 34 KB，塞进 gallery 会把那个产物顶穿
//! 335 KB 门槛（实测 gallery 13 页 334,336 B 时再挂 markdown + diff → 366,080 B）。
//!
//! `--once` 无窗口渲染第 0 页；`--shot-0` / `--shot-1` / `--shot-2` 用隐藏窗口真渲染对应页。
const std = @import("std");
const zzui = @import("zzui");

const page_names = [_][]const u8{ "Markdown", "Diff", "Flame", "Tour", "Regex", "Files", "Trace", "Editor" };

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
    re_pattern: [32]u8 = @splat(0),
    re_pattern_len: usize = 0,
    re_caret: usize = 0,
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
};

/// 正则测试器的样本文本。
const re_sample =
    "Release 2.4 (2026-11-11)\n" ++
    "Contact: dev@example.com or ops@example.com\n" ++
    "Build: zig build -Doptimize=ReleaseSmall\n" ++
    "Tag: v2.4.0, commit 91cbf17\n";

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

/// 一次页面加载的请求（含一条 404）。
const net_requests = [_]zzui.trace.NetRequest{
    .{ .name = "/index.html", .method = "GET", .status = 200, .type = "document", .size = 8_412, .start = 0.00, .timing = .{ 0, 0.012, 0.028, 0.052, 0.120, 0.045 } },
    .{ .name = "/app.js", .method = "GET", .status = 200, .type = "script", .size = 96_512, .start = 0.24, .timing = .{ 0.02, 0, 0.030, 0.046, 0.085, 0.140 } },
    .{ .name = "/app.css", .method = "GET", .status = 200, .type = "stylesheet", .size = 12_880, .start = 0.26, .timing = .{ 0.01, 0, 0.026, 0.040, 0.062, 0.038 } },
    .{ .name = "/api/session", .method = "POST", .status = 201, .type = "json", .size = 640, .start = 0.62, .timing = .{ 0, 0, 0.024, 0.044, 0.210, 0.012 } },
    .{ .name = "/logo.png", .method = "GET", .status = 404, .type = "image", .size = 0, .start = 0.88, .timing = .{ 0, 0.010, 0.022, 0.038, 0.048, 0.004 } },
    .{ .name = "/fonts/inter.woff2", .method = "GET", .status = 200, .type = "font", .size = 34_208, .start = 1.05, .timing = .{ 0.02, 0, 0.034, 0.052, 0.076, 0.126 } },
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
        zzui.extras.muted(ui, "Regex: type a pattern, the first match is reported");
        _ = zzui.widgets.input(ui, "pattern", &st.re_pattern, &st.re_pattern_len, &st.re_caret, .{ .placeholder = "\\w+@\\w+" });
        const pat = st.re_pattern[0..st.re_pattern_len];
        var m = zzui.regex.Match{};
        const r = zzui.regex.search(pat, zzui.regex.ICASE, re_sample, 0, &m, null);
        switch (r) {
            .invalid_pattern => zzui.extras.badge(ui, "invalid pattern", .danger),
            .none => zzui.extras.muted(ui, "no match"),
            .too_slow => zzui.extras.badge(ui, "too slow", .warn),
            .found => {
                zzui.widgets.textInt(ui, "first match at ", @intCast(m.start), "");
                if (m.start >= 0 and m.end > m.start) {
                    zzui.extras.code(ui, re_sample[@intCast(m.start)..@intCast(m.end)]);
                }
                if (m.groups > 0) zzui.widgets.textInt(ui, "groups = ", @intCast(m.groups), "");
            },
        }
        zzui.widgets.separator(ui);
        _ = ui.textRun(re_sample, zzui.theme.font_body, zzui.theme.secondary);
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
