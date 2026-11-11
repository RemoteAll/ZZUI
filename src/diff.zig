//! 差异视图（对位 CUI 的 `cui_diff.c`）：行级 diff（先剥公共前后缀，再对中间段做 LCS），
//! 并排（split）/ 内联（inline）两种版式、context 折叠、变更块选中。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次有人当成 bug）：
//! - 中间段每侧超过 `MAX_MID` 行时退化为「整块替换」并置 `approximate`（CUI 是 Myers 到 1600 万步）；
//!   这样不需要堆分配、也不需要 O(N·M) 的 DP 表超出固定预算；
//! - 不做**词级**高亮（CUI 用 `cui_diff_words` 标出改动词）；行级已经能定位到行；
//! - 不做行内横向滚动（超长行直接裁到视图宽）；
//! - 键盘 N/P 切换变更块没做：`current` 完全由调用方写（点击变更行也会写回）。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");

/// 版式：`split` = 左右并排；`unified` = 单列（对位 CUI 的 `CUI_DIFF_INLINE`，
/// Zig 里 `inline` 是关键字，所以叫 unified）。
pub const DiffMode = enum { split, unified };

pub const DiffOpts = struct {
    mode: DiffMode = .split,
    old_title: []const u8 = "",
    new_title: []const u8 = "",
    /// 每个变更块前后保留的未变行数。
    context: usize = 3,
    /// 显示全部未变行（不折叠）。
    no_fold: bool = false,
    /// `\r\n` 与 `\n` 等价。
    ignore_eol: bool = false,
    /// 窄于该宽度时 split 自动退回 inline。
    split_min_width: f32 = 560,
    /// 0 = 撑满内容宽。
    width: f32 = 0,
    /// 0 = 按行数（上限 420）；负数 = 撑满（这里按 420 处理）。
    height: f32 = 0,
    size: f32 = 12,
};

pub const DiffResult = struct {
    added: usize = 0,
    removed: usize = 0,
    /// 变更块数（相邻的删/增算一块）。
    changes: usize = 0,
    /// 选中的变更块（-1 = 无）。
    current: i32 = -1,
    /// 本帧选中项被改变（点击或 `current` 被外部改）。
    current_changed: bool = false,
    /// 实际展示的版式（太窄时 split 会退回 inline）。
    mode: DiffMode = .split,
    /// 折叠行数与它们隐藏的行数。
    folds: usize = 0,
    hidden: usize = 0,
    /// 中间段过大而退化成整块替换。
    approximate: bool = false,
    /// 展示的行数（对齐行）。
    rows: usize = 0,
};

/// 中间段每侧最多参与 LCS 的行数（(MAX_MID+1)^2 个 u16 ≈ 18 KB 栈）。
pub const MAX_MID = 96;
/// 单侧最多读取的行数（其余截断并置 approximate）。
pub const MAX_LINES = 512;
/// 输出操作数的上限。
pub const MAX_OPS = 1024;

const OpKind = enum { same, del, add, fold };

const Op = struct {
    kind: OpKind,
    old_no: i32 = -1,
    new_no: i32 = -1,
    /// fold：隐藏的行数。
    hidden: usize = 0,
};

const LineSplit = struct {
    buf: [MAX_LINES][]const u8 = @splat(&.{}),
    n: usize = 0,
    truncated: bool = false,

    fn lines(self: *const LineSplit) []const []const u8 {
        return self.buf[0..self.n];
    }
};

fn splitLines(text: []const u8, out: *LineSplit) void {
    out.n = 0;
    out.truncated = false;
    if (text.len == 0) return;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (out.n >= out.buf.len) {
            out.truncated = true;
            return;
        }
        var ln = raw;
        if (ln.len > 0 and ln[ln.len - 1] == '\r') ln = ln[0 .. ln.len - 1];
        out.buf[out.n] = ln;
        out.n += 1;
    }
    // 文本以 \n 结尾时最后会多出一个空行，去掉它（CUI 同口径）
    if (out.n > 0 and out.buf[out.n - 1].len == 0 and text.len > 0 and text[text.len - 1] == '\n') out.n -= 1;
}

