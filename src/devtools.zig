//! 开发工具族（对位 CUI `cui_devtools.c` **12/12**，2026-11-12 收口）：
//! 键值编辑器（HTTP 头 / 查询参数 / 环境变量）、问题面板（编译器诊断按文件分组）、
//! CI 流水线（阶段 × 作业）、查询构建（分组可嵌套 + 文本化 + 记录匹配）、
//! cron 定时选择（六种友好模式 + 下次运行）、测试树（套件折叠 + 过滤 + 汇总）、键位图（按修饰键看快捷键）。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **跨帧状态由调用方持有**（`ProblemsState`），键值对的文本与光标也存在 `KvPair` 里
//!   （CUI 把光标放进控件的状态池）；与 `nodes.State` / `emoji.State` / `devviews.CoverageState` 一致。
//! - **问题面板不做虚拟列表**：行数上限 `MAX_ROWS`（=192），一屏足够；CUI 走虚拟列表是为了
//!   上万条诊断，ZZUI 这里用「先过滤再截断」并如实标注 `truncated`。
//! - **流水线不画斜角连接线**：阶段之间画一段短横线/竖线（软件光栅没有 AA 斜线）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const trace = @import("trace.zig");
const widgets = @import("widgets.zig");
const controls = @import("controls.zig");
const textedit = @import("textedit.zig");
const actions = @import("actions.zig");
const month = @import("month.zig");
const strings = @import("strings.zig");

pub const Tone = trace.Tone;

fn idOf(id: []const u8) u64 {
    return core.Context.idOf(id);
}

/// 给命中 id 加盐与下标（避开 usize/u64 混算）。
fn kk(key: u64, salt: u64, i: usize) u64 {
    return key ^ (salt +% @as(u64, @intCast(i)));
}

