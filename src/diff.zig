//! 差异视图（对位 CUI 的 `cui_diff.c`）：行级 diff（先剥公共前后缀，再对中间段做 LCS），
//! 并排（split）/ 内联（inline）两种版式、context 折叠、变更块选中、词级高亮与行表导出。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次有人当成 bug）：
//! - 中间段每侧超过 `MAX_MID` 行时退化为「整块替换」并置 `approximate`（CUI 是 Myers 到 1600 万步）；
//!   这样不需要堆分配、也不需要 O(N·M) 的 DP 表超出固定预算；
//! - **词级高亮只在并排版式（split）里画**：unified 的删除/新增是两行，配对的词标
//!   需要额外一张跨行表；`words` 本身在两种版式下都能用（`viewRows` 也导出 unified 行）；
//! - 词级 LCS 的中间段上限 `WORD_MAX_MID`（96 token）：超过就整行不上词标（仍保留行级底色）；
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

const LineKind = enum { same, del, add, fold };

const Row = struct {
    kind: LineKind = .same,
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

fn buildRows(d: *const Differ, a: []const []const u8, b: []const []const u8, out: *Rows, split: bool) void {
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
                // LCS 回溯可能产出「add 在 del 之前」，所以先把整段变更**一起**收下来。
                const start = i;
                var nd: usize = 0;
                var na: usize = 0;
                while (i < d.n and (d.ops[i].kind == .del or d.ops[i].kind == .add)) : (i += 1) {
                    if (d.ops[i].kind == .del) nd += 1 else na += 1;
                }
                if (!split) {
                    // 内联：删除与新增各占一行，**先删后增**（与 CUI 的行表/常见 diff 一致）。
                    // 原来无条件配对，导致「删一行/增一行」时后一行根本不画（真 bug）。
                    var j = start;
                    while (j < i) : (j += 1) {
                        const o2 = d.ops[j];
                        if (o2.kind == .del) {
                            out.push(.{ .kind = .del, .change = change, .old_no = o2.old_no, .left = a[@intCast(o2.old_no)] });
                        }
                    }
                    j = start;
                    while (j < i) : (j += 1) {
                        const o2 = d.ops[j];
                        if (o2.kind == .add) {
                            out.push(.{ .kind = .add, .change = change, .new_no = o2.new_no, .right = b[@intCast(o2.new_no)] });
                        }
                    }
                    continue;
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

    const size = opts.size;
    const prob = ui.measureText("Ag", size);
    const line_h = (if (prob.h > 0) prob.h else size * 1.35) + 2;
    const frame = &ui.stack[ui.depth - 1];
    const w = if (opts.width > 0) opts.width else frame.width;
    if (opts.mode == .split and w > 0 and w < opts.split_min_width) res.mode = .unified;
    const split = res.mode == .split;

    var rows: Rows = .{};
    buildRows(&d, la.lines(), lb.lines(), &rows, split);
    res.rows = rows.n;
    for (rows.buf[0..rows.n]) |r| {
        if (r.kind == .fold) {
            res.folds += 1;
            res.hidden += r.hidden;
        }
    }

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
    const content_w = if (sc.rect.w > 0) sc.rect.w else w;
    const col_w = if (split) (content_w - gutter) / 2 else content_w;
    const num_w: f32 = 30;
    const sign_w: f32 = 12;
    // 词级标记的帧内预算：一屏几十行 × 每行几条，不能把节点池吃光
    var mark_budget: usize = 48;

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
                    // 成对变更行：先算词级区间，把标记底色压在文字下面（split 才有配对关系）
                    var ra: [MAX_WORD_MARKS]WordRange = undefined;
                    var rb: [MAX_WORD_MARKS]WordRange = undefined;
                    var na: usize = 0;
                    var nb: usize = 0;
                    const marked = r.old_no >= 0 and r.new_no >= 0 and r.change >= 0 and
                        words(r.left, r.right, ra[0..], &na, rb[0..], &nb);
                    if (r.left.len > 0 or r.kind == .del) {
                        ui.addBox(.{ .x = row.x, .y = row.y, .w = col_w, .h = line_h }, .{
                            .fill = toneBg(theme.danger, if (selected) 40 else 24),
                        });
                        if (marked) drawWordMarks(ui, row.x + num_w + sign_w, row.y, size, line_h, r.left, ra[0..na], theme.danger, &mark_budget);
                        ui.addText(.{ .x = row.x + 4, .y = row.y, .w = num_w - 8, .h = line_h }, numText(ui, r.old_no), size, theme.secondary);
                        ui.addText(.{ .x = row.x + num_w - 4, .y = row.y, .w = sign_w, .h = line_h }, "-", size, theme.danger);
                        ui.addText(.{ .x = row.x + num_w + sign_w, .y = row.y, .w = col_w - num_w - sign_w, .h = line_h }, r.left, size, theme.text);
                    }
                    if (r.right.len > 0 or r.kind == .add) {
                        const x0 = row.x + col_w + gutter;
                        ui.addBox(.{ .x = x0, .y = row.y, .w = col_w, .h = line_h }, .{
                            .fill = toneBg(theme.success, if (selected) 40 else 24),
                        });
                        if (marked) drawWordMarks(ui, x0 + num_w + sign_w, row.y, size, line_h, r.right, rb[0..nb], theme.success, &mark_budget);
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

// ------------------------------------------------------------------ 词级标记

/// 一行里被改动的一段（字节区间，对位 `cui_diff_range`）。
pub const WordRange = struct { start: i32 = 0, length: i32 = 0 };

/// 单行词标的渲染上限（`words` 的容量也取这个）。
pub const MAX_WORD_MARKS = 16;

const WORD_MAX_LINE = 2000;
const WORD_MAX_TOKENS = 512;
const WORD_MAX_MID = 96;

fn wordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c >= 0x80;
}

/// 词 / 空格串 / 单个标点；0x80 以上的字节并入词（UTF-8 不会被切开）。
fn tokenize(s: []const u8, starts: *[WORD_MAX_TOKENS + 1]u32) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n >= WORD_MAX_TOKENS) return null;
        starts[n] = @intCast(i);
        n += 1;
        const c = s[i];
        if (wordChar(c)) {
            while (i < s.len and wordChar(s[i])) i += 1;
        } else if (c == ' ' or c == '\t') {
            while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
        } else {
            i += 1;
        }
    }
    starts[n] = @intCast(s.len);
    return n;
}

