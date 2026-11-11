//! 选择器族样例（对位 CUI `cui_pickers.c` / `cui_media.c`）：多选 / 区间日历 / 日期区间 / 时分 /
//! 滚轮 / 表盘 / 刻度尺 / 直方图 / 签名板 / 拖放 / 头像上传 / 图片查看裁剪 / 媒体动效。
//!
//! 单独一个产物（不塞进 gallery）：选择器族代码量大，塞进 gallery 会顶穿它的体积门槛。
//! **分 5 页**：单页全画会吃光 `MAX_NODES`（实测 `--shot-2` 溢出退出码 8），
//! 按页构建才稳（和 gallery 同一套路）。
//!
//! `--once` 无窗口渲染写 `zzui-pickers.bmp`；`--shot-N` 真渲染（含系统字体）写
//! `zzui-pickers-shotN.bmp`（N = 0/1/2/3/4，不带 N 等同 0）。
const std = @import("std");
const zzui = @import("zzui");

const page_names = [_][]const u8{ "Inputs", "Graphs", "Upload", "Photos", "Media" };

const State = struct {
    page: usize = 0,
    // 多选
    ms_state: zzui.pickers.PopupState = .{},
    ms: [8]bool = .{ true, false, true, false, false, false, false, false },
    // 区间日历
    cal_month: zzui.pickers.Date = .{ .year = 2026, .month = 11, .day = 1 },
    range: zzui.pickers.DateRange = .{
        .start = .{ .year = 2026, .month = 11, .day = 3 },
        .end = .{ .year = 2026, .month = 11, .day = 10 },
    },
    // 日期区间字段
    dr_state: zzui.pickers.PopupState = .{},
    // 时分
    hour: i32 = 9,
    minute: i32 = 30,
    tp_state: zzui.pickers.PopupState = .{},
    // 滚轮
    wheel_idx: usize = 2,
    wheel: zzui.pickers.WheelState = .{ .pos = 2 },
    wheel_idx2: usize = 0,
    wheel2: zzui.pickers.WheelState = .{ .pos = 0 },
    // 表盘
    dial_hour: i32 = 3,
    dial_minute: i32 = 45,
    // 刻度尺
    ruler_v: f32 = 42,
    ruler: zzui.pickers.RulerState = .{},
    // 直方图
    hist_lo: f32 = 20,
    hist_hi: f32 = 78,
    // 签名
    sig: zzui.pickers.SignatureState = .{},
    // 拖放 / 头像
    av_state: zzui.upload.AvatarState = .{},
    dropped_path: [260]u8 = @splat(0),
    dropped_len: usize = 0,
    uploaded: u32 = 0,
    // 图片查看 / 裁剪
    view: zzui.photo.ImageView = .{},
    vdrag: zzui.photo.Drag = .{},
    crop: zzui.types.Rect = .{ .x = 2, .y = 2, .w = 12, .h = 12 },
    cdrag: zzui.photo.CropDrag = .{},
    // 媒体动效
    car: zzui.media.CarouselState = .{},
    cmp: zzui.media.CompareState = .{},
    deck: zzui.media.CardStackState = .{},
    deck_index: usize = 0,
    odo: zzui.media.CounterState = .{},
    odo2: zzui.media.CounterState = .{},
    odo_value: f64 = 48210,
    tk: zzui.media.TickerState = .{},
};

const multi_items = [_][]const u8{ "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel" };
const wheel_items = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const wheel_items2 = [_][]const u8{ "2024", "2025", "2026", "2027", "2028" };
const hist_bins = [_]f32{ 2, 5, 9, 14, 22, 31, 38, 42, 36, 28, 19, 12, 8, 5, 3 };

/// 示例头像：16×16 斜向渐变（BGRA，顶行在前）。真项目里这块由图片解码得到，
/// 框架本身不解码任何图片格式。
const avatar_img = blk: {
    var px: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            const i = (y * 16 + x) * 4;
            const r: u8 = @intCast(90 + x * 8);
            const g: u8 = @intCast(70 + y * 9);
            px[i] = 0xE0;
            px[i + 1] = g;
            px[i + 2] = r;
            px[i + 3] = 0xFF;
        }
    }
    break :blk px;
};
const avatar_src = zzui.core.ImageSrc{ .pixels = &avatar_img, .w = 16, .h = 16 };

/// 对比用的「处理前」图像：同心方环（与头像截然不同，一眼能看出分割）。
const before_img = blk: {
    var px: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            const i = (y * 16 + x) * 4;
            const ring = (@max(@max(x, 15 - x), @max(y, 15 - y)) / 3) % 2;
            const v: u8 = if (ring == 0) 235 else 120;
            px[i] = v;
            px[i + 1] = v;
            px[i + 2] = v;
            px[i + 3] = 0xFF;
        }
    }
    break :blk px;
};
const before_src = zzui.core.ImageSrc{ .pixels = &before_img, .w = 16, .h = 16 };

