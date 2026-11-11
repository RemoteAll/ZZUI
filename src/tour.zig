//! 引导（对位 CUI `cui_tour.c`）：一次高亮一个控件，旁边一张卡片说明它做什么，
//! 用于上手引导与「有什么新功能」。窗口其余部分压暗，聚光区跟着步骤走。
//!
//! 调用位置：**在被指向的控件之后**，每帧调用（`step >= 0` 时）。
//! 结束（走完 / Esc）会把 `*step` 置 -1。
//!
//! 与 CUI 的差异（有意为之）：
//! - **聚光区不做滑动动画**（CUI 是 glide）：直接跳到当前步骤的目标；
//! - `count_format` 不做格式化回调：计数固定写成「3 / 4」；
//! - `block_target` 只对**卡片之外**的点击生效（聚光区默认仍可交互，与 CUI 相反），
//!   因为立即模式下要走「点目标继续操作」的引导更常见。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const widgets = @import("widgets.zig");

pub const Placement = enum {
    bottom_start,
    bottom,
    bottom_end,
    top_start,
    top,
    top_end,
    right_start,
    left_start,
    right,
    left,
};

pub const Step = struct {
    /// 要指向的控件 id（控件建完后的 `ui.lastRect` 值）；0 = 屏幕中央一张卡片。
    target: u64 = 0,
    title: []const u8 = "",
    body: []const u8 = "",
    /// 卡片在目标哪一侧，默认下方。
    placement: Placement = .bottom,
};

pub const TourOpts = struct {
    /// 卡片宽，默认 300。
    width: f32 = 300,
    /// 聚光区外扩，默认 6。
    padding: f32 = 6,
    /// 聚光区也挡住指针。
    block_target: bool = false,
    next_label: []const u8 = "Next",
    back_label: []const u8 = "Back",
    done_label: []const u8 = "Done",
};

pub const Action = enum { none, next, back, done, skipped };

const GAP: f32 = 10;

