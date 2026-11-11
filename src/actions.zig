//! 操作件族（对位 CUI `cui_actions.c`）：两段式确认按钮、就地编辑、快捷键录制与展示、
//! 金额输入、拖拽取数、反应条。
//!
//! 与 `widgets` 的分工：`widgets.button` 是「点一下立即生效」，这里是「点一下要再确认」、
//! 「点一下变可编辑」这类**带内部阶段**的操作件 —— 立即模式下阶段必须由调用方持有（`*State`），
//! 与 CUI 用 `cui_ctx` 内部状态池的做法不同，但语义一致。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const widgets = @import("widgets.zig");
const num = @import("num.zig");
const t = @import("types.zig");

// ---------------------------------------------------------------- 键名与组合键
/// 键的**显示名**（`f1` → `"F1"`、`digit4` → `"4"`、`A` → `"A"`）。
pub fn keyName(k: t.Key) []const u8 {
    return switch (k) {
        .unknown => "",
        .backspace => "Backspace",
        .tab => "Tab",
        .enter => "Enter",
        .escape => "Esc",
        .space => "Space",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .end => "End",
        .home => "Home",
        .left => "Left",
        .up => "Up",
        .right => "Right",
        .down => "Down",
        .insert => "Insert",
        .delete => "Delete",
        .digit0 => "0",
        .digit1 => "1",
        .digit2 => "2",
        .digit3 => "3",
        .digit4 => "4",
        .digit5 => "5",
        .digit6 => "6",
        .digit7 => "7",
        .digit8 => "8",
        .digit9 => "9",
        .A => "A",
        .B => "B",
        .C => "C",
        .D => "D",
        .E => "E",
        .F => "F",
        .G => "G",
        .H => "H",
        .I => "I",
        .J => "J",
        .K => "K",
        .L => "L",
        .M => "M",
        .N => "N",
        .O => "O",
        .P => "P",
        .Q => "Q",
        .R => "R",
        .S => "S",
        .T => "T",
        .U => "U",
        .V => "V",
        .W => "W",
        .X => "X",
        .Y => "Y",
        .Z => "Z",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
        .semicolon => ";",
        .equal => "=",
        .comma => ",",
        .minus => "-",
        .period => ".",
        .slash => "/",
        .tilde => "`",
        .bracket_left => "[",
        .backslash => "\\",
        .bracket_right => "]",
        .quote => "'",
    };
}

/// 组合键（修饰键 + 主键）。CUI 的 `cui_key_combo` 同构。
pub const KeyCombo = struct {
    mods: t.Mods = .{},
    key: t.Key = .unknown,

    pub fn isEmpty(self: KeyCombo) bool {
        return self.key == .unknown and !self.mods.any();
    }

    pub fn eql(a: KeyCombo, b: KeyCombo) bool {
        return a.key == b.key and
            a.mods.ctrl == b.mods.ctrl and
            a.mods.shift == b.mods.shift and
            a.mods.alt == b.mods.alt and
            a.mods.win == b.mods.win;
    }
};

/// 组合键的显示文本（`"Ctrl+Shift+K"`）；结果拷进帧内池，可安全用于绘制。
pub fn shortcutLabel(ui: *core.Context, combo: KeyCombo) []const u8 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    const parts = [_]struct { on: bool, name: []const u8 }{
        .{ .on = combo.mods.ctrl, .name = "Ctrl" },
        .{ .on = combo.mods.shift, .name = "Shift" },
        .{ .on = combo.mods.alt, .name = "Alt" },
        .{ .on = combo.mods.win, .name = "Win" },
    };
    for (parts) |p| {
        if (!p.on) continue;
        for (p.name) |c| {
            if (n < buf.len) {
                buf[n] = c;
                n += 1;
            }
        }
        if (n < buf.len) {
            buf[n] = '+';
            n += 1;
        }
    }
    const kn = keyName(combo.key);
    for (kn) |c| {
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    return ui.frameStr(buf[0..n]);
}

// ---------------------------------------------------------------- 快捷键录制
pub const ShortcutRecorderOpts = struct {
    placeholder: []const u8 = "Press keys",
    /// 0 = 撑满父宽。
    width: f32 = 0,
};

