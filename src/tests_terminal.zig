//! 终端：写入解析（换行 / 回车重写 / 制表 / 退格 / SGR）、环形缓冲与折行、视图交互、
//! 选区复制、历史与命令回显。
const std = @import("std");
const core = @import("core.zig");
const terminal = @import("terminal.zig");
const types = @import("types.zig");

const Fixture = struct {
    text: [512]u8 = @splat(0),
    lines: [8]terminal.Line = @splat(.{}),
    buf: terminal.Buffer = .{},
    st: terminal.State = .{},
    ui: core.Context = .{},

    fn initTerm(self: *Fixture) void {
        terminal.init(&self.buf, &self.text, &self.lines);
    }

    fn lineText(self: *Fixture, i: u32) []const u8 {
        const L = self.lines[(self.buf.first + i) % self.lines.len];
        return self.text[L.offset .. L.offset + L.len];
    }

    fn frame(self: *Fixture, opts: terminal.Opts) terminal.Result {
        self.ui.begin(700, 500);
        const r = terminal.terminal(&self.ui, "term", &self.buf, &self.st, opts);
        self.ui.paint();
        return r;
    }
};

test "terminal: newlines start new lines and each line counts its columns" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "hello\nworld");
    try std.testing.expectEqual(@as(u32, 2), f.buf.count);
    try std.testing.expectEqualStrings("hello", f.lineText(0));
    try std.testing.expectEqualStrings("world", f.lineText(1));
    try std.testing.expectEqual(@as(u32, 5), f.lines[0].cols);
    try std.testing.expectEqual(@as(u32, 5), f.lines[1].cols);
}

test "terminal: carriage return rewrites the current line in place" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "10%\r50%\r100%");
    try std.testing.expectEqual(@as(u32, 1), f.buf.count);
    try std.testing.expectEqualStrings("100%", f.lineText(0));
    try std.testing.expectEqual(@as(u32, 4), f.lines[0].cols);
}

test "terminal: tab advances to the next multiple of eight columns" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "ab\tc");
    try std.testing.expectEqualStrings("ab      c", f.lineText(0));
    try std.testing.expectEqual(@as(u32, 9), f.lines[0].cols);
}

test "terminal: backspace removes one plain ASCII byte" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "abc\x08d");
    try std.testing.expectEqualStrings("abd", f.lineText(0));
    // 多字节行不做退格（删半个字更糟）
    terminal.write(&f.buf, "\n你好\x08");
    try std.testing.expectEqualStrings("你好", f.lineText(1));
}

test "terminal: SGR stays in the text but adds no columns" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "\x1b[31mred\x1b[0m.");
    try std.testing.expectEqual(@as(u32, 4), f.lines[0].cols);
    try std.testing.expectEqualStrings("\x1b[31mred\x1b[0m.", f.lineText(0));
    // 折行/宽度计算只看可见列
    const shown = terminal.copySelection(&f.buf, .{ .line = f.buf.total - 1, .col = 0 }, .{ .line = f.buf.total - 1, .col = 4 }, &[_]u8{});
    try std.testing.expectEqual(@as(usize, 0), shown);
}

test "terminal: an escape sequence split across two writes is still parsed" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "a\x1b[3");
    terminal.write(&f.buf, "1mb");
    try std.testing.expectEqualStrings("a\x1b[31mb", f.lineText(0));
    try std.testing.expectEqual(@as(u32, 2), f.lines[0].cols);
}

test "terminal: OSC sequences are dropped and do not join the line" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "x\x1b]0;title\x07y");
    try std.testing.expectEqualStrings("xy", f.lineText(0));
}

test "terminal: CSI 2J clears the buffer" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "one\ntwo");
    try std.testing.expectEqual(@as(u32, 2), f.buf.count);
    terminal.write(&f.buf, "\x1b[2J");
    try std.testing.expectEqual(@as(u32, 1), f.buf.count);
    try std.testing.expectEqual(@as(u32, 0), f.lines[0].len);
}

test "terminal: the ring drops the oldest line when the line table is full" {
    var f = Fixture{};
    f.initTerm();
    var k: usize = 0;
    while (k < 12) : (k += 1) terminal.print(&f.buf, "{d}\n", .{k});
    try std.testing.expect(f.buf.count <= f.lines.len);
    // 最后一行仍是 "11"（末尾那个 \n 已经起了一行空的）
    try std.testing.expectEqualStrings("11", f.lineText(f.buf.count - 2));
}

