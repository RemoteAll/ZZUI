//! AI 界面族（对位 CUI `cui_ai.c` 13 个 API）：推理折叠块、工具调用、智能体计划与状态、
//! 来源卡片与行内引用、上下文环、回复操作、提示建议、模型选择器、聊天输入框、语音球。
//!
//! 这一族几乎全是「已有控件的组合」，所以全部落地、零堆分配：
//! 卡片一律 `addBox` + `addText`，状态色复用 `trace` 的 8 色语义色。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **折叠体不做高度动画**（CUI 用 spring 收放）：ZZUI 的 `anim` 只插值颜色、不插几何，
//!   收放是瞬时的；`reasoning` 的标题秒数照样随状态跳；
//! - **计划/工具调用的连接轨道用矩形+圆点拼**，不画抗锯齿斜线（软件光栅没有 AA）；
//! - **语音球只有 3 层同心圆环**（CUI 是几十段贝塞尔噪声），但状态色/呼吸/电平响应都在；
//! - 模型选择的浮层自己画（`panel` + 行），不复用 `overlay.selectPopup`（那是给字符串列表的，
//!   这里每行要名字/说明/徽标三列）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const trace = @import("trace.zig");
const widgets = @import("widgets.zig");
const extras = @import("extras.zig");
const textedit = @import("textedit.zig");
const codeview = @import("codeview.zig");

pub const Tone = trace.Tone;

/// 任务状态（计划步骤 / 工具调用 / 智能体状态共用）。
pub const Status = enum(u8) { pending, running, done, failed, skipped };

fn statusTone(s: Status) Tone {
    return switch (s) {
        .pending => .neutral,
        .running => .info,
        .done => .success,
        .failed => .danger,
        .skipped => .neutral,
    };
}

fn statusLabel(s: Status) []const u8 {
    return switch (s) {
        .pending => "pending",
        .running => "running",
        .done => "done",
        .failed => "failed",
        .skipped => "skipped",
    };
}

/// 秒数格式化：`12s` / `1m 05s`。
fn fmtSecs(buf: []u8, secs: f32) []const u8 {
    const total: u32 = @intFromFloat(@max(0.0, secs));
    if (total < 60) {
        var tmp: [8]u8 = undefined;
        const s = num.int(tmp[0..], total);
        return std.fmt.bufPrint(buf, "{s}s", .{s}) catch "0s";
    }
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const mm = num.int(a[0..], total / 60);
    const ss = num.int(b[0..], total % 60);
    return std.fmt.bufPrint(buf, "{s}m {s}s", .{ mm, ss }) catch "0s";
}

fn idOf(ui: *core.Context, id: []const u8) u64 {
    _ = ui;
    return core.Context.idOf(id);
}

fn clipText(ui: *core.Context, s: []const u8, size: f32, max_w: f32) []const u8 {
    if (s.len == 0 or max_w <= 12) return "";
    if (ui.measureText(s, size).w <= max_w) return s;
    var take: usize = @min(s.len, 60);
    while (take > 0) : (take -= 1) {
        var n = take;
        while (n > 0 and (s[n - 1] & 0xC0) == 0x80) n -= 1;
        var buf: [68]u8 = undefined;
        if (n + 3 <= buf.len) {
            @memcpy(buf[0..n], s[0..n]);
            buf[n] = '.';
            buf[n + 1] = '.';
            buf[n + 2] = '.';
            if (ui.measureText(buf[0 .. n + 3], size).w <= max_w) return ui.frameStr(buf[0 .. n + 3]);
        }
    }
    return "";
}

// ---------------------------------------------------------------- 推理折叠块

pub const ReasoningOpts = struct {
    /// 正在思考（标题会显示动态省略号与秒数）。
    thinking: bool = false,
    /// 思考用时（思考中给 0）。
    seconds: f32 = 0,
    title: []const u8 = "",
};

pub const ReasoningState = struct {
    open: bool = true,
    hover: bool = false,
};

