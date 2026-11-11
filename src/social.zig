//! 会话族（对位 CUI `cui_social.c`）：聊天气泡 / 日期分隔 / 正在输入 / 评论串 / 在线头像组。
//!
//! 五个都是「流式排版的呈现件」：调用方按顺序调用即可，状态（评论串的连接线、
//! 在线头像的展开）由调用方持有的结构体保存，组件本身不分配。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **没有逐角圆角**：框架的圆角是单值，气泡四角同半径（CUI 有 `(big, big, big, small)`）；
//! - **没有逐节点透明度/位移**：新消息不做淡入 + 上浮动画（框架只插值颜色）；
//! - **在线头像组不做弹簧展开**：悬停时直接切到展开间距，不做过渡；
//! - 评论的「点赞/回复」用 `widgets.button` 的 ghost 变体（高 36），不是 CUI 的小号图标按钮；
//! - 聊天气泡的 markdown 走固定宽度（不 hug content），首帧高度用估算、第二帧起用真高。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const widgets = @import("widgets.zig");
const markdown = @import("markdown.zig");

pub const ChatOpts = struct {
    /// 自己的消息：右对齐 + 强调色气泡。
    mine: bool = false,
    /// 一组消息里第一条显示作者名与时间。
    author: []const u8 = "",
    time: []const u8 = "",
    /// 自己的最后一条下面那行（"Read"）。
    status: []const u8 = "",
    /// 接在同一个人上一条消息后面。
    grouped: bool = false,
    /// 一组里的最后一条（决定头像与状态行画不画）。
    last_in_group: bool = true,
    /// 用 markdown 渲染气泡内容（固定最大宽度）。
    markdown: bool = false,
    /// 气泡最大宽度（0 = 480）。
    max_width: f32 = 480,
};

/// 名字的首字（UTF-8 安全）：头像里用。
pub fn initials(buf: []u8, name: []const u8) []const u8 {
    if (name.len == 0) {
        buf[0] = '?';
        return buf[0..1];
    }
    var e = firstCharLen(name);
    // 有空格就取第一个词的首字（"Ada Lovelace" → "A"）
    if (std.mem.indexOfScalar(u8, name, ' ')) |sp| {
        const head = name[0..sp];
        if (head.len > 0) e = firstCharLen(head);
    }
    const n = @min(e, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    // ASCII 小写转大写（中文原样）
    if (n == 1 and buf[0] >= 'a' and buf[0] <= 'z') buf[0] -= 32;
    return buf[0..n];
}

fn firstCharLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n: usize = 1;
    while (n < s.len and (s[n] & 0xC0) == 0x80) n += 1;
    return n;
}

/// 圆形头像（无图时画首字）。返回占用的矩形。
pub fn avatar(ui: *core.Context, name: []const u8, size: f32, tint: ?t.Color) t.Rect {
    const rect = ui.reserve(size, size, false);
    const bg = tint orelse theme.accent_bg;
    ui.addBox(rect, .{ .fill = bg, .radius = size * 0.5 });
    var buf: [8]u8 = undefined;
    // 局部缓冲的 slice 必须在帧内拷贝：addText 不拷贝，绘制时 buf 已经失效
    const ini = ui.frameStr(initials(buf[0..], name));
    const m = ui.measureText(ini, size * 0.42);
    // 文本节点按给定宽度裁切：留 6pt 余量，否则首字会被裁成一条竖线
    ui.addText(.{
        .x = rect.x + (size - m.w) / 2 - 2,
        .y = rect.y + (size - m.h) / 2,
        .w = m.w + 6,
        .h = m.h,
    }, ini, size * 0.42, tintForeground(bg));
    return rect;
}

/// 与底色成对的前景色（深色底用浅字，浅色底用深字）。
fn tintForeground(bg: t.Color) t.Color {
    const lum: u32 = @as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114;
    return if (lum > 140000) t.Color.hex(0x18181b, 255) else t.Color.hex(0xfafafa, 255);
}

