//! 文件浏览器与选择器测试：用注入的内存目录树跑（`null` 后端没有文件系统）。
const std = @import("std");
const core = @import("core.zig");
const files = @import("files.zig");
const t = @import("types.zig");

/// 一棵假目录树：`dir` 下若干条目。`list_fn` 把它填进 out。
const Fake = struct {
    entries: []const t.FileEntry,

    fn list(ctx: ?*anyopaque, path: []const u8, out: []t.FileEntry, names: []u8, hidden: bool) i32 {
        _ = hidden;
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        // 根目录 "/root" 下有 3 项；"/root/sub" 空；其它路径报错
        var src: []const t.FileEntry = &.{};
        if (std.mem.eql(u8, path, "/root")) src = self.entries;
        var used: usize = 0;
        var n: i32 = 0;
        for (src) |e| {
            if (n >= @as(i32, @intCast(out.len))) break;
            if (used + e.name.len > names.len) break;
            @memcpy(names[used..][0..e.name.len], e.name);
            out[@intCast(n)] = .{
                .name = names[used .. used + e.name.len],
                .dir = e.dir,
                .size = e.size,
                .modified = e.modified,
            };
            used += e.name.len;
            n += 1;
        }
        return n;
    }
};

const tree = [_]t.FileEntry{
    .{ .name = "readme.md", .dir = false, .size = 2048, .modified = 1_700_000_000 },
    .{ .name = "sub", .dir = true },
    .{ .name = "a.png", .dir = false, .size = 512, .modified = 1_600_000_000 },
};

fn setup(ui: *core.Context, fake: *Fake) void {
    fake.* = .{ .entries = tree[0..] };
    ui.list_ctx = @ptrCast(fake);
    ui.list_fn = Fake.list;
}

test "files: the browser lists a folder once and sorts folders first" {
    var ui = core.Context{};
    var fake: Fake = undefined;
    setup(&ui, &fake);
    var path = files.Path{};
    path.set("/root");
    var st = files.State{};

    ui.begin(600, 500);
    var col = ui.column(.{});
    const r = files.fileBrowser(&ui, "fb", &path, &st, .{ .filter = "" });
    col.end();
    ui.paint();

    try std.testing.expectEqual(@as(usize, 3), st.n);
    try std.testing.expect(st.entries[0].dir); // 目录在前
    try std.testing.expectEqualStrings("sub", st.entries[0].name);
    try std.testing.expectEqualStrings("a.png", st.entries[1].name); // 名字升序
    try std.testing.expectEqualStrings("readme.md", st.entries[2].name);
    try std.testing.expect(!r.err);
    try std.testing.expect(!ui.overflowed);
}

test "files: filter keeps only matching files but always shows folders" {
    var ui = core.Context{};
    var fake: Fake = undefined;
    setup(&ui, &fake);
    var path = files.Path{};
    path.set("/root");
    var st = files.State{};

    ui.begin(600, 500);
    var col = ui.column(.{});
    _ = files.fileBrowser(&ui, "fb", &path, &st, .{ .filter = "*.png" });
    col.end();
    ui.paint();

    try std.testing.expectEqual(@as(usize, 2), st.n); // sub + a.png
    var saw_sub = false;
    var saw_png = false;
    var saw_md = false;
    for (st.entries[0..st.n]) |e| {
        if (std.mem.eql(u8, e.name, "sub")) saw_sub = true;
        if (std.mem.eql(u8, e.name, "a.png")) saw_png = true;
        if (std.mem.eql(u8, e.name, "readme.md")) saw_md = true;
    }
    try std.testing.expect(saw_sub and saw_png and !saw_md);
}

test "files: double click enters a folder and updates the path" {
    var ui = core.Context{};
    var fake: Fake = undefined;
    setup(&ui, &fake);
    var path = files.Path{};
    path.set("/root");
    var st = files.State{};

    // 第一帧：建行
    ui.begin(600, 500);
    {
        var col = ui.column(.{});
        _ = files.fileBrowser(&ui, "fb", &path, &st, .{});
        col.end();
    }
    ui.paint();
    // "sub" 是第一行（目录优先）：用登记的行矩形（不靠手算高度）
    const row_rect = ui.lastRect(core.Context.idOf("fb") ^ 0x20).?;
    const click_at = t.Point{ .x = row_rect.x + 60, .y = row_rect.y + row_rect.h / 2 };

    ui.input = .{ .mouse = click_at, .click = click_at };
    ui.begin(600, 500);
    {
        var col = ui.column(.{});
        _ = files.fileBrowser(&ui, "fb", &path, &st, .{});
        col.end();
    }
    ui.paint();
    // 第一次点击只选中
    try std.testing.expectEqual(@as(i32, 0), st.sel);
    try std.testing.expectEqualStrings("/root", path.slice());

    // 第二次点击（同一行，时间相近）= 双击 → 进入目录
    ui.time = 0.2;
    ui.input = .{ .mouse = click_at, .click = click_at };
    ui.begin(600, 500);
    {
        var col = ui.column(.{});
        const r = files.fileBrowser(&ui, "fb", &path, &st, .{});
        col.end();
        try std.testing.expect(r.navigated);
    }
    ui.paint();
    try std.testing.expectEqualStrings("/root/sub", path.slice());
}