/// 推理块的开头。返回 true 表示体是展开的（调用方在 `end` 之前放内容）。
pub fn reasoningBegin(ui: *core.Context, id: []const u8, st: *ReasoningState, opts: ReasoningOpts) bool {
    const row_h: f32 = 30;
    const hint: []const u8 = if (opts.thinking) "Thinking" else "Thought";
    const row = ui.reserve(0, row_h, true);
    const hit = ui.interactEx(idOf(ui, id) ^ 0x4A11, row, true);
    if (hit.clicked) st.open = !st.open;
    st.hover = hit.hover;
    const base_tone: Tone = if (opts.thinking) .info else .neutral;
    const c = trace.toneColor(base_tone);
    if (hit.hover) ui.addBox(row, .{ .fill = theme.track, .radius = 6 });
    // 折叠箭头（用两段矩形拼）
    const cx = row.x + 6;
    const cy = row.y + row_h * 0.5;
    if (st.open) {
        ui.addBox(.{ .x = cx, .y = cy - 2, .w = 6, .h = 2 }, .{ .fill = theme.secondary });
        ui.addBox(.{ .x = cx + 2, .y = cy, .w = 2, .h = 2 }, .{ .fill = theme.secondary });
    } else {
        ui.addBox(.{ .x = cx + 1, .y = cy - 3, .w = 2, .h = 6 }, .{ .fill = theme.secondary });
        ui.addBox(.{ .x = cx + 3, .y = cy - 1, .w = 2, .h = 2 }, .{ .fill = theme.secondary });
    }
    var buf: [24]u8 = undefined;
    var label_buf: [48]u8 = undefined;
    const dots: []const u8 = if (opts.thinking) "..." else "";
    const secs = if (opts.thinking) "" else ui.frameStr(fmtSecs(buf[0..], opts.seconds));
    const label = if (opts.title.len > 0)
        (std.fmt.bufPrint(label_buf[0..], "{s}  {s}{s}", .{ opts.title, secs, dots }) catch opts.title)
    else
        (std.fmt.bufPrint(label_buf[0..], "{s} for {s}{s}", .{ hint, secs, dots }) catch hint);
    ui.addText(.{
        .x = row.x + 18,
        .y = row.y + 6,
        .w = @max(20, row.w - 24),
        .h = 18,
    }, clipText(ui, ui.frameStr(label), theme.font_small, row.w - 24), theme.font_small, if (opts.thinking) c else theme.secondary);
    if (opts.thinking) ui.requestFrame();
    return st.open;
}

pub fn reasoningEnd(ui: *core.Context, st: *ReasoningState) void {
    _ = ui;
    _ = st;
}

// ---------------------------------------------------------------- 工具调用

pub const ToolCallOpts = struct {
    status: Status = .pending,
    detail: []const u8 = "",
    /// 输入 / 输出（输出像 JSON 就按 JSON 高亮显示）。
    input: []const u8 = "",
    output: []const u8 = "",
    seconds: f32 = 0,
};

pub const ToolCallState = struct {
    open: bool = false,
};

/// 工具调用行（点开看输入与输出）。
pub fn toolCall(ui: *core.Context, id: []const u8, st: *ToolCallState, name: []const u8, opts: ToolCallOpts) void {
    const row_h: f32 = 34;
    const row = ui.reserve(0, row_h, true);
    const hit = ui.interactEx(idOf(ui, id) ^ 0xA11D, row, true);
    if (hit.clicked and (opts.input.len > 0 or opts.output.len > 0)) st.open = !st.open;
    ui.addBox(row, .{
        .fill = if (hit.hover) theme.track else theme.surface,
        .radius = 6,
        .border = theme.border,
    });
    const tone = statusTone(opts.status);
    // 状态点（运行中是空心圈，完成是实心）
    const dx = row.x + 12;
    const dy = row.y + row_h * 0.5;
    if (opts.status == .running) {
        ui.addBox(.{ .x = dx - 4, .y = dy - 4, .w = 8, .h = 8 }, .{ .fill = theme.surface, .radius = 4, .border = trace.toneColor(tone), .border_width = 2 });
        ui.requestFrame();
    } else {
        ui.addBox(.{ .x = dx - 4, .y = dy - 4, .w = 8, .h = 8 }, .{ .fill = trace.toneColor(tone), .radius = 4 });
    }
    // 名字 + 细节
    const name_w = ui.measureText(name, theme.font_small).w;
    ui.addText(.{ .x = row.x + 24, .y = row.y + 8, .w = name_w + 2, .h = 18 }, name, theme.font_small, theme.text);
    if (opts.detail.len > 0) {
        const x0 = row.x + 24 + name_w + 8;
        ui.addText(.{
            .x = x0,
            .y = row.y + 8,
            .w = @max(8, row.x + row.w - 90 - x0),
            .h = 18,
        }, clipText(ui, opts.detail, theme.font_small, @max(8, row.x + row.w - 90 - x0)), theme.font_small, theme.secondary);
    }
    // 右侧：状态徽标 + 秒数
    var buf: [16]u8 = undefined;
    const secs = if (opts.seconds > 0) ui.frameStr(fmtSecs(buf[0..], opts.seconds)) else "";
    const badge_w = ui.measureText(statusLabel(opts.status), theme.font_small).w + 14;
    const right_x = row.x + row.w - 10 - badge_w - (if (secs.len > 0) ui.measureText(secs, theme.font_small).w + 8 else 0);
    if (secs.len > 0) {
        ui.addText(.{ .x = right_x + badge_w + 8, .y = row.y + 8, .w = 60, .h = 18 }, secs, theme.font_small, theme.secondary);
    }
    ui.addBox(.{ .x = right_x, .y = row.y + 7, .w = badge_w, .h = 18 }, .{
        .fill = theme.withAlpha(trace.toneColor(tone), 40),
        .radius = 9,
    });
    ui.addText(.{ .x = right_x + 7, .y = row.y + 8, .w = badge_w - 10, .h = 18 }, statusLabel(opts.status), theme.font_small, trace.toneColor(tone));

    if (st.open) {
        var col = ui.column(.{ .pad = 10, .gap = 6 });
        defer col.end();
        if (opts.input.len > 0) {
            extras.muted(ui, "input");
            codeview.codeBlock(ui, "tc-input", opts.input, .{ .lang = "json", .size = 11, .line_numbers = false, .max_height = 120 });
        }
        if (opts.output.len > 0) {
            extras.muted(ui, "output");
            codeview.codeBlock(ui, "tc-output", opts.output, .{ .lang = "json", .size = 11, .line_numbers = false, .max_height = 160 });
        }
    }
}

