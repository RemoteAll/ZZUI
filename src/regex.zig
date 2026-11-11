//! 正则（对位 CUI `cui_regex.c`）：回溯引擎，支持常用语法 ——
//! 字面量与转义、`.`、`[]` / `[^]` 含区间、`\d \w \s \D \W \S`、`\b \B`、`^ $`、
//! 分组 `( )` / `(?: )` / `(?<name> )`、`|`、量词 `* + ? {n} {n,} {n,m}`（每个都能加 `?` 变惰性）。
//! 不支持前瞻/后顾与反向引用（与 CUI 一致）。
//!
//! 与 CUI 的差异（有意为之）：
//! - **按字节匹配**（CUI 同样以字节偏移报位置）：`.`、`\w`、`\s` 都是 ASCII 语义，
//!   对 UTF-8 文本做 `.` 会落在字节上 —— 搜索 ASCII 关键词没问题，按字符切 CJK 需上层处理；
//! - 无「正则测试器」控件（`cui_regex_tester_ex`）：那是一个组合界面，等编辑器族一起做。
const std = @import("std");

pub const CAP = 10;
pub const ICASE: u32 = 1;
pub const MULTILINE: u32 = 2;
pub const DOTALL: u32 = 4;

pub const Result = enum { found, none, invalid_pattern, too_slow };

pub const Match = struct {
    start: i32 = -1,
    end: i32 = -1,
    /// 模式里的捕获分组数（不含 `(?:` 与 `(?<name>` 也算捕获）。
    groups: usize = 0,
    /// 1 基；没参与匹配的为 -1。
    group_start: [CAP]i32 = @splat(-1),
    group_end: [CAP]i32 = @splat(-1),
    group_name: [CAP][24]u8 = @splat(@splat(0)),
};

/// 节点池上限（模式越复杂越吃；超出报 invalid_pattern）。
const MAX_NODES = 128;
/// 嵌套深度上限（分组 / 交替嵌套）。
const MAX_DEPTH = 8;
/// 单个量词最多展开的重复次数。
const MAX_REPEAT = 16;
/// 回溯步数上限（超出返回 too_slow）。
const MAX_STEPS = 200_000;

const Range = struct { lo: u32, hi: u32 };

const Kind = enum { lit, any, class, bol, eol, wordb, not_wordb, group, alt, repeat };

const Node = struct {
    kind: Kind,
    ch: u8 = 0,
    neg: bool = false,
    /// 字符类位图（ASCII 128 位 → 16 字节，这里给 32 字节以覆盖 0..255）。
    cls: [32]u8 = @splat(0),
    /// group / alt 的第一分支 / repeat 的循环体所在的节点区间 [a, b)。
    a: u32 = 0,
    b: u32 = 0,
    /// alt 的第二分支 [c, d)。
    c: u32 = 0,
    d: u32 = 0,
    min: u32 = 0,
    max: u32 = 0,
    lazy: bool = false,
    gidx: u8 = 0,
};