/// 点击聚焦后按任意组合键录制。Backspace 清除、Esc 取消；返回 true 表示组合键变了。
pub fn shortcutRecorder(
    ui: *core.Context,
    id: []const u8,
    combo: *KeyCombo,
    opts: ShortcutRecorderOpts,
) bool {
    const h: f32 = 34;
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const it = ui.interactEx(core.Context.idOf(id) ^ 0x5EA1C0DE, rect, true);
    var changed = false;

    if (it.focused) {
        if (ui.input.keyPressed(.escape) or ui.input.keyPressed(.backspace)) {
            if (!combo.isEmpty()) {
                combo.* = .{};
                changed = true;
            }
        } else if (ui.input.firstTypedKey()) |k| {
            const next = KeyCombo{ .mods = ui.input.mods, .key = k };
            if (!KeyCombo.eql(next, combo.*)) {
                combo.* = next;
                changed = true;
            }
        }
    }

    const border = if (it.focused) theme.accent else theme.border;
    widgets.ringBox(ui, rect, theme.radius_control, theme.bg, border);

    const label = if (it.focused)
        opts.placeholder
    else if (combo.isEmpty())
        opts.placeholder
    else
        shortcutLabel(ui, combo.*);
    const color: t.Color = if (combo.isEmpty() and !it.focused) theme.secondary else theme.text;
    const m = ui.measureText(label, theme.font_body);
    ui.addText(
        .{ .x = rect.x + 10, .y = rect.y + (rect.h - m.h) / 2, .w = m.w, .h = m.h },
        label,
        theme.font_body,
        color,
    );
    if (it.focused and !combo.isEmpty()) {
        // 录制中把当前组合键显示在右侧，避免用户以为输入框空了
        const cur = shortcutLabel(ui, combo.*);
        const cm = ui.measureText(cur, theme.font_small);
        ui.addText(
            .{ .x = rect.x + rect.w - cm.w - 10, .y = rect.y + (rect.h - cm.h) / 2, .w = cm.w, .h = cm.h },
            cur,
            theme.font_small,
            theme.accent,
        );
    }
    return changed;
}

// ---------------------------------------------------------------- 两段式确认按钮
pub const ConfirmState = struct {
    armed: bool = false,
    /// 进入待确认时的帧时间（超时自动复位）。
    since: f64 = 0,
};

pub const ConfirmButtonOpts = struct {
    /// 待确认阶段显示的文案。
    confirm_label: []const u8 = "Click again to confirm",
    variant: t.Variant = .secondary,
    /// 待确认阶段保持多久（秒），超时自动复位。
    timeout: f64 = 3.0,
    /// 待确认阶段是否用危险色。
    danger: bool = true,
    width: f32 = 0,
    id_salt: u64 = 0,
};

/// 危险操作的「点两下」按钮：第一次点击进入待确认（`state.armed`），
/// `timeout` 秒内再点才返回 true。比原生 confirm 弹窗轻，且不打断布局。
pub fn confirmButton(
    ui: *core.Context,
    label: []const u8,
    state: *ConfirmState,
    opts: ConfirmButtonOpts,
) bool {
    if (state.armed and ui.time - state.since > opts.timeout) state.armed = false;
    if (state.armed) ui.requestFrame(); // 计时中：要持续出帧才能自动解除

    const text = if (state.armed) opts.confirm_label else label;
    const m = ui.measureText(text, theme.font_body);
    const h: f32 = 36;
    const w = if (opts.width > 0) opts.width else m.w + 28;
    const rect = ui.reserve(w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x3C6EF372 ^ opts.id_salt, rect, true);

    if (state.armed and opts.danger) {
        var fill = theme.danger_bg;
        if (it.hover) fill = theme.danger;
        widgets.ringBox(ui, rect, theme.radius_control, fill, theme.danger);
        const color: t.Color = if (it.hover) theme.accent_text else theme.danger;
        ui.addText(
            .{ .x = rect.x + (rect.w - m.w) / 2, .y = rect.y + (rect.h - m.h) / 2, .w = m.w, .h = m.h },
            text,
            theme.font_body,
            color,
        );
    } else {
        switch (opts.variant) {
            .primary => ui.addBox(rect, .{ .fill = if (it.pressed and it.hover) theme.accent_active else theme.accent, .radius = theme.radius_control }),
            .secondary => widgets.ringBox(ui, rect, theme.radius_control, if (it.hover) theme.track else theme.surface, theme.border),
            .ghost => {
                if (it.hover) ui.addBox(rect, .{ .fill = theme.surface, .radius = theme.radius_control });
            },
        }
        const color: t.Color = if (opts.variant == .primary) theme.accent_text else theme.text;
        ui.addText(
            .{ .x = rect.x + (rect.w - m.w) / 2, .y = rect.y + (rect.h - m.h) / 2, .w = m.w, .h = m.h },
            text,
            theme.font_body,
            color,
        );
    }
    if (it.focused) {
        ui.addBox(rect.inset(-2), .{ .border = theme.accent, .border_width = 1, .radius = theme.radius_control + 2 });
    }

    if (it.clicked or it.activated) {
        if (state.armed) {
            state.armed = false;
            return true;
        }
        state.armed = true;
        state.since = ui.time;
    }
    return false;
}

