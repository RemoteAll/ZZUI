//! 文件浏览器与文件选择器（对位 CUI `cui_files.c`）。
//!
//! 目录枚举走 `Context.list_fn`：`App` 每帧把它挂到平台层（Win32 `FindFirstFileW`），
//! `null` 后端没有文件系统，测试与 headless 用 `ui.list_fn = &fakeList` 注入内存树。
//! 浏览器**只在进入目录/改过滤/按刷新时读盘**，不是每帧。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **没有侧边栏「places」**（CUI 有 6 个默认位置）：那需要取用户目录/桌面/文档的路径，
//!   属平台层能力，等 X11/Cocoa 后端一起补；`Opts` 里也没留这个口子；
//! - 路径栏**不可输入**（CUI 可以点进去改路径）：改成「上级」按钮 + 只读路径；
//! - 列宽固定比例，不做 CUI 的「按内容自适应 + 可拖」；
//! - 只画视口内的行（长目录不把节点预算打爆），**双击**用尺寸池记状态而不是加 `Input` 字段。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const widgets = @import("widgets.zig");
const extras = @import("extras.zig");

/// 单次列出的最大条目数。
pub const MAX_ENTRIES = 256;
/// 名字缓冲（所有条目名共用）。
pub const MAX_NAMES = 8192;
/// 路径缓冲。
pub const PATH_CAP = 512;

pub const Path = struct {
    buf: [PATH_CAP]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Path, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }

    pub fn isEmpty(self: *const Path) bool {
        return self.len == 0;
    }

    /// 上一级（根目录保持不变）。
    pub fn up(self: *Path) bool {
        const s = self.slice();
        var n = s.len;
        while (n > 0 and isSep(s[n - 1])) n -= 1;
        if (n == 0) return false;
        // 保留 "C:\" 这种根
        var i = n;
        while (i > 0 and !isSep(s[i - 1])) i -= 1;
        if (i == 0) return false;
        var keep = i;
        // 去掉多余的尾分隔符，但保留根（"C:\"）
        while (keep > 1 and isSep(s[keep - 1])) keep -= 1;
        if (keep == self.len) return false;
        self.len = keep;
        return true;
    }

    /// 拼接子路径（自动补分隔符）。
    pub fn join(self: *Path, name: []const u8) void {
        const s = self.slice();
        var need_sep = s.len > 0 and !isSep(s[s.len - 1]);
        if (s.len == 0) need_sep = false;
        if (self.len + name.len + 1 > self.buf.len) return;
        if (need_sep) {
            self.buf[self.len] = sep();
            self.len += 1;
        }
        @memcpy(self.buf[self.len..][0..name.len], name);
        self.len += name.len;
    }
};

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// 路径分隔符：**统一用 `/`**。Win32 的 `FindFirstFileW` 也接受 `/`，
/// 统一之后调用方与测试都不用关心平台（`up()` 仍认得 `\\`）。
fn sep() u8 {
    return '/';
}

pub const BrowserOpts = struct {
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    height: f32 = 380,
    /// 过滤模式，分号分隔（`"*.png;*.jpg"`）；目录永远显示。
    filter: []const u8 = "",
    folders_only: bool = false,
    hidden: bool = false,
};

pub const BrowserResult = struct {
    /// 双击/回车选中的文件（帧内存，指向 `State.entries` 的名字）。
    picked: ?[]const u8 = null,
    /// 当前选中的条目名（可能是目录）。
    selected: ?[]const u8 = null,
    /// 目录变了（`path` 被改写）。
    navigated: bool = false,
    /// 目录读不了。
    err: bool = false,
};

pub const State = struct {
    entries: [MAX_ENTRIES]t.FileEntry = @splat(.{}),
    names: [MAX_NAMES]u8 = @splat(0),
    n: usize = 0,
    /// 上次加载的目录 + 选项签名（变了才重读，不是每帧读盘）。
    loaded: [PATH_CAP]u8 = @splat(0),
    loaded_len: usize = 0,
    loaded_hidden: bool = false,
    loaded_folders_only: bool = false,
    loaded_filter: [64]u8 = @splat(0),
    loaded_filter_len: usize = 0,
    loaded_once: bool = false,
    /// 排序：0 = 名称，1 = 修改时间，2 = 大小。
    sort_col: u8 = 0,
    sort_desc: bool = false,
    sel: i32 = -1,
    err: bool = false,
};

