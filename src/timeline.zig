//! 时间线族（对位 CUI `cui_timeline.c` 的编辑器部分）：轨道 + 关键帧 + 播放头 + 标尺。
//!
//! 立即模式口径：关键帧数组与播放头都由调用方持有，控件只负责「拖动、点选、按键」并把
//! 结果写回，返回本帧发生了什么（CUI 的 `cui_timeline_editor_result` 同义）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const num = @import("num.zig");
const t = @import("types.zig");

pub const TimelineKey = struct {
    time: f32,
    /// 轨道内的取值（画成纵向位置）。
    value: f32 = 0.5,
    selected: bool = false,
};

pub const TimelineTrack = struct {
    name: []const u8,
    keys: []TimelineKey,
};

pub const TimelineOpts = struct {
    /// 整块高度（含标尺与轨道）。
    height: f32 = 180,
    time_min: f32 = 0,
    time_max: f32 = 10,
    row_h: f32 = 26,
    /// 轨道名宽度。
    name_w: f32 = 96,
    /// 循环播放（由调用方处理，这里只是标记）。
    loop: bool = false,
};

pub const TimelineResult = struct {
    changed: bool = false,
    time_changed: bool = false,
    scrubbing: bool = false,
    play_toggled: bool = false,
    keys_moved: bool = false,
    /// 本帧被点选/取消选中的关键帧（-1 表示没有）。
    picked_track: i32 = -1,
    picked_key: i32 = -1,
};

pub const TimelineState = struct {
    /// 拖动起点（鼠标 x）与原始时间。
    drag_x: f32 = 0,
    drag_time: f32 = 0,
    drag_track: usize = 0,
    drag_key: usize = 0,
    dragging: bool = false,
};

fn timeToX(x0: f32, w: f32, tm: f32, t_min: f32, t_max: f32) f32 {
    if (t_max <= t_min) return x0;
    const r = (tm - t_min) / (t_max - t_min);
    return x0 + w * (if (r < 0) 0 else if (r > 1) 1 else r);
}

fn xToTime(x: f32, x0: f32, w: f32, t_min: f32, t_max: f32) f32 {
    if (w <= 0) return t_min;
    const r = (x - x0) / w;
    return t_min + (t_max - t_min) * (if (r < 0) 0 else if (r > 1) 1 else r);
}