// ---------------------------------------------------------------- 就地编辑
pub const InlineEditState = struct {
    editing: bool = false,
    caret: usize = 0,
};

pub const InlineEditOpts = struct {
    placeholder: []const u8 = "",
    /// 0 = 按内容宽（最少 80）。
    width: f32 = 0,
    size: f32 = theme.font_body,
};

pub const InlineEditResult = struct {
    /// 本帧内容被改过。
    changed: bool = false,
    /// 本帧按 Enter 提交（或点击别处结束编辑）。
    committed: bool = false,
    /// 本帧按 Esc 取消（内容保持原样，调用方可用自己的快照回滚）。
    canceled: bool = false,
    editing: bool = false,
};

/// 点一下变输入框、Enter 提交、Esc 取消的就地编辑。
/// 与 `widgets.input` 的区别：不占常驻编辑框，平时就是一段文本。
pub fn inlineEdit(
    ui: *core.Context,
    id: []const u8,
    buf: []u8,
    len: *usize,
    state: *InlineEditState,
    opts: InlineEditOpts,
) InlineEditResult {
    const content = buf[0..@min(len.*, buf.len)];
    const m = ui.measureText(if (content.len > 0) content else opts.placeholder, opts.size);
    const h: f32 = @max(28, m.h + 12);
    const w = if (opts.width > 0) opts.width else @max(m.w + 20, 80);
    const rect = ui.reserve(w, h, opts.width <= 0);
    const it = ui.interactEx(core.Context.idOf(id) ^ 0x1A2B3C4D, rect, true);
    var res = InlineEditResult{ .editing = state.editing };

    if (!state.editing) {
        if (it.hover) ui.addBox(rect, .{ .fill = theme.surface, .radius = 6 });
        const text = if (content.len > 0) content else opts.placeholder;
        const color: t.Color = if (content.len > 0) theme.text else theme.secondary;
        ui.addText(
            .{ .x = rect.x + 4, .y = rect.y + (rect.h - m.h) / 2, .w = m.w, .h = m.h },
            text,
            opts.size,
            color,
        );
        if (it.hover) {
            // 右侧画一支极简铅笔：一条斜线 + 一点，提示可编辑
            const px = rect.x + rect.w - 10;
            const py = rect.y + rect.h / 2;
            ui.addOverlayLine(.{ .x = px - 4, .y = py + 4 }, .{ .x = px + 4, .y = py - 4 }, 1.5, theme.secondary);
        }
        if (it.clicked or it.activated) {
            state.editing = true;
            state.caret = content.len;
            res.editing = true;
        }
        return res;
    }

    // 编辑态：与 widgets.input 同款外观，但共用本控件的交互 id，
    // 这样点进来的那一帧就能直接拿焦点（不需要再点一次）。
    if (it.clicked) state.caret = @min(len.*, buf.len);
    const border = if (it.focused) theme.accent else theme.border;
    widgets.ringBox(ui, rect, theme.radius_control, theme.bg, border);

    var changed = false;
    if (it.focused) widgets.editKeys(ui, buf, len, &state.caret, &changed);
    if (changed) res.changed = true;

    const cur = buf[0..@min(len.*, buf.len)];
    if (cur.len == 0 and opts.placeholder.len > 0) {
        const pm = ui.measureText(opts.placeholder, opts.size);
        ui.addText(
            .{ .x = rect.x + 8, .y = rect.y + (rect.h - pm.h) / 2, .w = pm.w, .h = pm.h },
            opts.placeholder,
            opts.size,
            theme.secondary,
        );
    } else {
        const cm = ui.measureText(cur, opts.size);
        ui.addText(
            .{ .x = rect.x + 8, .y = rect.y + (rect.h - cm.h) / 2, .w = cm.w, .h = cm.h },
            cur,
            opts.size,
            theme.text,
        );
    }
    if (it.focused) {
        const careted = ui.measureText(buf[0..@min(state.caret, cur.len)], opts.size);
        var cx = rect.x + 8 + careted.w;
        if (cx > rect.x + rect.w - 6) cx = rect.x + rect.w - 6;
        ui.addOverlayLine(.{ .x = cx, .y = rect.y + 6 }, .{ .x = cx, .y = rect.y + rect.h - 6 }, 1.5, theme.text);
        if (ui.input.keyPressed(.enter)) {
            state.editing = false;
            res.committed = true;
            res.editing = false;
        } else if (ui.input.keyPressed(.escape)) {
            state.editing = false;
            res.canceled = true;
            res.editing = false;
        }
    }
    return res;
}