fn clipText(ui: *core.Context, s: []const u8, size: f32, max_w: f32) []const u8 {
    if (s.len == 0 or max_w <= 12) return "";
    if (ui.measureText(s, size).w <= max_w) return s;
    var take: usize = @min(s.len, 64);
    while (take > 0) : (take -= 1) {
        var n = take;
        while (n > 0 and (s[n - 1] & 0xC0) == 0x80) n -= 1;
        var buf: [72]u8 = undefined;
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

/// ASCII 大小写不敏感的子串查找（空 `needle` 恒真）。
pub fn containsCi(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        var k: usize = 0;
        while (k < needle.len) : (k += 1) {
            if (std.ascii.toLower(hay[i + k]) != std.ascii.toLower(needle[k])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// "48s" / "1m 24s" / "2h 05m"
fn fmtDuration(buf: []u8, seconds: f32) []const u8 {
    if (!(seconds >= 0)) return "";
    const total: u32 = @intFromFloat(seconds + 0.5);
    if (total < 60) {
        var tb: [8]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}s", .{num.int(tb[0..], total)}) catch "";
    }
    if (total < 3600) {
        var a: [4]u8 = undefined;
        var b: [4]u8 = undefined;
        const mm = pad2(a[0..], total / 60);
        const ss = pad2(b[0..], total % 60);
        return std.fmt.bufPrint(buf, "{s}m {s}s", .{ mm, ss }) catch "";
    }
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    const hh = num.int(a[0..], total / 3600);
    const mm = pad2(b[0..], (total / 60) % 60);
    return std.fmt.bufPrint(buf, "{s}h {s}m", .{ hh, mm }) catch "";
}

fn pad2(buf: []u8, v: u32) []const u8 {
    if (v < 10) {
        buf[0] = '0';
        const s = num.int(buf[1..], @intCast(v));
        return buf[0 .. 1 + s.len];
    }
    return num.int(buf, @intCast(v));
}

/// 小方框复选（键值对的开关）：返回本帧是否被点。
fn boxToggle(ui: *core.Context, key: u64, rect: t.Rect, on: bool) bool {
    const hit = ui.interactEx(key, rect, true);
    const c = if (on) theme.accent else theme.border;
    ui.addBox(rect, .{ .fill = if (on) theme.accent else theme.surface, .radius = 4, .border = c, .border_width = 1.5 });
    if (on) {
        // 对勾用两段矩形拼（软件光栅没有曲线）
        ui.addBox(.{ .x = rect.x + 4, .y = rect.y + rect.h * 0.5, .w = 4, .h = 2 }, .{ .fill = theme.accent_text });
        ui.addBox(.{ .x = rect.x + 6, .y = rect.y + rect.h * 0.5 - 3, .w = 2, .h = 5 }, .{ .fill = theme.accent_text });
    }
    return hit.clicked;
}

/// 小号图标按钮（`x` / `*` 这类单字符），返回是否被点。
fn iconButton(ui: *core.Context, key: u64, rect: t.Rect, glyph: []const u8, color: t.Color) bool {
    const hit = ui.interactEx(key, rect, true);
    if (hit.hover) ui.addBox(rect, .{ .fill = theme.track, .radius = 4 });
    const w = ui.measureText(glyph, theme.font_small).w;
    ui.addText(.{ .x = rect.x + (rect.w - w) * 0.5, .y = rect.y + (rect.h - 16) * 0.5, .w = w + 1, .h = 18 }, glyph, theme.font_small, color);
    return hit.clicked;
}

// =============================================================== 键值编辑器

pub const KvPair = struct {
    key: [64]u8 = @splat(0),
    key_len: usize = 0,
    key_caret: usize = 0,
    value: [256]u8 = @splat(0),
    value_len: usize = 0,
    value_caret: usize = 0,
    enabled: bool = true,
    secret: bool = false,

    pub fn keySlice(self: *const KvPair) []const u8 {
        return self.key[0..@min(self.key_len, self.key.len)];
    }

    pub fn valueSlice(self: *const KvPair) []const u8 {
        return self.value[0..@min(self.value_len, self.value.len)];
    }

    pub fn setKey(self: *KvPair, s: []const u8) void {
        const n = @min(s.len, self.key.len);
        @memcpy(self.key[0..n], s[0..n]);
        self.key_len = n;
        self.key_caret = n;
    }

    pub fn setValue(self: *KvPair, s: []const u8) void {
        const n = @min(s.len, self.value.len);
        @memcpy(self.value[0..n], s[0..n]);
        self.value_len = n;
        self.value_caret = n;
    }

    pub fn reset(self: *KvPair) void {
        self.* = .{};
    }
};

pub const KvEditorOpts = struct {
    key_placeholder: []const u8 = "Key",
    value_placeholder: []const u8 = "Value",
    /// 不画开关：每一对都算启用。
    no_toggles: bool = false,
    /// 不画「保密」按钮。
    no_secrets: bool = false,
    read_only: bool = false,
};

/// 键值是否写得不对：带空格，或与前面**启用**的一对重名。
pub fn kvProblem(pairs: []const KvPair, i: usize) ?[]const u8 {
    if (i >= pairs.len) return null;
    const p = &pairs[i];
    if (p.key_len == 0) return null;
    for (p.keySlice()) |c| {
        if (c == ' ' or c == '\t') return "Has a space";
    }
    if (!p.enabled) return null;
    var j: usize = 0;
    while (j < i) : (j += 1) {
        if (pairs[j].enabled and std.mem.eql(u8, pairs[j].keySlice(), p.keySlice())) return "Used twice";
    }
    return null;
}

/// 键值编辑器：一行一对「开关 / 键 / 值 / 保密 / 删除」，末尾空行输入即新增。
/// 返回 true 表示本帧有任何变化（编辑、开关、保密、删除或新增）。
pub fn kvEditor(ui: *core.Context, id: []const u8, pairs: []KvPair, count: *usize, opts: KvEditorOpts) bool {
    if (pairs.len == 0) return false;
    var changed = false;
    const n = @min(count.*, pairs.len);
    const key = idOf(id);
    const fresh = !opts.read_only and n < pairs.len;
    // 窄了就键值分两行
    const avail = ui.stack[ui.depth - 1].width;
    const narrow = avail > 0 and avail < 480;

    var i: usize = 0;
    const rows = n + @as(usize, if (fresh) 1 else 0);
    while (i < rows) : (i += 1) {
        const is_fresh = i == n and fresh;
        const p = &pairs[i];
        // 空行没被聚焦就清干净（上一帧可能残留）
        if (is_fresh) {
            var kb: [24]u8 = undefined;
            var vb: [24]u8 = undefined;
            const kid = core.Context.idOf(ui.frameStr(std.fmt.bufPrint(kb[0..], "kv-k{d}", .{i}) catch "kv-k"));
            const vid = core.Context.idOf(ui.frameStr(std.fmt.bufPrint(vb[0..], "kv-v{d}", .{i}) catch "kv-v"));
            if (ui.focus_id != kid and ui.focus_id != vid) p.reset();
        }
        const problem = if (is_fresh) null else kvProblem(pairs, i);
        const row_h: f32 = if (problem != null and !narrow) 46 else 36;

        if (narrow) {
            // 上：开关 + 键；下：值 + 按钮
            {
                var r = ui.row(.{ .gap = 8 });
                defer r.end();
                if (!opts.no_toggles) {
                    const box = ui.reserve(16, row_h, false);
                    var on = p.enabled;
                    if (!is_fresh and !opts.read_only) {
                        if (boxToggle(ui, kk(key, 0x100, i), .{ .x = box.x, .y = box.y + 10, .w = 16, .h = 16 }, on)) {
                            on = !on;
                            p.enabled = on;
                            changed = true;
                        }
                    } else {
                        _ = boxToggle(ui, kk(key, 0x100, i), .{ .x = box.x, .y = box.y + 10, .w = 16, .h = 16 }, is_fresh and false);
                    }
                }
                var kb: [24]u8 = undefined;
                const kid = ui.frameStr(std.fmt.bufPrint(kb[0..], "kv-k{d}", .{i}) catch "kv-k");
                if (widgets.input(ui, kid, p.key[0..], &p.key_len, &p.key_caret, .{ .placeholder = opts.key_placeholder })) changed = true;
            }
            {
                var r = ui.row(.{ .gap = 8 });
                defer r.end();
                var vb: [24]u8 = undefined;
                const vid = ui.frameStr(std.fmt.bufPrint(vb[0..], "kv-v{d}", .{i}) catch "kv-v");
                if (widgets.input(ui, vid, p.value[0..], &p.value_len, &p.value_caret, .{
                    .placeholder = opts.value_placeholder,
                    .password = p.secret,
                })) changed = true;
                if (!opts.no_secrets) {
                    const b = ui.reserve(36, 36, false);
                    if (iconButton(ui, kk(key, 0x200, i), b, if (p.secret) "*" else "o", if (p.secret) theme.text else theme.secondary) and !is_fresh) {
                        p.secret = !p.secret;
                        changed = true;
                    }
                }
                if (!opts.read_only) {
                    const b = ui.reserve(36, 36, false);
                    if (iconButton(ui, kk(key, 0x300, i), b, "x", theme.secondary) and !is_fresh) {
                        removeKv(pairs, count, i);
                        return true;
                    }
                }
            }
        } else {
            var r = ui.row(.{ .gap = 8 });
            defer r.end();
            if (!opts.no_toggles) {
                const box = ui.reserve(16, row_h, false);
                if (!is_fresh and !opts.read_only) {
                    if (boxToggle(ui, kk(key, 0x100, i), .{ .x = box.x, .y = box.y + 10, .w = 16, .h = 16 }, p.enabled)) {
                        p.enabled = !p.enabled;
                        changed = true;
                    }
                } else {
                    _ = boxToggle(ui, kk(key, 0x100, i), .{ .x = box.x, .y = box.y + 10, .w = 16, .h = 16 }, false);
                }
            }
            const rest = ui.stack[ui.depth - 1].width - ui.stack[ui.depth - 1].cursor;
            // 按钮与间距先扣掉，剩下的才给键/值（否则最后两颗按钮会被挤出视口）
            const items: f32 = 2 + (if (opts.no_toggles) @as(f32, 0) else 1) + (if (opts.no_secrets) @as(f32, 0) else 1) + (if (opts.read_only) @as(f32, 0) else 1);
            const btn_w_sum: f32 = (if (opts.no_toggles) @as(f32, 0) else 16) + (if (opts.no_secrets) @as(f32, 0) else 30) + (if (opts.read_only) @as(f32, 0) else 30);
            const usable = @max(120, rest - btn_w_sum - (items - 1) * 8);
            const val_w = usable * 0.58;
            var kb: [24]u8 = undefined;
            const kid = ui.frameStr(std.fmt.bufPrint(kb[0..], "kv-k{d}", .{i}) catch "kv-k");
            if (widgets.input(ui, kid, p.key[0..], &p.key_len, &p.key_caret, .{
                .placeholder = opts.key_placeholder,
                .width = usable - val_w,
            })) changed = true;
            var vb: [24]u8 = undefined;
            const vid = ui.frameStr(std.fmt.bufPrint(vb[0..], "kv-v{d}", .{i}) catch "kv-v");
            if (widgets.input(ui, vid, p.value[0..], &p.value_len, &p.value_caret, .{
                .placeholder = opts.value_placeholder,
                .width = val_w,
                .password = p.secret,
            })) changed = true;
            if (!opts.no_secrets) {
                const b = ui.reserve(30, 36, false);
                if (iconButton(ui, kk(key, 0x200, i), b, if (p.secret) "*" else "o", if (p.secret) theme.text else theme.secondary) and !is_fresh) {
                    p.secret = !p.secret;
                    changed = true;
                }
            }
            if (!opts.read_only) {
                const b = ui.reserve(30, 36, false);
                if (iconButton(ui, kk(key, 0x300, i), b, "x", theme.secondary) and !is_fresh) {
                    removeKv(pairs, count, i);
                    return true;
                }
            }
        }
        if (problem) |msg| {
            if (!narrow) {
                const hint = ui.reserve(0, 14, false);
                ui.addText(.{ .x = hint.x + 24, .y = hint.y - 1, .w = @max(60, hint.w - 26), .h = 14 }, msg, theme.font_small, theme.danger);
            }
        }
        // 空行里打了字 → 变成一对
        if (is_fresh and (p.key_len > 0 or p.value_len > 0)) {
            p.enabled = true;
            count.* = @min(n + 1, pairs.len);
            changed = true;
            break;
        }
    }
    return changed;
}

fn removeKv(pairs: []KvPair, count: *usize, i: usize) void {
    const n = @min(count.*, pairs.len);
    if (i >= n) return;
    var k = i;
    while (k + 1 < n) : (k += 1) pairs[k] = pairs[k + 1];
    pairs[n - 1].reset();
    count.* = n - 1;
}

// =============================================================== 问题面板

pub const Severity = enum(u8) { err = 0, warning = 1, info = 2, hint = 3 };

pub const Diagnostic = struct {
    severity: Severity = .err,
    message: []const u8 = "",
    /// 分组用；空 = 「No file」组。
    file: []const u8 = "",
    /// 1 起；0 不显示位置。
    line: i32 = 0,
    column: i32 = 0,
    source: []const u8 = "",
    code: []const u8 = "",
};

pub const ProblemsOpts = struct {
    /// 0 = 按行数自适应（最多 360）。
    height: f32 = 0,
    /// 不画顶部的「严重度开关 + 过滤框」。
    no_toolbar: bool = false,
};

pub const ProblemsResult = struct {
    /// 选中的诊断下标，-1 = 无。
    selected: i32 = -1,
    /// 本帧被打开的诊断（双击或回车），-1 = 无。
    activated: i32 = -1,
    /// 通过过滤的诊断条数。
    shown: i32 = 0,
    /// 因为行数上限被截断（诊断太多）。
    truncated: bool = false,
};

pub const ProblemsState = struct {
    show: [4]bool = .{ true, true, true, true },
    query: [96]u8 = @splat(0),
    query_len: usize = 0,
    query_caret: usize = 0,
    sel: i32 = -1,
    /// 折叠的文件键（文件名哈希），固定容量。
    folded: [16]u32 = @splat(0),
    nfolded: usize = 0,
};

const MAX_ROWS = 192;
const MAX_FILES = 16;
const PRB_ROW: f32 = 26;

fn sevTone(s: Severity) Tone {
    return switch (s) {
        .err => .danger,
        .warning => .warn,
        .info => .info,
        .hint => .neutral,
    };
}

fn sevGlyph(s: Severity) []const u8 {
    return switch (s) {
        .err => "x",
        .warning => "!",
        .info => "i",
        .hint => "?",
    };
}

fn hash32(name: []const u8) u32 {
    var h: u32 = 2166136261;
    for (name) |c| {
        h ^= c;
        h *%= 16777619;
    }
    return h;
}

fn baseName(path: []const u8) []const u8 {
    var base = path;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') base = path[i + 1 ..];
    }
    return base;
}

fn dirPart(path: []const u8, base: []const u8) []const u8 {
    if (base.len >= path.len) return "";
    return path[0 .. path.len - base.len];
}

fn prbFolded(st: *ProblemsState, h: u32) bool {
    for (st.folded[0..st.nfolded]) |f| {
        if (f == h) return true;
    }
    return false;
}

fn prbToggleFold(st: *ProblemsState, h: u32) void {
    var i: usize = 0;
    while (i < st.nfolded) : (i += 1) {
        if (st.folded[i] == h) {
            st.folded[i] = st.folded[st.nfolded - 1];
            st.nfolded -= 1;
            return;
        }
    }
    if (st.nfolded < st.folded.len) {
        st.folded[st.nfolded] = h;
        st.nfolded += 1;
    }
}

/// 编译器 / linter 诊断：按文件分组的树，顶部有严重度开关与过滤框，
/// 点文件头折叠，上下键移动选择、左右键折叠展开、回车或双击打开。
pub fn problems(ui: *core.Context, id: []const u8, diags: []const Diagnostic, st: *ProblemsState, opts: ProblemsOpts) ProblemsResult {
    var res = ProblemsResult{};
    const key = idOf(id);
    const query = st.query[0..st.query_len];

    // ---- 计数（过滤前）
    var total = [4]i32{ 0, 0, 0, 0 };
    for (diags) |d| total[@backingInt(d.severity)] += 1;

    // ---- 过滤 + 分组（保留首次出现的顺序）
    var gname: [MAX_FILES][]const u8 = @splat("");
    var ghash: [MAX_FILES]u32 = @splat(0);
    var gcount: [MAX_FILES]i32 = @splat(0);
    var ng: usize = 0;
    var pass_buf: [MAX_ROWS]i32 = @splat(-1);
    var npass: usize = 0;
    var shown: i32 = 0;
    for (diags, 0..) |d, i| {
        if (!st.show[@backingInt(d.severity)]) continue;
        moved: {
            if (!containsCi(d.message, query) and !containsCi(d.code, query) and !containsCi(d.file, query) and !containsCi(d.source, query)) break :moved;
            shown += 1;
            const name = if (d.file.len == 0) "No file" else d.file;
            var gi: usize = 0;
            var found: ?usize = null;
            while (gi < ng) : (gi += 1) {
                if (std.mem.eql(u8, gname[gi], name)) {
                    found = gi;
                    break;
                }
            }
            const g = found orelse blk: {
                if (ng >= MAX_FILES) break :moved;
                gname[ng] = name;
                ghash[ng] = hash32(name);
                gcount[ng] = 0;
                ng += 1;
                break :blk ng - 1;
            };
            gcount[g] += 1;
            if (npass < pass_buf.len) {
                pass_buf[npass] = @intCast(i);
                npass += 1;
            } else res.truncated = true;
        }
    }
    res.shown = shown;

    // ---- 顶部工具栏
    if (!opts.no_toolbar) {
        var r = ui.row(.{ .gap = 8 });
        defer r.end();
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const sev: Severity = @fromBackingInt(@intCast(k));
            const label_w = ui.measureText(sevGlyph(sev), theme.font_small).w;
            var cnt_buf: [8]u8 = undefined;
            const cnt = num.int(cnt_buf[0..], total[k]);
            const w = label_w + ui.measureText(cnt, theme.font_small).w + 22;
            const chip = ui.reserve(w, 24, false);
            const hit = ui.interactEx(kk(key, 0x9100, k), chip, true);
            const on = st.show[k];
            const tone_c = trace.toneColor(sevTone(sev));
            ui.addBox(chip, .{
                .fill = if (on) theme.withAlpha(tone_c, 34) else theme.track,
                .radius = 12,
                .border = if (on) theme.withAlpha(tone_c, 140) else theme.border,
            });
            ui.addText(.{ .x = chip.x + 8, .y = chip.y + 3, .w = label_w + 1, .h = 18 }, sevGlyph(sev), theme.font_small, if (on) tone_c else theme.secondary);
            ui.addText(.{ .x = chip.x + 12 + label_w, .y = chip.y + 3, .w = chip.w, .h = 18 }, cnt, theme.font_small, if (on) theme.text else theme.secondary);
            if (hit.clicked) st.show[k] = !on;
        }
        var fb: [24]u8 = undefined;
        const fid = ui.frameStr(std.fmt.bufPrint(fb[0..], "{s}-q", .{id}) catch "prb-q");
        _ = widgets.input(ui, fid, st.query[0..], &st.query_len, &st.query_caret, .{ .placeholder = "Filter", .width = 180 });
    }

    // ---- 行表（文件头 + 诊断）
    var row_kind: [MAX_ROWS]i32 = @splat(0); // >=0 诊断下标；<0 = -(组 + 2)
    var nrows: usize = 0;
    var g: usize = 0;
    while (g < ng) : (g += 1) {
        if (nrows >= row_kind.len) {
            res.truncated = true;
            break;
        }
        row_kind[nrows] = -(@as(i32, @intCast(g)) + 2);
        nrows += 1;
        if (prbFolded(st, ghash[g])) continue;
        // 把这一组的诊断塞进来（保持原始顺序）
        var pi: usize = 0;
        while (pi < npass) : (pi += 1) {
            const di: usize = @intCast(pass_buf[pi]);
            const name = if (diags[di].file.len == 0) "No file" else diags[di].file;
            if (!std.mem.eql(u8, name, gname[g])) continue;
            if (nrows >= row_kind.len) {
                res.truncated = true;
                break;
            }
            row_kind[nrows] = @intCast(di);
            nrows += 1;
        }
    }

    const h: f32 = if (opts.height > 0) opts.height else @min(360, PRB_ROW * @as(f32, @floatFromInt(nrows + 1)) + 8);
    var area = ui.scroll(.{ .id = id, .height = h });
    defer area.end();
    const avail = area.rect.w;

    if (nrows == 0) {
        ui.addText(.{ .x = area.rect.x + 12, .y = area.rect.y + 10, .w = avail - 24, .h = 18 }, if (diags.len == 0) "No problems" else "No problems match the filters", theme.font_body, theme.secondary);
        return res;
    }

    // 键盘：上下移动选择、左右折叠、回车激活（列表先登记焦点，行后登记所以照样抢得到点击）
    const list_key = kk(key, 0x9F00, 0);
    const list_hit = ui.interactEx(list_key, area.rect, true);
    const focused = list_hit.focused;
    var visible: [MAX_ROWS]i32 = @splat(-1);
    var nvis: usize = 0;
    for (row_kind[0..nrows]) |rk| {
        if (rk >= 0 and nvis < visible.len) {
            visible[nvis] = rk;
            nvis += 1;
        }
    }
    if (focused and nvis > 0) {
        if (ui.input.keyPressed(.down)) {
            var at: i32 = -1;
            for (visible[0..nvis], 0..) |v, vi| {
                if (v == st.sel) at = @intCast(vi);
            }
            const next = if (at < 0) 0 else @min(@as(i32, @intCast(nvis - 1)), at + 1);
            st.sel = visible[@intCast(next)];
        } else if (ui.input.keyPressed(.up)) {
            var at: i32 = @intCast(nvis);
            for (visible[0..nvis], 0..) |v, vi| {
                if (v == st.sel) at = @intCast(vi);
            }
            const prev = if (at >= @as(i32, @intCast(nvis))) @as(i32, @intCast(nvis - 1)) else @max(0, at - 1);
            st.sel = visible[@intCast(prev)];
        } else if (ui.input.keyPressed(.left) or ui.input.keyPressed(.right)) {
            // 折叠 / 展开选中诊断所在的文件
            if (st.sel >= 0) {
                const dm = diags[@intCast(st.sel)];
                const nm = if (dm.file.len == 0) "No file" else dm.file;
                prbToggleFold(st, hash32(nm));
            }
        } else if (ui.input.keyPressed(.enter) and st.sel >= 0) {
            res.activated = st.sel;
        }
    }

    var r: usize = 0;
    while (r < nrows) : (r += 1) {
        const rk = row_kind[r];
        if (rk < 0) {
            // 文件头
            const gi: usize = @intCast(-rk - 2);
            const name = gname[gi];
            const base = if (std.mem.eql(u8, name, "No file")) name else baseName(name);
            const dir = if (std.mem.eql(u8, name, "No file")) "" else dirPart(name, base);
            const row = ui.reserve(0, PRB_ROW, true);
            const hit = ui.interactEx(kk(key, 0x9200, gi), row, false);
            if (hit.hover) ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
            const folded = prbFolded(st, ghash[gi]);
            ui.addText(.{ .x = row.x + 4, .y = row.y + 4, .w = 12, .h = 18 }, if (folded) ">" else "v", theme.font_small, theme.secondary);
            const bw = @min(ui.measureText(base, theme.font_body).w + 2, @max(40, avail * 0.5));
            ui.addText(.{ .x = row.x + 20, .y = row.y + 3, .w = bw, .h = 20 }, clipText(ui, base, theme.font_body, bw), theme.font_body, theme.text);
            if (dir.len > 0 and avail > 520) {
                const dx = row.x + 24 + bw;
                ui.addText(.{ .x = dx, .y = row.y + 5, .w = @max(0, row.w - (dx - row.x) - 40), .h = 16 }, clipText(ui, dir, theme.font_small, @max(0, row.w - (dx - row.x) - 40)), theme.font_small, theme.secondary);
            }
            var cb: [8]u8 = undefined;
            const cnt = num.int(cb[0..], gcount[gi]);
            const cw = ui.measureText(cnt, theme.font_small).w + 12;
            ui.addBox(.{ .x = row.x + row.w - cw - 4, .y = row.y + 5, .w = cw, .h = 16 }, .{ .fill = theme.track, .radius = 8 });
            ui.addText(.{ .x = row.x + row.w - cw + 2, .y = row.y + 5, .w = cw, .h = 16 }, cnt, theme.font_small, theme.secondary);
            if (hit.clicked) prbToggleFold(st, ghash[gi]);
            continue;
        }
        // 诊断行
        const di: usize = @intCast(rk);
        const d = diags[di];
        const row = ui.reserve(0, PRB_ROW, true);
        const hit = ui.interactEx(kk(key, 0x9300, di), row, true);
        const sel = st.sel == rk;
        if (sel) {
            ui.addBox(row, .{ .fill = theme.accent_bg, .radius = 4 });
        } else if (hit.hover) ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
        const tone_c = trace.toneColor(sevTone(d.severity));
        ui.addText(.{ .x = row.x + 22, .y = row.y + 4, .w = 12, .h = 18 }, sevGlyph(d.severity), theme.font_small, tone_c);
        // 右侧：位置
        var pos_buf: [20]u8 = undefined;
        var pos_txt: []const u8 = "";
        if (d.line > 0) {
            if (d.column > 0) {
                var lb: [8]u8 = undefined;
                var cb2: [8]u8 = undefined;
                const ls = num.int(lb[0..], d.line);
                const cs = num.int(cb2[0..], d.column);
                pos_txt = std.fmt.bufPrint(pos_buf[0..], "{s}:{s}", .{ ls, cs }) catch "";
            } else {
                var lb: [8]u8 = undefined;
                const ls = num.int(lb[0..], d.line);
                pos_txt = std.fmt.bufPrint(pos_buf[0..], "{s}", .{ls}) catch "";
            }
        }
        const posw = if (pos_txt.len > 0) ui.measureText(pos_txt, theme.font_small).w + 8 else 0;
        // 代码：source(code)
        var code_buf: [64]u8 = undefined;
        var code_txt: []const u8 = "";
        if (avail > 520) {
            if (d.code.len > 0 and d.source.len > 0) {
                code_txt = std.fmt.bufPrint(code_buf[0..], "{s}({s})", .{ d.source, d.code }) catch d.code;
            } else if (d.code.len > 0) {
                code_txt = d.code;
            } else {
                code_txt = d.source;
            }
        }
        const codew = if (code_txt.len > 0) @min(ui.measureText(code_txt, theme.font_small).w + 10, avail * 0.32) else 0;
        const msg_x = row.x + 40;
        const msg_w = @max(20, row.w - 40 - codew - posw - 8);
        ui.addText(.{ .x = msg_x, .y = row.y + 4, .w = msg_w, .h = 18 }, clipText(ui, d.message, theme.font_body, msg_w), theme.font_body, theme.text);
        if (code_txt.len > 0) {
            const cx = msg_x + msg_w + 4;
            ui.addText(.{ .x = cx, .y = row.y + 5, .w = codew, .h = 16 }, clipText(ui, ui.frameStr(code_txt), theme.font_small, codew), theme.font_small, theme.secondary);
        }
        if (pos_txt.len > 0) {
            ui.addText(.{ .x = row.x + row.w - posw, .y = row.y + 5, .w = posw, .h = 16 }, ui.frameStr(pos_txt), theme.font_small, theme.secondary);
        }
        if (hit.clicked) {
            st.sel = rk;
            // 双击 = 450ms 内同一行
            const dbl_key = kk(key, 0x9D00, 0);
            const prev = ui.knownSize(dbl_key);
            const is_double = if (prev) |p|
                (ui.time * 1000.0 - @as(f64, p.w) < 450.0 and @as(i32, @intFromFloat(@max(p.h, 0))) == rk)
            else
                false;
            ui.rememberSize(dbl_key, @as(f32, @floatCast(ui.time * 1000.0)), @floatFromInt(rk));
            if (is_double) res.activated = rk;
        }
        if (hit.activated) res.activated = rk;
    }
    res.selected = st.sel;
    return res;
}

// =============================================================== CI 流水线

pub const JobStatus = enum(u8) { pending, running, passed, failed, skipped, canceled };

pub const PipelineJob = struct {
    name: []const u8 = "",
    /// 阶段下标。
    stage: i32 = 0,
    status: JobStatus = .pending,
    /// 秒；负数 = 还没跑。
    duration: f32 = -1,
    /// 失败也不算阶段失败。
    allow_failure: bool = false,
};

pub const PipelineOpts = struct {
    /// 选中作业（点一下写进去）。
    selected: ?*i32 = null,
    /// 0 = 按阶段与作业数自适应。
    height: f32 = 0,
};

pub const PipelineResult = struct {
    clicked: i32 = -1,
    hovered: i32 = -1,
};

fn jobTone(s: JobStatus) Tone {
    return switch (s) {
        .pending => .neutral,
        .running => .info,
        .passed => .success,
        .failed => .danger,
        .skipped => .neutral,
        .canceled => .neutral,
    };
}

fn jobGlyph(s: JobStatus) []const u8 {
    return switch (s) {
        .pending => ".",
        .running => ">",
        .passed => "v",
        .failed => "x",
        .skipped => "-",
        .canceled => "/",
    };
}

/// 一个阶段的汇总状态：失败 > 运行 > 待跑 > 取消 > 跳过 > 通过。
fn stageStatus(jobs: []const PipelineJob, stage_i: i32, soft: *bool) JobStatus {
    var any = false;
    var all_passed = true;
    var all_skipped = true;
    soft.* = false;
    for (jobs) |j| {
        if (j.stage != stage_i) continue;
        any = true;
        switch (j.status) {
            .failed => {
                if (j.allow_failure) {
                    soft.* = true;
                } else return .failed;
            },
            .running => return .running,
            .pending => return .pending,
            .canceled => return .canceled,
            .passed => all_skipped = false,
            .skipped => all_passed = false,
        }
    }
    if (!any) return .pending;
    if (all_passed) return .passed;
    if (all_skipped) return .skipped;
    return .passed;
}

/// CI/CD 流水线：阶段从左到右，每个阶段一列作业（状态 + 耗时），阶段头汇总。
/// 窄于 560 时阶段上下堆叠。点击作业返回下标（用于打开日志）。
pub fn pipeline(ui: *core.Context, id: []const u8, stages: []const []const u8, jobs: []const PipelineJob, opts: PipelineOpts) PipelineResult {
    var res = PipelineResult{};
    const key = idOf(id);
    if (stages.len == 0) return res;
    const card_h: f32 = 30;
    const gap_v: f32 = 6;
    var max_jobs: usize = 1;
    var s: usize = 0;
    while (s < stages.len) : (s += 1) {
        var cnt: usize = 0;
        for (jobs) |j| {
            if (j.stage == @as(i32, @intCast(s))) cnt += 1;
        }
        if (cnt > max_jobs) max_jobs = cnt;
    }
    const h: f32 = if (opts.height > 0)
        opts.height
    else
        24 + @as(f32, @floatFromInt(max_jobs)) * (card_h + gap_v) + 8;

    var area = ui.scroll(.{ .id = id, .height = h });
    defer area.end();
    const avail = area.rect.w;
    const vertical = avail < 560;

    if (vertical) {
        s = 0;
        while (s < stages.len) : (s += 1) {
            drawStageColumn(ui, key, s, stages, jobs, area.rect.w, card_h, gap_v, opts.selected, &res);
            if (s + 1 < stages.len) {
                // 竖向连接段
                const link = ui.reserve(0, 14, false);
                ui.addBox(.{ .x = link.x + 11, .y = link.y, .w = 2, .h = link.h }, .{ .fill = theme.border });
            }
        }
    } else {
        var row = ui.row(.{ .gap = 10 });
        defer row.end();
        const col_w = (avail - @as(f32, @floatFromInt(stages.len - 1)) * 10) / @as(f32, @floatFromInt(stages.len));
        s = 0;
        while (s < stages.len) : (s += 1) {
            drawStageColumn(ui, key, s, stages, jobs, @max(120, col_w), card_h, gap_v, opts.selected, &res);
        }
    }
    return res;
}

fn drawStageColumn(
    ui: *core.Context,
    key: u64,
    s: usize,
    stages: []const []const u8,
    jobs: []const PipelineJob,
    col_w: f32,
    card_h: f32,
    gap_v: f32,
    selected: ?*i32,
    res: *PipelineResult,
) void {
    var col = ui.column(.{ .gap = gap_v });
    defer col.end();
    // 阶段头
    const head = ui.reserve(col_w, 22, false);
    var soft = false;
    const st = stageStatus(jobs, @intCast(s), &soft);
    const tone_c = trace.toneColor(jobTone(st));
    ui.addBox(.{ .x = head.x, .y = head.y + 7, .w = 8, .h = 8 }, .{ .fill = tone_c, .radius = 4 });
    const name = if (s < stages.len) stages[s] else "";
    var tb: [8]u8 = undefined;
    var total: f32 = -1;
    for (jobs) |j| {
        if (j.stage == @as(i32, @intCast(s)) and j.duration >= 0 and j.duration > total) total = j.duration;
    }
    const dur = if (total >= 0) ui.frameStr(fmtDuration(tb[0..], total)) else "";
    const durw = if (dur.len > 0) ui.measureText(dur, theme.font_small).w + 6 else 0;
    const name_w = @max(20, col_w - 18 - durw);
    ui.addText(.{ .x = head.x + 14, .y = head.y + 2, .w = name_w, .h = 18 }, clipText(ui, name, theme.font_small, name_w), theme.font_small, if (soft) theme.secondary else theme.text);
    if (dur.len > 0) {
        ui.addText(.{ .x = head.x + col_w - durw + 6, .y = head.y + 2, .w = durw, .h = 18 }, dur, theme.font_small, theme.secondary);
    }
    // 作业卡
    for (jobs, 0..) |j, ji| {
        if (j.stage != @as(i32, @intCast(s))) continue;
        const card = ui.reserve(col_w, card_h, false);
        const hit = ui.interactEx(kk(key, 0x8100, ji), card, true);
        const jc = trace.toneColor(jobTone(j.status));
        ui.addBox(card, .{
            .fill = if (hit.hover) theme.track else theme.surface,
            .radius = 6,
            .border = if (hit.hover) theme.accent else theme.border,
        });
        ui.addText(.{ .x = card.x + 8, .y = card.y + 6, .w = 12, .h = 18 }, jobGlyph(j.status), theme.font_small, jc);
        var db: [16]u8 = undefined;
        const d2 = if (j.duration >= 0) ui.frameStr(fmtDuration(db[0..], j.duration)) else "";
        const d2w = if (d2.len > 0) ui.measureText(d2, theme.font_small).w + 6 else 0;
        const nw = @max(16, card.w - 24 - d2w);
        const name_col = if (j.status == .pending or j.status == .skipped or j.status == .canceled) theme.secondary else theme.text;
        ui.addText(.{ .x = card.x + 22, .y = card.y + 5, .w = nw, .h = 18 }, clipText(ui, j.name, theme.font_small, nw), theme.font_small, name_col);
        if (d2.len > 0) {
            ui.addText(.{ .x = card.x + card.w - d2w + 4, .y = card.y + 5, .w = d2w, .h = 18 }, d2, theme.font_small, theme.secondary);
        }
        if (hit.hover) res.hovered = @intCast(ji);
        if (hit.clicked) {
            res.clicked = @intCast(ji);
            if (selected) |sel| sel.* = @intCast(ji);
        }
    }
}

// =============================================================== 查询构建

/// 字段类型决定可用的运算符与值的编辑方式（对位 `cui_query_type`）。
pub const QueryType = enum(u8) { text = 0, number = 1, choice = 2, boolean = 3 };

pub const QueryField = struct {
    name: []const u8 = "",
    type: QueryType = .text,
    /// `choice` 的可选值。
    choices: []const []const u8 = &.{},
};

/// 一条条件（`group == false`）或一个分组（`group == true`），按树序排列，`depth` 表示层级。
pub const QueryNode = struct {
    depth: i32 = 0,
    group: bool = false,
    /// 分组：`any`（或）而不是 `all`（且）。
    any: bool = false,
    field: i32 = 0,
    /// 见 `queryOpName`。
    op: i32 = 0,
    value: [64]u8 = @splat(0),
    value_len: usize = 0,
    value_caret: usize = 0,

    pub fn valueSlice(self: *const QueryNode) []const u8 {
        return self.value[0..@min(self.value_len, self.value.len)];
    }

    pub fn setValue(self: *QueryNode, s: []const u8) void {
        const n = @min(s.len, self.value.len);
        @memcpy(self.value[0..n], s[0..n]);
        self.value_len = n;
        self.value_caret = n;
        if (n < self.value.len) self.value[n] = 0;
    }
};

pub const QueryOpts = struct {
    /// 分组嵌套上限（默认 3）。
    max_depth: u8 = 3,
    /// 只读：不画增删按钮，也不改任何值。
    read_only: bool = false,
    // 与 CUI 的差异：**没有 `width`** —— ZZUI 的容器不带显式宽度，
    // 要定宽请把它放进 `ui.panel()` 的定宽面板里（见 `docs/迁移审计.md` §4）。
};

const qb_ops_text = [_][]const u8{ "is", "is not", "contains", "does not contain", "starts with", "ends with" };
const qb_ops_num = [_][]const u8{ "=", "!=", ">", ">=", "<", "<=" };
const qb_ops_choice = [_][]const u8{ "is", "is not" };
const qb_ops_bool = [_][]const u8{ "is true", "is false" };

fn qbOps(qt: QueryType) []const []const u8 {
    return switch (qt) {
        .number => qb_ops_num[0..],
        .choice => qb_ops_choice[0..],
        .boolean => qb_ops_bool[0..],
        .text => qb_ops_text[0..],
    };
}

/// 某类型的第 `op` 个运算符的文案（越界返回 null），对位 `cui_query_op_name`。
pub fn queryOpName(qt: QueryType, op: i32) ?[]const u8 {
    const ops = qbOps(qt);
    if (op < 0 or op >= @as(i32, @intCast(ops.len))) return null;
    return ops[@intCast(op)];
}

fn qbField(fields: []const QueryField, i: i32) ?QueryField {
    if (i < 0 or i >= @as(i32, @intCast(fields.len))) return null;
    return fields[@intCast(i)];
}

/// 节点 `i` 子树的结束下标（第一个不比它深的节点）；规则恒为 `i + 1`。
fn qbEnd(nodes: []const QueryNode, i: usize) usize {
    if (!nodes[i].group) return i + 1;
    var j = i + 1;
    while (j < nodes.len and nodes[j].depth > nodes[i].depth) j += 1;
    return j;
}

fn ieqPrefix(a: []const u8, b: []const u8, n: usize) bool {
    if (a.len < n or b.len < n) return false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

/// 判定一条规则（`values[field]` 是记录里该字段的文本值）。
fn qbRule(f: QueryField, nd: QueryNode, raw: ?[]const u8) bool {
    const v = raw orelse "";
    const q = nd.valueSlice();
    switch (f.type) {
        .number => {
            const a = num.parseF32(v) orelse 0;
            const c = num.parseF32(q) orelse 0;
            return switch (nd.op) {
                0 => a == c,
                1 => a != c,
                2 => a > c,
                3 => a >= c,
                4 => a < c,
                else => a <= c,
            };
        },
        .choice => return std.mem.eql(u8, v, q) == (nd.op == 0),
        .boolean => {
            const tr = std.mem.eql(u8, v, "1") or ieqPrefix(v, "true", 4) or ieqPrefix(v, "yes", 3);
            return tr == (nd.op == 0);
        },
        .text => {
            const lv = v.len;
            const lq = q.len;
            return switch (nd.op) {
                0 => lv == lq and ieqPrefix(v, q, lq),
                1 => !(lv == lq and ieqPrefix(v, q, lq)),
                2 => containsCi(v, q),
                3 => !containsCi(v, q),
                4 => lv >= lq and ieqPrefix(v, q, lq),
                else => lv >= lq and ieqPrefix(v[lv - lq ..], q, lq),
            };
        },
    }
}

fn qbMatch(fields: []const QueryField, nodes: []const QueryNode, i: usize, values: []const ?[]const u8) bool {
    const nd = nodes[i];
    if (!nd.group) {
        const f = qbField(fields, nd.field) orelse return true;
        const raw: ?[]const u8 = if (nd.field >= 0 and nd.field < @as(i32, @intCast(values.len))) values[@intCast(nd.field)] else null;
        return qbRule(f, nd, raw);
    }
    const end = qbEnd(nodes, i);
    var any_kid = false;
    var j = i + 1;
    while (j < end) : (j = qbEnd(nodes, j)) {
        const m = qbMatch(fields, nodes, j, values);
        any_kid = true;
        if (nd.any and m) return true;
        if (!nd.any and !m) return false;
    }
    // 空分组匹配一切
    return if (nd.any) !any_kid else true;
}

/// 记录是否满足查询（空查询恒真）。`values[i]` 是第 i 个字段的文本值。
pub fn queryMatch(fields: []const QueryField, nodes: []const QueryNode, values: []const ?[]const u8) bool {
    if (nodes.len == 0) return true;
    return qbMatch(fields, nodes, 0, values);
}

const QbBuf = struct {
    out: []u8,
    len: usize = 0,

    fn put(self: *QbBuf, s: []const u8) void {
        for (s) |c| {
            if (self.len < self.out.len) self.out[self.len] = c;
            self.len += 1;
        }
    }

    fn slice(self: *const QbBuf) []const u8 {
        return self.out[0..@min(self.len, self.out.len)];
    }
};

fn qbTextNode(fields: []const QueryField, nodes: []const QueryNode, i: usize, b: *QbBuf, nested: bool) usize {
    const nd = nodes[i];
    if (!nd.group) {
        const f = qbField(fields, nd.field) orelse return i + 1;
        b.put(if (f.name.len > 0) f.name else "?");
        b.put(" ");
        b.put(queryOpName(f.type, nd.op) orelse "?");
        if (f.type != .boolean) {
            b.put(if (f.type == .text) " \"" else " ");
            b.put(nd.valueSlice());
            if (f.type == .text) b.put("\"");
        }
        return i + 1;
    }
    const end = qbEnd(nodes, i);
    var kids: usize = 0;
    var j = i + 1;
    while (j < end) : (j = qbEnd(nodes, j)) kids += 1;
    const paren = nested and kids > 1;
    if (paren) b.put("(");
    var k: usize = 0;
    j = i + 1;
    while (j < end) : (k += 1) {
        if (k > 0) b.put(if (nd.any) " or " else " and ");
        const next = qbTextNode(fields, nodes, j, b, true);
        if (next <= j) break;
        j = next;
    }
    if (paren) b.put(")");
    return end;
}

/// 把查询写成一句话（"status is \"open\" and age > 3"），返回写进 `out` 的部分。
pub fn queryText(fields: []const QueryField, nodes: []const QueryNode, out: []u8) []const u8 {
    var b = QbBuf{ .out = out };
    if (nodes.len == 0) return b.slice();
    _ = qbTextNode(fields, nodes, 0, &b, false);
    return b.slice();
}

// ---- 编辑器 ----

const QbEdit = struct {
    at: i32 = -1,
    end: i32 = 0,
    insert: bool = false,
    group: bool = false,
    depth: i32 = 0,
};

const QbF = struct {
    ui: *core.Context,
    key: u64,
    id: []const u8,
    fields: []const QueryField,
    nodes: []QueryNode,
    count: usize,
    capacity: usize,
    narrow: bool,
    read_only: bool,
    max_depth: u8,
    edit: QbEdit = .{},
    changed: bool = false,
};

/// 当前行内还剩多宽（`reserve(0, ...)` 在 row 里会得到零宽，必须显式算）。
fn remaining(ui: *core.Context) f32 {
    const fr = ui.stack[ui.depth - 1];
    const w = fr.width - fr.cursor;
    return if (w > 0) w else 0;
}

/// 带下拉箭头的循环按钮（点一下换下一个值；不用浮层，窄屏也不会挤爆）。
fn cycleChip(ui: *core.Context, key: u64, rect: t.Rect, label: []const u8, enabled: bool) bool {
    const it = ui.interactEx(key, rect, enabled);
    const arrow: f32 = if (enabled) 14 else 0;
    ui.addBox(rect, .{
        .fill = if (it.hover and enabled) theme.track else theme.surface,
        .radius = theme.radius_control,
        .border = if (it.focused) theme.accent else theme.border,
    });
    const room = @max(8, rect.w - 18 - arrow);
    const m = ui.measureText(label, theme.font_body);
    ui.addText(.{ .x = rect.x + 10, .y = rect.y + (rect.h - m.h) / 2, .w = room, .h = m.h }, clipText(ui, label, theme.font_body, room), theme.font_body, if (enabled) theme.text else theme.secondary);
    if (enabled) {
        const ax = rect.x + rect.w - 13;
        const ay = rect.y + rect.h / 2 - 2;
        ui.addOverlayLine(.{ .x = ax - 4, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.5, theme.secondary);
        ui.addOverlayLine(.{ .x = ax + 4, .y = ay }, .{ .x = ax, .y = ay + 4 }, 1.5, theme.secondary);
    }
    return enabled and (it.clicked or it.activated);
}

fn qbRuleRow(f: *QbF, i: usize) void {
    const ui = f.ui;
    const nd = &f.nodes[i];
    const field_w: f32 = if (f.narrow) 132 else 150;
    const op_w: f32 = if (f.narrow) 96 else 140;
    const fld = qbField(f.fields, nd.field);
    const qt: QueryType = if (fld) |x| x.type else .text;
    const ops = qbOps(qt);

    // 窄屏：值单独一行
    if (f.narrow) {
        var r1 = ui.row(.{ .gap = 8 });
        const fr = cycleChip(ui, kk(f.key, 0xB000, i), ui.reserve(field_w, 34, false), if (fld) |x| x.name else "?", !f.read_only);
        if (fr) {
            nd.field = @intCast(@mod(nd.field + 1, @as(i32, @intCast(@max(1, f.fields.len)))));
            nd.op = 0;
            nd.setValue("");
            f.changed = true;
        }
        const op = qbOps(qt);
        const oi = @min(@max(nd.op, 0), @as(i32, @intCast(op.len - 1)));
        if (cycleChip(ui, kk(f.key, 0xB100, i), ui.reserve(op_w, 34, false), op[@intCast(oi)], !f.read_only)) {
            nd.op = @intCast(@mod(oi + 1, @as(i32, @intCast(op.len))));
            f.changed = true;
        }
        if (!f.read_only) {
            const b = ui.reserve(30, 34, false);
            if (iconButton(ui, kk(f.key, 0xB300, i), b, "x", theme.secondary)) {
                f.edit = .{ .at = @intCast(i), .end = @intCast(i + 1) };
            }
        }
        r1.end();
        var r2 = ui.row(.{ .gap = 8 });
        defer r2.end();
        qbValueWidth(f, nd, qt, i, @max(120, remaining(ui)));
        return;
    }

    var row = ui.row(.{ .gap = 8 });
    defer row.end();
    if (cycleChip(ui, kk(f.key, 0xB000, i), ui.reserve(field_w, 34, false), if (fld) |x| x.name else "?", !f.read_only)) {
        if (f.fields.len > 0) {
            nd.field = @intCast(@mod(nd.field + 1, @as(i32, @intCast(f.fields.len))));
            nd.op = 0;
            nd.setValue("");
            f.changed = true;
        }
    }
    const oi = @min(@max(nd.op, 0), @as(i32, @intCast(ops.len - 1)));
    if (cycleChip(ui, kk(f.key, 0xB100, i), ui.reserve(if (qt == .number) 76 else op_w, 34, false), ops[@intCast(oi)], !f.read_only)) {
        nd.op = @intCast(@mod(oi + 1, @as(i32, @intCast(ops.len))));
        f.changed = true;
    }
    const rest = remaining(ui) - 8 - (if (f.read_only) @as(f32, 0) else 30);
    qbValueWidth(f, nd, qt, i, @max(120, rest));
    if (!f.read_only) {
        const b = ui.reserve(30, 34, false);
        if (iconButton(ui, kk(f.key, 0xB300, i), b, "x", theme.secondary)) {
            f.edit = .{ .at = @intCast(i), .end = @intCast(i + 1) };
        }
    }
}

fn qbValueWidth(f: *QbF, nd: *QueryNode, qt: QueryType, i: usize, width: f32) void {
    const ui = f.ui;
    const fld = qbField(f.fields, nd.field);
    if (qt == .choice and fld != null and fld.?.choices.len > 0) {
        const choices = fld.?.choices;
        const cur = nd.valueSlice();
        const label = if (cur.len > 0) cur else choices[0];
        const clicked = cycleChip(ui, kk(f.key, 0xB200, i), ui.reserve(if (width > 0) width else 160, 34, false), label, !f.read_only);
        if (!f.read_only and (clicked or cur.len == 0)) {
            var ci: usize = 0;
            while (ci < choices.len) : (ci += 1) {
                if (std.mem.eql(u8, choices[ci], cur)) break;
            }
            const next = if (cur.len == 0 or ci >= choices.len) @as(usize, 0) else (ci + 1) % choices.len;
            nd.setValue(choices[next]);
            f.changed = true;
        }
        return;
    }
    // 布尔值只由运算符决定（is true / is false），没有值输入框
    if (qt == .boolean) return;
    var ib: [48]u8 = undefined;
    const kid = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}#v{d}", .{ f.id, i }) catch "qb-v");
    if (widgets.input(ui, kid, nd.value[0..], &nd.value_len, &nd.value_caret, .{
        .placeholder = if (qt == .number) "0" else "Value",
        .width = if (width > 0) width else 180,
    })) f.changed = true;
}

fn qbGroup(f: *QbF, i: usize) usize {
    const ui = f.ui;
    const nd = &f.nodes[i];
    const end = qbEnd(f.nodes[0..f.count], i);
    const nested = nd.depth > 0;

    var box = ui.column(.{
        .gap = 8,
        .pad = if (nested) 10 else 0,
        .fill = if (nested) (if (@mod(nd.depth, 2) == 0) theme.surface else theme.row_alt) else null,
        .radius = if (nested) theme.radius_control else 0,
        .border = if (nested) theme.border else null,
    });
    defer box.end();

    // 头部：Match [All|Any] of these conditions   [删除组]
    {
        var head = ui.row(.{ .gap = 8 });
        defer head.end();
        const fs_small = theme.font_small;
        const hm = ui.measureText("Match", fs_small);
        const mr = ui.reserve(hm.w + 2, 30, false);
        ui.addText(.{ .x = mr.x, .y = mr.y + (30 - hm.h) / 2, .w = mr.w, .h = hm.h }, "Match", fs_small, theme.secondary);
        var join = @as(usize, if (nd.any) 1 else 0);
        if (f.read_only) {
            // 只读：不画可点的分段控件（否则点了没效果 = 假功能）
            const word = if (nd.any) "any" else "all";
            const wm = ui.measureText(word, fs_small);
            const wr = ui.reserve(wm.w + 2, 30, false);
            ui.addText(.{ .x = wr.x, .y = wr.y + (30 - wm.h) / 2, .w = wr.w, .h = wm.h }, word, fs_small, theme.text);
        } else {
            var jb: [48]u8 = undefined;
            const jid = ui.frameStr(std.fmt.bufPrint(jb[0..], "{s}#join{d}", .{ f.id, i }) catch "qb-join");
            controls.segmented(ui, jid, &[_][]const u8{ "All", "Any" }, &join);
            if (join != @as(usize, if (nd.any) 1 else 0)) {
                nd.any = join == 1;
                f.changed = true;
            }
        }
        const tail = ui.measureText("of these conditions", fs_small);
        const tail_room = remaining(ui) - (if (nested and !f.read_only) @as(f32, 42) else 0);
        if (tail_room > tail.w) {
            const tr = ui.reserve(tail.w + 2, 30, false);
            ui.addText(.{ .x = tr.x, .y = tr.y + 5, .w = tr.w, .h = tail.h }, "of these conditions", fs_small, theme.secondary);
        }
        if (nested and !f.read_only) {
            const b = ui.reserve(30, 30, false);
            if (iconButton(ui, kk(f.key, 0xB400, i), b, "x", theme.secondary)) {
                f.edit = .{ .at = @intCast(i), .end = @intCast(end) };
            }
        }
    }

    // 子节点
    var j = i + 1;
    while (j < end) {
        if (f.nodes[j].group) {
            j = qbGroup(f, j);
        } else {
            qbRuleRow(f, j);
            j += 1;
        }
        if (j <= i) break;
    }
    if (end == i + 1) {
        zzuiMuted(ui, "No conditions: everything matches.");
    }

    if (!f.read_only) {
        var foot = ui.row(.{ .gap = 4 });
        defer foot.end();
        const add_depth: i32 = nd.depth + 1;
        if (widgets.button(ui, "+ Condition", .{ .variant = .ghost, .id_salt = kk(f.key, 0xB500, i) })) {
            f.edit = .{ .at = @intCast(end), .end = @intCast(end), .insert = true, .group = false, .depth = add_depth };
        }
        if (add_depth < @as(i32, f.max_depth)) {
            if (widgets.button(ui, "+ Group", .{ .variant = .ghost, .id_salt = kk(f.key, 0xB600, i) })) {
                if (f.count + 2 <= f.capacity) {
                    f.edit = .{ .at = @intCast(end), .end = @intCast(end), .insert = true, .group = true, .depth = add_depth };
                }
            }
        }
    }
    return end;
}

fn zzuiMuted(ui: *core.Context, s: []const u8) void {
    const m = ui.measureText(s, theme.font_small);
    const r = ui.reserve(0, m.h + 4, true);
    ui.addText(.{ .x = r.x, .y = r.y + 2, .w = r.w, .h = m.h }, s, theme.font_small, theme.secondary);
}

fn qbApply(f: *QbF) void {
    const e = f.edit;
    if (e.insert) {
        const add: usize = if (e.group) 2 else 1;
        if (f.count + add > f.capacity or f.count + add > f.nodes.len) return;
        const at: usize = @intCast(e.at);
        if (at > f.count) return;
        var k = f.count;
        while (k > at) : (k -= 1) f.nodes[k - 1 + add] = f.nodes[k - 1];
        var j: usize = 0;
        while (j < add) : (j += 1) f.nodes[at + j] = .{};
        f.nodes[at].depth = e.depth;
        f.nodes[at].group = e.group;
        if (e.group) f.nodes[at + 1].depth = e.depth + 1;
        const ri = if (e.group) at + 1 else at;
        if (f.fields.len > 0 and f.fields[0].type == .choice and f.fields[0].choices.len > 0) {
            f.nodes[ri].setValue(f.fields[0].choices[0]);
        }
        f.count += add;
    } else if (e.end > e.at and e.at > 0) {
        const at: usize = @intCast(e.at);
        const en: usize = @intCast(e.end);
        if (en > f.count) return;
        var k = en;
        while (k < f.count) : (k += 1) f.nodes[k - (en - at)] = f.nodes[k];
        var j = f.count - (en - at);
        while (j < f.count) : (j += 1) f.nodes[j] = .{};
        f.count -= en - at;
    }
    f.changed = true;
}

/// 条件构建器：分组可嵌套，规则 = 字段 + 运算符 + 值；返回 true 表示查询变了。
/// 节点数组由调用方持有（树序 + `depth`），`count` 为实际条数（`count.* == 0` 时自动建外层分组）。
pub fn queryBuilder(ui: *core.Context, id: []const u8, fields: []const QueryField, nodes: []QueryNode, count: *usize, opts: QueryOpts) bool {
    if (nodes.len == 0) return false;
    var f = QbF{
        .ui = ui,
        .key = idOf(id),
        .id = id,
        .fields = fields,
        .nodes = nodes,
        .count = @min(count.*, nodes.len),
        .capacity = nodes.len,
        .narrow = false,
        .read_only = opts.read_only,
        .max_depth = if (opts.max_depth > 0) opts.max_depth else 3,
    };
    if (f.read_only) f.max_depth = 0;
    if (f.count == 0) {
        nodes[0] = .{ .group = true };
        f.count = 1;
        f.changed = true;
    }
    nodes[0].depth = 0;
    nodes[0].group = true;
    if (ui.prevHitRect(f.key)) |r| f.narrow = r.w > 0 and r.w < 520;

    var col = ui.column(.{ .gap = 8 });
    defer col.end();
    _ = qbGroup(&f, 0);
    if (f.edit.at >= 0) qbApply(&f);
    count.* = f.count;
    return f.changed;
}

// =============================================================== 定时选择（cron）

/// cron 解析结果（5 个字段的位掩码）。
pub const Cron = struct {
    min: u64 = 0,
    hour: u32 = 0,
    dom: u32 = 0,
    mon: u16 = 0,
    dow: u8 = 0,
    dom_any: bool = false,
    dow_any: bool = false,
};

fn bit64(m: u64, i: usize) bool {
    return (m >> @intCast(i)) & 1 != 0;
}
fn bit32(m: u32, i: usize) bool {
    return (m >> @intCast(i)) & 1 != 0;
}
fn bit16(m: u16, i: usize) bool {
    return (m >> @intCast(i)) & 1 != 0;
}
fn bit8(m: u8, i: usize) bool {
    return (m >> @intCast(i)) & 1 != 0;
}

fn cronName(tok: []const u8, names: []const []const u8, base: i32) ?i32 {
    if (tok.len != 3 or names.len == 0) return null;
    var i: usize = 0;
    while (i < names.len) : (i += 1) {
        const nm = names[i];
        if (nm.len != 3) continue;
        if (std.ascii.toLower(tok[0]) == std.ascii.toLower(nm[0]) and
            std.ascii.toLower(tok[1]) == std.ascii.toLower(nm[1]) and
            std.ascii.toLower(tok[2]) == std.ascii.toLower(nm[2])) return base + @as(i32, @intCast(i));
    }
    return null;
}

fn cronNum(tok: []const u8, names: []const []const u8, base: i32, out: *i32) bool {
    if (tok.len == 0) return false;
    if (tok[0] >= '0' and tok[0] <= '9') {
        var x: i32 = 0;
        for (tok) |c| {
            if (c < '0' or c > '9' or x > 1000) return false;
            x = x * 10 + @as(i32, @intCast(c - '0'));
        }
        out.* = x;
        return true;
    }
    const v = cronName(tok, names, base) orelse return false;
    out.* = v;
    return true;
}

/// 一个字段：`*`、`a`、`a-b`、可带 `/step`，逗号分隔的列表；写 `lo..hi` 位。
fn cronField(tok: []const u8, lo: i32, hi: i32, names: []const []const u8, name_base: i32, mask: *u64, any: *bool) bool {
    mask.* = 0;
    any.* = false;
    var i: usize = 0;
    while (i <= tok.len) {
        var j = i;
        while (j < tok.len and tok[j] != ',') j += 1;
        const it = tok[i..j];
        const il = it.len;
        var slash: i32 = -1;
        var dash: i32 = -1;
        var k: usize = 0;
        while (k < il) : (k += 1) {
            if (it[k] == '/') {
                slash = @intCast(k);
            } else if (it[k] == '-' and dash < 0 and slash < 0) {
                dash = @intCast(k);
            }
        }
        const range_len: usize = if (slash >= 0) @intCast(slash) else il;
        var a: i32 = 0;
        var b: i32 = 0;
        var step: i32 = 1;
        if (slash >= 0) {
            const s0: usize = @intCast(slash + 1);
            if (s0 > il or !cronNum(it[s0..il], cron_no_names[0..], 0, &step)) return false;
        }
        if (step <= 0) return false;
        if (range_len == 1 and it[0] == '*') {
            a = lo;
            b = hi;
            if (slash < 0 and il == 1) any.* = true;
        } else if (dash >= 0) {
            const d0: usize = @intCast(dash);
            if (!cronNum(it[0..d0], names, name_base, &a)) return false;
            if (d0 + 1 > range_len or !cronNum(it[d0 + 1 .. range_len], names, name_base, &b)) return false;
        } else {
            if (!cronNum(it[0..range_len], names, name_base, &a)) return false;
            b = if (slash >= 0) hi else a;
        }
        const max_hi: i32 = if (hi == 6) 7 else hi; // 7 也是周日
        if (a < lo or b > max_hi or a > b) return false;
        var v = a;
        while (v <= b) : (v += step) {
            const idx: usize = @intCast(if (hi == 6 and v == 7) 0 else v);
            mask.* |= @as(u64, 1) << @intCast(idx);
        }
        if (j >= tok.len) break;
        i = j + 1;
    }
    return mask.* != 0;
}

const cron_mons = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const cron_days = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
const cron_no_names = [_][]const u8{};

fn cronParse(s: []const u8) ?Cron {
    if (s.len == 0) return null;
    var toks: [6][]const u8 = @splat("");
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        if (i >= s.len) break;
        const b = i;
        while (i < s.len and s[i] != ' ' and s[i] != '\t') i += 1;
        if (n < 6) toks[n] = s[b..i];
        n += 1;
    }
    if (n != 5) return null;
    var c = Cron{};
    var m: u64 = 0;
    var any = false;
    if (!cronField(toks[0], 0, 59, cron_no_names[0..], 0, &m, &any)) return null;
    c.min = m;
    if (!cronField(toks[1], 0, 23, cron_no_names[0..], 0, &m, &any)) return null;
    c.hour = @intCast(m);
    if (!cronField(toks[2], 1, 31, cron_no_names[0..], 0, &m, &any)) return null;
    c.dom = @intCast(m);
    c.dom_any = any;
    if (!cronField(toks[3], 1, 12, cron_mons[0..], 1, &m, &any)) return null;
    c.mon = @intCast(m);
    if (!cronField(toks[4], 0, 6, cron_days[0..], 0, &m, &any)) return null;
    c.dow = @intCast(m);
    c.dow_any = any;
    return c;
}

fn cronDay(c: Cron, day: i32, wd: i32) bool {
    const dm = bit32(c.dom, @intCast(day));
    const wm = bit8(c.dow, @intCast(wd));
    if (c.dom_any and c.dow_any) return true;
    if (c.dom_any) return wm;
    if (c.dow_any) return dm;
    return dm or wm;
}

/// `after`（Unix 秒）之后首次匹配的时刻，时区为 UTC 以东 `utc_offset_min` 分钟。
/// 表达式非法或五年内不运行返回 null。
pub fn cronNext(cron: []const u8, after: i64, utc_offset_min: i32) ?i64 {
    const c = cronParse(cron) orelse return null;
    const off: i64 = @as(i64, utc_offset_min) * 60;
    var ts: i64 = @divTrunc(after + off, 60) * 60 + 60;
    if (after + off < 0) ts = @divTrunc(after + off - 59, 60) * 60 + 60;
    const span: i64 = 5 * 366 * 86400;
    const limit = after + off + span;
    var guard: usize = 0;
    while (guard < 200000 and ts <= limit) : (guard += 1) {
        const days = if (ts >= 0) @divTrunc(ts, 86400) else @divTrunc(ts - 86399, 86400);
        const sec = ts - days * 86400;
        const dt = month.fromDays(days);
        if (dt.year > 9999) return null;
        if (!bit16(c.mon, dt.month)) {
            var y = dt.year;
            var mo: i32 = @as(i32, dt.month) + 1;
            if (mo > 12) {
                mo = 1;
                y += 1;
            }
            ts = month.daysFromCivil(.{ .year = y, .month = @intCast(mo), .day = 1 }) * 86400;
            continue;
        }
        const wd = @mod(@mod(days, 7) + 7 + 4, 7); // 1970-01-01 是周四，0 = 周日
        if (!cronDay(c, dt.day, @intCast(wd))) {
            ts = (days + 1) * 86400;
            continue;
        }
        const h = @divTrunc(sec, 3600);
        const mi = @mod(@divTrunc(sec, 60), 60);
        if (!bit32(c.hour, @intCast(h))) {
            ts = days * 86400 + (h + 1) * 3600;
            continue;
        }
        if (!bit64(c.min, @intCast(mi))) {
            ts += 60;
            continue;
        }
        const next = ts - off;
        return if (next - after <= span) next else null;
    }
    return null;
}

fn cronCount(m: u64, lo: i32, hi: i32, first: *i32) i32 {
    var n: i32 = 0;
    first.* = -1;
    var v = lo;
    while (v <= hi) : (v += 1) {
        if (bit64(m, @intCast(v))) {
            if (first.* < 0) first.* = v;
            n += 1;
        }
    }
    return n;
}

/// cron 周几（0 = 周日）→ 文案表的周一优先下标。
fn cronWeekday(d: i32) usize {
    return @intCast(@mod(d + 6, 7));
}

fn putStr(buf: []u8, n: *usize, s: []const u8) void {
    for (s) |c| {
        if (n.* < buf.len) {
            buf[n.*] = c;
            n.* += 1;
        }
    }
}

fn putInt(buf: []u8, n: *usize, v: i32) void {
    var tmp: [12]u8 = undefined;
    putStr(buf, n, num.int(tmp[0..], v));
}

fn put2(buf: []u8, n: *usize, v: i32) void {
    if (n.* + 2 > buf.len) return;
    buf[n.*] = '0' + @as(u8, @intCast(@mod(@divTrunc(v, 10), 10)));
    buf[n.* + 1] = '0' + @as(u8, @intCast(@mod(v, 10)));
    n.* += 2;
}

/// 用一句话说明表达式（"Every weekday at 09:30"），非法返回 null。结果在帧内池。
pub fn cronDescribe(ui: *core.Context, cron: []const u8) ?[]const u8 {
    const c = cronParse(cron) orelse return null;
    var m0: i32 = -1;
    var h0: i32 = -1;
    var d0: i32 = -1;
    var mn0: i32 = -1;
    var wf: i32 = -1;
    const nm = cronCount(c.min, 0, 59, &m0);
    const nh = cronCount(c.hour, 0, 23, &h0);
    const nd = cronCount(c.dom, 1, 31, &d0);
    const nmon = cronCount(c.mon, 1, 12, &mn0);
    const nw = cronCount(c.dow, 0, 6, &wf);
    const every_hour = nh == 24;
    const every_month = nmon == 12;
    var buf: [192]u8 = undefined;
    var n: usize = 0;

    if (every_hour and c.dom_any and c.dow_any and every_month) {
        if (nm == 60) {
            putStr(buf[0..], &n, "Every minute");
        } else if (nm == 1) {
            putStr(buf[0..], &n, "Every hour at :");
            put2(buf[0..], &n, m0);
        } else {
            var step: i32 = 0;
            var v = m0 + 1;
            while (v < 60) : (v += 1) {
                if (bit64(c.min, @intCast(v))) {
                    step = v - m0;
                    break;
                }
            }
            var even = step > 0 and m0 == 0;
            if (even) {
                v = 0;
                while (v < 60) : (v += 1) {
                    if (bit64(c.min, @intCast(v)) != (@mod(v, step) == 0)) even = false;
                }
            }
            if (even) {
                putStr(buf[0..], &n, "Every ");
                putInt(buf[0..], &n, step);
                putStr(buf[0..], &n, " minutes");
            } else {
                putInt(buf[0..], &n, nm);
                putStr(buf[0..], &n, " times an hour");
            }
        }
        return ui.frameStr(buf[0..n]);
    }
    if (nm != 1 or nh != 1 or !every_month) {
        if (nm == 1 and every_hour and every_month and !c.dom_any and c.dow_any) {
            putStr(buf[0..], &n, "Every hour at :");
            put2(buf[0..], &n, m0);
            putStr(buf[0..], &n, " on chosen days");
            return ui.frameStr(buf[0..n]);
        }
        putStr(buf[0..], &n, "Custom schedule");
        return ui.frameStr(buf[0..n]);
    }

    if (c.dom_any and c.dow_any) {
        putStr(buf[0..], &n, "Every day at ");
    } else if (c.dom_any) {
        if (c.dow == 0x3E) {
            putStr(buf[0..], &n, "Every weekday at ");
        } else if (c.dow == 0x41) {
            putStr(buf[0..], &n, "Every weekend at ");
        } else {
            putStr(buf[0..], &n, "Every ");
            var k: i32 = 0;
            var i: i32 = 0;
            while (i < 7) : (i += 1) {
                const d: i32 = @mod(i + 1, 7); // 周一优先
                if (!bit8(c.dow, @intCast(d))) continue;
                const idx = cronWeekday(d);
                const nmw = if (nw > 2) strings.weekdayShort(ui, idx) else strings.weekdayName(ui, idx);
                const sep = if (k == 0) "" else if (k == nw - 1) " and " else ", ";
                putStr(buf[0..], &n, sep);
                putStr(buf[0..], &n, nmw);
                k += 1;
            }
            putStr(buf[0..], &n, " at ");
        }
    } else if (c.dow_any and nd == 1) {
        putStr(buf[0..], &n, "On day ");
        putInt(buf[0..], &n, d0);
        putStr(buf[0..], &n, " of every month at ");
    } else {
        putStr(buf[0..], &n, "Custom schedule");
        return ui.frameStr(buf[0..n]);
    }
    put2(buf[0..], &n, h0);
    putStr(buf[0..], &n, ":");
    put2(buf[0..], &n, m0);
    return ui.frameStr(buf[0..n]);
}

pub const ScheduleOpts = struct {
    /// 起始时刻（Unix 秒）；0 = 不知道，不列后续运行。
    now: i64 = 0,
    /// UTC 以东多少分钟（默认 0 = UTC）。CUI 用平台时区；这里由调用方给，便于测试。
    utc_offset_min: i32 = 0,
    /// 列几条后续运行（默认 3，0 = 不列）。
    next_count: u8 = 3,
};

pub const ScheduleResult = struct {
    changed: bool = false,
    valid: bool = false,
    /// 下次运行时刻（Unix 秒），0 = 无。
    next: i64 = 0,
};

pub const ScheduleState = struct {
    init: bool = false,
    /// 0..5 = Minutes / Hourly / Daily / Weekly / Monthly / Custom。
    mode: u8 = 0,
    seen: u32 = 0,
    every: i32 = 15,
    minute: i32 = 0,
    hour: i32 = 9,
    day: i32 = 1,
    days: [7]bool = .{ true, true, true, true, true, false, false },
    cron_len: usize = 0,
    cron_caret: usize = 0,
};

fn zlen(buf: []const u8) usize {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0) i += 1;
    return i;
}

fn scRead(st: *ScheduleState, cron: []const u8) void {
    st.every = 15;
    st.minute = 0;
    st.hour = 9;
    st.day = 1;
    st.days = .{ true, true, true, true, true, false, false };
    st.mode = 5;
    const c = cronParse(cron) orelse return;
    var m0: i32 = -1;
    var h0: i32 = -1;
    var d0: i32 = -1;
    var mn0: i32 = -1;
    const nm = cronCount(c.min, 0, 59, &m0);
    const nh = cronCount(c.hour, 0, 23, &h0);
    const nd = cronCount(c.dom, 1, 31, &d0);
    const nmon = cronCount(c.mon, 1, 12, &mn0);
    if (nmon != 12) return;
    if (nh == 24 and c.dom_any and c.dow_any) {
        if (nm == 1) {
            st.mode = 1;
            st.minute = m0;
            return;
        }
        var step: i32 = 0;
        var v: i32 = 1;
        while (v < 60) : (v += 1) {
            if (bit64(c.min, @intCast(v))) {
                step = v;
                break;
            }
        }
        var even = m0 == 0 and step > 0;
        if (even) {
            v = 0;
            while (v < 60) : (v += 1) {
                if (bit64(c.min, @intCast(v)) != (@mod(v, step) == 0)) even = false;
            }
        }
        if (even or nm == 60) {
            st.mode = 0;
            st.every = if (nm == 60) 1 else step;
        }
        return;
    }
    if (nm != 1 or nh != 1) return;
    st.minute = m0;
    st.hour = h0;
    if (c.dom_any and c.dow_any) {
        st.mode = 2;
        return;
    }
    if (c.dom_any) {
        st.mode = 3;
        var i: usize = 0;
        while (i < 7) : (i += 1) st.days[i] = bit8(c.dow, @intCast(@mod(@as(i32, @intCast(i)) + 1, 7)));
        return;
    }
    if (c.dow_any and nd == 1) {
        st.mode = 4;
        st.day = d0;
    }
}

fn scWrite(st: *const ScheduleState, cron: []u8) []const u8 {
    var n: usize = 0;
    switch (st.mode) {
        0 => {
            if (st.every <= 1) {
                putStr(cron, &n, "* * * * *");
            } else {
                putStr(cron, &n, "*/");
                putInt(cron, &n, st.every);
                putStr(cron, &n, " * * * *");
            }
        },
        1 => {
            putInt(cron, &n, st.minute);
            putStr(cron, &n, " * * * *");
        },
        2 => {
            putInt(cron, &n, st.minute);
            putStr(cron, &n, " ");
            putInt(cron, &n, st.hour);
            putStr(cron, &n, " * * *");
        },
        3 => {
            putInt(cron, &n, st.minute);
            putStr(cron, &n, " ");
            putInt(cron, &n, st.hour);
            putStr(cron, &n, " * * ");
            var any = false;
            var i: usize = 0;
            while (i < 7) : (i += 1) {
                if (!st.days[i]) continue;
                if (any) putStr(cron, &n, ",");
                putInt(cron, &n, @intCast(@mod(@as(i32, @intCast(i)) + 1, 7)));
                any = true;
            }
            if (!any) putStr(cron, &n, "1");
        },
        4 => {
            putInt(cron, &n, st.minute);
            putStr(cron, &n, " ");
            putInt(cron, &n, st.hour);
            putStr(cron, &n, " ");
            putInt(cron, &n, st.day);
            putStr(cron, &n, " * *");
        },
        else => {},
    }
    if (n < cron.len) cron[n] = 0;
    return cron[0..n];
}

fn scLabel(ui: *core.Context, s: []const u8) void {
    const m = ui.measureText(s, theme.font_small);
    const r = ui.reserve(m.w + 2, 34, false);
    ui.addText(.{ .x = r.x, .y = r.y + (r.h - m.h) / 2, .w = r.w, .h = m.h }, s, theme.font_small, theme.secondary);
}

fn scNumber(ui: *core.Context, id: []const u8, value: *i32, lo: i32, hi: i32, width: f32, suffix: []const u8) bool {
    var v: f32 = @floatFromInt(value.*);
    const changed = textedit.number(ui, id, &v, .{
        .width = width,
        .min = @floatFromInt(lo),
        .max = @floatFromInt(hi),
        .step = 1,
        .suffix = suffix,
    });
    if (changed) {
        const iv: i32 = @intFromFloat(v + 0.5);
        value.* = @min(@max(iv, lo), hi);
    }
    return changed;
}

fn scWhen(ui: *core.Context, stamp: i64, offset_min: i32) []const u8 {
    const lt = stamp + @as(i64, offset_min) * 60;
    const days = if (lt >= 0) @divTrunc(lt, 86400) else @divTrunc(lt - 86399, 86400);
    const sec = lt - days * 86400;
    const dt = month.fromDays(days);
    const wd = @mod(@mod(days, 7) + 7 + 4, 7);
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    putStr(buf[0..], &n, strings.weekdayShort(ui, cronWeekday(@intCast(wd))));
    putStr(buf[0..], &n, ", ");
    putStr(buf[0..], &n, strings.monthShort(ui, dt.month - 1));
    putStr(buf[0..], &n, " ");
    putInt(buf[0..], &n, dt.day);
    putStr(buf[0..], &n, "  ");
    put2(buf[0..], &n, @intCast(@divTrunc(sec, 3600)));
    putStr(buf[0..], &n, ":");
    put2(buf[0..], &n, @intCast(@mod(@divTrunc(sec, 60), 60)));
    return ui.frameStr(buf[0..n]);
}

/// cron 定时选择器：Minutes / Hourly / Daily / Weekly / Monthly / Custom 六种写法，
/// 下方给出含义与后续运行时刻。`cron` 由调用方持有（NUL 结尾，容量至少 12）。
pub fn schedulePicker(ui: *core.Context, id: []const u8, cron: []u8, st: *ScheduleState, opts: ScheduleOpts) ScheduleResult {
    var res = ScheduleResult{};
    if (cron.len < 12) return res;
    if (!st.init or st.cron_len > cron.len - 1) {
        st.cron_len = zlen(cron);
        st.cron_caret = st.cron_len;
    }
    const seen_now = hash32(cron[0..zlen(cron)]);
    if (!st.init or seen_now != st.seen) {
        st.cron_len = zlen(cron);
        st.cron_caret = st.cron_len;
        scRead(st, cron[0..st.cron_len]);
        st.init = true;
    }

    var col = ui.column(.{ .gap = 12 });
    defer col.end();

    const modes = [_][]const u8{ "Minutes", "Hourly", "Daily", "Weekly", "Monthly", "Custom" };
    var mb: [40]u8 = undefined;
    const mid = ui.frameStr(std.fmt.bufPrint(mb[0..], "{s}#mode", .{id}) catch "sc-mode");
    var mode: usize = st.mode;
    controls.segmented(ui, mid, modes[0..], &mode);
    var edited = false;
    if (mode != st.mode) {
        st.mode = @intCast(mode);
        edited = st.mode != 5;
    }

    {
        var row = ui.row(.{ .gap = 10 });
        defer row.end();
        var ib: [40]u8 = undefined;
        switch (st.mode) {
            0 => {
                scLabel(ui, "Every");
                const eid = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}#every", .{id}) catch "sc-every");
                if (scNumber(ui, eid, &st.every, 1, 59, 132, "minutes")) edited = true;
            },
            1 => {
                scLabel(ui, "Every hour at minute");
                const mid2 = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}#minute", .{id}) catch "sc-minute");
                if (scNumber(ui, mid2, &st.minute, 0, 59, 104, "")) edited = true;
            },
            2, 3, 4 => {
                if (st.mode == 3) {
                    const labels = [_][]const u8{
                        strings.weekdayMin(ui, 0), strings.weekdayMin(ui, 1), strings.weekdayMin(ui, 2),
                        strings.weekdayMin(ui, 3), strings.weekdayMin(ui, 4), strings.weekdayMin(ui, 5),
                        strings.weekdayMin(ui, 6),
                    };
                    var i: usize = 0;
                    var toggled = false;
                    const before = st.days;
                    while (i < 7) : (i += 1) {
                        if (controls.chip(ui, labels[i], &st.days[i])) toggled = true;
                    }
                    if (toggled) {
                        var any = false;
                        for (st.days) |d| {
                            if (d) any = true;
                        }
                        if (!any) st.days = before; // 至少留一天
                        edited = true;
                    }
                } else if (st.mode == 4) {
                    scLabel(ui, "On day");
                    const did = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}#day", .{id}) catch "sc-day");
                    if (scNumber(ui, did, &st.day, 1, 31, 104, "")) edited = true;
                }
                if (st.mode == 2) scLabel(ui, "Every day at") else if (st.mode == 4) scLabel(ui, "at");
                const hid = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}#hour", .{id}) catch "sc-hour");
                if (scNumber(ui, hid, &st.hour, 0, 23, 112, "h")) edited = true;
                const nid = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}#min2", .{id}) catch "sc-min2");
                if (scNumber(ui, nid, &st.minute, 0, 59, 112, "m")) edited = true;
            },
            else => {
                const cid = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}#cron", .{id}) catch "sc-cron");
                const width = @max(160, remaining(ui));
                if (widgets.input(ui, cid, cron[0 .. cron.len - 1], &st.cron_len, &st.cron_caret, .{
                    .placeholder = "minute hour day month weekday",
                    .width = width,
                })) {
                    res.changed = true;
                    edited = false;
                }
                cron[st.cron_len] = 0;
            },
        }
    }

    if (edited) {
        const written = scWrite(st, cron);
        st.cron_len = written.len;
        st.cron_caret = written.len;
        res.changed = true;
    }
    st.seen = hash32(cron[0..zlen(cron)]);

    const desc = cronDescribe(ui, cron[0..zlen(cron)]);
    res.valid = desc != null;
    var next: i64 = 0;
    if (res.valid and opts.now > 0) {
        next = cronNext(cron[0..zlen(cron)], opts.now, opts.utc_offset_min) orelse 0;
        res.next = next;
    }

    // 含义行
    {
        var row = ui.row(.{ .gap = 8 });
        defer row.end();
        const dot = ui.reserve(10, 20, false);
        ui.addBox(.{ .x = dot.x, .y = dot.y + 6, .w = 8, .h = 8 }, .{
            .fill = if (res.valid) trace.toneColor(.success) else theme.danger,
            .radius = 4,
        });
        const txt = if (desc) |d| d else "Not a valid schedule";
        const m = ui.measureText(txt, theme.font_body);
        const tr = ui.reserve(@max(60, remaining(ui)), 22, true);
        ui.addText(.{ .x = tr.x, .y = tr.y + 2, .w = tr.w, .h = m.h }, txt, theme.font_body, if (res.valid) theme.text else theme.danger);
    }
    if (st.mode != 5) {
        var mb2: [48]u8 = undefined;
        const exp = ui.frameStr(std.fmt.bufPrint(mb2[0..], "{s}", .{cron[0..zlen(cron)]}) catch "");
        const m = ui.measureText(exp, theme.font_small);
        const r = ui.reserve(0, m.h + 2, true);
        ui.addMonoText(.{ .x = r.x, .y = r.y, .w = r.w, .h = m.h }, exp, theme.font_small, theme.secondary);
    }
    const count: usize = @min(opts.next_count, 10);
    if (next > 0 and count > 0) {
        var cur = next;
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const s = scWhen(ui, cur, opts.utc_offset_min);
            const m = ui.measureText(s, theme.font_small);
            const r = ui.reserve(0, m.h + 2, true);
            ui.addText(.{ .x = r.x + 14, .y = r.y, .w = r.w, .h = m.h }, s, theme.font_small, theme.secondary);
            const nx = cronNext(cron[0..zlen(cron)], cur, opts.utc_offset_min) orelse break;
            cur = nx;
        }
    }
    return res;
}