const Parser = struct {
    pat: []const u8,
    pos: usize = 0,
    nodes: [MAX_NODES]Node = undefined,
    n: u32 = 0,
    groups: usize = 0,
    names: [CAP][24]u8 = @splat(@splat(0)),
    err: []const u8 = "",

    fn fail(self: *Parser, msg: []const u8) error{Invalid} {
        if (self.err.len == 0) self.err = msg;
        return error.Invalid;
    }

    fn push(self: *Parser, nd: Node) error{Invalid}!u32 {
        if (self.n >= MAX_NODES) return self.fail("pattern too complex");
        self.nodes[self.n] = nd;
        self.n += 1;
        return self.n - 1;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.pat.len) self.pat[self.pos] else null;
    }

    /// 解析交替：seq ('|' seq)* —— 第一支放进 a/b，后续支链成嵌套 alt。
    fn parseAlt(self: *Parser, depth: usize) error{Invalid}!Range {
        if (depth > MAX_DEPTH) return self.fail("nesting too deep");
        const first = try self.parseSeq(depth);
        if (self.peek() != '|') return first;
        var cur = first;
        while (self.peek() == '|') {
            self.pos += 1;
            const next = try self.parseSeq(depth);
            const idx = try self.push(.{ .kind = .alt, .a = cur.lo, .b = cur.hi, .c = next.lo, .d = next.hi });
            cur = .{ .lo = idx, .hi = idx + 1 };
        }
        return cur;
    }

    fn parseSeq(self: *Parser, depth: usize) error{Invalid}!Range {
        const start = self.n;
        while (true) {
            const ch = self.peek() orelse break;
            if (ch == '|' or ch == ')') break;
            try self.parsePiece(depth);
        }
        return .{ .lo = start, .hi = self.n };
    }

    fn parsePiece(self: *Parser, depth: usize) error{Invalid}!void {
        // 先给 repeat 占位，再解析原子：这样序列里只有 repeat 一个节点，
        // 原子落在它自己的子区间 [a, b) 里。否则「原子」会被序列匹配一次、
        // 又被 repeat 匹配 N 次（`a{2,3}` 在 "aaaa" 会匹配 4 个字）。
        const slot = try self.push(.{ .kind = .repeat, .min = 1, .max = 1 });
        const atom = try self.parseAtom(depth);
        const atom_start = atom.lo;
        const atom_end = atom.hi;
        var min: u32 = 1;
        var max: u32 = 1;
        var lazy = false;
        const q = self.peek() orelse {
            self.nodes[slot] = .{ .kind = .repeat, .a = atom_start, .b = atom_end, .min = 1, .max = 1 };
            return;
        };
        switch (q) {
            '*' => {
                min = 0;
                max = std.math.maxInt(u32);
                self.pos += 1;
            },
            '+' => {
                min = 1;
                max = std.math.maxInt(u32);
                self.pos += 1;
            },
            '?' => {
                min = 0;
                max = 1;
                self.pos += 1;
            },
            '{' => {
                self.pos += 1;
                const lo = try self.parseNum();
                var hi: u32 = lo;
                if (self.peek() == ',') {
                    self.pos += 1;
                    if (self.peek() == '}') hi = std.math.maxInt(u32) else hi = try self.parseNum();
                }
                if (self.peek() != '}') return self.fail("unterminated {}");
                self.pos += 1;
                min = lo;
                max = hi;
            },
            else => {
                self.nodes[slot] = .{ .kind = .repeat, .a = atom_start, .b = atom_end, .min = 1, .max = 1 };
                return;
            },
        }
        if (self.peek() == '?') {
            lazy = true;
            self.pos += 1;
        }
        self.nodes[slot] = .{ .kind = .repeat, .a = atom_start, .b = atom_end, .min = min, .max = max, .lazy = lazy };
    }

    fn parseNum(self: *Parser) error{Invalid}!u32 {
        var v: u32 = 0;
        var any = false;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            v = v * 10 + (c - '0');
            if (v > 10_000) return self.fail("count too large");
            any = true;
            self.pos += 1;
        }
        if (!any) return self.fail("expected a number");
        return v;
    }

    fn parseAtom(self: *Parser, depth: usize) error{Invalid}!Range {
        const c = self.peek() orelse return self.fail("unexpected end");
        switch (c) {
            '(' => {
                self.pos += 1;
                var gidx: u8 = 0;
                if (self.peek() == '?') {
                    self.pos += 1;
                    if (self.peek() == ':') {
                        self.pos += 1;
                    } else if (self.peek() == '<') {
                        self.pos += 1;
                        const name_start = self.pos;
                        while (self.peek()) |x| {
                            if (x == '>') break;
                            self.pos += 1;
                        }
                        if (self.peek() != '>') return self.fail("unterminated group name");
                        const name = self.pat[name_start..self.pos];
                        self.pos += 1;
                        if (self.groups >= CAP) return self.fail("too many groups");
                        self.groups += 1;
                        gidx = @intCast(self.groups);
                        const take = @min(name.len, 23);
                        @memcpy(self.names[gidx - 1][0..take], name[0..take]);
                    } else return self.fail("unsupported (?");
                } else {
                    if (self.groups >= CAP) return self.fail("too many groups");
                    self.groups += 1;
                    gidx = @intCast(self.groups);
                }
                const inner = try self.parseAlt(depth + 1);
                if (self.peek() != ')') return self.fail("unterminated group");
                self.pos += 1;
                const gi = try self.push(.{ .kind = .group, .a = inner.lo, .b = inner.hi, .gidx = gidx });
                return .{ .lo = gi, .hi = gi + 1 };
            },
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                const i = try self.push(.{ .kind = .any });
                return .{ .lo = i, .hi = i + 1 };
            },
            '^' => {
                self.pos += 1;
                const i = try self.push(.{ .kind = .bol });
                return .{ .lo = i, .hi = i + 1 };
            },
            '$' => {
                self.pos += 1;
                const i = try self.push(.{ .kind = .eol });
                return .{ .lo = i, .hi = i + 1 };
            },
            '\\' => return self.parseEscape(),
            else => {
                self.pos += 1;
                const i = try self.push(.{ .kind = .lit, .ch = c });
                return .{ .lo = i, .hi = i + 1 };
            },
        }
    }

    fn setBit(nd: *Node, c: u8) void {
        nd.cls[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
    }

    fn setRange(nd: *Node, lo: u8, hi: u8) void {
        var c: u16 = lo;
        while (c <= hi) : (c += 1) setBit(nd, @intCast(c));
    }

    fn parseEscape(self: *Parser) error{Invalid}!Range {
        self.pos += 1;
        const c = self.peek() orelse return self.fail("trailing backslash");
        self.pos += 1;
        switch (c) {
            'd' => {
                var nd = Node{ .kind = .class };
                setRange(&nd, '0', '9');
                const i = try self.push(nd);
                return .{ .lo = i, .hi = i + 1 };
            },
            'D' => {
                var nd = Node{ .kind = .class, .neg = true };
                setRange(&nd, '0', '9');
                const i = try self.push(nd);
                return .{ .lo = i, .hi = i + 1 };
            },
            'w' => {
                var nd = Node{ .kind = .class };
                setRange(&nd, 'a', 'z');
                setRange(&nd, 'A', 'Z');
                setRange(&nd, '0', '9');
                setBit(&nd, '_');
                const i = try self.push(nd);
                return .{ .lo = i, .hi = i + 1 };
            },
            'W' => {
                var nd = Node{ .kind = .class, .neg = true };
                setRange(&nd, 'a', 'z');
                setRange(&nd, 'A', 'Z');
                setRange(&nd, '0', '9');
                setBit(&nd, '_');
                const i = try self.push(nd);
                return .{ .lo = i, .hi = i + 1 };
            },
            's' => {
                var nd = Node{ .kind = .class };
                setBit(&nd, ' ');
                setBit(&nd, '\t');
                setBit(&nd, '\n');
                setBit(&nd, '\r');
                setBit(&nd, 0x0b);
                setBit(&nd, 0x0c);
                const i = try self.push(nd);
                return .{ .lo = i, .hi = i + 1 };
            },
            'S' => {
                var nd = Node{ .kind = .class, .neg = true };
                setBit(&nd, ' ');
                setBit(&nd, '\t');
                setBit(&nd, '\n');
                setBit(&nd, '\r');
                setBit(&nd, 0x0b);
                setBit(&nd, 0x0c);
                const i = try self.push(nd);
                return .{ .lo = i, .hi = i + 1 };
            },
            'b' => {
                const i = try self.push(.{ .kind = .wordb });
                return .{ .lo = i, .hi = i + 1 };
            },
            'B' => {
                const i = try self.push(.{ .kind = .not_wordb });
                return .{ .lo = i, .hi = i + 1 };
            },
            'n' => {
                const i = try self.push(.{ .kind = .lit, .ch = '\n' });
                return .{ .lo = i, .hi = i + 1 };
            },
            't' => {
                const i = try self.push(.{ .kind = .lit, .ch = '\t' });
                return .{ .lo = i, .hi = i + 1 };
            },
            'r' => {
                const i = try self.push(.{ .kind = .lit, .ch = '\r' });
                return .{ .lo = i, .hi = i + 1 };
            },
            else => {
                const i = try self.push(.{ .kind = .lit, .ch = c });
                return .{ .lo = i, .hi = i + 1 };
            },
        }
    }

    fn parseClass(self: *Parser) error{Invalid}!Range {
        self.pos += 1; // '['
        var nd = Node{ .kind = .class };
        if (self.peek() == '^') {
            nd.neg = true;
            self.pos += 1;
        }
        var first = true;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated []");
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            var lo: u8 = 0;
            if (c == '\\') {
                self.pos += 1;
                const e = self.peek() orelse return self.fail("trailing backslash");
                self.pos += 1;
                switch (e) {
                    'd' => {
                        setRange(&nd, '0', '9');
                        continue;
                    },
                    'w' => {
                        setRange(&nd, 'a', 'z');
                        setRange(&nd, 'A', 'Z');
                        setRange(&nd, '0', '9');
                        setBit(&nd, '_');
                        continue;
                    },
                    's' => {
                        setBit(&nd, ' ');
                        setBit(&nd, '\t');
                        setBit(&nd, '\n');
                        setBit(&nd, '\r');
                        continue;
                    },
                    'n' => lo = '\n',
                    't' => lo = '\t',
                    'r' => lo = '\r',
                    else => lo = e,
                }
            } else {
                self.pos += 1;
                lo = c;
            }
            // 区间 a-z（`-` 在末尾时按字面量）
            if (self.peek() == '-' and self.pos + 1 < self.pat.len and self.pat[self.pos + 1] != ']') {
                self.pos += 1;
                const hi = self.pat[self.pos];
                self.pos += 1;
                setRange(&nd, lo, hi);
            } else {
                setBit(&nd, lo);
            }
        }
        const i = try self.push(nd);
        return .{ .lo = i, .hi = i + 1 };
    }
};

