//! Emoji：目录、肤色拼接、字体三件（平台代劳）、选择器（页签 / 搜索 / 选中间 / 最近使用 / 预览）。
const std = @import("std");
const core = @import("core.zig");
const emoji = @import("emoji.zig");
const types = @import("types.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

fn keysOf(k: types.Key) [8]types.Key {
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = k;
    return keys;
}

const Fx = struct {
    ui: core.Context = .{},
    st: emoji.State = .{},
    tone: u8 = 0,
    recent: [96]u8 = @splat(0),
    recent_len: usize = 0,
    got: ?[]const u8 = null,
    got_copy: [8]u8 = @splat(0),
    got_len: usize = 0,

    fn frame(self: *Fx) void {
        self.ui.begin(420, 620);
        const r = emoji.picker(&self.ui, "emoji", &self.st, .{
            .width = 360,
            .height = 240,
            .tone = &self.tone,
            .recent = self.recent[0..],
            .recent_len = &self.recent_len,
        });
        if (r) |s| {
            self.got_len = @min(s.len, self.got_copy.len);
            @memcpy(self.got_copy[0..self.got_len], s[0..self.got_len]);
            self.got = self.got_copy[0..self.got_len];
        } else self.got = null;
        self.ui.paint();
    }
};

test "emoji: the catalog is grouped and every entry has a name" {
    try std.testing.expect(emoji.catalog.len >= 120);
    var seen = [emoji.GROUP_COUNT]bool{ false, false, false, false, false, false, false, false, false };
    for (emoji.catalog) |e| {
        try std.testing.expect(e.text.len > 0);
        try std.testing.expect(e.name.len > 0);
        seen[@backingInt(e.group)] = true;
    }
    for (seen) |s| try std.testing.expect(s);
    // 名字不重复
    for (emoji.catalog, 0..) |a, i| {
        for (emoji.catalog[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "emoji: font loading is delegated to the platform" {
    try std.testing.expect(emoji.fontLoadSystem());
    try std.testing.expect(!emoji.fontLoadFile("seguiemj.ttf"));
    try std.testing.expect(!emoji.fontLoadMemory("not a font"));
    try std.testing.expect(emoji.supported("\u{1F600}"));
}

test "emoji: a tone appends the modifier to single codepoint emoji only" {
    const wave = emoji.catalog[18]; // waving hand
    try std.testing.expect(wave.tonable);
    var buf: [8]u8 = undefined;
    const t3 = emoji.toned(wave, 3, buf[0..]);
    try std.testing.expect(t3.len > wave.text.len);
    // 基字符保留，追加 U+1F3FD
    try std.testing.expect(std.mem.startsWith(u8, t3, wave.text));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xF0, 0x9F, 0x8F, 0xBD }, t3[wave.text.len..]);
    // 0 = 不加
    try std.testing.expectEqualStrings(wave.text, emoji.toned(wave, 0, buf[0..]));
    // 不可调肤色的不追加
    const brain = emoji.catalog[12];
    try std.testing.expect(!brain.tonable);
    try std.testing.expectEqualStrings(brain.text, emoji.toned(brain, 4, buf[0..]));
}

test "emoji: the picker draws a grid for the first group" {
    var f = Fx{};
    f.frame();
    try std.testing.expect(f.st.filter_n > 0); // 页签 0 = 最近，未选时按「全部」列出
    try std.testing.expect(!f.ui.overflowed);
    try std.testing.expect(f.got == null);
}

test "emoji: clicking a cell picks it and pushes it into the recents" {
    var f = Fx{};
    f.frame();
    // 网格第一格
    const grid_id = core.Context.idOf("emoji") ^ 0x9911;
    const g = f.ui.lastRect(grid_id).?;
    f.ui.input = .{ .mouse = at(g.x + 10, g.y + 10), .pressed = true, .down = true };
    f.frame();
    f.ui.input = .{ .mouse = at(g.x + 10, g.y + 10), .click = at(g.x + 10, g.y + 10) };
    f.frame();
    try std.testing.expect(f.got != null);
    try std.testing.expect(f.recent_len > 0);
    // 最近的第一个就是刚选的
    const first = f.recent[0..f.got_len];
    try std.testing.expectEqualSlices(u8, f.got.?, first);
}

test "emoji: picking the same emoji twice keeps one recent" {
    var f = Fx{};
    f.frame();
    const grid_id = core.Context.idOf("emoji") ^ 0x9911;
    const g = f.ui.lastRect(grid_id).?;
    var round: usize = 0;
    while (round < 2) : (round += 1) {
        f.ui.input = .{ .mouse = at(g.x + 10, g.y + 10), .pressed = true, .down = true };
        f.frame();
        f.ui.input = .{ .mouse = at(g.x + 10, g.y + 10), .click = at(g.x + 10, g.y + 10) };
        f.frame();
    }
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, f.recent[0..f.recent_len], ' ');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "emoji: the search box filters by name" {
    var f = Fx{};
    f.ui.focus_id = core.Context.idOf("emoji") ^ 0x5EA2; // 搜索框
    f.frame();
    const all = f.st.filter_n;
    // 输入 "d" → 名字含 d 的
    var chars: [64]u8 = @splat(0);
    chars[0] = 'd';
    f.ui.input = .{ .chars = chars, .chars_len = 1 };
    f.frame();
    try std.testing.expect(f.st.query_len == 1);
    try std.testing.expect(f.st.filter_n < all);
    try std.testing.expect(f.st.filter_n > 0);
    // 退格清掉
    f.ui.input = .{ .keys = keysOf(.backspace), .key_count = 1 };
    f.frame();
    try std.testing.expect(f.st.query_len == 0);
    try std.testing.expectEqual(all, f.st.filter_n);
}

test "emoji: switching a group tab narrows the list to that group" {
    var f = Fx{};
    f.frame();
    var tab: usize = 1;
    while (tab <= emoji.GROUP_COUNT) : (tab += 1) {
        const tab_id = core.Context.idOf("emoji") ^ (0x7A00 + tab);
        const r = f.ui.lastRect(tab_id).?;
        f.ui.input = .{ .mouse = at(r.x + r.w * 0.5, r.y + r.h * 0.5), .pressed = true, .down = true };
        f.frame();
        const r2 = f.ui.lastRect(tab_id).?;
        f.ui.input = .{ .mouse = at(r2.x + r2.w * 0.5, r2.y + r2.h * 0.5), .click = at(r2.x + r2.w * 0.5, r2.y + r2.h * 0.5) };
        f.frame();
        try std.testing.expectEqual(@as(u8, @intCast(tab)), f.st.tab);
        // 列表里每一项都属于这个分组
        var k: usize = 0;
        while (k < f.st.filter_n) : (k += 1) {
            try std.testing.expectEqual(tab - 1, @backingInt(emoji.catalog[f.st.filter[k]].group));
        }
    }
}

test "emoji: the tone button cycles 0..5" {
    var f = Fx{};
    f.frame();
    const btn_id = core.Context.idOf("emoji") ^ 0x70E1;
    var r = f.ui.lastRect(btn_id).?;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        f.ui.input = .{ .mouse = at(r.x + 4, r.y + 4), .pressed = true, .down = true };
        f.frame();
        r = f.ui.lastRect(btn_id).?;
        f.ui.input = .{ .mouse = at(r.x + 4, r.y + 4), .click = at(r.x + 4, r.y + 4) };
        f.frame();
        try std.testing.expectEqual(@as(u8, @intCast((i + 1) % 6)), f.tone);
    }
    // 6 次之后回到 0（上面循环里 i=5 已经断言过）
    try std.testing.expectEqual(@as(u8, 0), f.tone);
}

test "emoji: arrow keys move the cursor and enter picks" {
    var f = Fx{};
    f.ui.focus_id = core.Context.idOf("emoji") ^ 0x9911; // 网格
    f.frame();
    f.ui.input = .{ .keys = keysOf(.right), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 0), f.st.sel);
    f.ui.input = .{ .keys = keysOf(.right), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 1), f.st.sel);
    f.ui.input = .{ .keys = keysOf(.left), .key_count = 1 };
    f.frame();
    try std.testing.expectEqual(@as(i32, 0), f.st.sel);
    f.ui.input = .{ .keys = keysOf(.enter), .key_count = 1 };
    f.frame();
    try std.testing.expect(f.got != null);
}

test "emoji: an empty filter shows the empty text instead of a grid" {
    var f = Fx{};
    f.ui.focus_id = core.Context.idOf("emoji") ^ 0x5EA2;
    f.frame();
    const chars = [_]u8{ 'z', 'z', 'z', 'z' };
    var input_chars: [64]u8 = @splat(0);
    @memcpy(input_chars[0..chars.len], chars[0..]);
    f.ui.input = .{ .chars = input_chars, .chars_len = chars.len };
    f.frame();
    try std.testing.expectEqual(@as(usize, 0), f.st.filter_n);
    try std.testing.expect(!f.ui.overflowed);
    f.ui.input = .{ .keys = keysOf(.enter), .key_count = 1 };
    f.frame();
    try std.testing.expect(f.got == null); // 空列表回车不出东西
}