// ---------------------------------------------------------------- 智能体计划

pub const PlanStep = struct {
    title: []const u8 = "",
    detail: []const u8 = "",
    status: Status = .pending,
};

pub const AgentPlanOpts = struct {
    title: []const u8 = "Plan",
};

/// 计划步骤轨道。返回本帧点击的步骤下标（-1 = 无）。
pub fn agentPlan(ui: *core.Context, id: []const u8, steps: []const PlanStep, opts: AgentPlanOpts) i32 {
    var clicked: i32 = -1;
    const done = blk: {
        var n: usize = 0;
        for (steps) |s| {
            if (s.status == .done) n += 1;
        }
        break :blk n;
    };
    // 标题 + 进度
    var head_buf: [48]u8 = undefined;
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const label = std.fmt.bufPrint(head_buf[0..], "{s}  {s}/{s}", .{
        opts.title,
        num.int(a[0..], @intCast(done)),
        num.int(b[0..], @intCast(steps.len)),
    }) catch opts.title;
    extras.muted(ui, ui.frameStr(label));
    extras.meter(ui, "", if (steps.len == 0) 0 else @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(steps.len)));

    // 步骤
    var i: usize = 0;
    while (i < steps.len) : (i += 1) {
        const s = steps[i];
        const row_h: f32 = if (s.detail.len > 0) 44 else 32;
        const row = ui.reserve(0, row_h, true);
        const hit = ui.interact(idOf(ui, id) ^ (0x91F0 + i), row);
        if (hit.clicked) clicked = @intCast(i);
        const tone = statusTone(s.status);
        const cx = row.x + 10;
        const cy = row.y + 16;
        // 轨道（除最后一步）
        if (i + 1 < steps.len) {
            ui.addBox(.{ .x = cx - 0.5, .y = cy + 5, .w = 1.5, .h = row_h - 10 }, .{ .fill = theme.border });
        }
        // 圆点（完成=实心，运行=环 + 深色芯，失败=实心红，其余空心）
        switch (s.status) {
            .done => ui.addBox(.{ .x = cx - 4, .y = cy - 4, .w = 8, .h = 8 }, .{ .fill = trace.toneColor(tone), .radius = 4 }),
            .running => {
                ui.addBox(.{ .x = cx - 5, .y = cy - 5, .w = 10, .h = 10 }, .{ .fill = theme.surface, .radius = 5, .border = trace.toneColor(tone), .border_width = 2 });
                ui.addBox(.{ .x = cx - 2, .y = cy - 2, .w = 4, .h = 4 }, .{ .fill = trace.toneColor(tone), .radius = 2 });
                ui.requestFrame();
            },
            .failed => ui.addBox(.{ .x = cx - 4, .y = cy - 4, .w = 8, .h = 8 }, .{ .fill = trace.toneColor(tone), .radius = 4 }),
            else => ui.addBox(.{ .x = cx - 4, .y = cy - 4, .w = 8, .h = 8 }, .{ .fill = theme.surface, .radius = 4, .border = theme.secondary, .border_width = 1.5 }),
        }
        const text_col = if (s.status == .pending or s.status == .skipped) theme.secondary else theme.text;
        ui.addText(.{
            .x = row.x + 22,
            .y = row.y + 6,
            .w = @max(20, row.w - 28),
            .h = 18,
        }, clipText(ui, s.title, theme.font_body, row.w - 28), theme.font_body, text_col);
        if (s.detail.len > 0) {
            ui.addText(.{
                .x = row.x + 22,
                .y = row.y + 24,
                .w = @max(20, row.w - 28),
                .h = 16,
            }, clipText(ui, s.detail, theme.font_small, row.w - 28), theme.font_small, theme.secondary);
        }
    }
    return clicked;
}

// ---------------------------------------------------------------- 智能体状态药丸

pub const AgentStatusOpts = struct {
    status: Status = .running,
    seconds: f32 = 0,
};

