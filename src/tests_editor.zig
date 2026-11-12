//! 代码编辑器测试：编辑/拒绝、光标与选区、缩进、括号配对、查找、标记、goto/select。
const std = @import("std");
const core = @import("core.zig");
const editor = @import("editor.zig");
const types = @import("types.zig");

const SAMPLE = "fn main() void {\n    const x = 1;\n    // note\n    print(x);\n}\n";

fn setup(buf: []u8, src: []const u8, len: *usize) void {
    @memset(buf, 0);
    @memcpy(buf[0..src.len], src);
    len.* = src.len;
}

fn frame(ui: *core.Context, buf: []u8, len: *usize, st: *editor.EditorState, opts: editor.Opts) editor.Result {
    ui.begin(600, 500);
    var col = ui.column(.{});
    const r = editor.codeEditor(ui, "ed", buf, len, st, opts);
    col.end();
    ui.paint();
    return r;
}

/// 让编辑器拿到键盘焦点（真实界面靠点击或 Tab，单测直接指定，与 tests_media 同口径）。
fn focusEditor(ui: *core.Context) void {
    ui.focus_id = core.Context.idOf("ed");
}

/// 真实后端的一次点击是两帧：按下（pressed+down）→ 抬起（click）。
fn clickAt(ui: *core.Context, buf: []u8, len: *usize, st: *editor.EditorState, opts: editor.Opts, x: f32, y: f32) editor.Result {
    ui.input = .{ .mouse = .{ .x = x, .y = y }, .pressed = true, .down = true };
    _ = frame(ui, buf, len, st, opts);
    ui.input = .{ .mouse = .{ .x = x, .y = y }, .click = .{ .x = x, .y = y } };
    return frame(ui, buf, len, st, opts);
}

fn keyOnly(k: types.Key) [8]types.Key {
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = k;
    return keys;
}

test "editor: typing inserts at the caret and reports the position" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "ab", &len);
    var st = editor.EditorState{ .cursor = 2, .anchor = 2 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .chars = blk: {
        var c: [64]u8 = @splat(0);
        c[0] = 'c';
        break :blk c;
    }, .chars_len = 1 };
    const r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("abc", buf[0..len]);
    try std.testing.expectEqual(@as(u32, 3), r.cursor);
    try std.testing.expectEqual(@as(u32, 1), r.line);
    try std.testing.expectEqual(@as(u32, 4), r.column);
}

test "editor: backspace and delete edit around the caret" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "abc", &len);
    var st = editor.EditorState{ .cursor = 2, .anchor = 2 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .keys = keyOnly(.backspace), .key_count = 1 };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("ac", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.cursor);

    ui.input = .{ .keys = keyOnly(.delete), .key_count = 1 };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("a", buf[0..len]);
}

test "editor: an edit that does not fit is refused whole" {
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "abcd", &len);
    var st = editor.EditorState{ .cursor = 4, .anchor = 4 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .chars = blk: {
        var c: [64]u8 = @splat(0);
        c[0] = 'e';
        break :blk c;
    }, .chars_len = 1 };
    const r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expect(!r.changed);
    try std.testing.expectEqualStrings("abcd", buf[0..len]); // 满容量：一个字节都没进
}

test "editor: arrows move by line while keeping the column, Shift extends" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "abc\ndef\n", &len);
    var st = editor.EditorState{ .cursor = 1, .anchor = 1 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .keys = keyOnly(.down), .key_count = 1 };
    var r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 2), r.line);
    try std.testing.expectEqual(@as(u32, 2), r.column);
    try std.testing.expectEqual(@as(u32, 5), r.cursor);

    ui.input = .{ .keys = keyOnly(.right), .key_count = 1, .mods = .{ .shift = true } };
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 6), r.cursor);
    try std.testing.expectEqual(@as(u32, 5), r.anchor); // Shift 保持锚点

    ui.input = .{ .keys = keyOnly(.home), .key_count = 1 };
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 4), r.cursor); // 行首
}

test "editor: Enter keeps indentation and deepens after a brace" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "fn f() {", &len);
    // 光标紧跟在 '{' 后面
    var st = editor.EditorState{ .cursor = 8, .anchor = 8 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .keys = keyOnly(.enter), .key_count = 1 };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("fn f() {\n    ", buf[0..len]);

    // 已有缩进的行再回车：复制缩进
    st.cursor = len;
    st.anchor = len;
    ui.input = .{ .keys = keyOnly(.enter), .key_count = 1 };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("fn f() {\n    \n    ", buf[0..len]);
}

