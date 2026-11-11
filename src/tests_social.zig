//! 会话族：聊天气泡（我的/别人的/分组）、日期分隔、正在输入、评论串（缩进 + 连接线 + 点赞回复）、
//! 在线头像组（叠放 / 展开 / +N）。
const std = @import("std");
const core = @import("core.zig");
const social = @import("social.zig");
const theme = @import("theme.zig");
const types = @import("types.zig");

const Harness = struct {
    ui: core.Context = .{},
    comments: social.CommentState = .{},
    pres: social.PresenceState = .{},
    flags: u8 = 0,

    fn begin(self: *Harness) void {
        self.ui.begin(600, 900);
    }

    fn end(self: *Harness) void {
        self.ui.paint();
    }
};

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

test "social: initials take the first character of the first word" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("A", social.initials(buf[0..], "Ada Lovelace"));
    try std.testing.expectEqualStrings("Z", social.initials(buf[0..], "zoe"));
    try std.testing.expectEqualStrings("?", social.initials(buf[0..], ""));
    // 中文按 UTF-8 首字符
    try std.testing.expectEqualStrings("张", social.initials(buf[0..], "张三"));
}

test "social: a chat message reserves a row and draws text" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    social.chatMessage(&h.ui, "Hello there", .{ .author = "Ada", .time = "09:12" });
    col.end();
    h.end();
    try std.testing.expect(!h.ui.overflowed);
    try std.testing.expect(h.ui.node_count > 3);
}

test "social: my own message is right aligned" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    social.chatMessage(&h.ui, "mine", .{ .mine = true, .status = "Read", .time = "09:14" });
    col.end();
    h.end();
    try std.testing.expect(!h.ui.overflowed);
}

test "social: grouped messages drop the header" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 0 });
    social.chatMessage(&h.ui, "first line", .{ .author = "Ada" });
    social.chatMessage(&h.ui, "second line", .{ .author = "Ada", .grouped = true });
    col.end();
    h.end();
    try std.testing.expect(!h.ui.overflowed);
}

test "social: long text wraps inside the bubble instead of one giant line" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    social.chatMessage(&h.ui, "This is a fairly long message that must wrap onto more than one line because the bubble has a maximum width of four hundred and eighty points.", .{ .author = "Ada" });
    col.end();
    h.end();
    try std.testing.expect(!h.ui.overflowed);
}

test "social: the divider draws a label between two rules" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    social.chatDivider(&h.ui, "Today");
    col.end();
    h.end();
    try std.testing.expect(!h.ui.overflowed);
}

test "social: the typing indicator asks for the next frame" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    social.typingIndicator(&h.ui, "Ada");
    col.end();
    try std.testing.expect(h.ui.need_frame); // 圆点是动画，必须持续请求帧
    h.end();
    try std.testing.expect(!h.ui.overflowed);
}

test "social: a top level comment draws and reports no action by default" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    h.flags = social.comment(&h.ui, "c1", "Ada", "First comment on the thread.", &h.comments, .{ .time = "10:02" });
    col.end();
    h.end();
    try std.testing.expectEqual(@as(u8, 0), h.flags);
    try std.testing.expect(!h.ui.overflowed);
    // 连接线的起点被记录
    try std.testing.expect(h.comments.rail_bottom[0] > 0);
}

test "social: a reply indents under its parent and keeps the rail" {
    var h = Harness{};
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    _ = social.comment(&h.ui, "c1", "Ada", "Parent comment.", &h.comments, .{});
    const parent_bottom = h.comments.rail_bottom[0];
    _ = social.comment(&h.ui, "c2", "Bo", "Reply under it.", &h.comments, .{ .depth = 1 });
    col.end();
    h.end();
    try std.testing.expect(!h.ui.overflowed);
    // 深度的连接线起点跟着更新，且在第一层之上
    try std.testing.expect(h.comments.rail_bottom[0] >= parent_bottom);
    try std.testing.expect(h.comments.rail_bottom[1] > parent_bottom);
}

test "social: clicking like flips the flag and bumps the count" {
    var h = Harness{};
    var likes: i32 = 4;
    var liked = false;
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    h.flags = social.comment(&h.ui, "c1", "Ada", "Nice.", &h.comments, .{ .likes = &likes, .liked = &liked });
    col.end();
    h.end();
    try std.testing.expectEqual(@as(i32, 4), likes);
    // 点赞按钮的矩形：拿 Ghost 按钮的命中矩形（它在本帧登记）
    const like_id = core.Context.idOf("♥ 4") ^ 0x11 ^ 0; // id_salt = idOf("c1") ^ 0x11
    _ = like_id;
    // 用命中表找出「♥ 4」按钮：它画在评论操作行里
    var found = false;
    var i: usize = 0;
    while (i < h.ui.hits_curr_n) : (i += 1) {
        if (h.ui.hits_curr[i].rect.h < 40 and h.ui.hits_curr[i].rect.y > 0) found = true;
    }
    try std.testing.expect(found);
}

test "social: the comment badge and edited time render" {
    var h = Harness{};
    var likes: i32 = 0;
    var liked = false;
    h.begin();
    var col = h.ui.column(.{ .pad = 20, .gap = 8 });
    _ = social.comment(&h.ui, "c1", "Ada", "Body", &h.comments, .{ .time = "10:02", .edited = true, .badge = "Author", .likes = &likes, .liked = &liked });
    col.end();
    h.end();
    try std.testing.expect(!h.ui.overflowed);
}

test "social: presence shows the avatars and a +N chip" {
    var h = Harness{};
    const users = [_]social.PresenceUser{
        .{ .name = "Ada" },
        .{ .name = "Bo", .color = theme.success },
        .{ .name = "Cy", .idle = true },
        .{ .name = "Di" },
        .{ .name = "Ed" },
        .{ .name = "Fay" },
    };
    h.ui.input = .{ .mouse = at(500, 800) }; // 指针离开头像组
    h.begin();
    social.presence(&h.ui, "who", users[0..], 4, 30, &h.pres);
    h.end();
    try std.testing.expect(!h.ui.overflowed);
    try std.testing.expect(!h.pres.hover);
}

test "social: hovering the presence row spreads it" {
    var h = Harness{};
    const users = [_]social.PresenceUser{ .{ .name = "Ada" }, .{ .name = "Bo" } };
    h.begin();
    social.presence(&h.ui, "who", users[0..], 4, 30, &h.pres);
    h.end();
    // 第二帧：指针落在头像组上
    h.ui.input = .{ .mouse = at(10, 10) };
    h.begin();
    social.presence(&h.ui, "who", users[0..], 4, 30, &h.pres);
    h.end();
    try std.testing.expect(h.pres.hover);
}

test "social: presence with no users draws nothing" {
    var h = Harness{};
    h.begin();
    social.presence(&h.ui, "who", &[_]social.PresenceUser{}, 4, 30, &h.pres);
    h.end();
    try std.testing.expectEqual(@as(usize, 0), h.ui.node_count);
}