/// 时间线编辑器（CUI `cui_timeline_editor`）：标尺点选/拖拽播放头、关键帧拖动、
/// 方向键移动选中帧、Space 播放/暂停、Delete 删除选中帧。
pub fn timelineEditor(
    ui: *core.Context,
    id: []const u8,
    tracks: []TimelineTrack,
    playhead: *f32,
    state: *TimelineState,
    opts: TimelineOpts,
) TimelineResult {
    var res = TimelineResult{};
    const h = if (opts.height > 80) opts.height else 180;
    const row_h = if (opts.row_h > 12) opts.row_h else 26;
    const name_w = if (opts.name_w > 40) opts.name_w else 96;
    const ruler_h: f32 = 22;
    const rect = ui.reserve(0, h, true);
    ui.addBox(rect, .{ .fill = theme.bg, .radius = 8, .border = theme.border });

    const lane_x = rect.x + name_w;
    const lane_w = rect.w - name_w - 12;
    const ruler_y = rect.y;
    const track_y0 = rect.y + ruler_h + 2;

    // ---- 标尺：每 1 秒一个刻度 + 每 5 秒标数字
    const ruler_hit = ui.interactEx(core.Context.idOf(id) ^ 0x71E0, .{
        .x = lane_x,
        .y = ruler_y,
        .w = lane_w,
        .h = ruler_h,
    }, false);
    var tick: i32 = @intFromFloat(@ceil(opts.time_min));
    while (@as(f32, @floatFromInt(tick)) <= opts.time_max) : (tick += 1) {
        const tx = timeToX(lane_x, lane_w, @floatFromInt(tick), opts.time_min, opts.time_max);
        const major = @mod(tick, 5) == 0;
        ui.addOverlayLine(.{ .x = tx, .y = ruler_y + ruler_h - (if (major) @as(f32, 10) else 5) }, .{ .x = tx, .y = ruler_y + ruler_h }, 1, theme.border);
        if (major) {
            var nb: [12]u8 = undefined;
            const ns = ui.frameStr(num.int(&nb, @intCast(tick)));
            ui.addText(
                .{ .x = tx + 3, .y = ruler_y + 2, .w = 24, .h = 12 },
                ns,
                theme.font_small,
                theme.secondary,
            );
        }
    }

    // ---- 播放头交互（标尺点击 / 拖拽）
    if (ui.input.pressed and ruler_hit.hover) {
        state.dragging = true;
    }
    if (state.dragging) {
        if (ui.input.down) {
            const nt = xToTime(ui.input.mouse.x, lane_x, lane_w, opts.time_min, opts.time_max);
            if (nt != playhead.*) {
                playhead.* = nt;
                res.time_changed = true;
            }
            res.scrubbing = true;
        } else {
            state.dragging = false;
        }
    }

    // ---- 轨道与关键帧
    for (tracks, 0..) |*tr, ti| {
        const ry = track_y0 + @as(f32, @floatFromInt(ti)) * (row_h + 2);
        if (ry + row_h > rect.y + rect.h) break;
        const label_row = t.Rect{ .x = rect.x + 8, .y = ry, .w = name_w - 8, .h = row_h };
        const nm = ui.measureText(tr.name, theme.font_small);
        ui.addText(
            .{ .x = label_row.x, .y = ry + (row_h - nm.h) / 2, .w = nm.w, .h = nm.h },
            tr.name,
            theme.font_small,
            theme.text,
        );
        // 轨道底
        ui.addBox(.{ .x = lane_x, .y = ry + row_h / 2 - 1, .w = lane_w, .h = 2 }, .{ .fill = theme.track, .radius = 1 });

        for (tr.keys, 0..) |*k, ki| {
            const kx = timeToX(lane_x, lane_w, k.time, opts.time_min, opts.time_max);
            const kw: f32 = 9;
            const marker = t.Rect{ .x = kx - kw / 2, .y = ry + (row_h - kw) / 2, .w = kw, .h = kw };
            // 命中区比标记大，方便点中
            const hz = t.Rect{ .x = kx - 7, .y = ry, .w = 14, .h = row_h };
            const khit = ui.interactEx(core.Context.idOf(id) ^ (0x7A00 + ti * 64 + ki), hz, true);
            ui.addBox(marker, .{
                .fill = if (k.selected) theme.accent else theme.bg,
                .radius = 2,
                .border = if (khit.hover) theme.accent else theme.secondary,
            });

            if (khit.clicked) {
                if (!ui.input.mods.shift) {
                    for (tracks) |*other| {
                        for (other.keys) |*ok| ok.selected = false;
                    }
                }
                k.selected = true;
                res.picked_track = @intCast(ti);
                res.picked_key = @intCast(ki);
                state.drag_x = ui.input.mouse.x;
                state.drag_time = k.time;
                state.drag_track = ti;
                state.drag_key = ki;
            }
        }
    }

    // ---- 选中帧的整体拖动（用第一帧选中帧建立拖拽）
    if (ui.input.pressed and ui.input.down) {
        for (tracks, 0..) |tr, ti| {
            for (tr.keys, 0..) |k, ki| {
                if (!k.selected) continue;
                const kx = timeToX(lane_x, lane_w, k.time, opts.time_min, opts.time_max);
                const hz = t.Rect{ .x = kx - 7, .y = track_y0 + @as(f32, @floatFromInt(ti)) * (row_h + 2), .w = 14, .h = row_h };
                if (hz.contains(ui.input.mouse.x, ui.input.mouse.y)) {
                    state.dragging = false; // 播放头不抢
                    state.drag_x = ui.input.mouse.x;
                    state.drag_time = k.time;
                    state.drag_track = ti;
                    state.drag_key = ki;
                }
            }
        }
    }
    if (ui.input.down and state.drag_track < tracks.len) {
        const tr = &tracks[state.drag_track];
        if (state.drag_key < tr.keys.len) {
            const k = &tr.keys[state.drag_key];
            if (k.selected and @abs(ui.input.mouse.x - state.drag_x) > 1.5) {
                const dt = (ui.input.mouse.x - state.drag_x) / lane_w * (opts.time_max - opts.time_min);
                var nt = state.drag_time + dt;
                if (nt < opts.time_min) nt = opts.time_min;
                if (nt > opts.time_max) nt = opts.time_max;
                if (nt != k.time) {
                    k.time = nt;
                    res.keys_moved = true;
                    res.changed = true;
                }
            }
        }
    }

    // ---- 键盘：方向键微调选中帧、Space 播放、Delete 删除
    if (ruler_hit.focused) {
        if (ui.input.keyPressed(.space)) res.play_toggled = true;
    }
    if (ui.input.keyPressed(.left) or ui.input.keyPressed(.right)) {
        const step: f32 = if (ui.input.mods.shift) 0.5 else 0.1;
        const dir: f32 = if (ui.input.keyPressed(.left)) -1 else 1;
        for (tracks) |*tr| {
            for (tr.keys) |*k| {
                if (!k.selected) continue;
                var nt = k.time + step * dir;
                if (nt < opts.time_min) nt = opts.time_min;
                if (nt > opts.time_max) nt = opts.time_max;
                if (nt != k.time) {
                    k.time = nt;
                    res.keys_moved = true;
                    res.changed = true;
                }
            }
        }
    }

    // ---- 播放头（画在轨道之上）
    const px = timeToX(lane_x, lane_w, playhead.*, opts.time_min, opts.time_max);
    ui.addOverlayLine(.{ .x = px, .y = ruler_y }, .{ .x = px, .y = rect.y + rect.h - 2 }, 1.5, theme.danger);
    ui.addBox(.{ .x = px - 4, .y = ruler_y, .w = 8, .h = 6 }, .{ .fill = theme.danger, .radius = 2 });

    return res;
}