fn classBit(nd: Node, c: u8) bool {
    return nd.cls[c >> 3] & (@as(u8, 1) << @intCast(c & 7)) != 0;
}

const Matcher = struct {
    nodes: []const Node,
    text: []const u8,
    flags: u32,
    caps: [CAP * 2]i32 = @splat(-1),
    steps: usize = 0,
    timed_out: bool = false,

    fn lower(self: *const Matcher, c: u8) u8 {
        if (self.flags & ICASE == 0) return c;
        return std.ascii.toLower(c);
    }

    fn isWord(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    /// 匹配节点区间 [lo, hi) 于 pos，成功返回结束位置。
    fn run(self: *Matcher, lo: u32, hi: u32, pos: usize) ?usize {
        if (lo >= hi) return pos;
        return self.one(lo, hi, pos);
    }

    fn one(self: *Matcher, i: u32, hi: u32, pos: usize) ?usize {
        self.steps += 1;
        if (self.steps > MAX_STEPS) {
            self.timed_out = true;
            return null;
        }
        const nd = self.nodes[i];
        switch (nd.kind) {
            .lit => {
                if (pos >= self.text.len) return null;
                if (self.lower(self.text[pos]) != self.lower(nd.ch)) return null;
                return self.run(i + 1, hi, pos + 1);
            },
            .any => {
                if (pos >= self.text.len) return null;
                if (self.text[pos] == '\n' and self.flags & DOTALL == 0) return null;
                return self.run(i + 1, hi, pos + 1);
            },
            .class => {
                if (pos >= self.text.len) return null;
                const c = self.lower(self.text[pos]);
                const hit = blk: {
                    if (self.flags & ICASE != 0) {
                        const lo_c = std.ascii.toLower(self.text[pos]);
                        const up_c = std.ascii.toUpper(self.text[pos]);
                        break :blk classBit(nd, lo_c) or classBit(nd, up_c);
                    }
                    break :blk classBit(nd, c);
                };
                if (hit == nd.neg) return null;
                return self.run(i + 1, hi, pos + 1);
            },
            .bol => {
                if (pos == 0) return self.run(i + 1, hi, pos);
                if (self.flags & MULTILINE != 0 and self.text[pos - 1] == '\n') return self.run(i + 1, hi, pos);
                return null;
            },
            .eol => {
                if (pos >= self.text.len) return self.run(i + 1, hi, pos);
                if (self.text[pos] == '\n') {
                    if (self.flags & MULTILINE != 0) return self.run(i + 1, hi, pos);
                    return null;
                }
                return null;
            },
            .wordb, .not_wordb => {
                const before = pos > 0 and isWord(self.text[pos - 1]);
                const after = pos < self.text.len and isWord(self.text[pos]);
                const b = before != after;
                if (b != (nd.kind == .wordb)) return null;
                return self.run(i + 1, hi, pos);
            },
            .group => {
                const slot: usize = if (nd.gidx == 0) 0 else @as(usize, nd.gidx) * 2 - 2;
                const save_s = self.caps[slot];
                const save_e = self.caps[slot + 1];
                if (nd.gidx != 0) self.caps[slot] = @intCast(pos);
                if (self.run(nd.a, nd.b, pos)) |e| {
                    if (nd.gidx != 0) self.caps[slot + 1] = @intCast(e);
                    if (self.run(i + 1, hi, e)) |e2| return e2;
                }
                if (nd.gidx != 0) {
                    self.caps[slot] = save_s;
                    self.caps[slot + 1] = save_e;
                }
                return null;
            },
            .alt => {
                if (self.run(nd.a, nd.b, pos)) |e| {
                    if (self.run(i + 1, hi, e)) |e2| return e2;
                }
                return self.run(nd.c, nd.d, pos);
            },
            .repeat => return self.rep(nd, hi, pos),
        }
    }

    fn rep(self: *Matcher, nd: Node, hi: u32, pos: usize) ?usize {
        var positions: [MAX_REPEAT + 1]usize = undefined;
        positions[0] = pos;
        var count: usize = 0;
        const max = @min(nd.max, MAX_REPEAT);
        while (count < max) {
            const np = self.run(nd.a, nd.b, positions[count]) orelse break;
            if (np == positions[count]) {
                // 零宽匹配（`^` `$` `\b` 这类）：**算一次成功**但不能继续循环，
                // 否则死循环。之前这里直接 break，导致零宽断言在 repeat 包装里恒失败。
                count += 1;
                positions[count] = np;
                break;
            }
            count += 1;
            positions[count] = np;
        }
        if (count < nd.min) return null;
        // 序列里的「下一个」是原子区间之后（nd.b），不是 i+1 ——
        // repeat 节点在原子**之前**占位，i+1 指向的是原子本身。
        if (nd.lazy) {
            var k: usize = nd.min;
            while (k <= count) : (k += 1) {
                if (self.run(nd.b, hi, positions[k])) |e| return e;
            }
        } else {
            var k: usize = count;
            while (true) {
                if (k >= nd.min) {
                    if (self.run(nd.b, hi, positions[k])) |e| return e;
                }
                if (k == nd.min) break;
                k -= 1;
            }
        }
        return null;
    }
};

fn compile(pat: []const u8, err: ?*[]const u8) ?struct { nodes: [MAX_NODES]Node, lo: u32, hi: u32, groups: usize, names: [CAP][24]u8 } {
    var p = Parser{ .pat = pat };
    const root = p.parseAlt(0) catch {
        if (err) |e| e.* = if (p.err.len > 0) p.err else "invalid pattern";
        return null;
    };
    if (p.pos < pat.len) {
        if (err) |e| e.* = "unexpected ')' or '+'";
        return null;
    }
    return .{ .nodes = p.nodes, .lo = root.lo, .hi = root.hi, .groups = p.groups, .names = p.names };
}

/// 从 `from` 起找第一个匹配。返回 1 找到 / 0 没有 / -1 模式非法 / -2 步数超限。
pub fn search(pat: []const u8, flags: u32, text: []const u8, from: usize, m: *Match, err: ?*[]const u8) Result {
    const prog = compile(pat, err) orelse return .invalid_pattern;
    m.* = .{ .groups = prog.groups, .group_name = prog.names, .group_start = @splat(-1), .group_end = @splat(-1) };

    var start = @min(from, text.len);
    while (start <= text.len) : (start += 1) {
        var mm = Matcher{ .nodes = prog.nodes[0..prog.hi], .text = text, .flags = flags };
        if (mm.run(prog.lo, prog.hi, start)) |e| {
            m.start = @intCast(start);
            m.end = @intCast(e);
            var k: usize = 0;
            while (k < CAP) : (k += 1) {
                m.group_start[k] = mm.caps[k * 2];
                m.group_end[k] = mm.caps[k * 2 + 1];
            }
            return .found;
        }
        if (mm.timed_out) {
            if (err) |e| e.* = "too many steps";
            return .too_slow;
        }
    }
    return .none;
}