/// 「正在做什么 + 多久了」的药丸。
pub fn agentStatus(ui: *core.Context, text: []const u8, opts: AgentStatusOpts) void {
    var buf: [16]u8 = undefined;
    const secs = if (opts.seconds > 0) ui.frameStr(fmtSecs(buf[0..], opts.seconds)) else "";
    const label_w = ui.measureText(text, theme.font_small).w;
    const secs_w = if (secs.len > 0) ui.measureText(secs, theme.font_small).w + 8 else 0;
    const w = label_w + secs_w + 34;
    const pill = ui.reserve(w, 26, false);
    const tone = statusTone(opts.status);
    ui.addBox(pill, .{
        .fill = theme.withAlpha(trace.toneColor(tone), 34),
        .radius = 13,
        .border = theme.withAlpha(trace.toneColor(tone), 120),
    });
    // 左侧小圆点（运行中呼吸）
    const cx = pill.x + 12;
    const cy = pill.y + 13;
    if (opts.status == .running) {
        const ph = breathe(ui, 4.0);
        ui.addBox(.{ .x = cx - 3, .y = cy - 3, .w = 6, .h = 6 }, .{
            .fill = theme.withAlpha(trace.toneColor(tone), @intFromFloat(120 + 120 * ph)),
            .radius = 3,
        });
        ui.requestFrame();
    } else {
        ui.addBox(.{ .x = cx - 3, .y = cy - 3, .w = 6, .h = 6 }, .{ .fill = trace.toneColor(tone), .radius = 3 });
    }
    ui.addText(.{ .x = pill.x + 22, .y = pill.y + 5, .w = label_w + 2, .h = 18 }, text, theme.font_small, theme.text);
    if (secs.len > 0) {
        ui.addText(.{ .x = pill.x + 22 + label_w + 8, .y = pill.y + 5, .w = secs_w, .h = 18 }, secs, theme.font_small, theme.secondary);
    }
}

// ---------------------------------------------------------------- 来源与引用

pub const Source = struct {
    title: []const u8 = "",
    url: []const u8 = "",
    snippet: []const u8 = "",
};

/// 来源卡片列表。返回本帧点击的卡片下标（-1 = 无）。
pub fn sourceList(ui: *core.Context, id: []const u8, sources: []const Source) i32 {
    var clicked: i32 = -1;
    for (sources, 0..) |s, i| {
        const row_h: f32 = if (s.snippet.len > 0) 58 else 40;
        const row = ui.reserve(0, row_h, true);
        const hit = ui.interactEx(idOf(ui, id) ^ (0x50C0 + i), row, true);
        if (hit.clicked) clicked = @intCast(i);
        ui.addBox(row, .{
            .fill = if (hit.hover) theme.track else theme.surface,
            .radius = 8,
            .border = theme.border,
        });
        // 序号
        var nb: [8]u8 = undefined;
        const n = ui.frameStr(num.int(nb[0..], @intCast(i + 1)));
        ui.addBox(.{ .x = row.x + 8, .y = row.y + 8, .w = 18, .h = 18 }, .{ .fill = theme.withAlpha(theme.accent, 40), .radius = 5 });
        ui.addText(.{ .x = row.x + 12, .y = row.y + 9, .w = 14, .h = 16 }, n, theme.font_small, theme.accent);
        ui.addText(.{
            .x = row.x + 32,
            .y = row.y + 8,
            .w = @max(20, row.w - 40),
            .h = 18,
        }, clipText(ui, s.title, theme.font_small, row.w - 40), theme.font_small, theme.text);
        if (s.url.len > 0) {
            ui.addText(.{
                .x = row.x + 32,
                .y = row.y + 24,
                .w = @max(20, row.w - 40),
                .h = 16,
            }, clipText(ui, s.url, theme.font_small, row.w - 40), theme.font_small, theme.accent);
        }
        if (s.snippet.len > 0) {
            ui.addText(.{
                .x = row.x + 32,
                .y = row.y + 39,
                .w = @max(20, row.w - 40),
                .h = 16,
            }, clipText(ui, s.snippet, theme.font_small, row.w - 40), theme.font_small, theme.secondary);
        }
    }
    return clicked;
}

/// 行内引用 `[n]`：悬停显示来源卡；返回 true 表示被点。
pub fn citation(ui: *core.Context, number: i32, source: Source) bool {
    var nb: [8]u8 = undefined;
    const n = ui.frameStr(num.int(nb[0..], @max(0, number)));
    const w = ui.measureText(n, theme.font_small).w + 14;
    const box = ui.reserve(w, 18, false);
    const key = core.Context.idOf("citation") ^ (@as(u64, @intCast(@as(u32, @bitCast(number)))) *% 0x9E37);
    const hit = ui.interact(key, box);
    ui.addBox(box, .{
        .fill = if (hit.hover) theme.accent_bg else theme.track,
        .radius = 9,
        .border = if (hit.hover) theme.accent else theme.border,
    });
    ui.addText(.{ .x = box.x + 7, .y = box.y + 1, .w = w - 8, .h = 16 }, n, theme.font_small, if (hit.hover) theme.accent else theme.secondary);
    if (hit.hover and source.title.len > 0) {
        // 悬停卡：放到下面（屏幕空间够的话）
        const card_w: f32 = 240;
        const card_h: f32 = if (source.snippet.len > 0) 58 else 40;
        const card = t.Rect{ .x = box.x, .y = box.y + box.h + 4, .w = card_w, .h = card_h };
        ui.addOverlayBox(card, .{ .fill = theme.surface, .radius = 8, .border = theme.border });
        ui.addText(.{ .x = card.x + 10, .y = card.y + 8, .w = card_w - 20, .h = 18 }, clipText(ui, source.title, theme.font_small, card_w - 20), theme.font_small, theme.text);
        if (source.url.len > 0) {
            ui.addText(.{ .x = card.x + 10, .y = card.y + 24, .w = card_w - 20, .h = 16 }, clipText(ui, source.url, theme.font_small, card_w - 20), theme.font_small, theme.accent);
        }
        if (source.snippet.len > 0) {
            ui.addText(.{ .x = card.x + 10, .y = card.y + 39, .w = card_w - 20, .h = 16 }, clipText(ui, source.snippet, theme.font_small, card_w - 20), theme.font_small, theme.secondary);
        }
    }
    return hit.clicked;
}