test "editor: selection is replaced by typing" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "hello world", &len);
    var st = editor.EditorState{ .cursor = 5, .anchor = 11 }; // 选中 " world"
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .chars = blk: {
        var c: [64]u8 = @splat(0);
        c[0] = '!';
        break :blk c;
    }, .chars_len = 1 };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("hello!", buf[0..len]);
}

test "editor: Ctrl+A selects everything and Tab indents the selection" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "a\nb\n", &len);
    var st = editor.EditorState{};
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .keys = keyOnly(.A), .key_count = 1, .mods = .{ .ctrl = true } };
    var r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 0), r.anchor);
    try std.testing.expectEqual(@as(u32, 4), r.cursor);

    ui.input = .{ .keys = keyOnly(.tab), .key_count = 1 };
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("    a\n    b\n", buf[0..len]);
}

test "editor: bracket match reports the partner" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "f(a[b])", &len);
    var st = editor.EditorState{ .cursor = 1, .anchor = 1 }; // '('
    var ui = core.Context{};
    const r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(i32, 1), r.bracket);
    try std.testing.expectEqual(@as(i32, 6), r.bracket_match);
}

test "editor: find counts matches and Enter jumps to the next one" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "one two one two one", &len);
    var st = editor.EditorState{ .cursor = 0, .anchor = 0 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    editor.find(&st, "one");
    var r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 3), r.find_matches);
    try std.testing.expectEqual(@as(u32, 1), r.find_index);

    // 焦点在编辑器上时 Enter 跳下一个（先点一下编辑器拿焦点）
    ui.input = .{ .mouse = .{ .x = 200, .y = 100 }, .pressed = true, .down = true };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    ui.input = .{ .mouse = .{ .x = 200, .y = 100 }, .click = .{ .x = 200, .y = 100 } };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    ui.input = .{ .keys = keyOnly(.enter), .key_count = 1 };
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("one", buf[@intCast(r.anchor)..@intCast(r.cursor)]);
}

test "editor: goto and select apply on the next call" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], SAMPLE, &len);
    var st = editor.EditorState{};
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    editor.gotoLine(&st, 3, 5);
    var r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 3), r.line);
    try std.testing.expectEqual(@as(u32, 5), r.column);

    editor.select(&st, 0, 2);
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 2), r.cursor);
    try std.testing.expectEqual(@as(u32, 0), r.anchor);
}

test "editor: marks and long lines stay inside the node budget" {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], SAMPLE, &len);
    var st = editor.EditorState{};
    var ui = core.Context{};
    const marks = [_]editor.TextMark{
        .{ .start = 0, .end = 2, .color = 0 },
        .{ .start = 12, .end = 17, .color = 2 },
    };
    const r = frame(&ui, buf[0..], &len, &st, .{ .marks = marks[0..], .lang = "zig" });
    try std.testing.expect(!ui.overflowed);
    try std.testing.expectEqual(@as(u32, 6), r.line_count); // 结尾换行后还有空的一行
    try std.testing.expect(ui.node_count > 10);
}

test "editor: read only refuses edits but still moves the caret" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "abc", &len);
    var st = editor.EditorState{ .cursor = 0, .anchor = 0 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{ .read_only = true });

    ui.input = .{ .keys = keyOnly(.right), .key_count = 1 };
    var r = frame(&ui, buf[0..], &len, &st, .{ .read_only = true });
    try std.testing.expectEqual(@as(u32, 1), r.cursor);

    ui.input = .{ .keys = keyOnly(.backspace), .key_count = 1 };
    r = frame(&ui, buf[0..], &len, &st, .{ .read_only = true });
    try std.testing.expect(!r.changed);
    try std.testing.expectEqualStrings("abc", buf[0..len]);
}

/// 假剪贴板（把应用侧的实现最小化，验证编辑器真的经由回调读写）。
const ClipBox = struct {
    buf: [256]u8 = @splat(0),
    len: usize = 0,

    fn getCb(ctx: ?*anyopaque, out: []u8) usize {
        const self: *ClipBox = @ptrCast(@alignCast(ctx.?));
        const n = @min(self.len, out.len);
        @memcpy(out[0..n], self.buf[0..n]);
        return n;
    }

    fn setCb(ctx: ?*anyopaque, text: []const u8) void {
        const self: *ClipBox = @ptrCast(@alignCast(ctx.?));
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        self.len = n;
    }

    fn clipboard(self: *ClipBox) core.Clipboard {
        return .{ .ctx = self, .get = getCb, .set = setCb };
    }
};