const slide_titles = [_][]const u8{ "Overview", "Signals", "Revenue" };
const deck_titles = [_][]const u8{ "#4821 pending", "#4822 shipped", "#4823 draft" };
const ticker_items = [_]zzui.media.TickerItem{
    .{ .label = "cpu", .value = "12%", .delta = -1.5, .lower_is_better = true },
    .{ .label = "rps", .value = "820", .delta = 3.2 },
    .{ .label = "p99", .value = "48ms", .delta = -6.4, .lower_is_better = true },
    .{ .label = "errors", .value = "0.02%", .delta = 0.4 },
};

fn pageInputs(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Multi-select (searchable, chips collapse to +N)");
    _ = zzui.pickers.multiSelect(ui, "ms", multi_items[0..], st.ms[0..], &st.ms_state, .{
        .searchable = true,
        .max_chips = 2,
        .placeholder = "Pick tags",
    });

    zzui.extras.muted(ui, "Date range calendar (click a start, then an end)");
    _ = zzui.pickers.rangeCalendar(ui, "rcal", &st.cal_month, &st.range, .{ .months = 2, .cell_h = 28 });

    var rb: [16]u8 = @splat(0);
    var r2: [16]u8 = @splat(0);
    zzui.widgets.textInt(ui, "selected days = ", @intCast(zzui.pickers.dateToDays(st.range.end) - zzui.pickers.dateToDays(st.range.start) + 1), "  ");
    zzui.extras.code(ui, ui.frameStr(zzui.pickers.formatDate(&rb, st.range.start)));
    zzui.extras.code(ui, ui.frameStr(zzui.pickers.formatDate(&r2, st.range.end)));

    zzui.extras.muted(ui, "Date range field (opens presets + two-month calendar)");
    _ = zzui.pickers.dateRangePicker(ui, "dr", &st.cal_month, &st.range, &st.dr_state, .{});

    zzui.extras.muted(ui, "Time picker (hour + minute columns)");
    _ = zzui.pickers.timePicker(ui, "tp", &st.hour, &st.minute, &st.tp_state, .{ .minute_step = 5 });

    zzui.extras.muted(ui, "Wheel pickers side by side (drag, wheel or arrow keys)");
    {
        var row = ui.row(.{ .gap = 0 });
        defer row.end();
        _ = zzui.pickers.wheelPicker(ui, "w1", wheel_items[0..], &st.wheel_idx, &st.wheel, .{ .join_right = true });
        _ = zzui.pickers.wheelPicker(ui, "w2", wheel_items2[0..], &st.wheel_idx2, &st.wheel2, .{ .join_left = true });
    }
}

fn pageGraphs(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Time dial (drag the hand inside for minutes, outside for hours)");
    _ = zzui.pickers.timeDial(ui, "dial", &st.dial_hour, &st.dial_minute, 180);

    zzui.extras.muted(ui, "Ruler slider (drag to change, snaps to step)");
    _ = zzui.pickers.rulerSlider(ui, "Threshold", &st.ruler_v, 0, 100, &st.ruler, .{ .step = 1, .major_every = 5, .spacing = 12, .unit = "ms" });

    zzui.extras.muted(ui, "Histogram range slider");
    _ = zzui.pickers.histogramSlider(ui, "Latency", hist_bins[0..], &st.hist_lo, &st.hist_hi, 0, 100, .{});

    zzui.extras.muted(ui, "Signature pad (press and drag; clear with the button)");
    _ = zzui.pickers.signaturePad(ui, "sig", &st.sig, .{ .height = 130, .placeholder = "Sign here" });
    if (zzui.widgets.button(ui, "Clear signature", .{})) {
        zzui.pickers.signatureClear(&st.sig);
    }
    const pts = zzui.pickers.signaturePoints(&st.sig);
    zzui.widgets.textInt(ui, "points = ", @intCast(pts.points.len), "  ");
    zzui.widgets.textInt(ui, "strokes = ", @intCast(pts.strokes), "");
}