const TokenRef = struct { s: []const u8, id: u32 };

fn internToken(known: []TokenRef, nk: *usize, tok: []const u8) u32 {
    var i: usize = 0;
    while (i < nk.*) : (i += 1) {
        if (std.mem.eql(u8, known[i].s, tok)) return known[i].id;
    }
    const id: u32 = @intCast(nk.*);
    if (nk.* < known.len) {
        known[nk.*] = .{ .s = tok, .id = id };
        nk.* += 1;
    }
    return id;
}

/// 两串 token id 的 LCS，把不同的 token 标进 `ca` / `cb`。中间段过大返回 false。
fn wordLcs(ia: []const u32, ib: []const u32, ca: []bool, cb: []bool) bool {
    var ao: usize = 0;
    var bo: usize = 0;
    var ah = ia.len;
    var bh = ib.len;
    while (ao < ah and bo < bh and ia[ao] == ib[bo]) {
        ao += 1;
        bo += 1;
    }
    while (ah > ao and bh > bo and ia[ah - 1] == ib[bh - 1]) {
        ah -= 1;
        bh -= 1;
    }
    const n = ah - ao;
    const m = bh - bo;
    if (n > WORD_MAX_MID or m > WORD_MAX_MID) return false;
    if (n == 0) {
        var y = bo;
        while (y < bh) : (y += 1) cb[y] = true;
        return true;
    }
    if (m == 0) {
        var x = ao;
        while (x < ah) : (x += 1) ca[x] = true;
        return true;
    }

    var dp: [(WORD_MAX_MID + 1) * (WORD_MAX_MID + 1)]u16 = undefined;
    const stride = m + 1;
    var i: usize = n + 1;
    while (i > 0) : (i -= 1) {
        const ii = i - 1;
        var j: usize = m + 1;
        while (j > 0) : (j -= 1) {
            const jj = j - 1;
            if (ii == n or jj == m) {
                dp[ii * stride + jj] = 0;
            } else if (ia[ao + ii] == ib[bo + jj]) {
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
        if (x < n and y < m and ia[ao + x] == ib[bo + y]) {
            x += 1;
            y += 1;
        } else if (y < m and (x == n or dp[x * stride + (y + 1)] >= dp[(x + 1) * stride + y])) {
            cb[bo + y] = true;
            y += 1;
        } else {
            ca[ao + x] = true;
            x += 1;
        }
    }
    return true;
}

fn buildWordMarks(s: []const u8, starts: []const u32, nt: usize, changed: []const bool, out: []WordRange) usize {
    var no: usize = 0;
    var k: usize = 0;
    while (k < nt) {
        if (!changed[k]) {
            k += 1;
            continue;
        }
        const k0 = k;
        while (k < nt and changed[k]) k += 1;
        const r0: i32 = @intCast(starts[k0]);
        const r1: i32 = @intCast(starts[k]);
        if (no > 0) {
            // 两个标记之间只隔一个空格时合并成一段
            const gap0: usize = @intCast(out[no - 1].start + out[no - 1].length);
            if (r0 >= @as(i32, @intCast(gap0)) and @as(usize, @intCast(r0)) - gap0 <= 1) {
                var spaces = true;
                for (s[gap0..@intCast(r0)]) |c| {
                    if (c != ' ' and c != '\t') spaces = false;
                }
                if (spaces) {
                    out[no - 1].length = r1 - out[no - 1].start;
                    continue;
                }
            }
        }
        if (no >= out.len) {
            out[no - 1].length = r1 - out[no - 1].start; // 余下的并进最后一段
            break;
        }
        out[no] = .{ .start = r0, .length = r1 - r0 };
        no += 1;
    }
    return no;
}

/// 两行文本的词级改动区间（对位 `cui_diff_words`）。行太长、词太多、
/// 或两行共同内容不足 30% 时返回 false（此时行级底色已经够了）。
pub fn words(
    old_line: []const u8,
    new_line: []const u8,
    old_ranges: []WordRange,
    old_count: *usize,
    new_ranges: []WordRange,
    new_count: *usize,
) bool {
    old_count.* = 0;
    new_count.* = 0;
    const cap = @min(old_ranges.len, new_ranges.len);
    if (cap == 0) return false;
    if (old_line.len > WORD_MAX_LINE or new_line.len > WORD_MAX_LINE) return false;
    var sa: [WORD_MAX_TOKENS + 1]u32 = undefined;
    var sb: [WORD_MAX_TOKENS + 1]u32 = undefined;
    const na = tokenize(old_line, &sa) orelse return false;
    const nb = tokenize(new_line, &sb) orelse return false;

    var known: [WORD_MAX_TOKENS * 2]TokenRef = undefined;
    var nk: usize = 0;
    var ia: [WORD_MAX_TOKENS]u32 = undefined;
    var ib: [WORD_MAX_TOKENS]u32 = undefined;
    var k: usize = 0;
    while (k < na) : (k += 1) ia[k] = internToken(known[0..], &nk, old_line[sa[k]..sa[k + 1]]);
    k = 0;
    while (k < nb) : (k += 1) ib[k] = internToken(known[0..], &nk, new_line[sb[k]..sb[k + 1]]);

    var ca: [WORD_MAX_TOKENS]bool = @splat(false);
    var cb: [WORD_MAX_TOKENS]bool = @splat(false);
    if (!wordLcs(ia[0..na], ib[0..nb], ca[0..na], cb[0..nb])) return false;

    // 共同内容太少（忽略空格）就不要标词
    var same: usize = 0;
    var tot: usize = 0;
    k = 0;
    while (k < na) : (k += 1) {
        const tok = old_line[sa[k]..sa[k + 1]];
        if (tok.len > 0 and (tok[0] == ' ' or tok[0] == '\t')) continue;
        tot += tok.len;
        if (!ca[k]) same += tok.len;
    }
    k = 0;
    while (k < nb) : (k += 1) {
        const tok = new_line[sb[k]..sb[k + 1]];
        if (tok.len > 0 and (tok[0] == ' ' or tok[0] == '\t')) continue;
        tot += tok.len;
        if (!cb[k]) same += tok.len;
    }
    if (tot > 0 and same * 10 < tot * 3) return false;

    old_count.* = buildWordMarks(old_line, sa[0 .. na + 1], na, ca[0..na], old_ranges[0..cap]);
    new_count.* = buildWordMarks(new_line, sb[0 .. nb + 1], nb, cb[0..nb], new_ranges[0..cap]);
    return true;
}

fn drawWordMarks(
    ui: *core.Context,
    tx: f32,
    y: f32,
    size: f32,
    line_h: f32,
    text: []const u8,
    marks: []const WordRange,
    color: t.Color,
    budget: *usize,
) void {
    for (marks, 0..) |m, k| {
        if (k >= 6 or budget.* == 0) break;
        if (m.start < 0 or m.length <= 0) continue;
        const s0: usize = @min(@as(usize, @intCast(m.start)), text.len);
        const s1: usize = @min(text.len, s0 + @as(usize, @intCast(m.length)));
        if (s1 <= s0) continue;
        const x0 = tx + ui.measureText(text[0..s0], size).w;
        const w = ui.measureText(text[s0..s1], size).w;
        if (w <= 0) continue;
        ui.addBox(.{ .x = x0, .y = y + 1, .w = w, .h = line_h - 2 }, .{ .fill = toneBg(color, 66), .radius = 2 });
        budget.* -= 1;
    }
}

// ------------------------------------------------------------------ 行表导出

/// 行表里的行类型（对位 `cui_diff_row_kind`）。
pub const RowKind = enum { same, removed, added, changed, fold };

/// 折叠后的一行（对外只读；`changed` 是 split 下配对的删除+新增）。
pub const ViewRow = struct {
    kind: RowKind = .same,
    old_line: i32 = -1,
    new_line: i32 = -1,
    change: i32 = -1,
    hidden: usize = 0,
};

fn mapViewRow(r: Row) ViewRow {
    return switch (r.kind) {
        .fold => .{ .kind = .fold, .old_line = r.old_no, .new_line = r.new_no, .hidden = r.hidden },
        .same => .{ .kind = .same, .old_line = r.old_no, .new_line = r.new_no },
        .del, .add => blk: {
            if (r.old_no >= 0 and r.new_no >= 0) break :blk .{ .kind = .changed, .old_line = r.old_no, .new_line = r.new_no, .change = r.change };
            if (r.old_no >= 0) break :blk .{ .kind = .removed, .old_line = r.old_no, .change = r.change };
            break :blk .{ .kind = .added, .new_line = r.new_no, .change = r.change };
        },
    };
}

/// 视图会显示的行（折叠之后）。`out` 接收 `[first, first + out.len)`，
/// 返回总行数；`first` 之前与末尾之外的行不拷贝（对位 `cui_diff_view_rows`）。
/// 与视图不同，这里**每调用一次重算**差异（调用方通常只在需要批注/跳转时用）。
pub fn viewRows(old_text: []const u8, new_text: []const u8, opts: DiffOpts, out: []ViewRow, first: usize) usize {
    var la: LineSplit = .{};
    var lb: LineSplit = .{};
    splitLines(old_text, &la);
    splitLines(new_text, &lb);
    var d: Differ = .{};
    compute(&d, la.lines(), lb.lines());
    if (!opts.no_fold and opts.context > 0) foldOps(&d, opts.context);
    var rows: Rows = .{};
    buildRows(&d, la.lines(), lb.lines(), &rows, opts.mode == .split);
    var n: usize = 0;
    for (rows.buf[0..rows.n]) |r| {
        if (n >= first and n - first < out.len) out[n - first] = mapViewRow(r);
        n += 1;
    }
    return n;
}

fn numText(ui: *core.Context, n: i32) []const u8 {
    if (n < 0) return "";
    var buf: [12]u8 = undefined;
    const s = num.int(buf[0..11], @intCast(n + 1)); // 1 基行号
    return ui.frameStr(s);
}