// =============================================================== 测试树

pub const TestItem = struct {
    name: []const u8 = "",
    /// 0 = 顶层套件。
    depth: i32 = 0,
    /// 套件自己的状态在有测试时被忽略（由测试汇总）。
    status: JobStatus = .pending,
    /// 秒；负数 = 还没跑。
    duration: f32 = -1,
    /// 失败原因（可空）。
    message: []const u8 = "",
};

pub const TestExplorerOpts = struct {
    height: f32 = 320,
};

pub const TestExplorerResult = struct {
    selected: i32 = -1,
    /// 本帧被激活（回车）的项，-1 = 无。
    activated: i32 = -1,
    /// 本帧点了运行按钮的项，-1 = 无。
    run: i32 = -1,
    run_all: bool = false,
    passed: i32 = 0,
    failed: i32 = 0,
    skipped: i32 = 0,
    total: i32 = 0,
};

pub const TestExplorerState = struct {
    show: [3]bool = .{ true, true, true },
    query: [96]u8 = @splat(0),
    query_len: usize = 0,
    query_caret: usize = 0,
    sel: i32 = -1,
    folded: [16]u32 = @splat(0),
    nfolded: usize = 0,
};

const TX_ROW: f32 = 26;
const MAX_TX = 256;

const TxSum = struct {
    pass: i32 = 0,
    fail: i32 = 0,
    skip: i32 = 0,
    run: i32 = 0,
    pend: i32 = 0,
    shown: i32 = 0,
    time: f32 = 0,
    suite: bool = false,
};

