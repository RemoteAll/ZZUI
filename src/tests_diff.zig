//! 差异视图测试：差分正确性（行级）与视图交互（折叠、选中变更块）。
const std = @import("std");
const core = @import("core.zig");
const diff = @import("diff.zig");

fn view(
    ui: *core.Context,
    old_text: []const u8,
    new_text: []const u8,
    current: ?*i32,
    opts: diff.DiffOpts,
) diff.DiffResult {
    var col = ui.column(.{ .gap = 0 });
    const res = diff.diffView(ui, "dv", old_text, new_text, current, opts);
    col.end();
    ui.paint();
    return res;
}

test "diff: identical texts report no changes" {
    var ui = core.Context{};
    ui.begin(800, 600);
    const txt = "alpha\nbeta\ngamma\n";
    const res = view(&ui, txt, txt, null, .{ .width = 780 });
    try std.testing.expectEqual(@as(usize, 0), res.added);
    try std.testing.expectEqual(@as(usize, 0), res.removed);
    try std.testing.expectEqual(@as(usize, 0), res.changes);
    // 全是未变行：整段折成一行（未变行不留着占屏）
    try std.testing.expectEqual(@as(usize, 1), res.folds);
    try std.testing.expectEqual(@as(usize, 3), res.hidden);
}

test "diff: one changed line counts as one change with context kept" {
    var ui = core.Context{};
    ui.begin(800, 600);
    const a = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n";
    const b = "l1\nl2\nl3\nl4\nl5\nCHANGED\nl7\nl8\nl9\nl10\n";
    const res = view(&ui, a, b, null, .{ .width = 780 });
    try std.testing.expectEqual(@as(usize, 1), res.added);
    try std.testing.expectEqual(@as(usize, 1), res.removed);
    try std.testing.expectEqual(@as(usize, 1), res.changes);
    // 前后各 3 行 context；l1/l2 与 l9/l10 应被折叠
    try std.testing.expect(res.folds > 0);
    try std.testing.expect(res.hidden > 0);
}

test "diff: pure insertion and pure deletion" {
    var ui = core.Context{};
    ui.begin(800, 600);
    const a = "a\nb\nc\n";
    const b = "a\nnew\nb\nc\n";
    const r1 = view(&ui, a, b, null, .{ .width = 780, .no_fold = true });
    try std.testing.expectEqual(@as(usize, 1), r1.added);
    try std.testing.expectEqual(@as(usize, 0), r1.removed);

    const r2 = view(&ui, b, a, null, .{ .width = 780, .no_fold = true });
    try std.testing.expectEqual(@as(usize, 0), r2.added);
    try std.testing.expectEqual(@as(usize, 1), r2.removed);
}

test "diff: unified mode is used when the view is narrow" {
    var ui = core.Context{};
    ui.begin(320, 600);
    const res = view(&ui, "a\nb\n", "a\nc\n", null, .{ .width = 300, .split_min_width = 560 });
    try std.testing.expectEqual(diff.DiffMode.unified, res.mode);

    var ui2 = core.Context{};
    ui2.begin(800, 600);
    const res2 = view(&ui2, "a\nb\n", "a\nc\n", null, .{ .width = 780, .split_min_width = 560 });
    try std.testing.expectEqual(diff.DiffMode.split, res2.mode);
}

test "diff: clicking a change row selects it and writes back current" {
    var ui = core.Context{};
    var cur: i32 = -1;
    const a = "a\nb\nc\n";
    const b = "a\nX\nc\n";

    // 第一帧：建行
    ui.begin(800, 400);
    _ = view(&ui, a, b, &cur, .{ .width = 780, .no_fold = true });

    // 找变更行的命中矩形（宽度接近整行、且带有 change id 的那批）
    var target: ?@import("types.zig").Rect = null;
    var i: usize = 0;
    while (i < ui.hits_curr_n) : (i += 1) {
        const r = ui.hits_curr[i].rect;
        if (r.w > 100 and r.h < 30 and r.y > 0) target = r;
    }
    try std.testing.expect(target != null);
    const tr = target.?;
    const cx = tr.x + 20;
    const cy = tr.y + tr.h / 2;

    ui.input = .{ .mouse = .{ .x = cx, .y = cy }, .click = .{ .x = cx, .y = cy } };
    ui.begin(800, 400);
    const res = view(&ui, a, b, &cur, .{ .width = 780, .no_fold = true });
    try std.testing.expectEqual(@as(i32, 0), cur);
    try std.testing.expectEqual(@as(i32, 0), res.current);
    try std.testing.expect(res.current_changed);
}

test "diff: big middle sections fall back to a whole-block replace" {
    var ui = core.Context{};
    ui.begin(800, 600);
    // 200 行全不同：中间段超过 MAX_MID，退化成整块替换（approximate）
    var a_buf: [2048]u8 = undefined;
    var b_buf: [2048]u8 = undefined;
    var al: usize = 0;
    var bl: usize = 0;
    var k: usize = 0;
    while (k < 150) : (k += 1) {
        const na = std.fmt.bufPrint(a_buf[al..], "old {d}\n", .{k}) catch break;
        al += na.len;
        const nb = std.fmt.bufPrint(b_buf[bl..], "new {d}\n", .{k}) catch break;
        bl += nb.len;
    }
    const res = view(&ui, a_buf[0..al], b_buf[0..bl], null, .{ .width = 780 });
    try std.testing.expect(res.approximate);
    try std.testing.expectEqual(@as(usize, 150), res.removed);
    try std.testing.expectEqual(@as(usize, 150), res.added);
    // 只画视口内的行：300 个对齐行不会把节点预算打爆
    try std.testing.expect(!ui.overflowed);
}