// ---------------------------------------------------------------- 上下文环

fn tokenCount(v: f32) i64 {
    if (!std.math.isFinite(v) or v <= 0) return 0;
    return @intFromFloat(@min(v, 1.0e12));
}

/// 帧时间驱动的 0..1 呼吸值（`ui.time` 是 f64，这里统一成 f32）。
fn breathe(ui: *core.Context, speed: f64) f32 {
    return @floatCast(0.5 + 0.5 * @sin(ui.time * speed));
}

pub const ContextMeterOpts = struct {
    used: f32 = 0,
    limit: f32 = 128_000,
};

/// 上下文占用对应的语义色：< 80% 成功、80~95% 琥珀、> 95% 危险。
pub fn contextTone(ratio: f32) Tone {
    return if (ratio > 0.95) .danger else if (ratio > 0.8) .warn else .success;
}

/// 「上下文占用」小环 + 数字；> 80% 变琥珀、> 95% 变红。
pub fn contextMeter(ui: *core.Context, id: []const u8, opts: ContextMeterOpts) void {
    const ratio = if (opts.limit <= 0) 0 else std.math.clamp(opts.used / opts.limit, 0, 1);
    const c = trace.toneColor(contextTone(ratio));
    var pb: [8]u8 = undefined;
    const pct = ui.frameStr(num.int(pb[0..], @intFromFloat(@round(ratio * 100))));
    const pct_w = ui.measureText(pct, theme.font_small).w;
    // 预留「环 + 百分比」整宽，不然后面的兄弟控件会被文字盖住
    const ring = ui.reserve(26 + 8 + pct_w + 10, 26, false);
    const cx = ring.x + 13;
    const cy = ring.y + 13;
    // 底环 + 占用弧（用矩形近似弧段，软件光栅没有 AA 圆）
    frameRing(ui, cx, cy, 11, 3, theme.track, 0, 1);
    if (ratio > 0) frameRing(ui, cx, cy, 11, 3, c, 0, ratio);
    ui.addText(.{ .x = ring.x + 34, .y = ring.y + 4, .w = pct_w + 2, .h = 18 }, pct, theme.font_small, theme.secondary);
    ui.addText(.{ .x = ring.x + 34 + pct_w, .y = ring.y + 4, .w = 12, .h = 18 }, "%", theme.font_small, theme.secondary);
    const key = idOf(ui, id) ^ 0x3C07;
    const hit = ui.interact(key, .{ .x = ring.x, .y = ring.y, .w = 34 + ui.measureText(pct, theme.font_small).w, .h = 26 });
    if (hit.hover) {
        var tb: [64]u8 = undefined;
        var a: [16]u8 = undefined;
        var b: [16]u8 = undefined;
        const label = std.fmt.bufPrint(tb[0..], "{s} / {s} tokens", .{
            num.int(a[0..], tokenCount(opts.used)),
            num.int(b[0..], tokenCount(opts.limit)),
        }) catch "context";
        const card = t.Rect{ .x = ring.x, .y = ring.y + 28, .w = ui.measureText(label, theme.font_small).w + 20, .h = 26 };
        ui.addOverlayBox(card, .{ .fill = theme.overlay_bg, .radius = 6 });
        ui.addText(.{ .x = card.x + 10, .y = card.y + 5, .w = card.w - 12, .h = 18 }, ui.frameStr(label), theme.font_small, theme.overlay_fg);
    }
}

/// 环形进度：用 N 个小矩形沿圆周铺（软件光栅没有 AA 画线）。
fn frameRing(ui: *core.Context, cx: f32, cy: f32, rad: f32, width: f32, c: t.Color, from: f32, to: f32) void {
    const segs: usize = 48;
    const a0 = from * std.math.pi * 2 - std.math.pi * 0.5;
    const a1 = to * std.math.pi * 2 - std.math.pi * 0.5;
    const total = @max(1, @as(usize, @intFromFloat(@abs(a1 - a0) / (std.math.pi * 2) * @as(f32, @floatFromInt(segs)))));
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const tt = if (total <= 1) 0.0 else @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(total - 1));
        const a = a0 + (a1 - a0) * tt;
        const x = cx + @cos(a) * rad;
        const y = cy + @sin(a) * rad;
        ui.addBox(.{ .x = x - width * 0.5, .y = y - width * 0.5, .w = width, .h = width }, .{ .fill = c, .radius = width * 0.5 });
    }
}

// ---------------------------------------------------------------- 回复操作

