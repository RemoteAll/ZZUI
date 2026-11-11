//! 动效核心测试：轨道推进、有界淘汰、颜色插值，以及「悬停淡入真的会逐帧变色」。
const std = @import("std");
const core = @import("core.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const anim = @import("anim.zig");
const t = @import("types.zig");

test "anim: step approaches the target monotonically and snaps" {
    var ui = core.Context{};
    // 先用 target=0 建立轨道（首次观测是对齐，不是过渡）
    ui.time = 0.5;
    _ = anim.step(&ui, 42, 0, anim.rate_hover);
    var v_prev: f32 = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        ui.time += 0.016; // 60fps
        const v = anim.step(&ui, 42, 1, anim.rate_hover);
        try std.testing.expect(v >= v_prev);
        try std.testing.expect(v <= 1);
        v_prev = v;
    }
    try std.testing.expect(v_prev > 0.4 and v_prev < 1); // 6 帧还没到位

    // 大量帧后吸附到 1（不留 0.9999）
    i = 0;
    while (i < 60) : (i += 1) {
        ui.time += 0.016;
        _ = anim.step(&ui, 42, 1, anim.rate_hover);
    }
    try std.testing.expectEqual(@as(f32, 1), anim.step(&ui, 42, 1, anim.rate_hover));
}

test "anim: dt is clamped so a long stall cannot jump" {
    var ui = core.Context{};
    ui.time = 1.0;
    _ = anim.step(&ui, 7, 1, 14); // 首帧只建立时间基线
    ui.time = 3.0; // 停了 2 秒
    const v = anim.step(&ui, 7, 1, 14);
    // dt 被夹到 0.1s -> k = min(1, 1.4) = 1 -> 直接到位（不是跳变，是饱和）
    try std.testing.expectEqual(@as(f32, 1), v);
}

test "anim: track pool is bounded and evicts the least recently used" {
    var ui = core.Context{};
    var i: u64 = 0;
    // 建出超过池容量的轨道
    while (i < core.MAX_TRACKS + 8) : (i += 1) {
        ui.time += 0.016;
        _ = anim.step(&ui, 1000 + i, 1, 14);
    }
    try std.testing.expect(ui.track_n <= core.MAX_TRACKS);
    // 最新的那条一定还在
    try std.testing.expect(anim.isAnimating(&ui, 1000 + core.MAX_TRACKS + 7) or true);
    var found_last = false;
    for (ui.tracks[0..ui.track_n]) |tr| {
        if (tr.id == 1000 + core.MAX_TRACKS + 7) found_last = true;
    }
    try std.testing.expect(found_last);
    // 最早的那条已被淘汰
    var found_first = false;
    for (ui.tracks[0..ui.track_n]) |tr| {
        if (tr.id == 1000) found_first = true;
    }
    try std.testing.expect(!found_first);
}

test "anim: color mix hits both endpoints exactly" {
    const a = t.Color.hex(0x000000, 255);
    const b = t.Color.hex(0xFFFFFF, 255);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, &[_]u8{ anim.mix(a, b, 0).r, anim.mix(a, b, 0).g, anim.mix(a, b, 0).b, anim.mix(a, b, 0).a });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, &[_]u8{ anim.mix(a, b, 1).r, anim.mix(a, b, 1).g, anim.mix(a, b, 1).b, anim.mix(a, b, 1).a });
    const mid = anim.mix(a, b, 0.5);
    try std.testing.expect(mid.r > 120 and mid.r < 136);
    // 越界会被夹住（不会因为 rate 调得过大而溢出）
    try std.testing.expectEqual(@as(u8, 255), anim.mix(a, b, 3.5).r);
}

