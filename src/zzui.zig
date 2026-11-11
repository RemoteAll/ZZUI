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
pub const num = @import("num.zig");
pub const theme = @import("theme.zig");
pub const widgets = @import("widgets.zig");
pub const extras = @import("extras.zig");
pub const controls = @import("controls.zig");
pub const overlay = @import("overlay.zig");
pub const textedit = @import("textedit.zig");
pub const table = @import("table.zig");
pub const grid = @import("grid.zig");
pub const dock = @import("dock.zig");
pub const dockspace = @import("dockspace.zig");
pub const pickers = @import("pickers.zig");
pub const upload = @import("upload.zig");
pub const photo = @import("photo.zig");
pub const media = @import("media.zig");
pub const anim = @import("anim.zig");
pub const image = @import("image.zig");
pub const charts = @import("charts.zig");
pub const chrome = @import("chrome.zig");
pub const disclosure = @import("disclosure.zig");
pub const actions = @import("actions.zig");
pub const dials = @import("dials.zig");
pub const codeview = @import("codeview.zig");
pub const viz = @import("viz.zig");
pub const curves = @import("curves.zig");
pub const month = @import("month.zig");
pub const timeline = @import("timeline.zig");
pub const markdown = @import("markdown.zig");
pub const diff = @import("diff.zig");
pub const flame = @import("flame.zig");
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
        // 按目标平台选后端：目前只有 Win32 实现了真窗口；
        // 其他平台返回**明确的运行时错误**（而不是编译不过或静默出空窗）。
        // 新增后端时在这里加一个分支，并在 `platform.zig` 的联合体里加成员。
        if (comptime @import("builtin").os.tag == .windows) {
            var app = App{ .backend = try platform.Backend.initWin32(desc.title, desc.width, desc.height, desc.show) };
            app.ui.need_frame = true; // 首帧不要被空闲节流挡住
            return app;
        }
        return error.PlatformNotImplemented;
    }

    pub fn initHeadless(width: u32, height: u32) !App {
        var app = App{ .backend = try platform.Backend.initNull(width, height) };
        app.ui.need_frame = true; // 首帧不要被空闲节流挡住
        return app;
    }

    pub fn deinit(self: *App) void {
        self.backend.deinit();
    }

    /// 处理事件并开始一帧；返回 false 表示窗口已关闭。
    ///
    /// **空闲节流**：上一帧没有要求继续出帧（无动画、无定时器在等）且没按住鼠标时，
    /// 先把线程**阻塞到有输入**再轮询消息队列 —— 不再每秒重建上千次整个界面。
    /// 有输入会立刻唤醒（`MsgWaitForMultipleObjectsEx`），手感不变。
    pub fn next(self: *App) bool {
        if (!self.ui.need_frame and !self.ui.input.down) self.backend.idle(50);
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

    /// 本帧拖入窗口的第 `i` 个文件路径（UTF-8）。帧外无效 —— 拖放是「本帧事件」。
    pub fn droppedFile(self: *App, i: usize) ?[]const u8 {
        return self.backend.droppedFile(i);
    }

    /// 本帧拖入的文件数（等价于 `ui.input.dropped`）。
    pub fn droppedCount(self: *App) u8 {
        return self.ui.input.dropped;
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
            render.renderImages(&self.ui, self.backend.pixels(), wpx, hpx, s, layer);
            render.renderOverlays(&self.ui, self.backend.pixels(), wpx, hpx, s, layer);
            self.backend.drawTextLayer(&self.ui, layer);
        }
        self.backend.present();
        self.backend.input().click = null;
    }
};

fn measureThunk(ctx: ?*anyopaque, s: []const u8, size: f32, bold: bool) types.Size {
    const b: *platform.Backend = @ptrCast(@alignCast(ctx.?));
    return b.measure(s, size, bold);
}