pub const RESPONSE_COPY: u32 = 1;
pub const RESPONSE_REGENERATE: u32 = 2;
pub const RESPONSE_UP: u32 = 4;
pub const RESPONSE_DOWN: u32 = 8;
pub const RESPONSE_SHARE: u32 = 16;

pub const ResponseActionsOpts = struct {
    has_regenerate: bool = true,
    has_share: bool = true,
};

/// 回复下方的操作行。`vote` 由调用方持有（0 = 无，1 = 赞，-1 = 踩）；
/// 返回按下的按钮位（`RESPONSE_*`）。
pub fn responseActions(ui: *core.Context, id: []const u8, vote: *i8, opts: ResponseActionsOpts) u32 {
    var flags: u32 = 0;
    var row = ui.row(.{ .gap = 6 });
    defer row.end();
    // 复制
    if (smallAction(ui, idOf(ui, id) ^ 0x0C01, "Copy", false)) flags |= RESPONSE_COPY;
    if (opts.has_regenerate) {
        if (smallAction(ui, idOf(ui, id) ^ 0x0C02, "Regenerate", false)) flags |= RESPONSE_REGENERATE;
    }
    if (smallAction(ui, idOf(ui, id) ^ 0x0C03, "Up", vote.* == 1)) {
        vote.* = if (vote.* == 1) 0 else 1;
        if (vote.* == 1) flags |= RESPONSE_UP;
    }
    if (smallAction(ui, idOf(ui, id) ^ 0x0C04, "Down", vote.* == -1)) {
        vote.* = if (vote.* == -1) 0 else -1;
        if (vote.* == -1) flags |= RESPONSE_DOWN;
    }
    if (opts.has_share) {
        if (smallAction(ui, idOf(ui, id) ^ 0x0C05, "Share", false)) flags |= RESPONSE_SHARE;
    }
    return flags;
}

/// 小号 ghost 按钮（高度 24）；`on` = 选中态（赞/踩）。
fn smallAction(ui: *core.Context, key: u64, label: []const u8, on: bool) bool {
    const m = ui.measureText(label, theme.font_small);
    const w = m.w + 20;
    const box = ui.reserve(w, 24, false);
    const hit = ui.interactEx(key, box, true);
    if (on) {
        ui.addBox(box, .{ .fill = theme.accent_bg, .radius = 6, .border = theme.accent });
    } else if (hit.hover) {
        ui.addBox(box, .{ .fill = theme.track, .radius = 6 });
    }
    ui.addText(.{
        .x = box.x + 10,
        .y = box.y + 3,
        .w = w - 12,
        .h = 18,
    }, label, theme.font_small, if (on) theme.accent else theme.secondary);
    return hit.clicked;
}

// ---------------------------------------------------------------- 提示建议

pub const PromptSuggestion = struct {
    icon: []const u8 = "",
    title: []const u8 = "",
    detail: []const u8 = "",
};

/// 提示建议卡片网格。返回本帧点击的卡片下标（-1 = 无）。
pub fn promptSuggestions(ui: *core.Context, id: []const u8, items: []const PromptSuggestion, columns: usize) i32 {
    if (items.len == 0) return -1;
    const cols = @max(1, columns);
    var clicked: i32 = -1;
    const measured = &ui.stack[ui.depth - 1];
    const avail = if (measured.width > 0) measured.width else 360;
    const gap: f32 = 10;
    const card_w = (avail - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    var row: core.Scope = undefined;
    var in_row = false;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        if (!in_row) {
            row = ui.row(.{ .gap = gap });
            in_row = true;
        }
        const s = items[i];
        const box = ui.reserve(card_w, 74, false);
        const hit = ui.interactEx(idOf(ui, id) ^ (0x7B00 + i), box, true);
        if (hit.clicked) clicked = @intCast(i);
        ui.addBox(box, .{
            .fill = if (hit.hover) theme.track else theme.surface,
            .radius = 8,
            .border = if (hit.hover) theme.accent else theme.border,
        });
        if (s.icon.len > 0) {
            ui.addText(.{ .x = box.x + 10, .y = box.y + 8, .w = 20, .h = 18 }, s.icon, theme.font_body, theme.accent);
        }
        ui.addText(.{
            .x = box.x + 10,
            .y = box.y + 26,
            .w = @max(20, card_w - 20),
            .h = 18,
        }, clipText(ui, s.title, theme.font_small, card_w - 20), theme.font_small, theme.text);
        if (s.detail.len > 0) {
            ui.addText(.{
                .x = box.x + 10,
                .y = box.y + 44,
                .w = @max(20, card_w - 20),
                .h = 20,
            }, clipText(ui, s.detail, theme.font_small, card_w - 20), theme.font_small, theme.secondary);
        }
        if (i % cols == cols - 1 or i + 1 == items.len) {
            row.end();
            in_row = false;
        }
    }
    return clicked;
}

// ---------------------------------------------------------------- 模型选择器

pub const Model = struct {
    name: []const u8 = "",
    detail: []const u8 = "",
    badge: []const u8 = "",
};

