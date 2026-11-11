//! 文档族示例：markdown 视图 + 差异视图（两页）。
//! 单独一个产物是为了**体积分账**：两族代码约 30 KB，塞进 gallery 会把那个产物顶穿
//! 335 KB 门槛（实测 gallery 13 页 335,104 B 时再挂 markdown + diff → 366,080 B）。
//!
//! `--once` 无窗口渲染第 0 页；`--shot-0` / `--shot-1` 用隐藏窗口真渲染对应页。
const std = @import("std");
const zzui = @import("zzui");

const page_names = [_][]const u8{ "Markdown", "Diff" };

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
    } else {
        const r = zzui.diff.diffView(ui, "dv", diff_old, diff_new, &st.diff_current, .{
            .old_title = "before.zig",
            .new_title = "after.zig",
            .height = 260,
        });
        zzui.widgets.textInt(ui, "changes = ", @intCast(r.changes), "");
        zzui.widgets.textInt(ui, "current = ", @intCast(@max(r.current, 0)), "");
    }
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--dark")) zzui.theme.setMode(.dark);
    if (hasFlag(cmdline, "--once")) return runOnce();
    if (hasFlag(cmdline, "--shot-1")) return runShot(1);
    if (hasFlag(cmdline, "--shot")) return runShot(0);

    var st = State{};
    var app = zzui.App.init(.{ .title = "ZZUI docs", .width = 760, .height = 1000 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        build(&app.ui, &st);
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