fn pageUpload(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Avatar upload (click the camera badge; image pixels come from the caller)");
    {
        var row = ui.row(.{ .gap = 16 });
        defer row.end();
        if (zzui.upload.avatarUpload(ui, "av1", "Ada Lovelace", avatar_src, &st.av_state, .{ .size = 72, .status = "online" })) {
            st.uploaded += 1;
        }
        if (zzui.upload.avatarUpload(ui, "av2", "Bob", null, &st.av_state, .{ .size = 72, .status = "busy" })) {
            st.uploaded += 1;
        }
        if (zzui.upload.avatarUpload(ui, "av3", "Carol", null, &st.av_state, .{ .size = 56, .square = true })) {
            st.uploaded += 1;
        }
    }
    zzui.widgets.textInt(ui, "upload clicks = ", st.uploaded, "");

    zzui.extras.muted(ui, "Dropzone (drag files from the OS onto the window, or click to browse)");
    const dz = zzui.upload.dropzone(ui, "dz", .{ .accept = "png;jpg;pdf", .height = 150 });
    if (dz.clicked) st.uploaded += 1;
    if (st.dropped_len > 0) {
        zzui.extras.code(ui, ui.frameStr(st.dropped_path[0..st.dropped_len]));
    } else {
        zzui.extras.muted(ui, "no file dropped this frame");
    }

    zzui.extras.muted(ui, "Compact dropzone");
    _ = zzui.upload.dropzone(ui, "dz2", .{ .compact = true, .title = "Replace file", .accept = "zip" });
}

fn pagePhotos(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Image viewer (wheel to zoom at the cursor, drag to pan, toolbar to step)");
    _ = zzui.photo.imageViewer(ui, "pv", avatar_src, &st.view, &st.vdrag, .{
        .height = 260,
        .checkerboard = true,
    });
    var zb: [12]u8 = undefined;
    zzui.extras.muted(ui, ui.frameStr(zzui.num.percent(&zb, if (st.view.isFit()) 1 else st.view.zoom / 16)));

    zzui.extras.muted(ui, "Cropper (drag inside to move, corners to resize, arrow keys to nudge)");
    _ = zzui.photo.cropper(ui, "pc", avatar_src, &st.crop, &st.cdrag, .{ .height = 240, .aspect = 1 });
    var cb: [40]u8 = @splat(0);
    var cn: usize = 0;
    const parts = [_]struct { k: u8, v: f32 }{
        .{ .k = 'x', .v = st.crop.x },
        .{ .k = 'y', .v = st.crop.y },
        .{ .k = 'w', .v = st.crop.w },
        .{ .k = 'h', .v = st.crop.h },
    };
    for (parts) |p| {
        if (cn < cb.len) {
            cb[cn] = p.k;
            cn += 1;
        }
        if (cn < cb.len) {
            cb[cn] = ':';
            cn += 1;
        }
        var fb: [10]u8 = undefined;
        const fs2 = zzui.num.fixed(&fb, p.v, 1);
        for (fs2) |c| {
            if (cn < cb.len) {
                cb[cn] = c;
                cn += 1;
            }
        }
        if (cn < cb.len) {
            cb[cn] = ' ';
            cn += 1;
        }
    }
    zzui.extras.code(ui, ui.frameStr(cb[0..cn]));
}

fn pageMedia(ui: *zzui.core.Context, st: *State) void {
    zzui.extras.muted(ui, "Carousel (drag, wheel or arrow keys; dots jump to a slide)");
    {
        var car = zzui.media.carousel(ui, "car", slide_titles.len, &st.car, .{ .height = 120, .loop = true });
        for (slide_titles, 0..) |title, i| {
            const r = car.slideRect(i) orelse continue;
            var s = ui.panel(r, .{
                .pad = 14,
                .gap = 6,
                .fill = zzui.theme.bg,
                .radius = 10,
                .border = zzui.theme.border,
            });
            zzui.widgets.heading(ui, title, 3);
            zzui.widgets.secondary(ui, "The caller draws whatever it wants inside slideRect().");
            s.end();
        }
        car.end();
    }

    zzui.extras.muted(ui, "Image compare (drag the handle, arrow keys when focused)");
    _ = zzui.media.imageCompare(ui, "cmp", before_src, avatar_src, &st.cmp, .{
        .height = 140,
        .before_label = "Original",
        .after_label = "Processed",
    });

    zzui.extras.muted(ui, "Card stack (drag the top card away, or use arrow keys)");
    {
        var cs = zzui.media.cardStack(ui, "deck", deck_titles.len, &st.deck, .{ .height = 100, .width = 320 });
        var d: usize = cs.visible;
        while (d > 0) {
            d -= 1;
            const idx = (st.deck_index + d) % deck_titles.len;
            var s = ui.panel(cs.cardRect(d), .{
                .pad = 12,
                .fill = zzui.theme.surface,
                .radius = 12,
                .border = zzui.theme.border,
            });
            // 深层卡片只露出一条边（内容会被上面那张盖住，所以只给最上面那张画）
            if (d == 0) zzui.widgets.secondary(ui, deck_titles[idx]);
            s.end();
        }
        if (cs.end() != 0) st.deck_index = (st.deck_index + 1) % deck_titles.len;
    }

    zzui.extras.muted(ui, "Odometer counters (digits roll towards their target)");
    {
        var row = ui.row(.{ .gap = 28 });
        defer row.end();
        zzui.media.counter(ui, "odo1", st.odo_value, &st.odo, .{ .size = 28, .group_thousands = true, .suffix = " req" });
        zzui.media.counter(ui, "odo2", 1234.5, &st.odo2, .{ .size = 28, .decimals = 2, .group_thousands = true, .prefix = "$" });
    }

    zzui.extras.muted(ui, "Ticker (scrolls while idle, pauses on hover)");
    zzui.media.ticker(ui, "tk", ticker_items[0..], &st.tk, .{ .height = 40 });

    if (zzui.widgets.button(ui, "Bump counters", .{})) st.odo_value += 1234;
}