fn filterMatches(filter: []const u8, name: []const u8) bool {
    if (filter.len == 0) return true;
    var it = std.mem.splitScalar(u8, filter, ';');
    while (it.next()) |raw| {
        const pat = std.mem.trim(u8, raw, " ");
        if (pat.len == 0) continue;
        if (globMatch(pat, name)) return true;
    }
    return false;
}

/// `*` / `?` 通配（ASCII 大小写不敏感）。
fn globMatch(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pat.len and (pat[p] == '?' or std.ascii.toLower(pat[p]) == std.ascii.toLower(s[i]))) {
            p += 1;
            i += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            mark = i;
        } else if (star) |sp| {
            p = sp + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn needReload(st: *State, path: *const Path, opts: BrowserOpts) bool {
    if (!st.loaded_once) return true;
    if (st.loaded_len != path.len) return true;
    if (!std.mem.eql(u8, st.loaded[0..st.loaded_len], path.slice())) return true;
    if (st.loaded_hidden != opts.hidden) return true;
    if (st.loaded_folders_only != opts.folders_only) return true;
    if (st.loaded_filter_len != opts.filter.len) return true;
    if (!std.mem.eql(u8, st.loaded_filter[0..st.loaded_filter_len], opts.filter)) return true;
    return false;
}

fn markLoaded(st: *State, path: *const Path, opts: BrowserOpts) void {
    st.loaded_len = @min(path.len, st.loaded.len);
    @memcpy(st.loaded[0..st.loaded_len], path.slice()[0..st.loaded_len]);
    st.loaded_hidden = opts.hidden;
    st.loaded_folders_only = opts.folders_only;
    st.loaded_filter_len = @min(opts.filter.len, st.loaded_filter.len);
    @memcpy(st.loaded_filter[0..st.loaded_filter_len], opts.filter[0..st.loaded_filter_len]);
    st.loaded_once = true;
}

const SortCtx = struct {
    col: u8,
    desc: bool,
};

fn lessEntry(ctx: SortCtx, a: t.FileEntry, b: t.FileEntry) bool {
    if (a.dir != b.dir) return a.dir; // 目录永远在前
    var less = false;
    switch (ctx.col) {
        1 => less = a.modified > b.modified,
        2 => less = a.size > b.size,
        else => less = std.ascii.lessThanIgnoreCase(a.name, b.name),
    }
    return if (ctx.desc) !less else less;
}

fn sortEntries(st: *State) void {
    // 插入排序：只在「重新读目录」时排一次（≤256 项），比实例化 `std.sort.pdq`
    // 划算得多 —— 泛型排序的实例化在产物里是实打实的几千字节。
    const ctx = SortCtx{ .col = st.sort_col, .desc = st.sort_desc };
    var i: usize = 1;
    while (i < st.n) : (i += 1) {
        const key = st.entries[i];
        var j = i;
        while (j > 0 and lessEntry(ctx, key, st.entries[j - 1])) : (j -= 1) {
            st.entries[j] = st.entries[j - 1];
        }
        st.entries[j] = key;
    }
}

/// 读目录（只在需要时）。返回 true 表示刚重读过。
fn reload(ui: *core.Context, path: *const Path, st: *State, opts: BrowserOpts) bool {
    if (!needReload(st, path, opts)) return false;
    st.n = 0;
    const n = ui.listDir(path.slice(), st.entries[0..], st.names[0..], opts.hidden);
    st.err = n < 0;
    if (n > 0) {
        var kept: usize = 0;
        var k: usize = 0;
        while (k < @as(usize, @intCast(n))) : (k += 1) {
            const e = st.entries[k];
            if (e.dir and opts.folders_only) {
                st.entries[kept] = e;
                kept += 1;
            } else if (e.dir or filterMatches(opts.filter, e.name)) {
                st.entries[kept] = e;
                kept += 1;
            }
        }
        st.n = kept;
    }
    sortEntries(st);
    markLoaded(st, path, opts);
    return true;
}

fn fmtSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) {
        var tmp: [24]u8 = undefined;
        const s = num.int(tmp[0..], @intCast(bytes));
        var n: usize = 0;
        @memcpy(buf[0..s.len], s);
        n = s.len;
        buf[n] = ' ';
        n += 1;
        buf[n] = 'B';
        n += 1;
        return buf[0..n];
    }
    const kb = @as(f32, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024) {
        var tmp: [24]u8 = undefined;
        const s = num.fixed(tmp[0..], kb, 1);
        var n: usize = 0;
        @memcpy(buf[0..s.len], s);
        n = s.len;
        const tail = " KB";
        @memcpy(buf[n..][0..tail.len], tail);
        n += tail.len;
        return buf[0..n];
    }
    const mb = kb / 1024.0;
    var tmp: [24]u8 = undefined;
    const s = num.fixed(tmp[0..], mb, 1);
    var n: usize = 0;
    @memcpy(buf[0..s.len], s);
    n = s.len;
    const tail = " MB";
    @memcpy(buf[n..][0..tail.len], tail);
    n += tail.len;
    return buf[0..n];
}