const TxScan = struct {
    nrows: usize = 0,
    passed: i32 = 0,
    failed: i32 = 0,
    skipped: i32 = 0,
    total: i32 = 0,
};

fn txKey(items: []const TestItem, i: usize) u32 {
    var h: u32 = 2166136261;
    for (items[i].name) |c| {
        h ^= c;
        h *%= 16777619;
    }
    h ^= @as(u32, @truncate(i *% 2654435761));
    return h;
}

fn txFolded(st: *const TestExplorerState, h: u32) bool {
    for (st.folded[0..st.nfolded]) |f| {
        if (f == h) return true;
    }
    return false;
}

fn txToggleFold(st: *TestExplorerState, h: u32) void {
    var i: usize = 0;
    while (i < st.nfolded) : (i += 1) {
        if (st.folded[i] == h) {
            st.folded[i] = st.folded[st.nfolded - 1];
            st.nfolded -= 1;
            return;
        }
    }
    if (st.nfolded < st.folded.len) {
        st.folded[st.nfolded] = h;
        st.nfolded += 1;
    }
}

fn txPasses(st: *const TestExplorerState, it: TestItem) bool {
    const bucket: i32 = switch (it.status) {
        .passed => 0,
        .failed => 1,
        .skipped, .canceled => 2,
        else => -1,
    };
    if (bucket >= 0 and !st.show[@intCast(bucket)]) return false;
    return containsCi(it.name, st.query[0..st.query_len]);
}

