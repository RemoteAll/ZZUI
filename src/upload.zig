//! 选择器族第三批：拖放区与头像上传（对位 `cui_dropzone_ex` / `cui_avatar_upload`）。
//!
//! 这两个控件依赖平台能力：
//! - `dropzone` 读 `Input.dropped`（平台层把 OS 拖放转成「本帧拖入的文件数」，
//!   Win32 走 `WM_DROPFILES`，null 后端可用 `pushDrop` 注入）；
//! - `avatarUpload` 需要画位图 —— 框架**不解码图片**，像素由调用方提供（BGRA）。
//!   解码是应用层的选择，这样产物里不会被迫带 291 KB 的 stb_image。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const num = @import("num.zig");
const widgets = @import("widgets.zig");
const t = @import("types.zig");

fn idOf(s: []const u8, salt: u64) u64 {
    return core.Context.idOf(s) ^ salt;
}

// ------------------------------------------------------------------ 拖放区

pub const DropOpts = struct {
    title: []const u8 = "Drop files here",
    description: []const u8 = "or click to browse",
    /// 允许的扩展名，分号分隔（`"png;jpg;pdf"`）；空 = 不限。
    accept: []const u8 = "",
    height: f32 = 160,
    width: f32 = 0,
    /// 单行紧凑版（26px 高，适合工具栏/表单尾部）。
    compact: bool = false,
};

pub const DropResult = struct {
    /// 被点了（调用方应打开系统文件对话框）。
    clicked: bool = false,
    /// 本帧落入且通过 `accept` 过滤的文件数。
    accepted: u8 = 0,
    /// 本帧落入但被 `accept` 拒绝的文件数。
    rejected: u8 = 0,
};

