//! 正则测试器：计数 / 分组 / 非法模式 / 开关 / 签名缓存 / 空匹配推进 / 上限 / 列表排版。
const std = @import("std");
const core = @import("core.zig");
const regex = @import("regex.zig");
const regextester = @import("regextester.zig");

fn setup(buf: []u8, src: []const u8, len: *usize) void {
    @memset(buf, 0);
    @memcpy(buf[0..src.len], src);
    len.* = src.len;
}

const Case = struct {
    ui: core.Context = .{},
    pattern: [64]u8 = @splat(0),
    pattern_len: usize = 0,
    caret: usize = 0,
    text: [256]u8 = @splat(0),
    text_len: usize = 0,
    st: regextester.TesterState = .{},

    fn frame(self: *Case, opts: regextester.Opts) regextester.Result {
        self.ui.begin(600, 600);
        var col = self.ui.column(.{});
        const r = regextester.tester(
            &self.ui,
            "rt",
            self.pattern[0..],
            &self.pattern_len,
            &self.caret,
            self.text[0..],
            &self.text_len,
            &self.st,
            opts,
        );
        col.end();
        self.ui.paint();
        return r;
    }
};

fn make(pat: []const u8, text: []const u8) Case {
    var c = Case{};
    setup(c.pattern[0..], pat, &c.pattern_len);
    setup(c.text[0..], text, &c.text_len);
    return c;
}

test "regextester: no pattern means no matches and no error" {
    var c = make("", "abc");
    const r = c.frame(.{});
    try std.testing.expect(r.valid);
    try std.testing.expectEqual(@as(u32, 0), r.matches);
    try std.testing.expect(r.err == null);
}

test "regextester: counts every match of a simple pattern" {
    var c = make("\\d+", "a1 b22 c333");
    const r = c.frame(.{});
    try std.testing.expect(r.valid);
    try std.testing.expectEqual(@as(u32, 3), r.matches);
    try std.testing.expect(!r.more);
    try std.testing.expectEqual(@as(i32, 1), c.st.hits[0].start);
    try std.testing.expectEqual(@as(i32, 2), c.st.hits[0].end);
    try std.testing.expectEqual(@as(i32, 4), c.st.hits[1].start);
    try std.testing.expectEqual(@as(i32, 6), c.st.hits[1].end);
}

test "regextester: reports capture groups and their spans" {
    var c = make("(?<user>[a-z]+)@(?<host>[a-z.]+)", "ping a@b.cn and cc@dd.io");
    const r = c.frame(.{});
    try std.testing.expectEqual(@as(u32, 2), r.matches);
    try std.testing.expectEqual(@as(usize, 2), c.st.groups);
    // 名字是 0 基数组：第 1 组在 [0]
    try std.testing.expectEqualStrings("user", std.mem.sliceTo(&c.st.names[0], 0));
    try std.testing.expectEqualStrings("host", std.mem.sliceTo(&c.st.names[1], 0));
    // 第一处命中：a@b.cn → 整体 [5,11)；分组数组 0 基：组 1 [5,6)、组 2 [7,11)
    const h = c.st.hits[0];
    try std.testing.expectEqual(@as(i32, 5), h.start);
    try std.testing.expectEqual(@as(i32, 11), h.end);
    try std.testing.expectEqual(@as(i32, 5), h.group_start[0]);
    try std.testing.expectEqual(@as(i32, 6), h.group_end[0]);
    try std.testing.expectEqual(@as(i32, 7), h.group_start[1]);
    try std.testing.expectEqual(@as(i32, 11), h.group_end[1]);
}

test "regextester: an invalid pattern is reported instead of crashing" {
    var c = make("(abc", "abc");
    const r = c.frame(.{});
    try std.testing.expect(!r.valid);
    try std.testing.expect(r.err != null);
    try std.testing.expect(r.err.?.len > 0);
    try std.testing.expectEqual(@as(u32, 0), r.matches);
}