// ---------------------------------------------------------------- 拖拽取数
pub const ScrubState = struct {
    start_x: f32 = 0,
    start_value: f32 = 0,
    moved: bool = false,
};

pub const ScrubOpts = struct {
    /// 0 = 自动（范围的 1%）。
    step: f32 = 0,
    suffix: []const u8 = "",
    decimals: u8 = 0,
    /// 0 = 按内容宽。
    width: f32 = 0,
    /// 拖满多少像素等于整个范围。
    travel: f32 = 200,
    /// 按住 Shift 的精细倍率。
    fine: f32 = 10,
};

/// 在控件上横向拖拽改值（Shift 精细），方向键步进。
/// 返回 true 表示值变了。CUI 的 `cui_scrub` 同义。
pub fn scrub(
    ui: *core.Context,
    label: []const u8,
    value: *f32,
    min: f32,
    max: f32,
    state: *ScrubState,
    opts: ScrubOpts,
) bool {
    const span = if (max - min > 0) max - min else 1;
    const step = if (opts.step > 0) opts.step else span / 100;
    const travel = if (opts.travel > 1) opts.travel else 200;

    var buf: [24]u8 = undefined;
    const vtext = num.fixed(&buf, value.*, opts.decimals);
    const vm = ui.measureText(vtext, theme.font_small);
    const lm = ui.measureText(label, theme.font_body);
    const h: f32 = 30;
    const suffix_w: f32 = @as(f32, @floatFromInt(opts.suffix.len)) * 8;
    const w = if (opts.width > 0) opts.width else @max(lm.w + vm.w + suffix_w + 34, 120);
    const rect = ui.reserve(w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x51C0BBED, rect, true);
    var changed = false;

    if (ui.input.pressed and it.hover) {
        state.start_x = ui.input.mouse.x;
        state.start_value = value.*;
        state.moved = false;
    }
    if (it.dragging) {
        const dx = ui.input.mouse.x - state.start_x;
        if (@abs(dx) > 0.5) state.moved = true;
        var delta = dx / travel * span;
        if (ui.input.mods.shift) delta /= (if (opts.fine > 1) opts.fine else 10);
        var next = state.start_value + delta;
        // 吸附到步进
        next = @round(next / step) * step;
        next = if (next < min) min else if (next > max) max else next;
        if (next != value.*) {
            value.* = next;
            changed = true;
        }
    }
    if (it.focused) {
        if (ui.input.keyPressed(.left)) {
            value.* = @max(min, value.* - step);
            changed = true;
        }
        if (ui.input.keyPressed(.right)) {
            value.* = @min(max, value.* + step);
            changed = true;
        }
    }

    if (it.hover or it.dragging) ui.addBox(rect, .{ .fill = theme.surface, .radius = 6 });
    ui.addText(
        .{ .x = rect.x + 6, .y = rect.y + (rect.h - lm.h) / 2, .w = lm.w, .h = lm.h },
        label,
        theme.font_body,
        theme.secondary,
    );
    // 右侧数值（含后缀），拖拽时高亮
    var vbuf2: [24]u8 = undefined;
    const vt2 = num.fixed(&vbuf2, value.*, opts.decimals);
    var full: [40]u8 = undefined;
    var fn_: usize = 0;
    for (vt2) |c| {
        full[fn_] = c;
        fn_ += 1;
    }
    for (opts.suffix) |c| {
        if (fn_ < full.len) {
            full[fn_] = c;
            fn_ += 1;
        }
    }
    const fm = ui.measureText(full[0..fn_], theme.font_small);
    ui.addText(
        .{ .x = rect.x + rect.w - fm.w - 8, .y = rect.y + (rect.h - fm.h) / 2, .w = fm.w, .h = fm.h },
        ui.frameStr(full[0..fn_]),
        theme.font_small,
        if (it.dragging or it.hover) theme.accent else theme.text,
    );
    return changed;
}