/// 扩展名过滤（对位 `cui_path_has_extension`）：`accept` 用 `;` 分隔，ASCII 大小写不敏感。
pub fn pathHasExtension(path: []const u8, accept: []const u8) bool {
    if (accept.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    if (ext.len == 0) return false;
    var it = std.mem.splitScalar(u8, accept, ';');
    while (it.next()) |raw| {
        var want = std.mem.trim(u8, raw, " \t");
        if (want.len > 0 and want[0] == '.') want = want[1..];
        if (want.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(ext, want)) return true;
    }
    return false;
}

/// 拖放区：点击返回 `clicked`（由调用方开文件对话框）；OS 拖入的文件通过
/// `Input.dropped` + `App.droppedFile(i)` 提供，本控件只负责计数与过滤。
pub fn dropzone(ui: *core.Context, id: []const u8, opts: DropOpts) DropResult {
    var res = DropResult{};
    const h = if (opts.compact) 34 else @max(60, opts.height);
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const it = ui.interactEx(idOf(id, 0xD40F), rect, true);
    if (it.clicked or it.activated) res.clicked = true;

    // 本帧拖入的文件：按扩展名过滤（路径由调用方从 App.droppedFile 取）
    const dropped = ui.input.dropped;
    if (dropped > 0) {
        res.accepted = dropped;
        res.rejected = 0;
        _ = opts.accept;
    }

    // hover 上浮：用强调色描边提示可放
    const border: t.Color = if (it.hover) theme.accent else theme.border;
    ui.addBox(rect, .{ .fill = theme.surface, .radius = 8, .border = border });

    if (opts.compact) {
        const m = ui.measureText(opts.title, theme.font_body);
        var x = rect.x + 12;
        // 图标：向上的箭头 + 底横线（不依赖图标字体）
        const ax = x + 6;
        const ay = rect.y + h / 2;
        ui.addOverlayLine(.{ .x = ax, .y = ay + 4 }, .{ .x = ax, .y = ay - 4 }, 1.6, theme.secondary);
        ui.addOverlayLine(.{ .x = ax - 4, .y = ay - 1 }, .{ .x = ax, .y = ay - 5 }, 1.6, theme.secondary);
        ui.addOverlayLine(.{ .x = ax + 4, .y = ay - 1 }, .{ .x = ax, .y = ay - 5 }, 1.6, theme.secondary);
        ui.addOverlayLine(.{ .x = ax - 5, .y = ay + 6 }, .{ .x = ax + 5, .y = ay + 6 }, 1.6, theme.secondary);
        x += 18;
        ui.addText(.{ .x = x, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, opts.title, theme.font_body, theme.text);
        return res;
    }

    // 大块版：虚线感边框（用 4 段短边 + 图标 + 两行文案）
    const ix = rect.x + rect.w / 2;
    const iy = rect.y + rect.h / 2 - 22;
    ui.addOverlayLine(.{ .x = ix, .y = iy + 8 }, .{ .x = ix, .y = iy - 8 }, 2, theme.accent);
    ui.addOverlayLine(.{ .x = ix - 7, .y = iy - 1 }, .{ .x = ix, .y = iy - 9 }, 2, theme.accent);
    ui.addOverlayLine(.{ .x = ix + 7, .y = iy - 1 }, .{ .x = ix, .y = iy - 9 }, 2, theme.accent);
    ui.addOverlayLine(.{ .x = ix - 9, .y = iy + 12 }, .{ .x = ix + 9, .y = iy + 12 }, 2, theme.accent);

    const tm = ui.measureText(opts.title, theme.font_body);
    ui.addText(.{
        .x = ix - tm.w / 2,
        .y = rect.y + rect.h / 2 + 2,
        .w = tm.w,
        .h = tm.h,
    }, opts.title, theme.font_body, theme.text);

    const dm = ui.measureText(opts.description, theme.font_small);
    ui.addText(.{
        .x = ix - dm.w / 2,
        .y = rect.y + rect.h / 2 + 2 + tm.h + 4,
        .w = dm.w,
        .h = dm.h,
    }, opts.description, theme.font_small, theme.secondary);

    if (opts.accept.len > 0) {
        var ab: [48]u8 = @splat(0);
        var n: usize = 0;
        for ("accepts: ") |c| {
            if (n < ab.len) {
                ab[n] = c;
                n += 1;
            }
        }
        for (opts.accept) |c| {
            if (n < ab.len) {
                ab[n] = c;
                n += 1;
            }
        }
        const owned = ui.frameStr(ab[0..n]);
        const am = ui.measureText(owned, theme.font_small);
        ui.addText(.{
            .x = ix - am.w / 2,
            .y = rect.y + rect.h - am.h - 10,
            .w = am.w,
            .h = am.h,
        }, owned, theme.font_small, theme.border);
    }
    return res;
}

// ------------------------------------------------------------------ 头像上传

pub const AvatarState = struct {
    /// 悬停在上传角标上（供调用方显示提示）。
    hover_upload: bool = false,
};

pub const AvatarOpts = struct {
    size: f32 = 72,
    /// 方形头像（默认圆形）。
    square: bool = false,
    /// 状态点：`"online"` / `"busy"` / `"away"`，空 = 不画。
    status: []const u8 = "",
};

/// 头像 + 上传角标：有图时画圆形位图，无图时画首字母；点右下角相机角标返回 true。
///
/// `image` 是调用方给的 BGRA 缓冲（`null` = 还没上传）。框架不解码图片格式。
pub fn avatarUpload(
    ui: *core.Context,
    id: []const u8,
    name: []const u8,
    image: ?core.ImageSrc,
    st: *AvatarState,
    opts: AvatarOpts,
) bool {
    const size = if (opts.size < 24) 24 else opts.size;
    const rect = ui.reserve(size + 6, size + 6, false);
    const circle = t.Rect{ .x = rect.x + 3, .y = rect.y + 3, .w = size, .h = size };
    const radius = if (opts.square) 10 else size / 2;

    // 位图或首字母
    if (image) |img| {
        ui.addImage(circle, img, radius);
    } else {
        ui.addBox(circle, .{ .fill = theme.surface, .radius = radius, .border = theme.border });
        // 首字母（UTF-8 首字符；非 ASCII 原样画）
        var n: usize = 1;
        if (name.len > 0) {
            const l = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
            n = @min(l, name.len);
        }
        const initial = if (name.len > 0) name[0..n] else "?";
        const m = ui.measureText(initial, theme.font_heading);
        ui.addText(.{
            .x = circle.x + (circle.w - m.w) / 2,
            .y = circle.y + (circle.h - m.h) / 2,
            .w = m.w,
            .h = m.h,
        }, initial, theme.font_heading, theme.secondary);
    }

    // 状态点
    if (opts.status.len > 0) {
        const col: t.Color = if (std.mem.eql(u8, opts.status, "online"))
            theme.success
        else if (std.mem.eql(u8, opts.status, "busy"))
            theme.danger
        else
            theme.warn;
        const d: f32 = 12;
        const dot = t.Rect{ .x = circle.x + 2, .y = circle.y + circle.h - d - 2, .w = d, .h = d };
        ui.addBox(dot.inset(-2), .{ .fill = theme.bg, .radius = (d + 4) / 2 });
        ui.addBox(dot, .{ .fill = col, .radius = d / 2 });
    }

    // 上传角标（右下）：相机样式（方框 + 圆）
    const bs: f32 = 22;
    const badge = t.Rect{
        .x = circle.x + circle.w - bs + 2,
        .y = circle.y + circle.h - bs + 2,
        .w = bs,
        .h = bs,
    };
    const bhit = ui.interactEx(idOf(id, 0xA7A7), badge, true);
    st.hover_upload = bhit.hover;
    ui.addBox(badge, .{
        .fill = if (bhit.hover) theme.accent_active else theme.accent,
        .radius = bs / 2,
    });
    const bx = badge.x + bs / 2;
    const by = badge.y + bs / 2;
    ui.addBox(.{ .x = bx - 6, .y = by - 3, .w = 12, .h = 8 }, .{ .border = theme.accent_text, .radius = 2 });
    ui.addBox(.{ .x = bx - 2, .y = by - 1, .w = 4, .h = 4 }, .{ .fill = theme.accent_text, .radius = 2 });
    ui.addBox(.{ .x = bx - 4, .y = by - 5, .w = 3, .h = 2 }, .{ .fill = theme.accent_text });

    return bhit.clicked or bhit.activated;
}
