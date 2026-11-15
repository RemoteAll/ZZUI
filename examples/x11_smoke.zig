//! X11 后端冒烟探针（Linux 专用）：开真窗口 → 画几个控件 → 存 BMP → 退出。
//! 用法：`zig build x11-smoke`，然后 `DISPLAY=:0 ./zig-out/bin/zzui-x11-smoke`（WSLg 也行），
//! 产出 `x11-smoke.bmp`。回归/人工验证 X11 后端时用它，比开整个 docs 快得多。
const std = @import("std");
const zzui = @import("zzui");

pub fn main() !void {
    var app = try zzui.App.init(.{ .title = "ZZUI X11 smoke", .width = 560, .height = 320, .show = true });
    defer app.deinit();
    var clicks: usize = 0;
    var n: usize = 0;
    while (n < 8) : (n += 1) {
        if (!app.next()) return;
        var col = app.ui.column(.{ .pad = 20, .gap = 10, .fill = zzui.theme.bg, .radius = 0 });
        zzui.widgets.heading(&app.ui, "ZZUI on X11", 1);
        zzui.widgets.text(&app.ui, "Hello from WSLg / Xwayland - vector icons, rects, text.");
        // 非 ASCII：字体里有的字形（如西里尔）会真画出来，没有的（中文）按半个 em 推进；
        // 想画中文就 `ZZUI_FONT=/path/to/NotoSansCJK.ttc ./zzui-x11-smoke`。
        zzui.widgets.text(&app.ui, "Привет · 中文需 ZZUI_FONT 指 CJK 字体");
        if (zzui.widgets.button(&app.ui, "Click me", .{})) clicks += 1;
        var row = app.ui.row(.{ .gap = 8 });
        _ = zzui.icons.iconButton(&app.ui, "smk-ok", .check, .{ .solid = true });
        _ = zzui.icons.iconButton(&app.ui, "smk-x", .x, .{});
        _ = zzui.icons.iconButton(&app.ui, "smk-search", .search, .{});
        _ = zzui.icons.iconButton(&app.ui, "smk-gear", .settings, .{});
        row.end();
        const bar = app.ui.reserve(300, 18, false);
        app.ui.addGradientBox(bar, 6, zzui.theme.accent, zzui.theme.danger, 24);
        var sb: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(sb[0..], "frame {d}, clicks {d}", .{ n, clicks });
        zzui.widgets.secondary(&app.ui, msg);
        col.end();
        app.end();
    }
    try app.saveSurface("x11-smoke.bmp");
    std.debug.print("saved x11-smoke.bmp ({d}x{d})\n", .{ app.ui.width, app.ui.height });
}