test "anim: hovering a button fades its fill over several frames" {
    theme.setMode(.light);
    defer theme.setMode(.light);

    var ui = core.Context{};
    const rect = t.Rect{ .x = 10, .y = 10, .w = 120, .h = 36 };

    // 第一帧：鼠标在按钮**外**（建立轨道，值为 0）
    ui.begin(200, 80);
    ui.input = .{ .mouse = .{ .x = 190, .y = 70 } };
    ui.time = 1.0;
    _ = widgets.buttonRect(&ui, rect, "Save", .{});
    ui.paint();

    var buf: [200 * 80 * 4]u8 = @splat(0);
    render.render(&ui, &buf, 200, 80, 1, 0);
    const idx = (@as(usize, 28) * 200 + 40) * 4;
    const first = [3]u8{ buf[idx + 2], buf[idx + 1], buf[idx] };

    // 鼠标移到按钮上，再跑 6 帧（每帧 16ms），底色应当朝 track 走
    var f: usize = 0;
    while (f < 6) : (f += 1) {
        ui.time += 0.016;
        ui.begin(200, 80);
        ui.input = .{ .mouse = .{ .x = 40, .y = 28 } };
        _ = widgets.buttonRect(&ui, rect, "Save", .{});
        ui.paint();
    }
    @memset(&buf, 0);
    render.render(&ui, &buf, 200, 80, 1, 0);
    const later = [3]u8{ buf[idx + 2], buf[idx + 1], buf[idx] };

    // surface(0xF3) -> track(0xD9)：中间帧必须比首帧暗、但还没到 track
    try std.testing.expect(later[0] < first[0]);
    try std.testing.expect(later[0] > 0xD9);
}

test "anim: a new track snaps to its target (no fade-in on startup)" {
    var ui = core.Context{};
    ui.time = 5.0;
    // 首次就 hover=true：直接到位，不从 0 爬
    try std.testing.expectEqual(@as(f32, 1), anim.hover(&ui, 99, true));
    // 同一帧之后变 false：这就开始过渡了
    ui.time = 5.016;
    const v = anim.hover(&ui, 99, false);
    try std.testing.expect(v > 0.5 and v < 1);
}

// 空闲节流（`App.next` 里的 `backend.idle`）依赖 `need_frame`：
// 动画没跑完却忘记请求出帧 -> 界面会冻在动画中途，这条用例就是护栏。
test "anim: transitions request the next frame, settled state does not" {
    var ui = core.Context{};
    ui.time = 1.0;
    ui.begin(200, 80);
    _ = anim.hover(&ui, 5, true); // 首次观测：对齐，不是过渡
    ui.paint();

    ui.begin(200, 80); // 新的一帧，need_frame 复位
    try std.testing.expect(!ui.need_frame);

    ui.time = 1.016;
    _ = anim.hover(&ui, 5, false); // 开始过渡
    try std.testing.expect(ui.need_frame);

    // 跑到收敛后就不再要求出帧
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        ui.time += 0.016;
        ui.begin(200, 80);
        _ = anim.hover(&ui, 5, false);
        ui.paint();
    }
    ui.begin(200, 80);
    _ = anim.hover(&ui, 5, false);
    try std.testing.expect(!ui.need_frame);
}

test "anim: spinner and scrolling ticker keep asking for frames" {
    const extras = @import("extras.zig");
    const media = @import("media.zig");

    var ui = core.Context{};
    ui.begin(200, 120);
    extras.spinner(&ui, 24);
    try std.testing.expect(ui.need_frame);

    var st = media.TickerState{};
    const items = [_]media.TickerItem{.{ .label = "cpu", .value = "12%" }};
    ui.time = 2.0;
    ui.begin(200, 120);
    ui.input = .{ .mouse = .{ .x = 900, .y = 900 } }; // 不在控件上 -> 滚动中
    media.ticker(&ui, "tk", &items, &st, .{ .height = 40 });
    try std.testing.expect(ui.need_frame);

    // 悬停暂停 -> 不再要求出帧
    ui.time = 2.1;
    ui.begin(200, 120);
    ui.input = .{ .mouse = .{ .x = 20, .y = 20 } };
    media.ticker(&ui, "tk", &items, &st, .{ .height = 40 });
    try std.testing.expect(!ui.need_frame);
}
