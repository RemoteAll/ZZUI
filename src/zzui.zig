//! ZZUI 门面：把平台后端、核心与控件接起来。
//! 用法：
//!   var app = try zzui.App.init(.{ .title = "Hello" });
//!   defer app.deinit();
//!   while (app.next()) {
//!       var ui = &app.ui;
//!       // 用 zzui.widgets.* 描述界面
//!       app.end();
//!   }
pub const core = @import("core.zig");
pub const types = @import("types.zig");
pub const theme = @import("theme.zig");
pub const widgets = @import("widgets.zig");
pub const render = @import("render.zig");
pub const platform = @import("platform.zig");
pub const win32 = @import("win32.zig");
pub const bmpfile = @import("bmpfile.zig");

pub const App = struct {
    backend: platform.Backend,
    ui: core.Context = .{},

    pub const Desc = struct {
        title: []const u8,
        width: u32 = 420,
        height: u32 = 300,
        show: bool = true,
    };

    pub fn init(desc: Desc) !App {
        return .{ .backend = try platform.Backend.initWin32(desc.title, desc.width, desc.height, desc.show) };
    }

    pub fn initHeadless(width: u32, height: u32) !App {
        return .{ .backend = try platform.Backend.initNull(width, height) };
    }

    pub fn deinit(self: *App) void {
        self.backend.deinit();
    }

    /// 处理事件并开始一帧；返回 false 表示窗口已关闭。
    pub fn next(self: *App) bool {
        if (!self.backend.poll()) return false;
        const sz = self.backend.size();
        self.ui.time = self.backend.now();
        self.ui.measure_ctx = @ptrCast(&self.backend);
        self.ui.measure_fn = measureThunk;
        self.ui.input = self.backend.input().*;
        self.ui.begin(sz.w, sz.h);
        return true;
    }

    /// 把当前帧存成 BMP（验证字体/图形用；Win32 下含系统字体文本）。
    pub fn saveSurface(self: *App, path: []const u8) !void {
        return self.backend.saveSurface(path);
    }

    /// 结束一帧：生成绘制指令、按层软件光栅 + 文本、呈现。
    pub fn end(self: *App) void {
        self.ui.paint();
        const sz = self.backend.size();
        const s = self.backend.scale();
        const wpx: u32 = @intFromFloat(@round(sz.w * s));
        const hpx: u32 = @intFromFloat(@round(sz.h * s));
        var layer: u8 = 0;
        while (layer <= self.ui.max_layer) : (layer += 1) {
            render.render(&self.ui, self.backend.pixels(), wpx, hpx, s, layer);
            self.backend.drawTextLayer(&self.ui, layer);
        }
        self.backend.present();
        self.backend.input().click = null;
    }
};

fn measureThunk(ctx: ?*anyopaque, s: []const u8, size: f32) types.Size {
    const b: *platform.Backend = @ptrCast(@alignCast(ctx.?));
    return b.measure(s, size);
}