fn build(ui: *zzui.core.Context, st: *State) void {
    var col = ui.column(.{ .pad = 24, .gap = 14 });
    defer col.end();

    zzui.widgets.heading(ui, "Pickers", 2);
    zzui.widgets.secondary(ui, "Multi-select, date ranges, time, wheels, dials, rulers, signature, dropzone and avatar.");
    zzui.controls.tabs(ui, "pickers-pages", page_names[0..], &st.page);

    var body = ui.scroll(.{ .id = "pickers-body", .height = ui.height - 190, .gap = 14 });
    defer body.end();

    switch (st.page) {
        0 => pageInputs(ui, st),
        1 => pageGraphs(ui, st),
        2 => pageUpload(ui, st),
        3 => pagePhotos(ui, st),
        else => pageMedia(ui, st),
    }
}

pub fn wWinMain(hinstance: zzui.win32.HINSTANCE, _: ?zzui.win32.HINSTANCE, cmdline: [*:0]u16, _: i32) callconv(.winapi) i32 {
    _ = hinstance;
    if (hasFlag(cmdline, "--once")) return runOnce();
    if (hasFlag(cmdline, "--shot-4")) return runShot(4);
    if (hasFlag(cmdline, "--shot-3")) return runShot(3);
    if (hasFlag(cmdline, "--shot-2")) return runShot(2);
    if (hasFlag(cmdline, "--shot-1")) return runShot(1);
    if (hasFlag(cmdline, "--shot")) return runShot(0);

    var st = State{};
    var app = zzui.App.init(.{ .title = "ZZUI pickers", .width = 760, .height = 1000 }) catch return 1;
    defer app.deinit();
    while (app.next()) {
        takeDropped(&app, &st);
        build(&app.ui, &st);
        app.end();
    }
    return 0;
}

/// 拖放是本帧事件：每帧开头把路径摘进 State（帧外 `droppedFile` 失效）。
fn takeDropped(app: *zzui.App, st: *State) void {
    st.dropped_len = 0;
    if (app.droppedFile(0)) |p| {
        const n = @min(p.len, st.dropped_path.len);
        @memcpy(st.dropped_path[0..n], p[0..n]);
        st.dropped_len = n;
    }
}

fn runOnce() i32 {
    var app = zzui.App.initHeadless(760, 1000) catch return 2;
    defer app.deinit();
    if (!app.next()) return 3;
    var st = State{};
    var page: usize = 0;
    while (page < page_names.len) : (page += 1) {
        st.page = page;
        build(&app.ui, &st);
        if (app.ui.overflowed) return 8;
        app.end();
        if (page + 1 < page_names.len) {
            if (!app.next()) break;
        }
    }
    app.saveSurface("zzui-pickers.bmp") catch return 4;
    return 0;
}

fn runShot(page: usize) i32 {
    var app = zzui.App.init(.{ .title = "ZZUI pickers", .width = 760, .height = 1000, .show = false }) catch return 5;
    defer app.deinit();
    if (!app.next()) return 6;
    var st = State{ .page = page };
    // 两帧：第一帧字体未挂上，宽度按估算，排版会偏
    build(&app.ui, &st);
    app.end();
    if (!app.next()) return 6;
    build(&app.ui, &st);
    app.end();
    if (app.ui.overflowed) return 8;
    switch (page) {
        1 => app.saveSurface("zzui-pickers-shot1.bmp") catch return 7,
        2 => app.saveSurface("zzui-pickers-shot2.bmp") catch return 7,
        3 => app.saveSurface("zzui-pickers-shot3.bmp") catch return 7,
        4 => app.saveSurface("zzui-pickers-shot4.bmp") catch return 7,
        else => app.saveSurface("zzui-pickers-shot.bmp") catch return 7,
    }
    return 0;
}

fn hasFlag(cmd: [*:0]u16, flag: []const u8) bool {
    var i: usize = 0;
    while (cmd[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < flag.len and cmd[i + j] != 0 and cmd[i + j] == @as(u16, flag[j])) : (j += 1) {}
        if (j == flag.len) return true;
    }
    return false;
}