/// 气泡底色：自己的用强调色，别人的用面板色（深色主题下提亮一档）。
fn bubbleFill(mine: bool) t.Color {
    if (mine) return theme.accent;
    return if (theme.isDark()) theme.raised else theme.track;
}

/// 一条聊天消息。
pub fn chatMessage(ui: *core.Context, text: []const u8, opts: ChatOpts) void {
    const frame = &ui.stack[ui.depth - 1];
    const avail = if (frame.width > 0) frame.width else 480;
    const size = theme.font_body;
    const line_h = size * 1.45;
    const max_w = if (opts.max_width > 0) opts.max_width else 480;
    const inner_w = @max(80, @min(max_w, avail * 0.72) - 26);

    var lines: [core.MAX_LINES][]const u8 = undefined;
    const n = core.wrapText(ui, text, size, inner_w, &lines);
    var text_w: f32 = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) text_w = @max(text_w, ui.measureText(lines[k], size).w);

    const head_h: f32 = if (!opts.grouped and !opts.mine and (opts.author.len > 0 or opts.time.len > 0)) 18 else 0;
    const bubble_h = @as(f32, @floatFromInt(n)) * line_h + 16;
    const status_h: f32 = if (opts.mine and opts.status.len > 0 and (opts.last_in_group or !opts.grouped)) 16 else 0;
    const av_size: f32 = 28;
    const gap: f32 = 8;
    const row_h = head_h + bubble_h + status_h + (if (opts.grouped) @as(f32, 2) else @as(f32, 10));

    const rect = ui.reserve(avail, row_h, true);
    var y = rect.y + (if (opts.grouped) @as(f32, 2) else @as(f32, 10));
    const bubble_w = @min(inner_w, text_w) + 26;
    const mine = opts.mine;

    // 头像（别人的消息，且是本组最后一条时画）
    if (!mine) {
        if (!opts.grouped or opts.last_in_group) {
            _ = avatarAt(ui, rect.x, y + head_h + bubble_h - av_size, av_size, opts.author, null);
        }
        if (head_h > 0) {
            var hx = rect.x + av_size + gap;
            if (opts.author.len > 0) {
                ui.addRichText(.{ .x = hx, .y = y, .w = ui.measureText(opts.author, theme.font_small).w + 8, .h = 16 }, opts.author, theme.font_small, theme.secondary, true, false);
                hx += ui.measureText(opts.author, theme.font_small).w + 6;
            }
            if (opts.time.len > 0) {
                ui.addText(.{ .x = hx, .y = y + 1, .w = ui.measureText(opts.time, theme.font_small).w + 2, .h = 16 }, opts.time, theme.font_small, theme.secondary);
            }
            y += head_h;
        }
    }

    const bx = if (mine) rect.x + rect.w - bubble_w else rect.x + av_size + gap;
    const bubble = t.Rect{ .x = bx, .y = y, .w = bubble_w, .h = bubble_h };
    ui.addBox(bubble, .{ .fill = bubbleFill(mine), .radius = 16 });
    const fg = if (mine) theme.accent_text else theme.text;
    if (opts.markdown) {
        var pan = ui.panel(.{ .x = bubble.x + 13, .y = bubble.y + 8, .w = bubble.w - 26, .h = bubble.h - 16 }, .{});
        defer pan.end();
        _ = markdown.markdown(ui, "chat-md", text, .{});
    } else {
        var ly = bubble.y + 8;
        k = 0;
        while (k < n) : (k += 1) {
            ui.addText(.{ .x = bubble.x + 13, .y = ly, .w = bubble.w - 20, .h = line_h }, lines[k], size, fg);
            ly += line_h;
        }
    }

    if (status_h > 0) {
        const label = if (opts.time.len > 0) ui.frameStr(joinStatus(ui, opts.status, opts.time)) else opts.status;
        const tw = ui.measureText(label, theme.font_small).w;
        ui.addText(.{ .x = bubble.x + bubble.w - tw, .y = bubble.y + bubble.h + 3, .w = tw + 2, .h = 14 }, label, theme.font_small, theme.secondary);
    }
}