test "terminal: the text buffer wraps instead of overflowing" {
    var f = Fixture{};
    f.initTerm();
    // 每行 40 字符，512 字节的缓冲装不下所有行 → 老行被丢，但不越界
    var k: usize = 0;
    while (k < 40) : (k += 1) {
        terminal.write(&f.buf, "0123456789012345678901234567890123456789\n");
    }
    try std.testing.expect(f.buf.end <= f.text.len);
    var i: u32 = 0;
    while (i < f.buf.count) : (i += 1) {
        const L = f.lines[(f.buf.first + i) % f.lines.len];
        try std.testing.expect(L.offset + L.len <= f.text.len);
        // 末尾那个 \n 起了一行空的，跳过它
        if (i + 1 < f.buf.count) try std.testing.expectEqual(@as(u32, 40), L.cols);
    }
}

test "terminal: clear resets the buffer and keeps the total counter moving" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "a\nb\nc");
    const before = f.buf.total;
    terminal.clear(&f.buf);
    try std.testing.expectEqual(@as(u32, 1), f.buf.count);
    try std.testing.expect(f.buf.total > before);
    try std.testing.expectEqual(@as(u32, 0), f.buf.end);
}

test "terminal: copySelection joins lines and leaves escapes out" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "\x1b[32mab\x1b[0m\ncd\nef");
    var out: [64]u8 = @splat(0);
    const first = f.buf.total - f.buf.count;
    const n = terminal.copySelection(&f.buf, .{ .line = first, .col = 1 }, .{ .line = first + 1, .col = 2 }, out[0..]);
    try std.testing.expectEqualStrings("b\ncd", out[0..n]);
}

test "terminal: the view renders output and an echoed command" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "ready\n");
    const r1 = f.frame(.{});
    try std.testing.expect(!f.ui.overflowed);
    try std.testing.expect(r1.command == null);

    // 输入行拿到焦点后回车：回显 + 返回命令
    f.ui.focus_id = core.Context.idOf("term-input") ^ 0x7FEB352D ^ core.Context.idOf("term");
    const cmd = "zig build";
    @memcpy(f.st.input[0..cmd.len], cmd);
    f.st.input_len = cmd.len;
    f.st.input[cmd.len] = 0;
    f.st.caret = cmd.len;
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .enter;
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    const r2 = f.frame(.{});
    try std.testing.expect(r2.command != null);
    try std.testing.expectEqualStrings("zig build", r2.command.?);
    try std.testing.expectEqual(@as(usize, 1), f.st.hn);
    try std.testing.expectEqual(@as(usize, 0), f.st.input_len);
    // 回显进了缓冲区（提示符 + 命令）
    const last = f.lineText(f.buf.count - 2);
    try std.testing.expect(std.mem.endsWith(u8, last, "zig build"));
    try std.testing.expect(std.mem.indexOf(u8, last, "$ ") != null);
}

test "terminal: up and down walk the history" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "> ");
    f.ui.focus_id = core.Context.idOf("term-input") ^ 0x7FEB352D ^ core.Context.idOf("term");
    var keys: [8]types.Key = @splat(.unknown);

    // 两条历史
    const cmds = [_][]const u8{ "first", "second" };
    for (cmds) |c| {
        @memcpy(f.st.input[0..c.len], c);
        f.st.input_len = c.len;
        f.st.input[c.len] = 0;
        f.st.caret = c.len;
        keys[0] = .enter;
        f.ui.input = .{ .keys = keys, .key_count = 1 };
        _ = f.frame(.{});
    }
    try std.testing.expectEqual(@as(usize, 2), f.st.hn);

    keys[0] = .up;
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    _ = f.frame(.{});
    try std.testing.expectEqualStrings("second", f.st.input[0..f.st.input_len]);
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    _ = f.frame(.{});
    try std.testing.expectEqualStrings("first", f.st.input[0..f.st.input_len]);
    keys[0] = .down;
    f.ui.input = .{ .keys = keys, .key_count = 1 };
    _ = f.frame(.{});
    try std.testing.expectEqualStrings("second", f.st.input[0..f.st.input_len]);
}

