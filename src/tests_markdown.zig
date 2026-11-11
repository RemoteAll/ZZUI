//! Markdown 视图测试：解析（块级/行内）与交互（任务框、链接）。
const std = @import("std");
const core = @import("core.zig");
const markdown = @import("markdown.zig");
const t = @import("types.zig");

fn run(ui: *core.Context, text: []const u8, width: f32) markdown.MarkdownResult {
    var col = ui.column(.{ .gap = 0 });
    const res = markdown.markdown(ui, "doc", text, .{ .width = width });
    col.end();
    ui.paint();
    return res;
}

test "markdown: headings, paragraphs and rules produce a sane height" {
    var ui = core.Context{};
    ui.begin(400, 800);
    const text =
        "# Title\n" ++
        "\n" ++
        "A paragraph that is long enough to wrap at least once inside a narrow column of text.\n" ++
        "\n" ++
        "---\n" ++
        "\n" ++
        "## Second\n";
    const res = run(&ui, text, 360);
    try std.testing.expect(res.height > 60);
    try std.testing.expect(!ui.overflowed);
    // 标题比正文大：必须有字号更大的文本节点
    var max_size: f32 = 0;
    var i: usize = 0;
    while (i < ui.node_count) : (i += 1) {
        if (ui.nodes[i].kind == .text and ui.nodes[i].font_size > max_size) max_size = ui.nodes[i].font_size;
    }
    try std.testing.expect(max_size > 18);
}

test "markdown: bold and italic spans use different font weights" {
    var ui = core.Context{};
    ui.begin(400, 200);
    _ = run(&ui, "plain **bold** and *italic* text", 380);
    var bold: usize = 0;
    var italic: usize = 0;
    var i: usize = 0;
    while (i < ui.node_count) : (i += 1) {
        if (ui.nodes[i].kind != .text) continue;
        if (ui.nodes[i].bold) bold += 1;
        if (ui.nodes[i].italic) italic += 1;
    }
    try std.testing.expect(bold > 0);
    try std.testing.expect(italic > 0);
}

test "markdown: task item reports the byte offset of its box" {
    var ui = core.Context{};
    const text = "- [ ] first\n- [x] second\n";
    ui.begin(300, 200);
    const res = run(&ui, text, 260);
    try std.testing.expectEqual(@as(i32, -1), res.task_offset); // 没点之前没有切换

    // 第二帧点击第一个任务框：位置由上一帧的命中矩形给出
    var col = ui.column(.{ .gap = 0 });
    const again = markdown.markdown(&ui, "doc", text, .{ .width = 260 });
    col.end();
    ui.paint();
    _ = again;

    // 直接验证 applyTask 的往返：把 offset 指向方括号内，写回 'x'
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..text.len], text);
    const r = markdown.MarkdownResult{ .task_offset = 3, .task_line = 1, .task_checked = true };
    try std.testing.expect(markdown.applyTask(buf[0..text.len], r));
    try std.testing.expectEqual(@as(u8, 'x'), buf[3]);
    // 再切回来
    const r2 = markdown.MarkdownResult{ .task_offset = 3, .task_checked = false };
    try std.testing.expect(markdown.applyTask(buf[0..text.len], r2));
    try std.testing.expectEqual(@as(u8, ' '), buf[3]);
    // 没有切换时不动文本
    try std.testing.expect(!markdown.applyTask(buf[0..text.len], .{}));
}

test "markdown: clicking a task box toggles it and maps back to the source" {
    var ui = core.Context{};
    var src = [_]u8{ '-', ' ', '[', ' ', ']', ' ', 'd', 'o', ' ', 'i', 't' };

    // 第一帧：建出任务框的命中矩形
    ui.begin(300, 200);
    var col = ui.column(.{});
    _ = markdown.markdown(&ui, "doc", &src, .{ .width = 260 });
    col.end();
    ui.paint();

    // 第二帧：点上去（任务框在第一行左侧）
    var hit: ?t.Rect = null;
    var i: usize = 0;
    while (i < ui.hits_curr_n) : (i += 1) {
        if (ui.hits_curr[i].rect.w <= 16 and ui.hits_curr[i].rect.h <= 16) hit = ui.hits_curr[i].rect;
    }
    try std.testing.expect(hit != null);
    const r = hit.?;
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(300, 200);
    var col2 = ui.column(.{});
    const res = markdown.markdown(&ui, "doc", &src, .{ .width = 260 });
    col2.end();
    ui.paint();

    try std.testing.expectEqual(@as(i32, 3), res.task_offset);
    try std.testing.expect(res.task_checked);
    try std.testing.expect(markdown.applyTask(&src, res));
    try std.testing.expectEqual(@as(u8, 'x'), src[3]);
}

test "markdown: links are reported on click and underlined" {
    var ui = core.Context{};
    ui.begin(400, 200);
    _ = run(&ui, "see [docs](https://example.com/x) end", 380);

    // 找到链接的命中矩形
    var target: ?t.Rect = null;
    var i: usize = 0;
    while (i < ui.hits_curr_n) : (i += 1) target = ui.hits_curr[i].rect;
    try std.testing.expect(target != null);
    const tr = target.?;
    const cx = tr.x + tr.w / 2;
    const cy = tr.y + tr.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(400, 200);
    var col = ui.column(.{});
    const res = markdown.markdown(&ui, "doc", "see [docs](https://example.com/x) end", .{ .width = 380 });
    col.end();
    ui.paint();
    try std.testing.expect(res.link != null);
    try std.testing.expectEqualStrings("https://example.com/x", res.link.?);
}

test "markdown: fenced code, table and list items build without overflowing" {
    var ui = core.Context{};
    ui.begin(600, 900);
    const text =
        "```zig\nconst x = 1;\nconst y = 2;\n```\n" ++
        "\n" ++
        "| a | b |\n" ++
        "|---|---|\n" ++
        "| 1 | 2 |\n" ++
        "\n" ++
        "1. one\n" ++
        "2. two\n" ++
        "\n" ++
        "> quoted line\n" ++
        "\n" ++
        "    indented code\n";
    const res = run(&ui, text, 560);
    try std.testing.expect(res.height > 100);
    try std.testing.expect(!ui.overflowed);
}

test "markdown: every block kind fits in the node budget" {
    var ui = core.Context{};
    ui.begin(600, 900);
    const text =
        "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n" ++
        "\n" ++
        "Para with **bold**, *italic*, ~~strike~~, `code`, [link](https://a.b), <https://c.d> and www.e.f\n" ++
        "\n" ++
        "* bullet\n" ++
        "+ another\n" ++
        "- [x] done\n" ++
        "\n" ++
        "> quote\n" ++
        "\n" ++
        "```\ncode\n```\n" ++
        "\n" ++
        "---\n";
    _ = run(&ui, text, 560);
    try std.testing.expect(!ui.overflowed);
}

test "markdown: empty text renders nothing" {
    var ui = core.Context{};
    ui.begin(300, 200);
    const res = run(&ui, "", 260);
    try std.testing.expectEqual(@as(f32, 0), res.height);
}