fn joinStatus(ui: *core.Context, status: []const u8, time: []const u8) []const u8 {
    var buf: [96]u8 = undefined;
    var n: usize = 0;
    const a = @min(status.len, 48);
    @memcpy(buf[0..a], status[0..a]);
    n = a;
    if (n + 1 < buf.len) {
        buf[n] = ' ';
        n += 1;
    }
    const b = @min(time.len, buf.len - n);
    @memcpy(buf[n .. n + b], time[0..b]);
    n += b;
    return ui.frameStr(buf[0..n]);
}

/// 在给定位置画头像（不参与流式布局）。
fn avatarAt(ui: *core.Context, x: f32, y: f32, size: f32, name: []const u8, tint: ?t.Color) t.Rect {
    const rect = t.Rect{ .x = x, .y = y, .w = size, .h = size };
    const bg = tint orelse theme.accent_bg;
    ui.addBox(rect, .{ .fill = bg, .radius = size * 0.5 });
    var buf: [8]u8 = undefined;
    // 局部缓冲的 slice 必须在帧内拷贝：addText 不拷贝，绘制时 buf 已经失效
    const ini = ui.frameStr(initials(buf[0..], name));
    const m = ui.measureText(ini, size * 0.42);
    ui.addText(.{ .x = rect.x + (size - m.w) / 2 - 2, .y = rect.y + (size - m.h) / 2, .w = m.w + 6, .h = m.h }, ini, size * 0.42, tintForeground(bg));
    return rect;
}

/// 「今天」这类日期分隔：两侧细线 + 中间小字。
pub fn chatDivider(ui: *core.Context, label: []const u8) void {
    const frame = &ui.stack[ui.depth - 1];
    const avail = if (frame.width > 0) frame.width else 480;
    const rect = ui.reserve(avail, 28, true);
    const tw = ui.measureText(label, theme.font_small).w;
    const cx = rect.x + rect.w / 2;
    const ly = rect.y + rect.h / 2;
    ui.addOverlayLine(.{ .x = rect.x + 8, .y = ly }, .{ .x = cx - tw / 2 - 10, .y = ly }, 1, theme.border);
    ui.addOverlayLine(.{ .x = cx + tw / 2 + 10, .y = ly }, .{ .x = rect.x + rect.w - 8, .y = ly }, 1, theme.border);
    ui.addText(.{ .x = cx - tw / 2, .y = rect.y, .w = tw + 2, .h = rect.h }, label, theme.font_small, theme.secondary);
}

/// 正在输入：头像 + 三个上下跳动的圆点 + "N is typing"。
pub fn typingIndicator(ui: *core.Context, name: []const u8) void {
    const frame = &ui.stack[ui.depth - 1];
    const avail = if (frame.width > 0) frame.width else 480;
    const rect = ui.reserve(avail, 44, true);
    const av = avatarAt(ui, rect.x, rect.y + 8, 28, name, null);
    const bubble = t.Rect{ .x = av.x + av.w + 8, .y = rect.y + 8, .w = 52, .h = 28 };
    ui.addBox(bubble, .{ .fill = bubbleFill(false), .radius = 16 });
    // 三个点：相位错开，随时间上下浮动（颜色逐帧变 → 需要 requestFrame）
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const ph: f32 = @floatCast(@as(f64, ui.time) * 7.0 - @as(f64, @floatFromInt(k)) * 0.7);
        const b = 0.5 + 0.5 * @sin(ph);
        const cy = bubble.y + bubble.h * 0.5 - b * 3.0;
        ui.addBox(.{ .x = bubble.x + 12 + @as(f32, @floatFromInt(k)) * 9, .y = cy - 3, .w = 6, .h = 6 }, .{
            .fill = theme.withAlpha(theme.secondary, @intFromFloat(115 + 140 * b)),
            .radius = 3,
        });
    }
    if (name.len > 0) {
        const label = ui.frameStr(joinTyping(ui, name));
        ui.addText(.{ .x = av.x + av.w + 8, .y = bubble.y + bubble.h + 2, .w = ui.measureText(label, theme.font_small).w + 2, .h = 14 }, label, theme.font_small, theme.secondary);
    }
    ui.requestFrame();
}