test "terminal: choosing text and pressing ctrl+c hands the copy to the caller" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "alpha\nbeta\ngamma");
    _ = f.frame(.{});
    // 直接把选区设上（真实界面靠拖拽建立）
    const first = f.buf.total - f.buf.count;
    f.st.a = .{ .line = first, .col = 2 };
    f.st.b = .{ .line = first + 1, .col = 2 };
    f.st.has_sel = true;
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .C;
    f.ui.input = .{ .keys = keys, .key_count = 1, .mods = .{ .ctrl = true } };
    const r = f.frame(.{});
    try std.testing.expect(r.copy != null);
    try std.testing.expectEqualStrings("pha\nbe", r.copy.?);
    try std.testing.expect(!f.st.has_sel);
}

test "terminal: ctrl+c without a selection reports an interrupt and echoes ^C" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "running\n");
    _ = f.frame(.{});
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .C;
    f.ui.input = .{ .keys = keys, .key_count = 1, .mods = .{ .ctrl = true } };
    const r = f.frame(.{});
    try std.testing.expect(r.interrupt);
    try std.testing.expectEqualStrings("^C", f.lineText(f.buf.count - 2));
}

test "terminal: ctrl+l clears the output" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "noise\nnoise\nnoise");
    _ = f.frame(.{});
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .L;
    f.ui.input = .{ .keys = keys, .key_count = 1, .mods = .{ .ctrl = true } };
    _ = f.frame(.{});
    try std.testing.expectEqual(@as(u32, 1), f.buf.count);
    try std.testing.expectEqual(@as(u32, 0), f.lines[0].len);
}

test "terminal: output only mode has no input row" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "only output");
    const r = f.frame(.{ .no_input = true });
    try std.testing.expect(r.command == null);
    try std.testing.expect(!f.ui.overflowed);
}

test "terminal: many colored lines still fit the node budget" {
    var f = Fixture{};
    f.initTerm();
    var k: usize = 0;
    while (k < 30) : (k += 1) {
        terminal.print(&f.buf, "\x1b[32mok\x1b[0m \x1b[1;31mFAIL\x1b[0m line {d}\n", .{k});
    }
    _ = f.frame(.{ .height = 200 });
    try std.testing.expect(!f.ui.overflowed);
}

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

test "terminal: ctrl+c writes the selection to the clipboard" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "alpha\nbeta");
    _ = f.frame(.{});
    var clip = ClipBox{};
    const cb = clip.clipboard();

    const first = f.buf.total - f.buf.count;
    f.st.a = .{ .line = first, .col = 0 };
    f.st.b = .{ .line = first, .col = 5 };
    f.st.has_sel = true;
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .C;
    f.ui.input = .{ .keys = keys, .key_count = 1, .mods = .{ .ctrl = true } };
    const r = f.frame(.{ .clipboard = &cb });
    try std.testing.expect(r.copy != null);
    try std.testing.expectEqualStrings("alpha", clip.buf[0..clip.len]);
}

test "terminal: ctrl+v pastes the clipboard into the input line" {
    var f = Fixture{};
    f.initTerm();
    terminal.write(&f.buf, "$ ");
    _ = f.frame(.{});
    var clip = ClipBox{};
    @memcpy(clip.buf[0..8], "zig test");
    clip.len = 8;
    const cb = clip.clipboard();

    // 光标在输入行中间：粘进去要插在光标处
    @memcpy(f.st.input[0..2], "ab");
    f.st.input_len = 2;
    f.st.input[2] = 0;
    f.st.caret = 1;
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = .V;
    f.ui.input = .{ .keys = keys, .key_count = 1, .mods = .{ .ctrl = true } };
    _ = f.frame(.{ .clipboard = &cb });
    try std.testing.expectEqualStrings("azig testb", f.st.input[0..f.st.input_len]);
    try std.testing.expectEqual(@as(usize, 9), f.st.caret);

    // 自带缓冲区满时不写越界（cap - 1 之后丢弃）
    f.st.input_len = f.st.input.len - 2;
    f.st.caret = f.st.input_len;
    f.ui.input = .{ .keys = keys, .key_count = 1, .mods = .{ .ctrl = true } };
    _ = f.frame(.{ .clipboard = &cb });
    try std.testing.expectEqual(f.st.input.len - 1, f.st.input_len);
}