test "diff: crlf lines compare equal to lf" {
    var ui = core.Context{};
    ui.begin(800, 400);
    const res = view(&ui, "a\r\nb\r\n", "a\nb\n", null, .{ .width = 780, .ignore_eol = true });
    try std.testing.expectEqual(@as(usize, 0), res.changes);
}

test "diff: words marks the changed words of a line pair" {
    var ra: [diff.MAX_WORD_MARKS]diff.WordRange = undefined;
    var rb: [diff.MAX_WORD_MARKS]diff.WordRange = undefined;
    var na: usize = 0;
    var nb: usize = 0;
    const a = "the quick brown fox";
    const b = "the slow brown fox";
    try std.testing.expect(diff.words(a, b, ra[0..], &na, rb[0..], &nb));
    try std.testing.expectEqual(@as(usize, 1), na);
    try std.testing.expectEqual(@as(usize, 1), nb);
    const oa = a[@intCast(ra[0].start)..][0..@intCast(ra[0].length)];
    const ob = b[@intCast(rb[0].start)..][0..@intCast(rb[0].length)];
    try std.testing.expectEqualStrings("quick", oa);
    try std.testing.expectEqualStrings("slow", ob);
}

test "diff: words merges adjacent marks and rejects unrelated lines" {
    var ra: [diff.MAX_WORD_MARKS]diff.WordRange = undefined;
    var rb: [diff.MAX_WORD_MARKS]diff.WordRange = undefined;
    var na: usize = 0;
    var nb: usize = 0;
    const a = "alpha beta";
    const b = "alpha gamma delta";
    try std.testing.expect(diff.words(a, b, ra[0..], &na, rb[0..], &nb));
    try std.testing.expectEqual(@as(usize, 1), na);
    try std.testing.expectEqual(@as(usize, 1), nb);
    try std.testing.expectEqualStrings("beta", a[@intCast(ra[0].start)..][0..@intCast(ra[0].length)]);
    try std.testing.expectEqualStrings("gamma delta", b[@intCast(rb[0].start)..][0..@intCast(rb[0].length)]);

    var c: [4096]u8 = undefined;
    var d: [4096]u8 = undefined;
    @memset(c[0..], 'a');
    @memset(d[0..], 'b');
    try std.testing.expect(!diff.words("abc", "xyz", ra[0..], &na, rb[0..], &nb));
    try std.testing.expect(!diff.words(c[0..], d[0..], ra[0..], &na, rb[0..], &nb));
}

test "diff: viewRows exposes folded rows and split pairs" {
    const a = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n";
    const b = "l1\nl2\nl3\nl4\nl5\nCHANGED\nl7\nl8\nl9\nl10\n";
    var out: [32]diff.ViewRow = undefined;
    const n = diff.viewRows(a, b, .{ .context = 1, .mode = .split }, out[0..], 0);
    try std.testing.expect(n > 4);
    try std.testing.expectEqual(diff.RowKind.fold, out[0].kind);
    try std.testing.expectEqual(@as(usize, 4), out[0].hidden);
    var saw_changed = false;
    var saw_fold2 = false;
    var k: usize = 0;
    while (k < @min(n, out.len)) : (k += 1) {
        if (out[k].kind == .changed) {
            saw_changed = true;
            try std.testing.expectEqual(@as(i32, 5), out[k].old_line);
            try std.testing.expectEqual(@as(i32, 5), out[k].new_line);
            try std.testing.expectEqual(@as(i32, 0), out[k].change);
        }
        if (k > 0 and out[k].kind == .fold) saw_fold2 = true;
    }
    try std.testing.expect(saw_changed);
    try std.testing.expect(saw_fold2);

    // first/cap 游标：只拷贝请求的一段
    var one: [1]diff.ViewRow = undefined;
    _ = diff.viewRows(a, b, .{ .context = 1, .mode = .split }, one[0..], 1);
    try std.testing.expectEqual(diff.RowKind.same, one[0].kind);
}

test "diff: unified rows keep the added line beside the removed one" {
    var out: [8]diff.ViewRow = undefined;
    const n = diff.viewRows("a\nb\nc\n", "a\nX\nc\n", .{ .no_fold = true, .mode = .unified }, out[0..], 0);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(diff.RowKind.same, out[0].kind);
    try std.testing.expectEqual(diff.RowKind.removed, out[1].kind);
    try std.testing.expectEqual(diff.RowKind.added, out[2].kind);
    try std.testing.expectEqual(diff.RowKind.same, out[3].kind);
}

test "diff: unified mode draws both sides of a replaced line" {
    var ui = core.Context{};
    ui.begin(320, 400);
    const res = view(&ui, "a\nb\nc\n", "a\nX\nc\n", null, .{
        .width = 300,
        .split_min_width = 560,
        .no_fold = true,
    });
    try std.testing.expectEqual(diff.DiffMode.unified, res.mode);
    try std.testing.expectEqual(@as(usize, 4), res.rows);
    try std.testing.expectEqual(@as(usize, 1), res.added);
    try std.testing.expectEqual(@as(usize, 1), res.removed);
}

test "diff: word marks draw inside the changed line budget" {
    var ui = core.Context{};
    ui.begin(800, 400);
    const a = "fn main() void {\n    const value = compute(alpha);\n}\n";
    const b = "fn main() void {\n    const value = compute(beta, gamma);\n}\n";
    const res = view(&ui, a, b, null, .{ .width = 780, .no_fold = true });
    try std.testing.expectEqual(@as(usize, 1), res.changes);
    try std.testing.expect(!ui.overflowed);
}