fn joinTyping(ui: *core.Context, name: []const u8) []const u8 {
    var buf: [80]u8 = undefined;
    const n = @min(name.len, 56);
    @memcpy(buf[0..n], name[0..n]);
    const tail = " is typing";
    @memcpy(buf[n .. n + tail.len], tail);
    return ui.frameStr(buf[0 .. n + tail.len]);
}

// ====================================================================== 评论

pub const COMMENT_LIKE: u8 = 1;
pub const COMMENT_REPLY: u8 = 2;

pub const CommentOpts = struct {
    time: []const u8 = "",
    /// 0 = 顶层，1+ = 回复（缩进 + 连接线）。
    depth: i32 = 0,
    likes: ?*i32 = null,
    liked: ?*bool = null,
    edited: bool = false,
    /// 作者名后的徽标（"Author"）。
    badge: []const u8 = "",
};

/// 评论串的跨帧状态（连接线的起点）。
pub const CommentState = struct {
    /// 每个深度的头像底部 y（按绘制顺序写入）。
    rail_bottom: [8]f32 = @splat(0),
};

/// 一条评论（可带回复）。返回 `COMMENT_LIKE` / `COMMENT_REPLY` 位组合。
pub fn comment(
    ui: *core.Context,
    id: []const u8,
    author: []const u8,
    text: []const u8,
    st: *CommentState,
    opts: CommentOpts,
) u8 {
    const frame = &ui.stack[ui.depth - 1];
    const avail = if (frame.width > 0) frame.width else 480;
    const depth: usize = @intCast(std.math.clamp(opts.depth, 0, 7));
    const indent: f32 = 44 * @as(f32, @floatFromInt(depth));
    const av_size: f32 = if (depth > 0) 28 else 34;
    const size = theme.font_body;
    const line_h = size * 1.5;
    const text_x = indent + av_size + 12;
    const text_w = @max(120, avail - text_x - 8);

    var lines: [core.MAX_LINES][]const u8 = undefined;
    const n = core.wrapText(ui, text, size, text_w, &lines);
    const head_h: f32 = 20;
    const body_h = @as(f32, @floatFromInt(n)) * line_h;
    const actions_h: f32 = 38;
    const row_h = head_h + body_h + actions_h + 12;

    const rect = ui.reserve(avail, row_h, true);
    // ---- 连接线（从上一条同深度的头像往下，再拐进本条头像）
    if (depth > 0 and depth < 8) {
        const mid = rect.y + 6 + av_size * 0.5;
        const px = rect.x + (indent - 44) + (if (depth > 1) @as(f32, 14.0) else @as(f32, 17.0));
        const top = @min(st.rail_bottom[depth - 1] + 6, mid - 8);
        if (mid - 8 > top) ui.addOverlayLine(.{ .x = px, .y = top }, .{ .x = px, .y = mid - 8 }, 1.5, theme.border);
        // 拐角：水平段接过竖直段（框架没有圆弧通道）
        const hx = px + 8;
        ui.addOverlayLine(.{ .x = px, .y = mid }, .{ .x = hx, .y = mid }, 1.5, theme.border);
        const end = rect.x + indent - 6;
        if (end > hx) ui.addOverlayLine(.{ .x = hx, .y = mid }, .{ .x = end, .y = mid }, 1.5, theme.border);
    }
    if (depth < 8) st.rail_bottom[depth] = rect.y + 6 + av_size;

    // ---- 头像
    _ = avatarAt(ui, rect.x + indent, rect.y + 6, av_size, author, null);
    // ---- 头部：作者 + 徽标 + 时间
    var hx = rect.x + text_x;
    const hy = rect.y + 4;
    ui.addRichText(.{ .x = hx, .y = hy, .w = ui.measureText(author, theme.font_small).w + 8, .h = 18 }, author, theme.font_small, theme.text, true, false);
    hx += ui.measureText(author, theme.font_small).w + 8;
    if (opts.badge.len > 0) {
        const bw = ui.measureText(opts.badge, theme.font_small).w;
        ui.addBox(.{ .x = hx, .y = hy + 1, .w = bw + 10, .h = 16 }, .{ .fill = theme.accent_bg, .radius = 8 });
        ui.addText(.{ .x = hx + 5, .y = hy + 2, .w = bw + 2, .h = 14 }, opts.badge, theme.font_small, theme.accent);
        hx += bw + 16;
    }
    if (opts.time.len > 0) {
        const label = if (opts.edited) ui.frameStr(joinEdited(ui, opts.time)) else opts.time;
        ui.addText(.{ .x = hx, .y = hy + 1, .w = ui.measureText(label, theme.font_small).w + 2, .h = 16 }, label, theme.font_small, theme.secondary);
    }

    // ---- 正文
    var ly = rect.y + head_h + 4;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        ui.addText(.{ .x = rect.x + text_x, .y = ly, .w = text_w, .h = line_h }, lines[k], size, theme.text);
        ly += line_h;
    }

    // ---- 操作行：点赞（带计数）+ 回复
    var res: u8 = 0;
    {
        var row = ui.panel(.{
            .x = rect.x + text_x - 12,
            .y = rect.y + head_h + 4 + body_h + 4,
            .w = text_w + 20,
            .h = actions_h - 4,
        }, .{ .dir = .row, .gap = 4 });
        defer row.end();
        const liked = if (opts.liked) |p| p.* else false;
        var lb: [32]u8 = undefined;
        const ld = numLike(lb[0..], if (opts.likes) |p| p.* else 0);
        const heart = if (liked) "♥ " else "♡ ";
        const like_label = ui.frameStr(joinLike(ui, heart, ld));
        if (widgets.button(ui, like_label, .{ .variant = .ghost, .id_salt = core.Context.idOf(id) ^ 0x11 })) {
            res |= COMMENT_LIKE;
            if (opts.liked) |p| p.* = !p.*;
            if (opts.likes) |p| p.* += if (if (opts.liked) |q| q.* else false) @as(i32, 1) else -1;
        }
        if (widgets.button(ui, "Reply", .{ .variant = .ghost, .id_salt = core.Context.idOf(id) ^ 0x12 })) res |= COMMENT_REPLY;
    }
    return res;
}

