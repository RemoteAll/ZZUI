//! 控件：立即模式函数。状态全部由调用方变量保存（与 CUI 一致）。
//! 交互一律对上一帧矩形判定（`Context.interactEx`），所以点击落在用户看到的位置。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const t = @import("types.zig");

/// 1px 圆角边框：外圈画边框色、内圈画填充色（比 4 条矩形拼边框更圆顺）。
pub fn ringBox(ui: *core.Context, rect: t.Rect, radius: f32, fill: t.Color, border: t.Color) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    ui.addBox(rect, .{ .fill = border, .radius = radius });
    const r2 = if (radius > 1) radius - 1 else 0;
    ui.addBox(rect.inset(1), .{ .fill = fill, .radius = r2 });
}

pub fn heading(ui: *core.Context, s: []const u8, level: u8) void {
    const size: f32 = switch (level) {
        1 => 32,
        2 => theme.font_heading,
        else => 20,
    };
    _ = ui.textRun(s, size, theme.text);
}

pub fn text(ui: *core.Context, s: []const u8) void {
    _ = ui.textRun(s, theme.font_body, theme.text);
}

pub fn secondary(ui: *core.Context, s: []const u8) void {
    _ = ui.textRun(s, theme.font_body, theme.secondary);
}

pub fn textInt(ui: *core.Context, prefix: []const u8, value: u64, suffix: []const u8) void {
    ui.textIntRun(prefix, value, suffix, theme.font_body, theme.text);
}

/// 水平分隔线（1px，撑满内容宽）。
pub fn separator(ui: *core.Context) void {
    const rect = ui.reserve(0, 1, true);
    ui.addBox(rect, .{ .fill = theme.border });
}

pub const ButtonOpts = struct {
    variant: t.Variant = .secondary,
    width: f32 = 0,
    /// 同名按钮重复出现时（分页/步进器等）用它区分交互 id。
    id_salt: u64 = 0,
};

pub fn button(ui: *core.Context, label: []const u8, opts: ButtonOpts) bool {
    return buttonEx(ui, label, opts).clicked;
}

pub const ButtonResult = struct {
    clicked: bool = false,
    rect: t.Rect = .{},
};

/// 与 `button` 相同，但把按钮矩形一并返回（菜单需要锚点）。
pub fn buttonEx(ui: *core.Context, label: []const u8, opts: ButtonOpts) ButtonResult {
    const m = ui.measureText(label, theme.font_body);
    const h: f32 = 36;
    const w = if (opts.width > 0) opts.width else m.w + 28;
    const rect = ui.reserve(w, h, false);
    return .{ .clicked = buttonRect(ui, rect, label, opts), .rect = rect };
}

/// 在指定矩形里画按钮（浮层等绝对定位场景）。
pub fn buttonRect(ui: *core.Context, rect: t.Rect, label: []const u8, opts: ButtonOpts) bool {
    const m = ui.measureText(label, theme.font_body);
    const id = core.Context.idOf(label) ^ 0x9E3779B97F4A7C15 ^ opts.id_salt;
    const it = ui.interactEx(id, rect, true);

    switch (opts.variant) {
        .primary => {
            // 按下时向 accent_active 过渡（动效只碰颜色，不动几何）
            const a = anim.step(ui, id ^ 0x9E37, if (it.pressed and it.hover) 1 else 0, anim.rate_toggle);
            ui.addBox(rect, .{ .fill = anim.mix(theme.accent, theme.accent_active, a), .radius = theme.radius_control });
        },
        .secondary => {
            const h = anim.hover(ui, id, it.hover);
            var fill = anim.mix(theme.surface, theme.track, h);
            if (it.pressed and it.hover) fill = theme.border;
            ringBox(ui, rect, theme.radius_control, fill, theme.border);
        },
        .ghost => {
            if (it.hover) ui.addBox(rect, .{ .fill = theme.surface, .radius = theme.radius_control });
        },
    }

    if (it.focused) {
        ui.addBox(rect.inset(-2), .{ .border = theme.accent, .border_width = 1, .radius = theme.radius_control + 2 });
    }
    const label_color: t.Color = if (opts.variant == .primary) theme.accent_text else theme.text;
    const tx = rect.x + (rect.w - m.w) / 2;
    const ty = rect.y + (rect.h - m.h) / 2;
    ui.addText(.{ .x = tx, .y = ty, .w = m.w, .h = m.h }, label, theme.font_body, label_color);
    return it.clicked or it.activated;
}