fn txStatus(sum: TxSum, it: TestItem) JobStatus {
    if (!sum.suite) return it.status;
    if (sum.fail > 0) return .failed;
    if (sum.run > 0) return .running;
    if (sum.pend > 0) return .pending;
    if (sum.pass > 0) return .passed;
    return if (sum.skip > 0) .skipped else .pending;
}

fn txScan(st: *TestExplorerState, items: []const TestItem, sums: []TxSum, rows: []i32) TxScan {
    var out = TxScan{};
    const n = items.len;
    var stack: [64]i32 = @splat(0);
    var sp: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const d = @min(@max(items[i].depth, 0), 63);
        while (sp > 0 and @min(@max(items[@intCast(stack[sp - 1])].depth, 0), 63) >= d) sp -= 1;
        const suite = i + 1 < n and items[i + 1].depth > items[i].depth;
        sums[i] = .{ .suite = suite };
        if (!suite) {
            const sh = txPasses(st, items[i]);
            const secs: f32 = if (items[i].duration > 0) items[i].duration else 0;
            switch (items[i].status) {
                .passed => out.passed += 1,
                .failed => out.failed += 1,
                .skipped, .canceled => out.skipped += 1,
                else => {},
            }
            out.total += 1;
            var k: usize = 0;
            while (k < sp) : (k += 1) {
                const m = &sums[@intCast(stack[k])];
                switch (items[i].status) {
                    .passed => m.pass += 1,
                    .failed => m.fail += 1,
                    .skipped, .canceled => m.skip += 1,
                    .running => m.run += 1,
                    else => m.pend += 1,
                }
                m.time += secs;
                if (sh) m.shown += 1;
            }
            if (sh) sums[i].shown = 1;
        }
        if (suite and sp < stack.len) {
            stack[sp] = @intCast(i);
            sp += 1;
        }
    }

    // 行表：套件在属下有测试通过过滤时才显示；折叠的套件藏起整棵子树
    var hide_below: i32 = -1;
    i = 0;
    while (i < n) : (i += 1) {
        const d = items[i].depth;
        if (hide_below >= 0) {
            if (d > hide_below) continue;
            hide_below = -1;
        }
        if (sums[i].shown == 0) continue;
        if (out.nrows >= rows.len) break;
        rows[out.nrows] = @intCast(i);
        out.nrows += 1;
        if (sums[i].suite and txFolded(st, txKey(items, i))) {
            hide_below = d;
        } else if (!sums[i].suite and items[i].status == .failed and items[i].message.len > 0) {
            if (out.nrows < rows.len) {
                rows[out.nrows] = -@as(i32, @intCast(i)) - 1;
                out.nrows += 1;
            }
        }
    }
    return out;
}