/// 每帧调用一次（`step >= 0` 时）。返回本帧发生了什么。
pub fn tour(
    ui: *core.Context,
    id: []const u8,
    steps: []const Step,
    step: *i32,
    opts: TourOpts,
) Action {
    if (steps.len == 0) {
        step.* = -1;
        return .done;
    }
    if (step.* < 0) return .none;
    if (step.* >= @as(i32, @intCast(steps.len))) {
        step.* = -1;
        return .done;
    }
    const idx: usize = @intCast(step.*);
    const cur = steps[idx];
    const last = idx + 1 == steps.len;

    // 聚光区：上一帧的控件矩形（0 = 居中卡片，无聚光）
    var hole = t.Rect{};
    if (cur.target != 0) {
        if (ui.prevHitRect(cur.target)) |r| {
            hole = r.inset(-opts.padding);
        }
    }
    if (hole.w <= 0 or hole.h <= 0) hole = .{};

    var ov = ui.beginOverlay(.{ .dim = null, .hit = true, .id = core.Context.idOf(id) ^ 0x70A7 });
    defer ov.end();

    // 压暗：用 4 块矩形围出聚光区（没有「挖洞」原语，也不该为它加一条绘制通道）
    const shade = t.Color{ .r = 0, .g = 0, .b = 0, .a = 120 };
    if (hole.w <= 0) {
        ui.addBox(.{ .x = 0, .y = 0, .w = ui.width, .h = ui.height }, .{ .fill = shade });
    } else {
        const hx0 = @max(hole.x, 0);
        const hy0 = @max(hole.y, 0);
        const hx1 = @min(hole.x + hole.w, ui.width);
        const hy1 = @min(hole.y + hole.h, ui.height);
        if (hy0 > 0) ui.addBox(.{ .x = 0, .y = 0, .w = ui.width, .h = hy0 }, .{ .fill = shade });
        if (hy1 < ui.height) ui.addBox(.{ .x = 0, .y = hy1, .w = ui.width, .h = ui.height - hy1 }, .{ .fill = shade });
        if (hx0 > 0) ui.addBox(.{ .x = 0, .y = hy0, .w = hx0, .h = hy1 - hy0 }, .{ .fill = shade });
        if (hx1 < ui.width) ui.addBox(.{ .x = hx1, .y = hy0, .w = ui.width - hx1, .h = hy1 - hy0 }, .{ .fill = shade });
        // 聚光边框（压在压暗层之上，用来把目标「框出来」）
        ui.addBox(.{ .x = hx0 - 1, .y = hy0 - 1, .w = hx1 - hx0 + 2, .h = hy1 - hy0 + 2 }, .{ .border = theme.accent, .radius = theme.radius_control + 2 });
    }

    // 卡片：高度由内容决定（尺寸池上一轮做实了「帧末回填 → 下一帧用真值」）
    const w = opts.width;
    const sig = core.Context.idOf(id) ^ core.Context.idOf(cur.title) ^ 0x70C4;
    const est_h: f32 = 150;
    const card_h = if (ui.knownSize(sig)) |s| s.h else est_h;
    var x: f32 = (ui.width - w) / 2;
    var y: f32 = (ui.height - card_h) / 2;
    if (hole.w > 0) {
        switch (cur.placement) {
            .bottom, .bottom_start, .bottom_end => {
                y = hole.y + hole.h + GAP;
                x = switch (cur.placement) {
                    .bottom_start => hole.x,
                    .bottom_end => hole.x + hole.w - w,
                    else => hole.x + hole.w / 2 - w / 2,
                };
            },
            .top, .top_start, .top_end => {
                y = hole.y - card_h - GAP;
                x = switch (cur.placement) {
                    .top_start => hole.x,
                    .top_end => hole.x + hole.w - w,
                    else => hole.x + hole.w / 2 - w / 2,
                };
            },
            .right, .right_start => {
                x = hole.x + hole.w + GAP;
                y = hole.y;
            },
            .left, .left_start => {
                x = hole.x - w - GAP;
                y = hole.y;
            },
        }
    }
    if (x + w > ui.width - 8) x = ui.width - w - 8;
    if (x < 8) x = 8;
    if (y + card_h > ui.height - 8) y = ui.height - card_h - 8;
    if (y < 8) y = 8;

    var card = ui.panel(.{ .x = x, .y = y, .w = w, .h = 0 }, .{
        .pad = 16,
        .gap = 8,
        .fill = theme.surface,
        .radius = 12,
        .border = theme.border,
        .auto_height = true,
        .size_key = sig,
    });

    _ = ui.textRun(cur.title, 16, theme.text);
    if (cur.body.len > 0) _ = ui.textRun(cur.body, theme.font_body, theme.secondary);

    var action: Action = .none;
    {
        const row = ui.reserve(0, 30, true);
        var buf: [24]u8 = undefined;
        const cnt = std.fmt.bufPrint(buf[0..], "{d} / {d}", .{ idx + 1, steps.len }) catch "?";
        const cm = ui.measureText(cnt, theme.font_small);
        ui.addText(.{ .x = row.x, .y = row.y + (30 - cm.h) / 2, .w = cm.w, .h = cm.h }, ui.frameStr(cnt), theme.font_small, theme.secondary);

        const bw: f32 = 74;
        const right_x = row.x + row.w - bw;
        const label = if (last) opts.done_label else opts.next_label;
        if (widgets.buttonRect(ui, .{ .x = right_x, .y = row.y, .w = bw, .h = 30 }, label, .{ .variant = .primary })) {
            action = if (last) .done else .next;
        }
        if (idx > 0) {
            if (widgets.buttonRect(ui, .{ .x = right_x - bw - 8, .y = row.y, .w = bw, .h = 30 }, opts.back_label, .{})) {
                action = .back;
            }
        }
    }
    card.end();

    // 点压暗区 = 下一步（与「点任意处继续」的常见引导一致）；点卡片内部不算
    const card_rect = t.Rect{ .x = x, .y = y, .w = w, .h = card_h };
    if (action == .none and ui.overlayBackdropClicked()) {
        const inside = if (ui.input.click) |p| card_rect.contains(p.x, p.y) else false;
        if (!inside) action = if (last) .done else .next;
    }
    if (ui.input.keyPressed(.right) or ui.input.keyPressed(.enter)) action = if (last) .done else .next;
    if (ui.input.keyPressed(.left) and idx > 0) action = .back;
    if (ui.input.keyPressed(.escape)) action = .skipped;

    switch (action) {
        .next => step.* = @intCast(idx + 1),
        .back => step.* = @intCast(idx - 1),
        .done, .skipped => step.* = -1,
        .none => {},
    }
    return action;
}