pub fn controlSwitch(ui: *core.Context, label: []const u8, value: *bool) void {
    const label_size = theme.font_body;
    const m = ui.measureText(label, label_size);
    const track_w: f32 = 44;
    const track_h: f32 = 24;

    var row = ui.row(.{ .gap = 10 });
    defer row.end();

    const lr = ui.reserve(m.w, track_h, false);
    ui.addText(.{ .x = lr.x, .y = lr.y + (lr.h - m.h) / 2, .w = m.w, .h = m.h }, label, label_size, theme.text);

    const tr = ui.reserve(track_w, track_h, false);
    const sid = core.Context.idOf(label) ^ 0x51ED270B;
    const it = ui.interactEx(sid, tr, true);
    if (it.clicked or it.activated) value.* = !value.*;

    const on = value.*;
    // 开/关用同一条轨道：轨道色、滑块位置一起插值（命中矩形不变）
    const k = anim.toggle(ui, sid ^ 0x5EA1, on);
    ui.addBox(tr, .{ .fill = anim.mix(theme.track, theme.accent, k), .radius = theme.radius_pill });
    const knob_d: f32 = 18;
    const kx = anim.lerp(tr.x + 3, tr.x + tr.w - knob_d - 3, k);
    ui.addBox(.{ .x = kx, .y = tr.y + 3, .w = knob_d, .h = knob_d }, .{
        .fill = theme.bg,
        .radius = knob_d / 2,
    });
    if (it.focused) {
        ui.addBox(tr.inset(-2), .{ .border = theme.accent, .border_width = 1, .radius = theme.radius_pill });
    }
}