// ---------------------------------------------------------------- 金额输入
pub const MoneyState = struct {
    editing: bool = false,
    caret: usize = 0,
    buf: [24]u8 = @splat(0),
    len: usize = 0,
};

pub const MoneyOpts = struct {
    label: []const u8 = "",
    symbol: []const u8 = "",
    /// 小数位（0..3）。
    decimals: u8 = 2,
    width: f32 = 0,
    hint: []const u8 = "",
};

/// 金额输入：平时显示千分位文本，点一下变纯数字编辑，Enter 提交、Esc 取消。
/// 返回 true 表示值变了。
pub fn moneyInput(
    ui: *core.Context,
    id: []const u8,
    value: *f64,
    state: *MoneyState,
    opts: MoneyOpts,
) bool {
    const h: f32 = 36;
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const it = ui.interactEx(core.Context.idOf(id) ^ 0x30A1E5, rect, true);
    var changed = false;

    if (!state.editing) {
        // 展示态：符号 + 千分位金额
        widgets.ringBox(ui, rect, theme.radius_control, theme.bg, if (it.hover) theme.track else theme.border);
        var ebuf: [40]u8 = undefined;
        var en: usize = 0;
        for (opts.symbol) |c| {
            if (en < ebuf.len) {
                ebuf[en] = c;
                en += 1;
            }
        }
        var mbuf: [32]u8 = undefined;
        const mtxt = num.money(&mbuf, @floatCast(value.*), opts.decimals);
        for (mtxt) |c| {
            if (en < ebuf.len) {
                ebuf[en] = c;
                en += 1;
            }
        }
        const em = ui.measureText(ebuf[0..en], theme.font_body);
        const lx: f32 = if (opts.label.len > 0) blk: {
            const lm = ui.measureText(opts.label, theme.font_small);
            ui.addText(
                .{ .x = rect.x + 10, .y = rect.y + (rect.h - lm.h) / 2, .w = lm.w, .h = lm.h },
                opts.label,
                theme.font_small,
                theme.secondary,
            );
            break :blk rect.x + 10 + lm.w + 10;
        } else rect.x + 10;
        ui.addText(
            .{ .x = lx, .y = rect.y + (rect.h - em.h) / 2, .w = em.w, .h = em.h },
            ui.frameStr(ebuf[0..en]),
            theme.font_body,
            theme.text,
        );
        if (opts.hint.len > 0) {
            const hm = ui.measureText(opts.hint, theme.font_small);
            ui.addText(
                .{ .x = rect.x + rect.w - hm.w - 10, .y = rect.y + (rect.h - hm.h) / 2, .w = hm.w, .h = hm.h },
                opts.hint,
                theme.font_small,
                theme.secondary,
            );
        }
        if (it.clicked or it.activated) {
            // 进入编辑：把数值写成无千分位的纯数字（小数位按 opts）
            var nb: [28]u8 = undefined;
            const plain = num.fixed(&nb, @floatCast(value.*), opts.decimals);
            state.len = @min(plain.len, state.buf.len);
            @memcpy(state.buf[0..state.len], plain[0..state.len]);
            state.caret = state.len;
            state.editing = true;
        }
        return false;
    }

    // 编辑态
    if (it.clicked) state.caret = @min(state.len, state.buf.len);
    widgets.ringBox(ui, rect, theme.radius_control, theme.bg, if (it.focused) theme.accent else theme.border);
    var edited = false;
    if (it.focused) widgets.editKeys(ui, &state.buf, &state.len, &state.caret, &edited);
    const cur = state.buf[0..@min(state.len, state.buf.len)];
    if (cur.len == 0) {
        const pm = ui.measureText("0", theme.font_body);
        ui.addText(
            .{ .x = rect.x + 10, .y = rect.y + (rect.h - pm.h) / 2, .w = pm.w, .h = pm.h },
            "0",
            theme.font_body,
            theme.secondary,
        );
    } else {
        const cm = ui.measureText(cur, theme.font_body);
        ui.addText(
            .{ .x = rect.x + 10, .y = rect.y + (rect.h - cm.h) / 2, .w = cm.w, .h = cm.h },
            cur,
            theme.font_body,
            theme.text,
        );
    }
    if (it.focused) {
        const careted = ui.measureText(state.buf[0..@min(state.caret, cur.len)], theme.font_body);
        var cx = rect.x + 10 + careted.w;
        if (cx > rect.x + rect.w - 8) cx = rect.x + rect.w - 8;
        ui.addOverlayLine(.{ .x = cx, .y = rect.y + 7 }, .{ .x = cx, .y = rect.y + rect.h - 7 }, 1.5, theme.text);
        if (ui.input.keyPressed(.enter)) {
            if (num.parseF32(cur)) |v| {
                if (@as(f64, v) != value.*) {
                    value.* = v;
                    changed = true;
                }
            }
            state.editing = false;
        } else if (ui.input.keyPressed(.escape)) {
            state.editing = false;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- 反应条
pub const Reaction = struct {
    icon: []const u8,
    count: u32 = 0,
    active: bool = false,
};

/// 一排可点的反应胶囊；点了哪个就把它的 `active` 翻转并返回其下标（CUI `cui_reactions`）。
pub fn reactions(ui: *core.Context, id: []const u8, items: []Reaction) ?usize {
    var picked: ?usize = null;
    var row = ui.row(.{ .gap = 6 });
    defer row.end();
    for (items, 0..) |*it, i| {
        const cm = ui.measureText(it.icon, theme.font_body);
        const nm = ui.measureText("999", theme.font_small);
        const w = cm.w + nm.w + 22;
        const h: f32 = 28;
        const r = ui.reserve(w, h, false);
        const salt: u64 = 0x2EA87000 +% @as(u64, @intCast(i));
        const hit = ui.interactEx(core.Context.idOf(id) ^ salt, r, true);
        const bg: t.Color = if (it.active) theme.accent_bg else if (hit.hover) theme.surface else theme.bg;
        widgets.ringBox(ui, r, theme.radius_pill, bg, if (it.active) theme.accent else theme.border);
        ui.addText(
            .{ .x = r.x + 8, .y = r.y + (h - cm.h) / 2, .w = cm.w, .h = cm.h },
            it.icon,
            theme.font_body,
            if (it.active) theme.accent else theme.text,
        );
        var nb: [12]u8 = undefined;
        const cnt = num.int(&nb, @intCast(it.count));
        const cm2 = ui.measureText(cnt, theme.font_small);
        ui.addText(
            .{ .x = r.x + 8 + cm.w + 4, .y = r.y + (h - cm2.h) / 2, .w = cm2.w, .h = cm2.h },
            cnt,
            theme.font_small,
            if (it.active) theme.accent else theme.secondary,
        );
        if (hit.clicked or hit.activated) {
            it.active = !it.active;
            if (it.active) {
                it.count += 1;
            } else if (it.count > 0) {
                it.count -= 1;
            }
            picked = i;
        }
    }
    return picked;
}