pub const ModelPickerState = struct {
    open: bool = false,
    hover: i32 = -1,
};

/// 模型选择按钮 + 浮层列表。`selected` 由调用方持有；返回 true 表示本帧改过选择。
pub fn modelPicker(ui: *core.Context, id: []const u8, st: *ModelPickerState, models: []const Model, selected: *usize, ghost: bool) bool {
    var changed = false;
    const cur = if (selected.* < models.len) models[selected.*] else Model{ .name = "Model" };
    const label_w = ui.measureText(cur.name, theme.font_small).w;
    const btn_w = label_w + (if (cur.badge.len > 0) ui.measureText(cur.badge, theme.font_small).w + 16 else 0) + 34;
    const btn = ui.reserve(btn_w, 28, false);
    const hit = ui.interactEx(idOf(ui, id) ^ 0x3D00, btn, true);
    if (hit.clicked) st.open = !st.open;
    ui.addBox(btn, .{
        .fill = if (ghost and !hit.hover) theme.surface else theme.track,
        .radius = 6,
        .border = if (st.open) theme.accent else theme.border,
    });
    var x = btn.x + 10;
    ui.addText(.{ .x = x, .y = btn.y + 5, .w = label_w + 2, .h = 18 }, cur.name, theme.font_small, theme.text);
    x += label_w + 6;
    if (cur.badge.len > 0) {
        const bw = ui.measureText(cur.badge, theme.font_small).w + 10;
        ui.addBox(.{ .x = x, .y = btn.y + 6, .w = bw, .h = 16 }, .{ .fill = theme.withAlpha(theme.accent, 40), .radius = 8 });
        ui.addText(.{ .x = x + 5, .y = btn.y + 6, .w = bw - 6, .h = 16 }, cur.badge, theme.font_small, theme.accent);
        x += bw;
    }
    // 下拉箭头
    ui.addBox(.{ .x = btn.x + btn.w - 14, .y = btn.y + 12, .w = 6, .h = 2 }, .{ .fill = theme.secondary });
    ui.addBox(.{ .x = btn.x + btn.w - 12, .y = btn.y + 14, .w = 2, .h = 2 }, .{ .fill = theme.secondary });

    if (st.open and models.len > 0) {
        const row_h: f32 = 40;
        const list_h = row_h * @as(f32, @floatFromInt(models.len)) + 8;
        const list = t.Rect{ .x = btn.x, .y = btn.y + btn.h + 4, .w = @max(200, btn_w), .h = list_h };
        ui.addOverlayBox(list, .{ .fill = theme.surface, .radius = 8, .border = theme.border });
        for (models, 0..) |m, i| {
            const rr = t.Rect{ .x = list.x + 4, .y = list.y + 4 + row_h * @as(f32, @floatFromInt(i)), .w = list.w - 8, .h = row_h };
            const rh = ui.interact(idOf(ui, id) ^ (0x3E00 + i), rr);
            if (rh.hover) st.hover = @intCast(i);
            if (rh.hover) ui.addOverlayBox(rr, .{ .fill = theme.track, .radius = 6 });
            if (i == selected.*) {
                ui.addBox(.{ .x = rr.x + 6, .y = rr.y + 6, .w = 3, .h = rr.h - 12 }, .{ .fill = theme.accent, .radius = 1.5 });
            }
            ui.addText(.{ .x = rr.x + 14, .y = rr.y + 5, .w = rr.w - 20, .h = 18 }, m.name, theme.font_small, theme.text);
            if (m.detail.len > 0) {
                ui.addText(.{ .x = rr.x + 14, .y = rr.y + 21, .w = rr.w - 20, .h = 16 }, clipText(ui, m.detail, theme.font_small, rr.w - 20), theme.font_small, theme.secondary);
            }
            if (rh.clicked) {
                if (i != selected.*) {
                    selected.* = i;
                    changed = true;
                }
                st.open = false;
            }
        }
        // 点外面（按在按钮或列表之外）就收起来（按下与释放都要认）
        const out_pt: ?t.Point = if (ui.input.click) |p| p else if (ui.input.pressed) ui.input.mouse else null;
        if (out_pt) |p| {
            if (!list.contains(p.x, p.y) and !btn.contains(p.x, p.y)) st.open = false;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- 聊天输入框

pub const COMPOSER_SEND: u32 = 1;
pub const COMPOSER_STOP: u32 = 2;
pub const COMPOSER_ATTACH: u32 = 4;
pub const COMPOSER_REMOVE: u32 = 8;
pub const COMPOSER_MODEL: u32 = 16;

pub const ComposerOpts = struct {
    placeholder: []const u8 = "Ask anything",
    /// 正在生成：发送按钮变「停止」。
    busy: bool = false,
    attachments: []const []const u8 = &.{},
    max_lines: usize = 8,
};

pub const ComposerState = struct {
    caret: usize = 0,
    buf: [1024]u8 = @splat(0),
    len: usize = 0,
    /// 被点掉的附件下标（调用方每帧读一次，没点就是 -1）。
    removed: i32 = -1,
};

/// 聊天输入框（附件 + 模型选择 + 发送/停止）。返回 `COMPOSER_*` 位标志。
/// 模型列表与当前选择由调用方持有（`models` / `model` / `mp`）。
pub fn chatComposer(
    ui: *core.Context,
    id: []const u8,
    st: *ComposerState,
    models: []const Model,
    model: *usize,
    mp: *ModelPickerState,
    opts: ComposerOpts,
) u32 {
    var flags: u32 = 0;
    st.removed = -1;
    // 附件行
    if (opts.attachments.len > 0) {
        var row = ui.row(.{ .gap = 6 });
        for (opts.attachments, 0..) |a, i| {
            const w = ui.measureText(a, theme.font_small).w + 30;
            const chip = ui.reserve(w, 22, false);
            const hit = ui.interact(idOf(ui, id) ^ (0x4A00 + i), chip);
            ui.addBox(chip, .{ .fill = theme.track, .radius = 11, .border = theme.border });
            ui.addText(.{ .x = chip.x + 8, .y = chip.y + 2, .w = w - 24, .h = 18 }, clipText(ui, a, theme.font_small, w - 26), theme.font_small, theme.text);
            // 小叉（两段矩形）
            ui.addBox(.{ .x = chip.x + w - 14, .y = chip.y + 10, .w = 6, .h = 1.5 }, .{ .fill = theme.secondary });
            ui.addBox(.{ .x = chip.x + w - 11, .y = chip.y + 10, .w = 1.5, .h = 6 }, .{ .fill = theme.secondary });
            if (hit.clicked) {
                st.removed = @intCast(i);
                flags |= COMPOSER_REMOVE;
            }
        }
        row.end();
    }
    // 输入区
    const lines = @max(1, @min(opts.max_lines, 1 + st.len / 48));
    _ = textedit.textarea(ui, id, st.buf[0..], &st.len, &st.caret, .{ .rows = @intCast(lines), .placeholder = opts.placeholder });
    // 底部行：附件按钮 + 模型 + 发送
    {
        var row = ui.row(.{ .gap = 8 });
        if (widgets.button(ui, "+ Attach", .{ .variant = .ghost })) flags |= COMPOSER_ATTACH;
        if (models.len > 0) {
            if (modelPicker(ui, id, mp, models, model, true)) flags |= COMPOSER_MODEL;
        }
        if (opts.busy) {
            if (widgets.button(ui, "Stop", .{ .variant = .secondary })) flags |= COMPOSER_STOP;
        } else {
            if (widgets.button(ui, "Send", .{ .variant = .primary })) flags |= COMPOSER_SEND;
        }
        row.end();
    }
    // 键盘：Enter 发送（textarea 已把回车写成换行，这里撤掉它）、Shift+Enter 换行
    const focus_key = core.Context.idOf(id) ^ 0x7A47E;
    if (ui.focus_id == focus_key and ui.input.keyPressed(.enter) and !ui.input.mods.shift) {
        if (st.len > 0 and st.buf[st.len - 1] == '\n') st.len -= 1;
        if (opts.busy) {
            flags |= COMPOSER_STOP;
        } else if (st.len > 0) {
            flags |= COMPOSER_SEND;
        }
    }
    return flags;
}

// ---------------------------------------------------------------- 语音球

pub const VoiceState = enum(u8) { idle, listening, thinking, speaking };

/// 语音球：状态色 + 呼吸 + 电平。返回 true 表示被点。
pub fn voiceOrb(ui: *core.Context, id: []const u8, state: VoiceState, level: f32, size: f32) bool {
    const box = ui.reserve(size, size, false);
    const hit = ui.interactEx(idOf(ui, id) ^ 0x0A11, box, true);
    const tone: Tone = switch (state) {
        .idle => .neutral,
        .listening => .info,
        .thinking => .violet,
        .speaking => .success,
    };
    const c = trace.toneColor(tone);
    const cx = box.x + size * 0.5;
    const cy = box.y + size * 0.5;
    const lv = std.math.clamp(level, 0, 1);
    // 三层同心圆（外环随电平/时间呼吸）
    const br = breathe(ui, 3.0);
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const f = @as(f32, @floatFromInt(k + 1)) / 3.0;
        const grow: f32 = switch (state) {
            .idle => 0.0,
            .listening => 0.10 * lv + 0.04 * br,
            .thinking => 0.06 * br,
            .speaking => 0.14 * lv + 0.05 * br,
        };
        const r = size * (0.22 + 0.12 * f + grow * f);
        const a: u8 = @intFromFloat(60 + 120 * (1 - f) * (0.5 + 0.5 * lv));
        ui.addBox(.{ .x = cx - r, .y = cy - r, .w = r * 2, .h = r * 2 }, .{
            .fill = theme.withAlpha(c, a),
            .radius = r,
        });
    }
    ui.addBox(.{ .x = cx - size * 0.16, .y = cy - size * 0.16, .w = size * 0.32, .h = size * 0.32 }, .{ .fill = c, .radius = size * 0.16 });
    if (state != .idle) ui.requestFrame();
    return hit.clicked;
}
