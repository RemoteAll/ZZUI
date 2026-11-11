//! 开发面板（对位 CUI `cui_devtools.c` 的前三块，11 API 里的 3 个控件）：
//! 键值编辑器（HTTP 头 / 查询参数 / 环境变量）、问题面板（编译器诊断按文件分组）、
//! CI 流水线（阶段 × 作业）。
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

fn fileHash(name: []const u8) u32 {
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
                ghash[ng] = fileHash(name);
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
                prbToggleFold(st, fileHash(nm));
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