/// 日期（本地近似：按 UTC 显示 `YYYY-MM-DD`，不引时区库）。
fn fmtDate(buf: []u8, unix_secs: i64) []const u8 {
    if (unix_secs <= 0) return "-";
    var days = @divFloor(unix_secs, 86400);
    var rem = @mod(unix_secs, 86400);
    const tod_h = @divFloor(rem, 3600);
    rem = @mod(rem, 3600);
    const tod_m = @divFloor(rem, 60);
    // 民用历反算（与 month.zig 同一算法）
    days += 719468;
    const era = @divFloor(days, 146097);
    const doe = days - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    var tmp: [8]u8 = undefined;
    const ds = num.int(tmp[0..], d);
    var n: usize = 0;
    const ys = num.int(buf[n..], year);
    n += ys.len;
    buf[n] = '-';
    n += 1;
    if (m < 10) {
        buf[n] = '0';
        n += 1;
    }
    const ms = num.int(buf[n..], m);
    n += ms.len;
    buf[n] = '-';
    n += 1;
    if (d < 10) {
        buf[n] = '0';
        n += 1;
    }
    @memcpy(buf[n..][0..ds.len], ds);
    n += ds.len;
    _ = tod_h;
    _ = tod_m;
    return buf[0..n];
}

/// 文件浏览器（在 column 容器里调用）。`path` 由调用方持有并可被改写。
pub fn fileBrowser(
    ui: *core.Context,
    id: []const u8,
    path: *Path,
    st: *State,
    opts: BrowserOpts,
) BrowserResult {
    var res = BrowserResult{};
    if (path.isEmpty()) path.set(".");
    const fresh = reload(ui, path, st, opts);

    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else if (frame.width > 0) frame.width else 480;
    const total_h = opts.height;

    var card = ui.column(.{ .fill = theme.surface, .radius = 10, .border = theme.border, .pad = 0, .gap = 0 });
    defer card.end();

    // ---- 工具栏：上级 / 刷新 / 路径
    {
        const bar = ui.reserve(0, 32, true);
        const bid = core.Context.idOf(id) ^ 0x51D0;
        if (widgets.buttonRect(ui, .{ .x = bar.x + 6, .y = bar.y + 4, .w = 26, .h = 24 }, "^", .{})) {
            if (path.up()) {
                st.sel = -1;
                res.navigated = true;
                _ = reload(ui, path, st, opts);
            }
        }
        if (widgets.buttonRect(ui, .{ .x = bar.x + 36, .y = bar.y + 4, .w = 26, .h = 24 }, "R", .{})) {
            st.loaded_once = false;
            _ = reload(ui, path, st, opts);
        }
        const pm = ui.measureText(path.slice(), theme.font_small);
        ui.addText(
            .{ .x = bar.x + 70, .y = bar.y + (32 - pm.h) / 2, .w = @max(0, w - 76), .h = pm.h },
            path.slice(),
            theme.font_small,
            theme.secondary,
        );
        _ = bid;
        ui.addOverlayLine(.{ .x = bar.x, .y = bar.y + 31 }, .{ .x = bar.x + bar.w, .y = bar.y + 31 }, 1, theme.border);
    }

    // ---- 表头（点击排序）
    const head_h: f32 = 24;
    const row_h: f32 = 24;
    {
        const hdr = ui.reserve(0, head_h, true);
        const cols = [_]struct { label: []const u8, frac: f32, col: u8 }{
            .{ .label = "Name", .frac = 0.60, .col = 0 },
            .{ .label = "Modified", .frac = 0.25, .col = 1 },
            .{ .label = "Size", .frac = 0.15, .col = 2 },
        };
        var x = hdr.x + 6;
        for (cols) |c| {
            const cw = (hdr.w - 12) * c.frac;
            const cid = core.Context.idOf(id) ^ 0x4EAD ^ @as(u64, c.col);
            const it = ui.interactEx(cid, .{ .x = x, .y = hdr.y, .w = cw, .h = head_h }, false);
            var lbl = c.label;
            if (st.sort_col == c.col) lbl = if (st.sort_desc) labelsDesc(c.col) else labelsAsc(c.col);
            ui.addText(.{ .x = x + 2, .y = hdr.y + (head_h - theme.font_small * 1.35) / 2, .w = cw, .h = theme.font_small * 1.35 }, lbl, theme.font_small, if (st.sort_col == c.col) theme.text else theme.secondary);
            if (it.clicked) {
                if (st.sort_col == c.col) st.sort_desc = !st.sort_desc else {
                    st.sort_col = c.col;
                    st.sort_desc = false;
                }
                sortEntries(st);
            }
            x += cw;
        }
        ui.addOverlayLine(.{ .x = hdr.x, .y = hdr.y + head_h - 1 }, .{ .x = hdr.x + hdr.w, .y = hdr.y + head_h - 1 }, 1, theme.border);
    }

    // ---- 列表（只画视口内的行）
    const list_h = @max(60, total_h - 32 - head_h - 24);
    var sc = ui.scroll(.{ .id = id, .height = list_h, .pad = 4, .gap = 0 });
    defer sc.end();

    if (st.err) {
        extras.muted(ui, "cannot read this folder");
    } else if (st.n == 0) {
        extras.muted(ui, if (fresh) "empty folder" else "no matching files");
    }
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        const e = st.entries[i];
        const row = ui.reserve(0, row_h, true);
        if (row.y + row_h < sc.rect.y - 1 or row.y > sc.rect.y + sc.rect.h + 1) continue;
        const rid = core.Context.idOf(id) ^ 0x20 ^ @as(u64, @intCast(i));
        const it = ui.interactEx(rid, row, false);
        const is_sel = st.sel == @as(i32, @intCast(i));
        if (is_sel) {
            ui.addBox(row, .{ .fill = theme.accent_bg, .radius = 4 });
        } else if (it.hover) {
            ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
        }
        // 图标：目录画一个实心小方块，文件画一个空心小方块
        const iy = row.y + (row_h - 12) / 2;
        if (e.dir) {
            ui.addBox(.{ .x = row.x + 6, .y = iy, .w = 12, .h = 12 }, .{ .fill = theme.accent, .radius = 2 });
        } else {
            ui.addBox(.{ .x = row.x + 6, .y = iy, .w = 12, .h = 12 }, .{ .border = theme.border, .radius = 2 });
        }
        const col_w = (row.w - 12);
        const name_x = row.x + 24;
        const name_w = col_w * 0.60 - 18;
        ui.addText(.{ .x = name_x, .y = row.y + (row_h - theme.font_small * 1.35) / 2, .w = name_w, .h = theme.font_small * 1.35 }, e.name, theme.font_small, theme.text);
        var dbuf: [16]u8 = undefined;
        const dtx = ui.frameStr(fmtDate(dbuf[0..], e.modified));
        ui.addText(.{ .x = row.x + col_w * 0.60 + 6, .y = row.y + (row_h - theme.font_small * 1.35) / 2, .w = col_w * 0.25, .h = theme.font_small * 1.35 }, dtx, theme.font_small, theme.secondary);
        var sbuf: [24]u8 = undefined;
        const stx = if (e.dir) "-" else ui.frameStr(fmtSize(sbuf[0..], e.size));
        ui.addText(.{ .x = row.x + col_w * 0.85 + 6, .y = row.y + (row_h - theme.font_small * 1.35) / 2, .w = col_w * 0.15, .h = theme.font_small * 1.35 }, stx, theme.font_small, theme.secondary);

        if (it.clicked) {
            // 双击 = 两次点击间隔 < 0.45s 且同一行
            const dbl_key = core.Context.idOf(id) ^ 0xDB1;
            const prev = ui.knownSize(dbl_key);
            const is_double = if (prev) |p|
                (ui.time * 1000.0 - @as(f64, p.w) < 450.0 and @as(usize, @intFromFloat(@max(p.h, 0))) == i)
            else
                false;
            ui.rememberSize(dbl_key, @as(f32, @floatCast(ui.time * 1000.0)), @floatFromInt(i));
            st.sel = @intCast(i);
            if (is_double or it.activated) {
                if (e.dir) {
                    path.join(e.name);
                    st.sel = -1;
                    res.navigated = true;
                    st.loaded_once = false;
                    _ = reload(ui, path, st, opts);
                } else {
                    res.picked = e.name;
                }
            }
        }
        if (it.activated and !e.dir) res.picked = e.name;
    }

    if (st.sel >= 0 and st.sel < @as(i32, @intCast(st.n))) {
        const e = st.entries[@intCast(st.sel)];
        res.selected = e.name;
        if (!e.dir and ui.input.keyPressed(.enter)) res.picked = e.name;
    }

    // 键盘：Backspace 上跳（在浏览器有焦点时也走这条，与 CUI 同口径）
    if (ui.input.keyPressed(.backspace)) {
        if (path.up()) {
            st.sel = -1;
            res.navigated = true;
            _ = reload(ui, path, st, opts);
        }
    }
    return res;
}