fn joinEdited(ui: *core.Context, time: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    const n = @min(time.len, 48);
    @memcpy(buf[0..n], time[0..n]);
    const tail = " · edited";
    @memcpy(buf[n .. n + tail.len], tail);
    return ui.frameStr(buf[0 .. n + tail.len]);
}

fn numLike(buf: []u8, v: i32) []const u8 {
    var tmp: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(tmp[0..], "{d}", .{v}) catch "0";
    const n = @min(digits.len, buf.len);
    @memcpy(buf[0..n], digits[0..n]);
    return buf[0..n];
}

fn joinLike(ui: *core.Context, heart: []const u8, digits: []const u8) []const u8 {
    var buf: [40]u8 = undefined;
    var n: usize = 0;
    @memcpy(buf[n .. n + heart.len], heart);
    n += heart.len;
    @memcpy(buf[n .. n + digits.len], digits);
    n += digits.len;
    return ui.frameStr(buf[0..n]);
}

// ====================================================================== 在线状态

pub const PresenceUser = struct {
    name: []const u8 = "",
    /// 圆环颜色；null = 强调色。
    color: ?t.Color = null,
    idle: bool = false,
};

/// 在线头像组的跨帧状态。
pub const PresenceState = struct {
    hover: bool = false,
};

/// 在线头像组：默认叠在一起，悬停时展开并显示名字。
pub fn presence(
    ui: *core.Context,
    id: []const u8,
    users: []const PresenceUser,
    max_visible: usize,
    size: f32,
    st: *PresenceState,
) void {
    if (users.len == 0) return;
    const s: f32 = if (size > 0) size else 30;
    const ring: f32 = 2;
    const outer = s + ring * 2 + 2;
    const shown = @min(users.len, if (max_visible > 0) max_visible else 5);
    const extra = users.len > shown;
    const count: f32 = @floatFromInt(shown + @as(usize, if (extra) 1 else 0));
    // 叠在一起时 -outer*0.24 的负间距（框架的 gap 不能为负 → 用绝对坐标算）
    const frame = &ui.stack[ui.depth - 1];
    const avail = if (frame.width > 0) frame.width else outer * count;
    const overlap: f32 = outer * 0.24;
    const spread: f32 = if (st.hover) outer + 4 else outer - overlap;
    const total = outer + (count - 1) * spread;
    const rect = ui.reserve(avail, outer, false);
    const hit = ui.interact(core.Context.idOf(id) ^ 0x9A17, .{ .x = rect.x, .y = rect.y, .w = @min(total, avail), .h = outer });
    st.hover = hit.hover;

    var k: usize = 0;
    while (k < shown) : (k += 1) {
        const u = users[k];
        const x = rect.x + @as(f32, @floatFromInt(k)) * spread;
        // 外圈：底色切开与邻居的叠压，再套一层彩色圆环
        ui.addBox(.{ .x = x, .y = rect.y, .w = outer, .h = outer }, .{ .fill = theme.bg, .radius = outer * 0.5 });
        const ringc = u.color orelse theme.accent;
        ui.addBox(.{ .x = x + 1, .y = rect.y + 1, .w = outer - 2, .h = outer - 2 }, .{ .border = if (u.idle) theme.secondary else ringc, .radius = (outer - 2) * 0.5 });
        const av = t.Rect{ .x = x + 1 + ring, .y = rect.y + 1 + ring, .w = s, .h = s };
        const bg = if (u.idle) theme.track else (u.color orelse theme.accent_bg);
        ui.addBox(av, .{ .fill = theme.withAlpha(bg, if (u.idle) 140 else 255), .radius = s * 0.5 });
        var buf: [8]u8 = undefined;
        const ini = ui.frameStr(initials(buf[0..], u.name));
        const m = ui.measureText(ini, s * 0.42);
        ui.addText(.{ .x = av.x + (s - m.w) / 2 - 2, .y = av.y + (s - m.h) / 2, .w = m.w + 6, .h = m.h }, ini, s * 0.42, tintForeground(bg));
    }
    if (extra) {
        const x = rect.x + @as(f32, @floatFromInt(shown)) * spread;
        ui.addBox(.{ .x = x, .y = rect.y, .w = outer, .h = outer }, .{ .fill = theme.bg, .radius = outer * 0.5 });
        ui.addBox(.{ .x = x + 1, .y = rect.y + 1, .w = outer - 2, .h = outer - 2 }, .{ .fill = theme.track, .radius = (outer - 2) * 0.5 });
        var buf: [8]u8 = undefined;
        const label = ui.frameStr(numPlus(buf[0..], users.len - shown));
        const m = ui.measureText(label, s * 0.36);
        ui.addText(.{ .x = x + (outer - m.w) / 2, .y = rect.y + (outer - m.h) / 2, .w = m.w + 2, .h = m.h }, label, s * 0.36, theme.secondary);
    }
    // 悬停时说明是谁
    if (st.hover) {
        var names: [128]u8 = undefined;
        const label = ui.frameStr(joinNames(names[0..], users));
        ui.addText(.{ .x = rect.x, .y = rect.y + outer + 4, .w = avail, .h = 16 }, label, theme.font_small, theme.secondary);
    }
}

fn numPlus(buf: []u8, v: usize) []const u8 {
    var tmp: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(tmp[0..], "+{d}", .{v}) catch "+?";
    const n = @min(digits.len, buf.len);
    @memcpy(buf[0..n], digits[0..n]);
    return buf[0..n];
}

fn joinNames(buf: []u8, users: []const PresenceUser) []const u8 {
    var n: usize = 0;
    for (users, 0..) |u, k| {
        if (k > 0 and n + 2 <= buf.len) {
            buf[n] = ',';
            buf[n + 1] = ' ';
            n += 2;
        }
        const take = @min(u.name.len, buf.len - n);
        @memcpy(buf[n .. n + take], u.name[0..take]);
        n += take;
    }
    return buf[0..n];
}