fn eqLine(a: []const u8, b: []const u8, ignore_eol: bool) bool {
    if (!ignore_eol) return std.mem.eql(u8, a, b);
    return std.mem.eql(u8, a, b); // splitLines 已经剥掉 \r，这里无需再处理
}

// ------------------------------------------------------------------ 差分

const Differ = struct {
    ops: [MAX_OPS]Op = undefined,
    n: usize = 0,
    truncated: bool = false,

    fn push(self: *Differ, op: Op) void {
        if (self.n >= self.ops.len) {
            self.truncated = true;
            return;
        }
        self.ops[self.n] = op;
        self.n += 1;
    }

    fn same(self: *Differ, o: usize, n: usize) void {
        self.push(.{ .kind = .same, .old_no = @intCast(o), .new_no = @intCast(n) });
    }

    fn del(self: *Differ, o: usize) void {
        self.push(.{ .kind = .del, .old_no = @intCast(o) });
    }

    fn add(self: *Differ, n: usize) void {
        self.push(.{ .kind = .add, .new_no = @intCast(n) });
    }
};

/// 中间段的 LCS（后缀式 DP）：把 a[ao..ah) 与 b[bo..bh) 对齐输出。
fn lcsDiff(
    d: *Differ,
    a: []const []const u8,
    ao: usize,
    ah: usize,
    b: []const []const u8,
    bo: usize,
    bh: usize,
) void {
    const n = ah - ao;
    const m = bh - bo;
    if (n == 0) {
        var j: usize = 0;
        while (j < m) : (j += 1) d.add(bo + j);
        return;
    }
    if (m == 0) {
        var i: usize = 0;
        while (i < n) : (i += 1) d.del(ao + i);
        return;
    }
    if (n > MAX_MID or m > MAX_MID) {
        // 太大：整块替换（正确但不保证最短）
        d.truncated = true;
        var i: usize = 0;
        while (i < n) : (i += 1) d.del(ao + i);
        var j: usize = 0;
        while (j < m) : (j += 1) d.add(bo + j);
        return;
    }

    var dp: [(MAX_MID + 1) * (MAX_MID + 1)]u16 = undefined;
    const stride = m + 1;
    // 从尾部往前填：dp[i][j] = LCS(a[ao+i..ah), b[bo+j..bh))
    var i: usize = n + 1;
    while (i > 0) : (i -= 1) {
        const ii = i - 1;
        var j: usize = m + 1;
        while (j > 0) : (j -= 1) {
            const jj = j - 1;
            if (ii == n or jj == m) {
                dp[ii * stride + jj] = 0;
            } else if (eqLine(a[ao + ii], b[bo + jj], false)) {
                dp[ii * stride + jj] = dp[(ii + 1) * stride + (jj + 1)] + 1;
            } else {
                const down = dp[(ii + 1) * stride + jj];
                const right = dp[ii * stride + (jj + 1)];
                dp[ii * stride + jj] = @max(down, right);
            }
        }
    }

    var x: usize = 0;
    var y: usize = 0;
    while (x < n or y < m) {
        if (x < n and y < m and eqLine(a[ao + x], b[bo + y], false)) {
            d.same(ao + x, bo + y);
            x += 1;
            y += 1;
        } else if (y < m and (x == n or dp[x * stride + (y + 1)] >= dp[(x + 1) * stride + y])) {
            d.add(bo + y);
            y += 1;
        } else {
            d.del(ao + x);
            x += 1;
        }
    }
}