fn txRowOf(rows: []const i32, sel: i32) i32 {
    for (rows, 0..) |v, r| {
        if (v == sel) return @intCast(r);
    }
    return -1;
}

fn txDuration(buf: []u8, secs: f32) []const u8 {
    if (!(secs >= 0)) return "";
    var tmp: [16]u8 = undefined;
    if (secs < 1) {
        const s = num.fixed(tmp[0..], secs * 1000, 0);
        return std.fmt.bufPrint(buf, "{s} ms", .{s}) catch "";
    }
    const s = num.fixed(tmp[0..], secs, 2);
    return std.fmt.bufPrint(buf, "{s} s", .{s}) catch "";
}

fn txChip(ui: *core.Context, key: u64, glyph: []const u8, count: i32, on: bool, tone: Tone) bool {
    const gm = ui.measureText(glyph, theme.font_small);
    var cb: [8]u8 = undefined;
    const cs = num.int(cb[0..], count);
    const cm = ui.measureText(cs, theme.font_small);
    const w = gm.w + cm.w + 22;
    const r = ui.reserve(w, 24, false);
    const hit = ui.interactEx(key, r, true);
    const c = trace.toneColor(tone);
    ui.addBox(r, .{
        .fill = if (on) theme.withAlpha(c, 34) else theme.track,
        .radius = 12,
        .border = if (on) theme.withAlpha(c, 140) else theme.border,
    });
    ui.addText(.{ .x = r.x + 8, .y = r.y + 3, .w = gm.w + 1, .h = 18 }, glyph, theme.font_small, if (on) c else theme.secondary);
    ui.addText(.{ .x = r.x + 12 + gm.w, .y = r.y + 3, .w = cm.w + 1, .h = 18 }, cs, theme.font_small, if (on) theme.text else theme.secondary);
    return hit.clicked;
}