fn labelsAsc(col: u8) []const u8 {
    return switch (col) {
        1 => "Modified ^",
        2 => "Size ^",
        else => "Name ^",
    };
}

fn labelsDesc(col: u8) []const u8 {
    return switch (col) {
        1 => "Modified v",
        2 => "Size v",
        else => "Name v",
    };
}

// ------------------------------------------------------------------ 文件选择器

pub const PickerOpts = struct {
    title: []const u8 = "Open",
    /// 保存模式：多一个文件名输入 + 按钮写 "Save"。
    save: bool = false,
    filter: []const u8 = "",
    /// 卡片宽。
    width: f32 = 520,
    height: f32 = 420,
};

pub const PickerState = struct {
    browser: State = .{},
    /// 文件名输入（保存模式用；打开模式跟着选中项走）。
    name: [128]u8 = @splat(0),
    name_len: usize = 0,
    name_caret: usize = 0,
    name_editing: bool = false,
};

/// 文件选择器（模态）。确认时返回完整路径（帧内存），`*open` 置 false。
pub fn filePicker(
    ui: *core.Context,
    id: []const u8,
    open: *bool,
    out: *Path,
    path: *Path,
    st: *PickerState,
    opts: PickerOpts,
) bool {
    if (!open.*) return false;
    var ov = ui.beginOverlay(.{ .hit = true, .id = core.Context.idOf(id) ^ 0x51EC });
    defer ov.end();

    const w = opts.width;
    const h = opts.height;
    const x = (ui.width - w) / 2;
    const y = (ui.height - h) / 2;
    var card = ui.panel(.{ .x = x, .y = y, .w = w, .h = h }, .{
        .fill = theme.surface,
        .radius = 12,
        .border = theme.border,
        .pad = 16,
        .gap = 8,
    });
    defer card.end();

    _ = ui.textRun(opts.title, 16, theme.text);

    const br = fileBrowser(ui, id, path, &st.browser, .{
        .height = @max(120, h - 150),
        .filter = opts.filter,
    });

    // 文件名行
    var confirmed = false;
    {
        const row = ui.reserve(0, 34, true);
        if (opts.save) {
            const field_w = row.w - 2 * 88 - 16;
            _ = widgets.input(ui, "file-name", &st.name, &st.name_len, &st.name_caret, .{ .placeholder = "name.txt", .width = field_w });
        } else {
            const cur = br.selected orelse "";
            const m = ui.measureText(cur, theme.font_body);
            ui.addText(.{ .x = row.x, .y = row.y + (34 - m.h) / 2, .w = @max(0, row.w - 200), .h = m.h }, cur, theme.font_body, theme.secondary);
        }

        const ok_x = row.x + row.w - 88;
        const label = if (opts.save) "Save" else "Open";
        if (widgets.buttonRect(ui, .{ .x = ok_x, .y = row.y + 2, .w = 88, .h = 30 }, label, .{ .variant = .primary })) {
            confirmed = true;
        }
        if (widgets.buttonRect(ui, .{ .x = ok_x - 96, .y = row.y + 2, .w = 88, .h = 30 }, "Cancel", .{})) {
            open.* = false;
            return false;
        }
    }

    if (br.picked) |name| {
        if (!opts.save) {
            out.* = path.*;
            out.join(name);
            confirmed = true;
        } else {
            st.name_len = @min(name.len, st.name.len);
            @memcpy(st.name[0..st.name_len], name[0..st.name_len]);
        }
    }

    if (confirmed) {
        out.* = path.*;
        const name = if (opts.save) st.name[0..st.name_len] else (br.selected orelse "");
        if (name.len > 0) {
            out.join(name);
            open.* = false;
            return true;
        }
    }
    if (ui.input.keyPressed(.escape) or ui.overlayBackdropClicked()) {
        open.* = false;
    }
    return false;
}