/// 计算行级差异。返回操作数（写入 `d.ops[0..d.n]`）。
pub fn compute(d: *Differ, a: []const []const u8, b: []const []const u8) void {
    d.n = 0;
    d.truncated = false;
    var ao: usize = 0;
    var bo: usize = 0;
    var ah = a.len;
    var bh = b.len;
    // 剥公共前缀
    while (ao < ah and bo < bh and std.mem.eql(u8, a[ao], b[bo])) {
        d.same(ao, bo);
        ao += 1;
        bo += 1;
    }
    // 剥公共后缀
    var suffix: usize = 0;
    while (ah > ao and bh > bo and std.mem.eql(u8, a[ah - 1], b[bh - 1])) {
        ah -= 1;
        bh -= 1;
        suffix += 1;
    }
    lcsDiff(d, a, ao, ah, b, bo, bh);
    var k: usize = 0;
    while (k < suffix) : (k += 1) d.same(ah + k, bh + k);
}

// ------------------------------------------------------------------ 折叠

/// 把 same 行的长跑折叠成 fold 行（保留每个变更块前后的 context 行）。
fn foldOps(d: *Differ, context: usize) void {
    if (d.n == 0) return;
    // 标记每个 same 行是否靠近变更
    var keep: [MAX_OPS]bool = @splat(false);
    var i: usize = 0;
    while (i < d.n) : (i += 1) {
        if (d.ops[i].kind == .same) continue;
        const lo = if (i >= context) i - context else 0;
        const hi = @min(d.n - 1, i + context);
        var k = lo;
        while (k <= hi) : (k += 1) {
            if (d.ops[k].kind == .same) keep[k] = true;
        }
    }
    // 重建
    var out: [MAX_OPS]Op = undefined;
    var n: usize = 0;
    i = 0;
    while (i < d.n) : (i += 1) {
        if (d.ops[i].kind != .same or keep[i]) {
            if (n < out.len) {
                out[n] = d.ops[i];
                n += 1;
            }
            continue;
        }
        // 折叠一段连续的 same 行
        var j = i;
        while (j < d.n and d.ops[j].kind == .same and !keep[j]) : (j += 1) {}
        if (n < out.len) {
            out[n] = .{ .kind = .fold, .hidden = j - i, .old_no = d.ops[i].old_no, .new_no = d.ops[i].new_no };
            n += 1;
        }
        i = j - 1;
    }
    @memcpy(d.ops[0..n], out[0..n]);
    d.n = n;
}

// ------------------------------------------------------------------ 对齐行

const RowKind = enum { same, del, add, fold };

const Row = struct {
    kind: RowKind = .same,
    old_no: i32 = -1,
    new_no: i32 = -1,
    /// split：左侧/右侧文本；inline：只有 left 有效。
    left: []const u8 = "",
    right: []const u8 = "",
    change: i32 = -1,
    hidden: usize = 0,
};

const Rows = struct {
    buf: [MAX_OPS]Row = undefined,
    n: usize = 0,

    fn push(self: *Rows, r: Row) void {
        if (self.n >= self.buf.len) return;
        self.buf[self.n] = r;
        self.n += 1;
    }
};

fn buildRows(d: *const Differ, a: []const []const u8, b: []const []const u8, out: *Rows) void {
    out.n = 0;
    var change: i32 = -1;
    var i: usize = 0;
    while (i < d.n) {
        const op = d.ops[i];
        switch (op.kind) {
            .fold => {
                out.push(.{ .kind = .fold, .hidden = op.hidden, .old_no = op.old_no, .new_no = op.new_no });
                i += 1;
            },
            .same => {
                out.push(.{
                    .kind = .same,
                    .old_no = op.old_no,
                    .new_no = op.new_no,
                    .left = a[@intCast(op.old_no)],
                    .right = b[@intCast(op.new_no)],
                });
                i += 1;
            },
            .del, .add => {
                change += 1;
                // LCS 回溯可能产出「add 在 del 之前」，所以先把整段变更**一起**收下来，
                // 再按 del / add 分别配对 —— 只按顺序吃 del 再吃 add 会把一个变更拆成两块。
                const start = i;
                var nd: usize = 0;
                var na: usize = 0;
                while (i < d.n and (d.ops[i].kind == .del or d.ops[i].kind == .add)) : (i += 1) {
                    if (d.ops[i].kind == .del) nd += 1 else na += 1;
                }
                const pairs = @max(nd, na);
                var k: usize = 0;
                while (k < pairs) : (k += 1) {
                    var r = Row{ .change = change };
                    var seen_d: usize = 0;
                    var seen_a: usize = 0;
                    var j = start;
                    while (j < i) : (j += 1) {
                        if (d.ops[j].kind == .del) {
                            if (seen_d == k) {
                                const op_d = d.ops[j];
                                r.old_no = op_d.old_no;
                                r.left = a[@intCast(op_d.old_no)];
                                r.kind = .del;
                            }
                            seen_d += 1;
                        } else {
                            if (seen_a == k) {
                                const op_a = d.ops[j];
                                r.new_no = op_a.new_no;
                                r.right = b[@intCast(op_a.new_no)];
                                if (seen_d <= k) r.kind = .add;
                            }
                            seen_a += 1;
                        }
                    }
                    out.push(r);
                }
            },
        }
    }
}