fn keyMods(k: types.Key, mods: types.Mods) types.Input {
    return .{ .keys = keyOnly(k), .key_count = 1, .mods = mods };
}

test "editor: undo and redo walk the edit log" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "ab", &len);
    var st = editor.EditorState{ .cursor = 2, .anchor = 2 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = .{ .chars = blk: {
        var c: [64]u8 = @splat(0);
        c[0] = 'c';
        break :blk c;
    }, .chars_len = 1 };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("abc", buf[0..len]);

    ui.input = keyMods(.Z, .{ .ctrl = true });
    focusEditor(&ui);
    var r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("ab", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), st.cursor);

    ui.input = keyMods(.Y, .{ .ctrl = true });
    focusEditor(&ui);
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("abc", buf[0..len]);

    // 栈空后再撤销不该崩、也不改内容
    ui.input = keyMods(.Z, .{ .ctrl = true });
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    ui.input = keyMods(.Z, .{ .ctrl = true });
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqualStrings("ab", buf[0..len]);
}

test "editor: cut and paste go through the clipboard callback" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "hello world", &len);
    var st = editor.EditorState{ .cursor = 5, .anchor = 0 };
    var ui = core.Context{};
    var clip = ClipBox{};
    const cb = clip.clipboard();
    const opts = editor.Opts{ .clipboard = &cb };
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, opts);

    ui.input = keyMods(.X, .{ .ctrl = true });
    focusEditor(&ui);
    var r = frame(&ui, buf[0..], &len, &st, opts);
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings(" world", buf[0..len]);
    try std.testing.expectEqualStrings("hello", clip.buf[0..clip.len]);

    ui.input = keyMods(.V, .{ .ctrl = true });
    focusEditor(&ui);
    r = frame(&ui, buf[0..], &len, &st, opts);
    try std.testing.expect(r.changed);
    try std.testing.expectEqualStrings("hello world", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 5), st.cursor);

    // 没有回调时 Ctrl+C/X/V 什么都不做
    ui.input = keyMods(.X, .{ .ctrl = true });
    focusEditor(&ui);
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expect(!r.changed);
    try std.testing.expectEqualStrings("hello world", buf[0..len]);
}

test "editor: ctrl+left and ctrl+right jump by word" {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], "foo bar baz", &len);
    var st = editor.EditorState{ .cursor = 0, .anchor = 0 };
    var ui = core.Context{};
    focusEditor(&ui);
    _ = frame(&ui, buf[0..], &len, &st, .{});

    ui.input = keyMods(.right, .{ .ctrl = true });
    focusEditor(&ui);
    var r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 3), r.cursor);

    ui.input = keyMods(.right, .{ .ctrl = true });
    focusEditor(&ui);
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 7), r.cursor);

    ui.input = keyMods(.left, .{ .ctrl = true });
    focusEditor(&ui);
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 4), r.cursor);

    // Shift 保持选区（anchor 不动）
    ui.input = keyMods(.right, .{ .ctrl = true, .shift = true });
    focusEditor(&ui);
    r = frame(&ui, buf[0..], &len, &st, .{});
    try std.testing.expectEqual(@as(u32, 7), r.cursor);
    try std.testing.expectEqual(@as(u32, 4), r.anchor);
}

test "editor: third click selects the whole line" {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    setup(buf[0..], SAMPLE, &len);
    var st = editor.EditorState{};
    var ui = core.Context{};
    _ = frame(&ui, buf[0..], &len, &st, .{});
    const rc = ui.lastRect(core.Context.idOf("ed")).?;
    const x = rc.x + 60;
    const y = rc.y + 3; // 第一行内（行内任一点都行）

    ui.time = 1.0;
    _ = clickAt(&ui, buf[0..], &len, &st, .{}, x, y); // 第 1 击
    ui.time = 1.1;
    var r = clickAt(&ui, buf[0..], &len, &st, .{}, x, y); // 第 2 击 = 选词
    try std.testing.expect(r.cursor > r.anchor);

    ui.time = 1.2;
    r = clickAt(&ui, buf[0..], &len, &st, .{}, x, y); // 第 3 击 = 选整行
    try std.testing.expectEqual(@as(u32, 0), r.anchor);
    const line1_end = std.mem.indexOfScalar(u8, SAMPLE, '\n').?;
    try std.testing.expectEqual(@as(u32, @intCast(line1_end + 1)), r.cursor);
}