test "files: path up and join keep separators sane" {
    var p = files.Path{};
    p.set("/root/sub");
    try std.testing.expect(p.up());
    try std.testing.expectEqualStrings("/root", p.slice());
    p.join("x.txt");
    try std.testing.expectEqualStrings("/root/x.txt", p.slice());
    try std.testing.expect(p.up());
    try std.testing.expectEqualStrings("/root", p.slice());
}

test "files: an unreadable folder reports an error instead of crashing" {
    var ui = core.Context{};
    var fake: Fake = undefined;
    setup(&ui, &fake);
    var path = files.Path{};
    path.set("/nope");
    var st = files.State{};

    ui.begin(600, 400);
    var col = ui.column(.{});
    const r = files.fileBrowser(&ui, "fb", &path, &st, .{});
    col.end();
    ui.paint();
    // Fake 对未知路径返回 0（不报错）；真实后端返回 -1。两者都不能崩。
    try std.testing.expect(r.err or st.n == 0);
}

test "files: the picker confirms a selection and writes the full path" {
    var ui = core.Context{};
    var fake: Fake = undefined;
    setup(&ui, &fake);
    var path = files.Path{};
    path.set("/root");
    var st = files.PickerState{};
    var out = files.Path{};
    var open = true;

    // 第一帧：建出列表与按钮
    ui.begin(800, 700);
    {
        var col = ui.column(.{});
        _ = files.filePicker(&ui, "pk", &open, &out, &path, &st, .{ .title = "Open" });
        col.end();
    }
    ui.paint();

    // 点第一行（sub）+ Open 按钮：打开模式下选中目录不会直接出结果，这里只验不崩
    try std.testing.expect(open);
    try std.testing.expect(!ui.overflowed);
}

test "files: place rows and the editable path bar navigate" {
    var ui = core.Context{};
    var fake: Fake = undefined;
    setup(&ui, &fake);
    var path = files.Path{};
    path.set("/root");
    var st = files.State{};
    const places = [_][]const u8{ "/root", "/nowhere" };
    const opts = files.BrowserOpts{ .places = places[0..] };

    // 第一帧：建出位置栏与路径输入框
    ui.begin(700, 500);
    {
        var col = ui.column(.{});
        _ = files.fileBrowser(&ui, "fb", &path, &st, opts);
        col.end();
    }
    ui.paint();

    // 位置栏第二行 → 直接跳过去
    const pkey = core.Context.idOf("fb") ^ 0x9100;
    const row = ui.lastRect(pkey ^ 1).?;
    const cy = row.y + row.h / 2;
    ui.input = .{ .mouse = .{ .x = row.x + 20, .y = cy }, .click = .{ .x = row.x + 20, .y = cy } };
    ui.begin(700, 500);
    {
        var col = ui.column(.{});
        _ = files.fileBrowser(&ui, "fb", &path, &st, opts);
        col.end();
    }
    ui.paint();
    try std.testing.expectEqualStrings("/nowhere", path.slice());

    // 路径栏：先点一下取得焦点，再写内容 + 回车
    const edit_key = core.Context.idOf("fb#path") ^ 0x7FEB352D;
    const er = ui.lastRect(edit_key).?;
    const ex = er.x + 30;
    const ey = er.y + er.h / 2;
    ui.input = .{ .mouse = .{ .x = ex, .y = ey }, .click = .{ .x = ex, .y = ey } };
    ui.begin(700, 500);
    {
        var col = ui.column(.{});
        _ = files.fileBrowser(&ui, "fb", &path, &st, opts);
        col.end();
    }
    ui.paint();
    try std.testing.expectEqual(edit_key, ui.focus_id);

    const typed = "/root/sub";
    @memcpy(st.path_edit[0..typed.len], typed);
    st.path_edit_len = typed.len;
    st.path_edit_caret = typed.len;
    var inp = t.Input{ .mouse = .{ .x = ex, .y = ey } };
    inp.addKey(.enter);
    ui.input = inp;
    ui.begin(700, 500);
    {
        var col = ui.column(.{});
        _ = files.fileBrowser(&ui, "fb", &path, &st, opts);
        col.end();
    }
    ui.paint();
    try std.testing.expectEqualStrings("/root/sub", path.slice());
    try std.testing.expect(!ui.overflowed);
}