pub fn checkbox(ui: *core.Context, label: []const u8, value: *bool) void {
    const m = ui.measureText(label, theme.font_body);
    const box: f32 = 18;
    const gap: f32 = 8;
    const h: f32 = 22;
    const rect = ui.reserve(box + gap + m.w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x1B873593, rect, true);
    if (it.clicked or it.activated) value.* = !value.*;

    const bx = rect.x;
    const by = rect.y + (h - box) / 2;
    if (it.focused) {
        ui.addBox(.{ .x = bx - 3, .y = by - 3, .w = box + 6, .h = box + 6 }, .{ .fill = theme.accent, .radius = 7 });
        ui.addBox(.{ .x = bx - 2, .y = by - 2, .w = box + 4, .h = box + 4 }, .{ .fill = theme.bg, .radius = 6 });
    }
    {
        const k = anim.toggle(ui, core.Context.idOf(label) ^ 0x1B87, value.*);
        ui.addBox(.{ .x = bx, .y = by, .w = box, .h = box }, .{
            .fill = anim.mix(theme.bg, theme.accent, k),
            .radius = 4,
            .border = anim.mix(theme.border, theme.accent, k),
        });
        if (k > 0.01) {
            const tick = theme.withAlpha(theme.accent_text, @intFromFloat(255.0 * k));
            ui.addOverlayLine(.{ .x = bx + 4.5, .y = by + 9.0 }, .{ .x = bx + 7.5, .y = by + 12.5 }, 2, tick);
            ui.addOverlayLine(.{ .x = bx + 7.5, .y = by + 12.5 }, .{ .x = bx + 13.5, .y = by + 5.5 }, 2, tick);
        }
    }
    ui.addText(.{ .x = bx + box + gap, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, theme.text);
}

pub fn radio(ui: *core.Context, label: []const u8, value: *u32, this_value: u32) void {
    const m = ui.measureText(label, theme.font_body);
    const d: f32 = 18;
    const gap: f32 = 8;
    const h: f32 = 22;
    const rect = ui.reserve(d + gap + m.w, h, false);
    const it = ui.interactEx(core.Context.idOf(label) ^ 0xCC9E2D51, rect, true);
    if (it.clicked or it.activated) value.* = this_value;

    const cx = rect.x;
    const cy = rect.y + (h - d) / 2;
    if (it.focused) {
        ui.addBox(.{ .x = cx - 3, .y = cy - 3, .w = d + 6, .h = d + 6 }, .{ .fill = theme.accent, .radius = (d + 6) / 2 });
        ui.addBox(.{ .x = cx - 2, .y = cy - 2, .w = d + 4, .h = d + 4 }, .{ .fill = theme.bg, .radius = (d + 4) / 2 });
    }
    {
        const k = anim.toggle(ui, core.Context.idOf(label) ^ 0xCC9E ^ @as(u64, this_value), value.* == this_value);
        ui.addBox(.{ .x = cx, .y = cy, .w = d, .h = d }, .{
            .fill = anim.mix(theme.bg, theme.accent, k),
            .radius = d / 2,
            .border = anim.mix(theme.border, theme.accent, k),
        });
        if (k > 0.01) {
            const dot: f32 = 8;
            ui.addBox(.{ .x = cx + (d - dot) / 2, .y = cy + (d - dot) / 2, .w = dot, .h = dot }, .{
                .fill = theme.withAlpha(theme.bg, @intFromFloat(255.0 * k)),
                .radius = dot / 2,
            });
        }
    }
    ui.addText(.{ .x = cx + d + gap, .y = rect.y + (h - m.h) / 2, .w = m.w, .h = m.h }, label, theme.font_body, theme.text);
}

/// 滑杆：点击/拖拽轨道改值；获得焦点后左右方向键步进。
pub fn slider(ui: *core.Context, label: []const u8, value: *f32, min: f32, max: f32) void {
    const m = ui.measureText(label, theme.font_small);
    var col = ui.column(.{ .gap = 6 });
    defer col.end();

    const lr = ui.reserve(m.w, m.h, false);
    ui.addText(.{ .x = lr.x, .y = lr.y, .w = m.w, .h = m.h }, label, theme.font_small, theme.secondary);

    const track_h: f32 = 6;
    const row_h: f32 = 24;
    const rect = ui.reserve(0, row_h, true);
    const track = t.Rect{ .x = rect.x, .y = rect.y + (row_h - track_h) / 2, .w = rect.w, .h = track_h };
    const it = ui.interactEx(core.Context.idOf(label) ^ 0x165667B1, rect, true);

    const step = (max - min) / 20;
    if (it.dragging and track.w > 0) {
        var ratio = (ui.input.mouse.x - track.x) / track.w;
        if (ratio < 0) ratio = 0;
        if (ratio > 1) ratio = 1;
        value.* = min + (max - min) * ratio;
    }
    if (it.focused) {
        if (ui.input.keyPressed(.left)) value.* -= step;
        if (ui.input.keyPressed(.right)) value.* += step;
    }
    if (value.* < min) value.* = min;
    if (value.* > max) value.* = max;

    const ratio: f32 = if (max > min) (value.* - min) / (max - min) else 0;
    ui.addBox(track, .{ .fill = theme.track, .radius = track_h / 2 });
    if (ratio > 0) {
        ui.addBox(.{ .x = track.x, .y = track.y, .w = track.w * ratio, .h = track_h }, .{
            .fill = theme.accent,
            .radius = track_h / 2,
        });
    }
    const d: f32 = 16;
    const thumb_x = track.x + track.w * ratio - d / 2;
    const thumb_y = rect.y + (row_h - d) / 2;
    if (it.focused) {
        ui.addBox(.{ .x = thumb_x - 3, .y = thumb_y - 3, .w = d + 6, .h = d + 6 }, .{ .fill = theme.accent, .radius = (d + 6) / 2 });
        ui.addBox(.{ .x = thumb_x - 2, .y = thumb_y - 2, .w = d + 4, .h = d + 4 }, .{ .fill = theme.bg, .radius = (d + 4) / 2 });
    }
    ui.addBox(.{ .x = thumb_x, .y = thumb_y, .w = d, .h = d }, .{ .fill = theme.accent, .radius = d / 2 });
    ui.addBox(.{ .x = thumb_x + 2, .y = thumb_y + 2, .w = d - 4, .h = d - 4 }, .{
        .fill = theme.bg,
        .radius = (d - 4) / 2,
    });
}

pub const InputOpts = struct {
    placeholder: []const u8 = "",
    /// 0 表示撑满内容宽。
    width: f32 = 0,
    /// 密码框：用圆点代替实际字符（缓冲里仍是明文）。
    password: bool = false,
    /// 剪贴板（Ctrl+C/X/V）。null = 不碰剪贴板，其余编辑行为不变。
    clipboard: ?*const core.Clipboard = null,
};

fn utf8Len(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

fn prevCharStart(s: []const u8, i: usize) usize {
    var k = i;
    while (k > 0) {
        k -= 1;
        if ((s[k] & 0xC0) != 0x80) return k;
    }
    return 0;
}

fn nextCharEnd(s: []const u8, i: usize) usize {
    const e = i + utf8Len(s[i]);
    return if (e > s.len) s.len else e;
}

fn caretFromX(ui: *core.Context, s: []const u8, x0: f32, mx: f32) usize {
    var i: usize = 0;
    while (i < s.len) {
        const e = nextCharEnd(s, i);
        if (x0 + ui.measureText(s[0..e], theme.font_body).w > mx) return i;
        i = e;
    }
    return s.len;
}

/// 光标所在「词」的字节区间（字母/数字/下划线/非 ASCII 算词字符）。
/// 双击选词用；落在空白上返回空区间（光标处）。`textedit.textarea` 也调它。
pub fn wordRange(s: []const u8, at: usize) struct { start: usize, end: usize } {
    const is_word = struct {
        fn f(c: u8) bool {
            return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or
                (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
        }
    }.f;
    if (s.len == 0) return .{ .start = 0, .end = 0 };
    var probe = @min(at, s.len);
    if (probe >= s.len or !is_word(s[probe])) {
        if (probe == 0) return .{ .start = 0, .end = 0 };
        probe -= 1;
        while (probe > 0 and (s[probe] & 0xC0) == 0x80) probe -= 1;
        if (!is_word(s[probe])) return .{ .start = @min(at, s.len), .end = @min(at, s.len) };
    }
    var a = probe;
    while (a > 0) {
        var p = a - 1;
        while (p > 0 and (s[p] & 0xC0) == 0x80) p -= 1;
        if (!is_word(s[p])) break;
        a = p;
    }
    var b = probe;
    while (b < s.len and is_word(s[b])) b = nextCharEnd(s, b);
    return .{ .start = a, .end = b };
}

/// 删掉 `buf[a..b]`（调用方保证 a <= b <= len）。
fn removeRange(buf: []u8, len: *usize, a: usize, b: usize) void {
    if (b <= a or b > len.*) return;
    const n = b - a;
    var k = b;
    while (k < len.*) : (k += 1) buf[k - n] = buf[k];
    len.* -= n;
}

/// 在 `at` 处插入字节；缓冲不够返回 false（内容不变）。
fn insertBytes(buf: []u8, len: *usize, at: usize, bytes: []const u8) bool {
    if (at > len.* or len.* + bytes.len > buf.len) return false;
    var k = len.*;
    while (k > at) : (k -= 1) buf[k + bytes.len - 1] = buf[k - 1];
    @memcpy(buf[at .. at + bytes.len], bytes);
    len.* += bytes.len;
    return true;
}

fn clipboardHotkey(ui: *core.Context) bool {
    return ui.input.keyPressed(.C) or ui.input.keyPressed(.X) or ui.input.keyPressed(.V);
}

/// 单行文本的「选区感知」按键处理（`input` / `textedit.search` 共用）：
/// Ctrl+A 全选、Ctrl+C/X/V（`clipboard` 非 null 时）、退格 / Delete 先吃选区、
/// Shift+方向键扩选、普通方向键塌缩到选区边界、字符插入先替换选区。
/// `st` 由调用方从 `ui.editState(pid)` 取（锚点与连击计数都在里面）。返回是否改了内容。
pub fn editKeysSel(
    ui: *core.Context,
    st: *core.EditState,
    buf: []u8,
    len: *usize,
    caret: *usize,
    clipboard: ?*const core.Clipboard,
) bool {
    var changed = false;
    const shift = ui.input.mods.shift;
    const ctrl = ui.input.mods.ctrl;
    const a0 = @min(st.anchor, caret.*);
    const b0 = @max(st.anchor, caret.*);
    const has_sel = b0 > a0;

    if (ctrl and ui.input.keyPressed(.A)) {
        st.anchor = 0;
        caret.* = len.*;
    } else if (ctrl and clipboard != null and clipboardHotkey(ui)) {
        const cb = clipboard.?;
        if (ui.input.keyPressed(.C)) {
            if (has_sel) {
                if (cb.set) |set| set(cb.ctx, buf[a0..b0]);
            }
        } else if (ui.input.keyPressed(.X)) {
            if (has_sel) {
                if (cb.set) |set| set(cb.ctx, buf[a0..b0]);
                removeRange(buf, len, a0, b0);
                caret.* = a0;
                st.anchor = a0;
                changed = true;
            }
        } else if (cb.get) |get| {
            var tmp: [1024]u8 = undefined;
            const n = get(cb.ctx, tmp[0..]);
            if (n > 0 and n <= tmp.len and len.* - (b0 - a0) + n <= buf.len) {
                removeRange(buf, len, a0, b0);
                if (insertBytes(buf, len, a0, tmp[0..n])) {
                    caret.* = a0 + n;
                    st.anchor = caret.*;
                    changed = true;
                }
            }
        }
    } else {
        // 有选区时退格 / Delete 只吃选区（不额外删一个字符）
        if (has_sel and (ui.input.keyPressed(.backspace) or ui.input.keyPressed(.delete))) {
            removeRange(buf, len, a0, b0);
            caret.* = a0;
            changed = true;
        } else if (!has_sel) {
            if (ui.input.keyPressed(.backspace) and caret.* > 0) {
                const prev = prevCharStart(buf[0..len.*], caret.*);
                removeRange(buf, len, prev, caret.*);
                caret.* = prev;
                changed = true;
            }
            if (ui.input.keyPressed(.delete) and caret.* < len.*) {
                const end = nextCharEnd(buf[0..len.*], caret.*);
                removeRange(buf, len, caret.*, end);
                changed = true;
            }
        }
        // 方向键 / Home / End：Shift = 只挪插入符（扩选），否则塌缩到选区边界
        if (ui.input.keyPressed(.left)) {
            caret.* = if (has_sel and !shift) a0 else prevCharStart(buf[0..len.*], caret.*);
        } else if (ui.input.keyPressed(.right)) {
            if (has_sel and !shift) {
                caret.* = b0;
            } else if (caret.* < len.*) {
                // nextCharEnd 会读 s[i]：必须自己守上界（光标在末尾时右移就是不动）
                caret.* = nextCharEnd(buf[0..len.*], caret.*);
            }
        } else if (ui.input.keyPressed(.home)) {
            caret.* = 0;
        } else if (ui.input.keyPressed(.end)) {
            caret.* = len.*;
        }
        // 输入字符：有选区先替换整段
        const chars = ui.input.charsSlice();
        if (chars.len > 0) {
            if (has_sel) {
                const s0 = @min(st.anchor, caret.*);
                const s1 = @max(st.anchor, caret.*);
                removeRange(buf, len, s0, s1);
                caret.* = s0;
                changed = true;
            }
            if (insertBytes(buf, len, caret.*, chars)) {
                caret.* += chars.len;
                changed = true;
            }
        }
        // Shift 扩选时保留锚点；其余情况锚点跟着插入符走
        if (!shift or changed) st.anchor = caret.*;
    }
    return changed;
}

/// 单行文本输入：点击定位光标、按住拖动 / 双击选词 / 三击全选、Shift+方向键扩选、
/// Ctrl+A 全选、Ctrl+C/X/V 走剪贴板；退格 / Delete / 输入字符都会先吃掉选区。
/// 返回 true 表示内容发生了变化。`buf` 由调用方提供（定长），`len` / `caret` 按字节计。
pub fn input(
    ui: *core.Context,
    id: []const u8,
    buf: []u8,
    len: *usize,
    caret: *usize,
    opts: InputOpts,
) bool {
    const h: f32 = 36;
    const rect = ui.reserve(opts.width, h, opts.width <= 0);
    const pid = core.Context.idOf(id) ^ 0x7FEB352D;
    const it = ui.interactEx(pid, rect, true);
    var changed = false;
    const pad_x: f32 = 10;
    const tx = rect.x + pad_x;
    const right = rect.x + rect.w - pad_x;

    if (len.* > buf.len) len.* = buf.len;
    if (caret.* > len.*) caret.* = len.*;
    const st = ui.editState(pid);
    if (st.anchor > len.*) st.anchor = len.*;

    // ---- 鼠标：按下定位 + 连击（双击选词、三击全选），按住拖动扩选
    if (it.pressed) {
        caret.* = caretFromX(ui, buf[0..len.*], tx, ui.input.mouse.x);
        const now = ui.time;
        st.clicks = if (st.clicks > 0 and now - st.last_click <= 0.42) st.clicks +| 1 else 1;
        st.last_click = now;
        if (st.clicks == 2) {
            const w = wordRange(buf[0..len.*], caret.*);
            st.anchor = w.start;
            caret.* = w.end;
        } else if (st.clicks >= 3) {
            st.anchor = 0;
            caret.* = len.*;
            st.clicks = 0;
        } else {
            st.anchor = caret.*;
        }
    } else if (it.dragging) {
        caret.* = caretFromX(ui, buf[0..len.*], tx, ui.input.mouse.x);
    }

    // ---- 键盘（只给焦点控件）：先按选区语义处理，再算方向键
    if (it.focused) {
        if (editKeysSel(ui, st, buf, len, caret, opts.clipboard)) changed = true;
    }

    const border = if (it.focused) theme.accent else theme.border;
    ringBox(ui, rect, theme.radius_control, theme.bg, border);

    // 选区底色：压在文字下面（节点顺序即绘制顺序）
    const sa = @min(st.anchor, caret.*);
    const sb = @max(st.anchor, caret.*);
    if (it.focused and sb > sa) {
        const x0 = @min(tx + ui.measureText(buf[0..sa], theme.font_body).w, right);
        const x1 = @min(tx + ui.measureText(buf[0..sb], theme.font_body).w, right);
        if (x1 > x0) ui.addBox(
            .{ .x = x0, .y = rect.y + 7, .w = x1 - x0, .h = rect.h - 14 },
            .{ .fill = theme.withAlpha(theme.accent, 64), .radius = 3 },
        );
    }

    const content = buf[0..len.*];
    const m = ui.measureText(content, theme.font_body);
    const ty = rect.y + (rect.h - m.h) / 2;
    if (len.* == 0 and opts.placeholder.len > 0) {
        const pm = ui.measureText(opts.placeholder, theme.font_body);
        ui.addText(.{ .x = tx, .y = rect.y + (rect.h - pm.h) / 2, .w = pm.w, .h = pm.h }, opts.placeholder, theme.font_body, theme.secondary);
    } else if (opts.password) {
        // 每个字符画一个圆点（宽度按真实文本算，光标位置不受影响）
        var dots: [192]u8 = @splat(0);
        var dn: usize = 0;
        var k: usize = 0;
        while (k < content.len and dn + 3 <= dots.len) : (k = nextCharEnd(content, k)) {
            @memcpy(dots[dn .. dn + 3], "•");
            dn += 3;
        }
        const dm = ui.measureText(dots[0..dn], theme.font_body);
        ui.addText(.{ .x = tx, .y = ty, .w = dm.w, .h = dm.h }, ui.frameStr(dots[0..dn]), theme.font_body, theme.text);
    } else {
        // 超宽时只显示尾部（保证光标可见的常见场景），从字符边界截断
        const inner_w = rect.w - pad_x * 2;
        var shown = content;
        if (m.w > inner_w and content.len > 0) {
            var start: usize = content.len;
            while (start > 0) {
                const prev = prevCharStart(content, start);
                if (ui.measureText(content[prev..], theme.font_body).w > inner_w) break;
                start = prev;
            }
            shown = content[start..];
        }
        const sm = ui.measureText(shown, theme.font_body);
        ui.addText(.{ .x = tx, .y = ty, .w = sm.w, .h = sm.h }, shown, theme.font_body, theme.text);
    }

    if (it.focused) {
        const cm = ui.measureText(buf[0..caret.*], theme.font_body);
        var cx = tx + cm.w;
        if (cx > right) cx = right;
        const bar = t.Rect{ .x = cx, .y = rect.y + 8, .w = 1.5, .h = rect.h - 16 };
        ui.addOverlayLine(.{ .x = bar.x, .y = bar.y }, .{ .x = bar.x, .y = bar.y + bar.h }, 1.5, theme.text);
        // 输入法的组成窗/候选窗要跟着光标（Windows 上靠这个位置才不跑到左上角）
        ui.noteCaret(bar);
    }
    return changed;
}

pub const DialogOpts = struct {
    width: f32 = 320,
    /// null = 高度按内容（标题 + 消息换行 + 按钮行）：首帧用测量估值，
    /// 从第二帧起用**上一帧真实高度**居中（`PanelOpts.size_key` 帧末回填）。
    /// 显式给值 = 固定高度，按钮贴底右对齐（老行为）。
    height: ?f32 = null,
    title: []const u8 = "",
    message: []const u8 = "",
    ok_label: []const u8 = "OK",
    cancel_label: []const u8 = "Cancel",
    /// `height == null` 时区分尺寸池条目的键（同页面多个对话框填不同值）。
    id: []const u8 = "",
};

pub const DialogResult = enum { none, ok, cancel };

/// 模态对话框：遮罩 + 居中卡片 + 右对齐按钮；点遮罩 / Esc / 取消都会关闭。
pub fn dialog(ui: *core.Context, open: *bool, opts: DialogOpts) DialogResult {
    var ov = ui.beginOverlay(.{});
    defer ov.end();

    const w = opts.width;
    const pad: f32 = 20;
    const gap: f32 = 10;
    const btn_h: f32 = 34;
    const btn_w: f32 = 88;
    // 首帧估值：标题行 + 消息按内容宽换行后的行高 + 间隙 + 按钮行。
    // 第二帧起直接用上一帧量到的真值（消息长了两行也不会撑出卡片）。
    var lines: [core.MAX_LINES][]const u8 = undefined;
    const nl = core.wrapText(ui, opts.message, theme.font_body, w - pad * 2, &lines);
    const line_h = blk: {
        const m = ui.measureText(opts.message, theme.font_body);
        break :blk if (m.h > 0) m.h else theme.font_body * 1.35;
    };
    const body_h = line_h * @as(f32, @floatFromInt(@max(nl, 1)));
    const title_h = blk: {
        const m = ui.measureText(opts.title, 18);
        break :blk if (m.h > 0) m.h else 24;
    };
    const est_h = pad * 2 + title_h + gap + body_h + gap + btn_h;

    const size_key = if (opts.height == null)
        core.Context.idOf(opts.id) ^ core.Context.idOf(opts.title) ^ 0xD1A106
    else
        0;
    const h = opts.height orelse (if (ui.knownSize(size_key)) |s| s.h else est_h);
    const x = (ui.width - w) / 2;
    const y = (ui.height - h) / 2;
    var card = ui.panel(.{ .x = x, .y = y, .w = w, .h = h }, .{
        .fill = theme.surface,
        .radius = 12,
        .border = theme.border,
        .pad = pad,
        .gap = gap,
        .auto_height = opts.height == null,
        .size_key = size_key,
    });
    defer card.end();

    _ = ui.textRun(opts.title, 18, theme.text);
    _ = ui.textRun(opts.message, theme.font_body, theme.secondary);

    // 固定高度：按钮贴底（老布局）；自动高度：按钮紧跟内容
    var ok_rect: t.Rect = undefined;
    var cancel_rect: t.Rect = undefined;
    if (opts.height != null) {
        const by = y + h - pad - btn_h;
        const ok_x = x + w - pad - btn_w;
        cancel_rect = .{ .x = ok_x - 8 - btn_w, .y = by, .w = btn_w, .h = btn_h };
        ok_rect = .{ .x = ok_x, .y = by, .w = btn_w, .h = btn_h };
    } else {
        _ = ui.reserve(0, 8, false);
        const row = ui.reserve(0, btn_h, true);
        ok_rect = .{ .x = row.x + row.w - btn_w, .y = row.y, .w = btn_w, .h = btn_h };
        cancel_rect = .{ .x = ok_rect.x - 8 - btn_w, .y = row.y, .w = btn_w, .h = btn_h };
    }

    var result: DialogResult = .none;
    if (buttonRect(ui, cancel_rect, opts.cancel_label, .{})) {
        open.* = false;
        result = .cancel;
    }
    if (buttonRect(ui, ok_rect, opts.ok_label, .{ .variant = .primary })) {
        open.* = false;
        result = .ok;
    }
    if (result == .none and (ui.overlayBackdropClicked() or ui.input.keyPressed(.escape))) {
        open.* = false;
        result = .cancel;
    }
    return result;
}
pub const MenuItem = struct {
    label: []const u8,
    enabled: bool = true,
};

pub const MenuOpts = struct {
    width: f32 = 180,
    item_h: f32 = 30,
    pad: f32 = 6,
    gap: f32 = 6,
    /// 同一 `id` 下多个菜单实例（菜单栏/多处下拉）时用来区分交互 id。
    id_salt: u64 = 0,
};

/// 弹出菜单：锚在 anchor 下方（放不下则上方），点空白/Esc 关闭；返回被选中项下标。
pub fn menu(ui: *core.Context, id: []const u8, anchor: t.Rect, items: []const MenuItem, open: *bool, opts: MenuOpts) ?usize {
    var ov = ui.beginOverlay(.{ .dim = null, .hit = true });
    defer ov.end();

    const count: f32 = @floatFromInt(items.len);
    const w = opts.width;
    const h = opts.pad * 2 + opts.item_h * count;
    var x = anchor.x;
    var y = anchor.y + anchor.h + opts.gap;
    if (x + w > ui.width) x = ui.width - w - 4;
    if (x < 0) x = 0;
    if (y + h > ui.height) y = anchor.y - h - opts.gap;
    if (y < 0) y = 0;

    var card = ui.panel(.{ .x = x, .y = y, .w = w, .h = h }, .{
        .fill = theme.surface,
        .radius = 10,
        .border = theme.border,
        .pad = opts.pad,
    });
    defer card.end();

    var selected: ?usize = null;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const r = ui.reserve(0, opts.item_h, true);
        const iid = core.Context.idOf(id) ^ (@as(u64, 0xA11CE) + i) ^ opts.id_salt;
        const it = ui.interactEx(iid, r, items[i].enabled);
        if (it.hover and items[i].enabled) {
            ui.addBox(r, .{ .fill = theme.track, .radius = 6 });
        }
        const m = ui.measureText(items[i].label, theme.font_body);
        const color: t.Color = if (items[i].enabled) theme.text else theme.secondary;
        ui.addText(.{ .x = r.x + 8, .y = r.y + (r.h - m.h) / 2, .w = m.w, .h = m.h }, items[i].label, theme.font_body, color);
        if (it.clicked and items[i].enabled) selected = i;
    }

    if (selected != null or ui.overlayBackdropClicked() or ui.input.keyPressed(.escape)) {
        open.* = false;
    }
    return selected;
}

/// 悬停提示：`hovered` 为真时开始计时，超过 `delay` 秒才显示；不拦截点击。
pub fn tooltip(ui: *core.Context, id: []const u8, anchor: t.Rect, label: []const u8, hovered: bool, delay: f64) void {
    const hash = core.Context.idOf(id) ^ 0x707;
    if (!hovered) {
        ui.hoverReset(hash);
        return;
    }
    const start = ui.hoverStart(hash);
    if (ui.time - start < delay) {
        ui.requestFrame(); // 等延迟：不出帧就永远等不到
        return;
    }

    const m = ui.measureText(label, theme.font_small);
    const w = m.w + 16;
    const h = m.h + 10;
    var x = anchor.x + anchor.w / 2 - w / 2;
    var y = anchor.y + anchor.h + 6;
    if (x + w > ui.width) x = ui.width - w - 4;
    if (x < 0) x = 0;
    if (y + h > ui.height) y = anchor.y - h - 6;
    if (y < 0) y = 0;

    var ov = ui.beginOverlay(.{ .dim = null, .hit = false });
    defer ov.end();

    ui.addBox(.{ .x = x, .y = y, .w = w, .h = h }, .{ .fill = theme.text, .radius = 6 });
    ui.addText(.{ .x = x + 8, .y = y + 5, .w = m.w, .h = m.h }, label, theme.font_small, theme.accent_text);
}