/// 测试结果树：套件折叠、每个测试带状态与耗时、失败消息挂在下面，
/// 顶部可跑全部、按状态过滤、按名字搜索。上下键移动、左右折叠、回车激活。
pub fn testExplorer(ui: *core.Context, id: []const u8, items: []const TestItem, st: *TestExplorerState, opts: TestExplorerOpts) TestExplorerResult {
    var res = TestExplorerResult{};
    const key = idOf(id);
    const n = @min(items.len, MAX_TX);
    const list = items[0..n];
    if (st.sel >= @as(i32, @intCast(n))) st.sel = -1;

    // 行表要两次：第一次给工具栏计数，改完过滤再算一次
    var sums: [MAX_TX]TxSum = @splat(.{});
    var rows: [MAX_TX * 2]i32 = @splat(0);
    var scan = txScan(st, list, sums[0..n], rows[0..]);

    {
        var bar = ui.row(.{ .gap = 8 });
        defer bar.end();
        if (widgets.button(ui, "Run all", .{ .variant = .primary, .id_salt = kk(key, 0xA100, 0) })) res.run_all = true;
        if (txChip(ui, kk(key, 0xA200, 0), "v", scan.passed, st.show[0], .success)) st.show[0] = !st.show[0];
        if (txChip(ui, kk(key, 0xA200, 1), "x", scan.failed, st.show[1], .danger)) st.show[1] = !st.show[1];
        if (txChip(ui, kk(key, 0xA200, 2), "-", scan.skipped, st.show[2], .neutral)) st.show[2] = !st.show[2];
        var fb: [40]u8 = undefined;
        const fid = ui.frameStr(std.fmt.bufPrint(fb[0..], "{s}#q", .{id}) catch "tx-q");
        _ = widgets.input(ui, fid, st.query[0..], &st.query_len, &st.query_caret, .{
            .placeholder = "Filter tests",
            .width = @max(120, remaining(ui) - 8),
        });
    }
    scan = txScan(st, list, sums[0..n], rows[0..]);
    res.passed = scan.passed;
    res.failed = scan.failed;
    res.skipped = scan.skipped;
    res.total = scan.total;

    var rb: [40]u8 = undefined;
    const rid = ui.frameStr(std.fmt.bufPrint(rb[0..], "{s}#rows", .{id}) catch "tx-rows");
    var area = ui.scroll(.{ .id = rid, .height = opts.height });
    defer area.end();
    res.selected = st.sel;

    const list_id = kk(key, 0x7E50, 0);
    const lit = ui.interactEx(list_id, area.rect, true);

    // 键盘
    if (lit.focused and scan.nrows > 0) {
        var at = txRowOf(rows[0..scan.nrows], st.sel);
        const nr: i32 = @intCast(scan.nrows);
        if (ui.input.keyPressed(.down)) {
            var r = at + 1;
            while (r < nr and rows[@intCast(r)] < 0) r += 1;
            if (r >= nr) r = at;
            if (at < 0) r = 0;
            at = r;
            st.sel = rows[@intCast(at)];
        } else if (ui.input.keyPressed(.up)) {
            var r = at - 1;
            while (r > 0 and rows[@intCast(r)] < 0) r -= 1;
            if (r < 0) r = 0;
            at = r;
            st.sel = rows[@intCast(at)];
        } else if (ui.input.keyPressed(.home)) {
            st.sel = rows[0];
        } else if (ui.input.keyPressed(.end)) {
            var r = nr - 1;
            while (r > 0 and rows[@intCast(r)] < 0) r -= 1;
            st.sel = rows[@intCast(r)];
        } else if (ui.input.keyPressed(.left) and st.sel >= 0) {
            const i: usize = @intCast(st.sel);
            const h = txKey(list, i);
            if (sums[i].suite and !txFolded(st, h)) {
                txToggleFold(st, h);
            } else if (list[i].depth > 0) {
                var k: i32 = @as(i32, @intCast(i)) - 1;
                while (k >= 0) : (k -= 1) {
                    if (list[@intCast(k)].depth < list[i].depth) {
                        st.sel = k;
                        break;
                    }
                }
            }
        } else if (ui.input.keyPressed(.right) and st.sel >= 0) {
            const i: usize = @intCast(st.sel);
            if (sums[i].suite) txToggleFold(st, txKey(list, i));
        } else if (ui.input.keyPressed(.enter) and st.sel >= 0) {
            res.activated = st.sel;
        }
        // 选择改变时滚到可见区
        if (st.sel >= 0) {
            const r = txRowOf(rows[0..scan.nrows], st.sel);
            if (r >= 0) {
                const y = @as(f32, @floatFromInt(r)) * TX_ROW;
                const off = ui.scrollOffset(rid);
                if (y < off) {
                    ui.scrollTo(rid, y);
                } else if (y + TX_ROW > off + area.rect.h) {
                    ui.scrollTo(rid, y + TX_ROW - area.rect.h);
                }
            }
        }
    }

    if (scan.nrows == 0) {
        zzuiMuted(ui, if (n == 0) "No tests" else "No tests match the filters");
        return res;
    }

    // 只画视口内的行（一屏 320 / 26 ≈ 12 行）
    const off = ui.scrollOffset(rid);
    const first: usize = if (off > 0) @min(scan.nrows, @as(usize, @intFromFloat(off / TX_ROW))) else 0;
    const visible: usize = @as(usize, @intFromFloat(area.rect.h / TX_ROW)) + 2;
    const last = @min(scan.nrows, first + visible);
    if (first > 0) _ = ui.reserve(0, @as(f32, @floatFromInt(first)) * TX_ROW, false);

    var narrow = false;
    if (area.rect.w > 0 and area.rect.w < 560) narrow = true;

    var r = first;
    while (r < last) : (r += 1) {
        const v = rows[r];
        if (v < 0) {
            // 失败消息行
            const it = list[@intCast(-v - 1)];
            const row = ui.reserve(0, TX_ROW, true);
            const indent = 8 + @as(f32, @floatFromInt(@min(@max(it.depth, 0), 12))) * (if (narrow) @as(f32, 12) else 16) + 40;
            const mw = @max(20, row.w - indent);
            ui.addMonoText(.{ .x = row.x + indent, .y = row.y + 4, .w = mw, .h = 18 }, clipText(ui, it.message, theme.font_small, mw), theme.font_small, theme.danger);
            continue;
        }
        const i: usize = @intCast(v);
        const it = list[i];
        const suite = sums[i].suite;
        const row = ui.reserve(0, TX_ROW, true);
        const hit = ui.interactEx(kk(key, 0x9200, i), row, false);
        const sel = st.sel == @as(i32, @intCast(i));
        if (sel) {
            ui.addBox(row, .{ .fill = theme.accent_bg, .radius = 4 });
        } else if (hit.hover) {
            ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
        }
        const indent = 8 + @as(f32, @floatFromInt(@min(@max(it.depth, 0), 12))) * (if (narrow) @as(f32, 12) else 16);
        var x = row.x + indent;
        const h = txKey(list, i);
        const folded = suite and txFolded(st, h);
        if (suite) {
            const cr = t.Rect{ .x = x, .y = row.y + 6, .w = 14, .h = 14 };
            const ch = ui.interactEx(kk(key, 0x9400, i), cr, false);
            ui.addText(.{ .x = cr.x, .y = cr.y, .w = 12, .h = 16 }, if (folded) ">" else "v", theme.font_small, if (ch.hover) theme.text else theme.secondary);
            if (ch.clicked) txToggleFold(st, h);
            x += 16;
        } else {
            x += 16;
        }
        const stt = txStatus(sums[i], it);
        const tone_c = trace.toneColor(jobTone(stt));
        ui.addText(.{ .x = x, .y = row.y + 4, .w = 12, .h = 18 }, jobGlyph(stt), theme.font_small, tone_c);
        x += 16;

        // 右侧：耗时与运行按钮
        var tb: [20]u8 = undefined;
        const dur_txt = if (suite) txDuration(tb[0..], sums[i].time) else txDuration(tb[0..], it.duration);
        const durw = if (dur_txt.len > 0) ui.measureText(dur_txt, theme.font_small).w + 8 else 0;
        const show_run = hit.hover or sel;
        const run_w: f32 = if (show_run) 28 else 0;
        // 套件的通过数
        var cnt_txt: []const u8 = "";
        var cb: [16]u8 = undefined;
        if (suite) {
            const all = sums[i].pass + sums[i].fail + sums[i].skip + sums[i].run + sums[i].pend;
            cnt_txt = std.fmt.bufPrint(cb[0..], "{d}/{d}", .{ sums[i].pass, all }) catch "";
        }
        const cntw = if (cnt_txt.len > 0) ui.measureText(cnt_txt, theme.font_small).w + 8 else 0;
        const name_w = @max(30, row.x + row.w - x - durw - cntw - run_w - 8);
        ui.addText(.{ .x = x, .y = row.y + 4, .w = name_w, .h = 18 }, clipText(ui, it.name, theme.font_small, name_w), theme.font_small, if (suite) theme.text else theme.secondary);
        var nx = x + name_w + 4;
        if (cnt_txt.len > 0) {
            ui.addText(.{ .x = nx, .y = row.y + 5, .w = cntw, .h = 18 }, ui.frameStr(cnt_txt), theme.font_small, theme.secondary);
            nx += cntw;
        }
        if (dur_txt.len > 0) {
            ui.addText(.{ .x = row.x + row.w - durw - run_w, .y = row.y + 5, .w = durw, .h = 18 }, ui.frameStr(dur_txt), theme.font_small, if ((if (suite) sums[i].time else it.duration) >= 1) theme.warn else theme.secondary);
        }
        if (show_run) {
            const br = t.Rect{ .x = row.x + row.w - 26, .y = row.y + 1, .w = 24, .h = 24 };
            if (iconButton(ui, kk(key, 0x9300, i), br, ">", theme.accent)) res.run = @intCast(i);
        }
        if (hit.clicked) {
            st.sel = @intCast(i);
            ui.focus_id = list_id;
        }
    }
    res.selected = st.sel;
    return res;
}

// =============================================================== 键位图

const M_CTRL: u8 = 1;
const M_SHIFT: u8 = 2;
const M_ALT: u8 = 4;
const M_WIN: u8 = 8;

const KmDef = struct {
    l: []const u8 = "",
    k: t.Key = .unknown,
    m: u8 = 0,
    w: f32 = 1,
};

const km_r0 = [_]KmDef{
    .{ .l = "Esc", .k = .escape }, .{ .w = 0.5 },
    .{ .l = "F1", .k = .f1 },      .{ .l = "F2", .k = .f2 },
    .{ .l = "F3", .k = .f3 },      .{ .l = "F4", .k = .f4 },
    .{ .w = 0.5 },                 .{ .l = "F5", .k = .f5 },
    .{ .l = "F6", .k = .f6 },      .{ .l = "F7", .k = .f7 },
    .{ .l = "F8", .k = .f8 },      .{ .w = 0.5 },
    .{ .l = "F9", .k = .f9 },      .{ .l = "F10", .k = .f10 },
    .{ .l = "F11", .k = .f11 },    .{ .l = "F12", .k = .f12 },
};

const km_r1 = [_]KmDef{
    .{ .l = "`", .k = .tilde },  .{ .l = "1", .k = .digit1 }, .{ .l = "2", .k = .digit2 }, .{ .l = "3", .k = .digit3 },               .{ .l = "4", .k = .digit4 },
    .{ .l = "5", .k = .digit5 }, .{ .l = "6", .k = .digit6 }, .{ .l = "7", .k = .digit7 }, .{ .l = "8", .k = .digit8 },               .{ .l = "9", .k = .digit9 },
    .{ .l = "0", .k = .digit0 }, .{ .l = "-", .k = .minus },  .{ .l = "=", .k = .equal },  .{ .l = "Bksp", .k = .backspace, .w = 2 },
};

const km_r2 = [_]KmDef{
    .{ .l = "Tab", .k = .tab, .w = 1.5 }, .{ .l = "Q", .k = .Q },            .{ .l = "W", .k = .W },             .{ .l = "E", .k = .E },                    .{ .l = "R", .k = .R },
    .{ .l = "T", .k = .T },               .{ .l = "Y", .k = .Y },            .{ .l = "U", .k = .U },             .{ .l = "I", .k = .I },                    .{ .l = "O", .k = .O },
    .{ .l = "P", .k = .P },               .{ .l = "[", .k = .bracket_left }, .{ .l = "]", .k = .bracket_right }, .{ .l = "\\", .k = .backslash, .w = 1.5 },
};

const km_r3 = [_]KmDef{
    .{ .l = "Caps", .w = 1.75 },    .{ .l = "A", .k = .A },     .{ .l = "S", .k = .S },                    .{ .l = "D", .k = .D }, .{ .l = "F", .k = .F },
    .{ .l = "G", .k = .G },         .{ .l = "H", .k = .H },     .{ .l = "J", .k = .J },                    .{ .l = "K", .k = .K }, .{ .l = "L", .k = .L },
    .{ .l = ";", .k = .semicolon }, .{ .l = "'", .k = .quote }, .{ .l = "Enter", .k = .enter, .w = 2.25 },
};