test "regextester: the i flag changes how many matches are found" {
    var c = make("abc", "ABC abc Abc");
    var r = c.frame(.{});
    try std.testing.expectEqual(@as(u32, 1), r.matches);
    var flags: u32 = regex.ICASE;
    r = c.frame(.{ .flags = &flags });
    try std.testing.expectEqual(@as(u32, 3), r.matches);
}

test "regextester: the s flag lets a dot cross newlines" {
    var c = make("a.b", "a\nb");
    var r = c.frame(.{});
    try std.testing.expectEqual(@as(u32, 0), r.matches);
    var flags: u32 = regex.DOTALL;
    r = c.frame(.{ .flags = &flags });
    try std.testing.expectEqual(@as(u32, 1), r.matches);
}

test "regextester: the result is cached until pattern, flags or text change" {
    var c = make("\\d", "1234");
    _ = c.frame(.{});
    try std.testing.expectEqual(@as(usize, 4), c.st.count);
    // 手工改一个命中：若被重算，值会被覆盖回去
    c.st.hits[0].start = 999;
    _ = c.frame(.{});
    try std.testing.expectEqual(@as(i32, 999), c.st.hits[0].start);
    // 改文本 → 重算
    c.text[c.text_len] = '5';
    c.text_len += 1;
    _ = c.frame(.{});
    try std.testing.expectEqual(@as(usize, 5), c.st.count);
    try std.testing.expectEqual(@as(i32, 0), c.st.hits[0].start);
}

test "regextester: empty matches advance so the scan terminates" {
    var c = make("x*", "abc");
    const r = c.frame(.{});
    try std.testing.expect(r.valid);
    // 每个位置都能空匹配：a 前、a 后 b 前、b 后 c 前、c 后 → 4 个
    try std.testing.expectEqual(@as(u32, 4), r.matches);
    try std.testing.expectEqual(@as(i32, 0), c.st.hits[0].start);
    try std.testing.expectEqual(@as(i32, 0), c.st.hits[0].end);
}

test "regextester: more than MAX_HITS matches sets the more flag" {
    var c = make("\\d", "0123456789012345678901234");
    const r = c.frame(.{});
    try std.testing.expectEqual(@as(u32, regextester.MAX_HITS), r.matches);
    try std.testing.expect(r.more);
    try std.testing.expect(c.st.count <= regextester.MAX_HITS);
}

test "regextester: marks stay sorted and bounded" {
    var c = make("(a)(b)(c)(d)(e)(f)(g)(h)(i)", "abcdefghi");
    _ = c.frame(.{});
    try std.testing.expect(c.st.n_marks > 0);
    try std.testing.expect(c.st.n_marks <= regextester.MAX_MARKS);
    var k: usize = 1;
    while (k < c.st.n_marks) : (k += 1) {
        try std.testing.expect(c.st.marks[k - 1].start <= c.st.marks[k].start);
    }
    // 整体命中用色号 0，分组用 1..6 循环
    try std.testing.expectEqual(@as(u8, 0), c.st.marks[0].color);
}

test "regextester: the hit list renders without overflowing the node budget" {
    var c = make("(\\w+)=(\\d+)", "a=1 b=2 c=3 d=4 e=5 f=6 g=7");
    _ = c.frame(.{});
    try std.testing.expectEqual(@as(usize, 7), c.st.count);
    try std.testing.expect(!c.ui.overflowed);
}

test "regextester: the sample text can be edited through the embedded editor" {
    var c = make("\\d+", "abc");
    c.ui.focus_id = core.Context.idOf("rt~");
    c.st.text_state = .{ .cursor = 3, .anchor = 3 };
    _ = c.frame(.{});
    var chars: [64]u8 = @splat(0);
    chars[0] = '7';
    c.ui.input = .{ .chars = chars, .chars_len = 1 };
    _ = c.frame(.{});
    try std.testing.expectEqualStrings("abc7", c.text[0..c.text_len]);
    // 文本变了 → 命中数跟着变
    try std.testing.expectEqual(@as(usize, 1), c.st.count);
}