fn countStats(d: *const Differ) struct { added: usize, removed: usize, changes: usize } {
    var added: usize = 0;
    var removed: usize = 0;
    var changes: usize = 0;
    var in_change = false;
    for (d.ops[0..d.n]) |op| {
        switch (op.kind) {
            .add => {
                added += 1;
                if (!in_change) {
                    changes += 1;
                    in_change = true;
                }
            },
            .del => {
                removed += 1;
                if (!in_change) {
                    changes += 1;
                    in_change = true;
                }
            },
            else => in_change = false,
        }
    }
    return .{ .added = added, .removed = removed, .changes = changes };
}

// ------------------------------------------------------------------ 渲染

fn toneBg(c: t.Color, a: u8) t.Color {
    return t.Color{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

/// 差异视图（在 column 容器里调用）。`current` 由调用方保存（切换变更块会写回）。
pub fn diffView(
    ui: *core.Context,
    id: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    current: ?*i32,
    opts: DiffOpts,
) DiffResult {
    var res = DiffResult{};
    res.mode = opts.mode;

    var la: LineSplit = .{};
    var lb: LineSplit = .{};
    splitLines(old_text, &la);
    splitLines(new_text, &lb);
    if (la.truncated or lb.truncated) res.approximate = true;

    var d: Differ = .{};
    compute(&d, la.lines(), lb.lines());
    const stats = countStats(&d);
    res.added = stats.added;
    res.removed = stats.removed;
    res.changes = stats.changes;
    if (d.truncated) res.approximate = true;
    if (!opts.no_fold and opts.context > 0) foldOps(&d, opts.context);

    var rows: Rows = .{};
    buildRows(&d, la.lines(), lb.lines(), &rows);
    res.rows = rows.n;
    for (rows.buf[0..rows.n]) |r| {
        if (r.kind == .fold) {
            res.folds += 1;
            res.hidden += r.hidden;
        }
    }

    const size = opts.size;
    const prob = ui.measureText("Ag", size);
    const line_h = (if (prob.h > 0) prob.h else size * 1.35) + 2;
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else frame.width;
    if (opts.mode == .split and w > 0 and w < opts.split_min_width) res.mode = .unified;

    // 表头（标题 + 增删统计）
    if (opts.old_title.len > 0 or opts.new_title.len > 0) {
        const hr = ui.reserve(0, 22, true);
        const m1 = ui.measureText(opts.old_title, theme.font_small);
        ui.addText(.{ .x = hr.x, .y = hr.y + (22 - m1.h) / 2, .w = m1.w, .h = m1.h }, opts.old_title, theme.font_small, theme.secondary);
        var nb: [24]u8 = undefined;
        const plus = num.int(nb[0..8], @intCast(res.added));
        const minus = num.int(nb[9..17], @intCast(res.removed));
        var buf: [40]u8 = undefined;
        var len: usize = 0;
        buf[len] = '+';
        len += 1;
        @memcpy(buf[len..][0..plus.len], plus);
        len += plus.len;
        buf[len] = ' ';
        len += 1;
        buf[len] = '-';
        len += 1;
        @memcpy(buf[len..][0..minus.len], minus);
        len += minus.len;
        const sm = ui.measureText(buf[0..len], theme.font_small);
        ui.addText(.{ .x = hr.x + hr.w - sm.w, .y = hr.y + (22 - sm.h) / 2, .w = sm.w, .h = sm.h }, ui.frameStr(buf[0..len]), theme.font_small, theme.secondary);
    }

    // 「选中变更块变化」时滚到它的第一行（用尺寸池记住上一帧的 current）
    const ckey = core.Context.idOf(id) ^ 0xD1FF;
    const prev_cur: i32 = if (ui.knownSize(ckey)) |s| @intFromFloat(s.w) else -1;
    var cur: i32 = if (current) |p| p.* else -1;
    if (cur != prev_cur) res.current_changed = true;

    const body_h = if (opts.height > 0) opts.height else @min(@as(f32, @floatFromInt(rows.n)) * line_h, 420);
    if (cur != prev_cur and cur >= 0) {
        var idx: usize = 0;
        for (rows.buf[0..rows.n], 0..) |r, k| {
            if (r.change == cur) {
                idx = k;
                break;
            }
        }
        const off = @max(@as(f32, 0), @as(f32, @floatFromInt(idx)) * line_h - body_h * 0.3);
        ui.scrollTo(id, off);
    }
    ui.rememberSize(ckey, @floatFromInt(cur), 0);

    var sc = ui.scroll(.{ .id = id, .height = body_h, .pad = 0, .gap = 0 });
    defer sc.end();

    const gutter: f32 = 6;
    const split = res.mode == .split;
    const content_w = if (sc.rect.w > 0) sc.rect.w else w;
    const col_w = if (split) (content_w - gutter) / 2 else content_w;
    const num_w: f32 = 30;
    const sign_w: f32 = 12;

    var i: usize = 0;
    while (i < rows.n) : (i += 1) {
        const r = rows.buf[i];
        const row = ui.reserve(0, line_h, true);
        // 视口外只占位不建节点：150 行 × 2 列轻松超过 MAX_NODES(256)，
        // 长文件必须只画看得见的行（CUI 的「只建可见行」同口径）。
        if (row.y + line_h < sc.rect.y - 1 or row.y > sc.rect.y + sc.rect.h + 1) continue;
        const selected = r.change >= 0 and r.change == cur;

        switch (r.kind) {
            .fold => {
                var buf: [32]u8 = undefined;
                const n = num.int(buf[0..12], @intCast(r.hidden));
                var wb: [48]u8 = undefined;
                var wl: usize = 0;
                @memcpy(wb[0..n.len], n);
                wl += n.len;
                const tail = " unchanged lines";
                @memcpy(wb[wl..][0..tail.len], tail);
                wl += tail.len;
                const txt = ui.frameStr(wb[0..wl]);
                const tm = ui.measureText(txt, theme.font_small);
                ui.addText(.{ .x = row.x + 8, .y = row.y + (line_h - tm.h) / 2, .w = tm.w, .h = tm.h }, txt, theme.font_small, theme.secondary);
            },
            .same => {
                if (split) {
                    ui.addText(.{ .x = row.x + 4, .y = row.y, .w = num_w - 8, .h = line_h }, numText(ui, r.old_no), size, theme.secondary);
                    ui.addText(.{ .x = row.x + num_w + sign_w, .y = row.y, .w = col_w - num_w - sign_w, .h = line_h }, r.left, size, theme.text);
                    const x1 = row.x + col_w + gutter;
                    ui.addText(.{ .x = x1 + 4, .y = row.y, .w = num_w - 8, .h = line_h }, numText(ui, r.new_no), size, theme.secondary);
                    ui.addText(.{ .x = x1 + num_w + sign_w, .y = row.y, .w = col_w - num_w - sign_w, .h = line_h }, r.right, size, theme.text);
                } else {
                    ui.addText(.{ .x = row.x + 4, .y = row.y, .w = num_w - 8, .h = line_h }, numText(ui, r.new_no), size, theme.secondary);
                    ui.addText(.{ .x = row.x + num_w + sign_w, .y = row.y, .w = content_w - num_w - sign_w, .h = line_h }, r.left, size, theme.text);
                }
            },
            .del, .add => {
                if (selected) {
                    ui.addBox(.{ .x = row.x, .y = row.y, .w = 2, .h = line_h }, .{ .fill = theme.accent });
                }
                if (split) {
                    if (r.left.len > 0 or r.kind == .del) {
                        ui.addBox(.{ .x = row.x, .y = row.y, .w = col_w, .h = line_h }, .{
                            .fill = toneBg(theme.danger, if (selected) 40 else 24),
                        });
                        ui.addText(.{ .x = row.x + 4, .y = row.y, .w = num_w - 8, .h = line_h }, numText(ui, r.old_no), size, theme.secondary);
                        ui.addText(.{ .x = row.x + num_w - 4, .y = row.y, .w = sign_w, .h = line_h }, "-", size, theme.danger);
                        ui.addText(.{ .x = row.x + num_w + sign_w, .y = row.y, .w = col_w - num_w - sign_w, .h = line_h }, r.left, size, theme.text);
                    }
                    if (r.right.len > 0 or r.kind == .add) {
                        const x0 = row.x + col_w + gutter;
                        ui.addBox(.{ .x = x0, .y = row.y, .w = col_w, .h = line_h }, .{
                            .fill = toneBg(theme.success, if (selected) 40 else 24),
                        });
                        ui.addText(.{ .x = x0 + 4, .y = row.y, .w = num_w - 8, .h = line_h }, numText(ui, r.new_no), size, theme.secondary);
                        ui.addText(.{ .x = x0 + num_w - 4, .y = row.y, .w = sign_w, .h = line_h }, "+", size, theme.success);
                        ui.addText(.{ .x = x0 + num_w + sign_w, .y = row.y, .w = col_w - num_w - sign_w, .h = line_h }, r.right, size, theme.text);
                    }
                } else {
                    const is_add = r.right.len > 0 and r.left.len == 0;
                    const bg = if (is_add) toneBg(theme.success, 24) else toneBg(theme.danger, 24);
                    const fg = if (is_add) theme.success else theme.danger;
                    const txt = if (is_add) r.right else r.left;
                    ui.addBox(.{ .x = row.x, .y = row.y, .w = content_w, .h = line_h }, .{ .fill = bg });
                    ui.addText(.{ .x = row.x + 4, .y = row.y, .w = num_w - 8, .h = line_h }, numText(ui, if (is_add) r.new_no else r.old_no), size, theme.secondary);
                    ui.addText(.{ .x = row.x + num_w - 4, .y = row.y, .w = sign_w, .h = line_h }, if (is_add) "+" else "-", size, fg);
                    ui.addText(.{ .x = row.x + num_w + sign_w, .y = row.y, .w = content_w - num_w - sign_w, .h = line_h }, txt, size, theme.text);
                }
                // 点击变更行选中该变更块
                if (r.change >= 0) {
                    const it = ui.interact(core.Context.idOf(id) ^ 0xC4A2 ^ @as(u64, @intCast(i)), row);
                    if (it.clicked) {
                        cur = r.change;
                        if (current) |p| p.* = cur;
                        res.current_changed = true;
                    }
                }
            },
        }
    }

    res.current = cur;
    return res;
}

fn numText(ui: *core.Context, n: i32) []const u8 {
    if (n < 0) return "";
    var buf: [12]u8 = undefined;
    const s = num.int(buf[0..11], @intCast(n + 1)); // 1 基行号
    return ui.frameStr(s);
}