const km_r4 = [_]KmDef{
    .{ .l = "Shift", .m = M_SHIFT, .w = 2.25 }, .{ .l = "Z", .k = .Z },                     .{ .l = "X", .k = .X }, .{ .l = "C", .k = .C },     .{ .l = "V", .k = .V },
    .{ .l = "B", .k = .B },                     .{ .l = "N", .k = .N },                     .{ .l = "M", .k = .M }, .{ .l = ",", .k = .comma }, .{ .l = ".", .k = .period },
    .{ .l = "/", .k = .slash },                 .{ .l = "Shift", .m = M_SHIFT, .w = 2.75 },
};

const km_r5 = [_]KmDef{
    .{ .l = "Ctrl", .m = M_CTRL, .w = 1.25 },  .{ .l = "Win", .m = M_WIN, .w = 1.25 },   .{ .l = "Alt", .m = M_ALT, .w = 1.25 },
    .{ .l = "Space", .k = .space, .w = 6.25 }, .{ .l = "Alt", .m = M_ALT, .w = 1.25 },   .{ .l = "Win", .m = M_WIN, .w = 1.25 },
    .{ .l = "Menu", .w = 1.25 },               .{ .l = "Ctrl", .m = M_CTRL, .w = 1.25 },
};

const KmKey = struct {
    l: []const u8 = "",
    k: t.Key = .unknown,
    m: u8 = 0,
    x: f32 = 0,
    w: f32 = 1,
    row: u8 = 0,
    nav: bool = false,
};

const KM_MAIN_W: f32 = 15.0;
const KM_NAV_W: f32 = 3.5;
const KM_NO_NAV: f32 = 600.0;
const KM_MAX_U: f32 = 46.0;

fn kmLayout(out: []KmKey) usize {
    const rows = [_][]const KmDef{ km_r0[0..], km_r1[0..], km_r2[0..], km_r3[0..], km_r4[0..], km_r5[0..] };
    var n: usize = 0;
    for (rows, 0..) |defs, r| {
        var x: f32 = 0;
        for (defs) |d| {
            if (d.l.len > 0 and n < out.len) {
                out[n] = .{ .l = d.l, .k = d.k, .m = d.m, .x = x, .w = d.w, .row = @intCast(r) };
                n += 1;
            }
            x += d.w;
        }
    }
    const nav_lbl = [_][]const u8{ "Home", "PgUp", "Del", "End", "PgDn", "\xe2\x86\x91", "\xe2\x86\x90", "\xe2\x86\x93", "\xe2\x86\x92" };
    const nav_key = [_]t.Key{ .home, .page_up, .delete, .end, .page_down, .up, .left, .down, .right };
    const nx = [_]f32{ 1, 2, 0, 1, 2, 1, 0, 1, 2 };
    const nr = [_]u8{ 1, 1, 2, 2, 2, 4, 5, 5, 5 };
    var i: usize = 0;
    while (i < 9 and n < out.len) : (i += 1) {
        out[n] = .{ .l = nav_lbl[i], .k = nav_key[i], .x = KM_MAIN_W + 0.5 + nx[i], .w = 1, .row = nr[i], .nav = true };
        n += 1;
    }
    return n;
}

fn kmMods(bits: u8) t.Mods {
    return .{ .ctrl = (bits & M_CTRL) != 0, .shift = (bits & M_SHIFT) != 0, .alt = (bits & M_ALT) != 0, .win = (bits & M_WIN) != 0 };
}

fn kmModsEql(a: t.Mods, b: t.Mods) bool {
    return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and a.win == b.win;
}

fn kmTone(cat: i32) t.Color {
    const tones = [_]Tone{ .violet, .info, .success, .warn, .danger, .teal };
    const idx: usize = @intCast(@mod(cat, 6));
    return trace.toneColor(tones[idx]);
}

const km_sets = [_]t.Mods{
    .{},
    .{ .ctrl = true },
    .{ .shift = true },
    .{ .alt = true },
    .{ .ctrl = true, .shift = true },
};

fn kmSetName(m: t.Mods) []const u8 {
    if (kmModsEql(m, km_sets[0])) return "None";
    if (kmModsEql(m, km_sets[1])) return "Ctrl";
    if (kmModsEql(m, km_sets[2])) return "Shift";
    if (kmModsEql(m, km_sets[3])) return "Alt";
    if (kmModsEql(m, km_sets[4])) return "Ctrl+Shift";
    return "Keys";
}

pub const KeymapBinding = struct {
    combo: actions.KeyCombo = .{},
    action: []const u8 = "",
    /// 分类下标（决定键的底色与图例）。
    category: i32 = 0,
};

pub const KeymapOpts = struct {
    /// 图例名（分类）。
    categories: []const []const u8 = &.{},
    /// 外部持有的修饰键选择；null = 用 `KeymapState.mods`。
    mods: ?*t.Mods = null,
    no_function_row: bool = false,
};

pub const KeymapResult = struct {
    /// 本帧被点击的键（`unknown` = 没有）。
    clicked: t.Key = .unknown,
    /// 同组合键的重复绑定数。
    conflicts: i32 = 0,
};

pub const KeymapState = struct {
    mods: t.Mods = .{},
};

/// 键位图：整块键盘按当前修饰键显示快捷键与分类色；同键重复绑定标冲突；
/// 悬停看该键的全部绑定，点击回键值（用于重新绑定）。
pub fn keymap(ui: *core.Context, id: []const u8, bindings: []const KeymapBinding, st: *KeymapState, opts: KeymapOpts) KeymapResult {
    var res = KeymapResult{};
    const key = idOf(id);
    const mods_ptr = opts.mods orelse &st.mods;
    var mods = mods_ptr.*;

    // 冲突：同一组合键出现两次以上
    var i: usize = 0;
    while (i < bindings.len) : (i += 1) {
        var j = i + 1;
        while (j < bindings.len) : (j += 1) {
            if (bindings[i].combo.key == bindings[j].combo.key and
                kmModsEql(bindings[i].combo.mods, bindings[j].combo.mods) and
                bindings[i].combo.key != .unknown)
            {
                res.conflicts += 1;
                break;
            }
        }
    }

    // 修饰键选择 + 图例
    {
        var bar = ui.row(.{ .gap = 12 });
        defer bar.end();
        var labels: [5][]const u8 = @splat("");
        var sel: usize = 0;
        var k: usize = 0;
        while (k < 5) : (k += 1) {
            var cnt: usize = 0;
            for (bindings) |b| {
                if (kmModsEql(b.combo.mods, km_sets[k])) cnt += 1;
            }
            var lb: [32]u8 = undefined;
            if (cnt > 0) {
                labels[k] = ui.frameStr(std.fmt.bufPrint(lb[0..], "{s} {d}", .{ kmSetName(km_sets[k]), cnt }) catch kmSetName(km_sets[k]));
            } else {
                labels[k] = kmSetName(km_sets[k]);
            }
            if (kmModsEql(mods, km_sets[k])) sel = k;
        }
        var mb: [40]u8 = undefined;
        const mid = ui.frameStr(std.fmt.bufPrint(mb[0..], "{s}#mods", .{id}) catch "km-mods");
        const prev_sel = sel;
        controls.segmented(ui, mid, labels[0..], &sel);
        if (sel != prev_sel) {
            mods = km_sets[sel];
            mods_ptr.* = mods;
        }
        const fs = theme.font_small;
        var c: usize = 0;
        while (c < opts.categories.len) : (c += 1) {
            const dot = ui.reserve(10, 26, false);
            ui.addBox(.{ .x = dot.x, .y = dot.y + 9, .w = 10, .h = 10 }, .{ .fill = kmTone(@intCast(c)), .radius = 3 });
            const m = ui.measureText(opts.categories[c], fs);
            const tr = ui.reserve(m.w + 2, 26, false);
            ui.addText(.{ .x = tr.x, .y = tr.y + 5, .w = tr.w, .h = m.h }, opts.categories[c], fs, theme.secondary);
        }
        if (res.conflicts > 0) {
            var cb: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(cb[0..], "{d} conflict(s)", .{res.conflicts}) catch "conflict";
            const cm = ui.measureText(msg, fs);
            const tr = ui.reserve(cm.w + 2, 26, false);
            ui.addText(.{ .x = tr.x, .y = tr.y + 5, .w = tr.w, .h = cm.h }, ui.frameStr(msg), fs, theme.danger);
        }
    }

    // 键盘
    const fr = ui.stack[ui.depth - 1];
    const avail0 = fr.width - fr.cursor;
    const avail: f32 = if (avail0 > 80) avail0 else 760;
    const nav = avail >= KM_NO_NAV;
    const frow = !opts.no_function_row;
    const units: f32 = KM_MAIN_W + (if (nav) KM_NAV_W else 0);
    const u: f32 = @min(KM_MAX_U, avail / units);
    const top: f32 = if (frow) 1.25 else 0;
    const height: f32 = (top + 5) * u;
    const kb = ui.reserve(0, height, true);
    const kit = ui.interact(kk(key, 0x4B3A, 0), kb);
    const x0: f32 = @max(0, (avail - units * u) * 0.5);

    var layout: [96]KmKey = @splat(.{});
    const nk = kmLayout(layout[0..]);
    const dark = theme.isDark();
    var hover_i: i32 = -1;
    var hover_key: t.Key = .unknown;

    i = 0;
    while (i < nk) : (i += 1) {
        const k = layout[i];
        if (k.nav and !nav) continue;
        if (!k.nav and k.row == 0 and !frow) continue;
        const y: f32 = if (k.row == 0) 0 else (top + @as(f32, @floatFromInt(k.row)) - 1) * u;
        const rect = t.Rect{
            .x = kb.x + x0 + k.x * u + 2,
            .y = kb.y + y + 2,
            .w = k.w * u - 4,
            .h = u - 4,
        };
        if (kit.hover and rect.contains(ui.input.mouse.x, ui.input.mouse.y)) {
            hover_i = @intCast(i);
            hover_key = k.k;
        }
        var first: i32 = -1;
        var cnt: i32 = 0;
        if (k.k != .unknown) {
            for (bindings, 0..) |b, j| {
                if (b.combo.key != k.k) continue;
                if (!kmModsEql(b.combo.mods, mods)) continue;
                if (first < 0) first = @intCast(j);
                cnt += 1;
            }
        }
        var fill = theme.surface;
        var conflict_key = false;
        var held_key = false;
        var label_color = if (k.l.len == 0) theme.secondary else theme.text;
        var action: []const u8 = "";
        var tint = theme.accent;
        if (k.m != 0 and (modsBits(mods) & k.m) != 0) {
            fill = theme.accent_bg;
            held_key = true;
        }
        if (first >= 0) {
            const b = bindings[@intCast(first)];
            tint = kmTone(b.category);
            fill = trace.mixColor(theme.surface, tint, if (dark) 0.16 else 0.10);
            action = b.action;
            label_color = theme.text;
            if (cnt > 1) {
                conflict_key = true;
                var nb: [24]u8 = undefined;
                action = ui.frameStr(std.fmt.bufPrint(nb[0..], "{d} actions", .{cnt}) catch "actions");
                fill = trace.mixColor(theme.surface, theme.danger, if (dark) 0.18 else 0.10);
            }
        }
        if (hover_i == @as(i32, @intCast(i))) fill = trace.mixColor(fill, theme.track, 0.85);
        // 每个键**不描边**：`addBox` 带 border 会出 5 条绘制指令，83 键直接顶穿
        // `MAX_COMMANDS`（实测溢出）。键面用底色区分，冲突/按住只用一条色条。
        ui.addBox(rect, .{ .fill = fill, .radius = keyRadius(u) });
        if (conflict_key) {
            ui.addBox(.{ .x = rect.x, .y = rect.y + rect.h - 2, .w = rect.w, .h = 2 }, .{ .fill = theme.danger });
        } else if (held_key) {
            ui.addBox(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 2 }, .{ .fill = theme.accent });
        }
        if (first >= 0) {
            ui.addBox(.{ .x = rect.x + 3, .y = rect.y + rect.h - 4, .w = rect.w - 6, .h = 2 }, .{ .fill = tint, .radius = 1 });
        }
        const ls = @min(@max(u * 0.27, 8), 12);
        // 长标签（Home / PgUp / F10）先缩字号再截断（CUI 同口径：最多缩到 70%）
        const room = @max(6, rect.w - 8);
        const raw = ui.measureText(k.l, ls).w;
        const ks = if (raw > room and raw > 0) @max(ls * 0.7, ls * room / raw) else ls;
        const lr = clipText(ui, k.l, ks, room);
        ui.addText(.{ .x = rect.x + 4, .y = rect.y + 3, .w = rect.w - 8, .h = ks + 4 }, lr, ks, label_color);
        if (first >= 0 and rect.h >= ls * 2.2) {
            const as = @min(@max(u * 0.22, 7), 10.5);
            const ar = clipText(ui, action, as, rect.w - 8);
            ui.addText(.{ .x = rect.x + 4, .y = rect.y + rect.h - as - 6, .w = rect.w - 8, .h = as + 4 }, ar, as, theme.secondary);
        }
    }

    if (kit.clicked and hover_i >= 0 and hover_key != .unknown) res.clicked = hover_key;

    // 悬停提示：该键上的全部绑定
    if (hover_i >= 0 and hover_key != .unknown and !ui.input.down) {
        var lines: usize = 0;
        for (bindings) |b| {
            if (b.combo.key == hover_key) lines += 1;
        }
        if (lines > 0) {
            const lh: f32 = 18;
            const w: f32 = 240;
            const h: f32 = @as(f32, @floatFromInt(@min(lines, 6))) * lh + 10;
            var bx = ui.input.mouse.x + 14;
            var by = ui.input.mouse.y + 18;
            if (bx + w > ui.width - 6) bx = @max(6, ui.width - w - 6);
            if (by + h > ui.height - 6) by = @max(6, ui.height - h - 6);
            ui.addOverlayBox(.{ .x = bx, .y = by, .w = w, .h = h }, .{ .fill = theme.bg, .radius = 8, .border = theme.border });
            var n: usize = 0;
            for (bindings) |b| {
                if (b.combo.key != hover_key) continue;
                if (n >= 6) break;
                var tb: [96]u8 = undefined;
                const line = std.fmt.bufPrint(tb[0..], "{s}  {s}", .{ actions.shortcutLabel(ui, b.combo), b.action }) catch b.action;
                ui.addText(.{ .x = bx + 8, .y = by + 5 + @as(f32, @floatFromInt(n)) * lh, .w = w - 16, .h = 16 }, ui.frameStr(line), theme.font_small, theme.text);
                n += 1;
            }
        }
    }
    return res;
}

fn keyRadius(u: f32) f32 {
    return @min(6, u * 0.16);
}

fn modsBits(m: t.Mods) u8 {
    var b: u8 = 0;
    if (m.ctrl) b |= M_CTRL;
    if (m.shift) b |= M_SHIFT;
    if (m.alt) b |= M_ALT;
    if (m.win) b |= M_WIN;
    return b;
}
