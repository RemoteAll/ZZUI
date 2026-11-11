//! 开发者面板（对位 CUI `cui_devpanels.c` 的 4 个控件 + 5 个 HTTP 辅助）：
//! 异常调用栈、请求栏、响应状态行、功能开关矩阵、API 浏览。
//!
//! 与 CUI 的差异（有意为之，写在这里免得下次当成 bug）：
//! - **方法不再弹菜单**：点方法胶囊**循环切换**（GET→POST→PUT→PATCH→DELETE→HEAD→OPTIONS），
//!   少一层浮层状态；调用方拿到 `changed` 自己决定要不要重发。
//! - **开关的灰度用预设循环**：点百分比徽标在 1/5/25/50/100 之间走，CUI 是滑杆 + 弹层。
//! - **复制走返回值**（`StackTraceResult.copy`）：核心层不碰系统剪贴板。
//! - `responseStatus` 的体积用 KB/MB 缩写，时间用 ms/s，与 CUI 文案同口径。
const std = @import("std");
const core = @import("core.zig");
const theme = @import("theme.zig");
const t = @import("types.zig");
const num = @import("num.zig");
const trace = @import("trace.zig");
const widgets = @import("widgets.zig");
const editor = @import("editor.zig");
const devviews = @import("devviews.zig");
const devtools = @import("devtools.zig");

pub const Tone = trace.Tone;

fn idOf(id: []const u8) u64 {
    return core.Context.idOf(id);
}

fn kk(key: u64, salt: u64, i: usize) u64 {
    return key ^ (salt +% @as(u64, @intCast(i)));
}

fn pad2(buf: []u8, v: u32) []const u8 {
    if (v < 10) {
        buf[0] = '0';
        const s = num.int(buf[1..], @intCast(v));
        return buf[0 .. 1 + s.len];
    }
    return num.int(buf, @intCast(v));
}

/// 小方框复选（开关）：返回本帧是否被点。
fn boxToggle(ui: *core.Context, key: u64, rect: t.Rect, on: bool) bool {
    const hit = ui.interactEx(key, rect, true);
    ui.addBox(rect, .{
        .fill = if (on) theme.accent else theme.surface,
        .radius = 4,
        .border = if (on) theme.accent else theme.border,
        .border_width = 1.5,
    });
    if (on) {
        ui.addBox(.{ .x = rect.x + 4, .y = rect.y + rect.h * 0.5, .w = 4, .h = 2 }, .{ .fill = theme.accent_text });
        ui.addBox(.{ .x = rect.x + 6, .y = rect.y + rect.h * 0.5 - 3, .w = 2, .h = 5 }, .{ .fill = theme.accent_text });
    }
    return hit.clicked;
}

/// 小号文字按钮（返回是否被点）。
fn textButton(ui: *core.Context, key: u64, rect: t.Rect, label: []const u8, primary: bool) bool {
    const hit = ui.interactEx(key, rect, true);
    ui.addBox(rect, .{
        .fill = if (primary) theme.accent else if (hit.hover) theme.track else theme.surface,
        .radius = 6,
        .border = if (primary) theme.accent else theme.border,
    });
    const c = if (primary) theme.accent_text else theme.text;
    ui.addText(.{ .x = rect.x + 10, .y = rect.y + (rect.h - 16) * 0.5, .w = @max(8, rect.w - 12), .h = 18 }, label, theme.font_small, c);
    return hit.clicked;
}

// =============================================================== HTTP 辅助

pub const Method = enum(u8) { get, post, put, patch, delete, head, options };

pub fn methodName(m: Method) []const u8 {
    return switch (m) {
        .get => "GET",
        .post => "POST",
        .put => "PUT",
        .patch => "PATCH",
        .delete => "DELETE",
        .head => "HEAD",
        .options => "OPTIONS",
    };
}

/// 循环切换（点击胶囊时用）。
pub fn nextMethod(m: Method) Method {
    return switch (m) {
        .get => .post,
        .post => .put,
        .put => .patch,
        .patch => .delete,
        .delete => .head,
        .head => .options,
        .options => .get,
    };
}

fn methodTone(m: Method) Tone {
    return switch (m) {
        .get => .info,
        .post => .success,
        .put, .patch => .warn,
        .delete => .danger,
        else => .neutral,
    };
}

/// 常见状态码的原因短语；不认识的返回空串。
pub fn httpReason(code: i32) []const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        418 => "I'm a teapot",
        422 => "Unprocessable Content",
        425 => "Too Early",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "",
    };
}

fn statusTone(code: i32) Tone {
    if (code <= 0) return .neutral;
    if (code < 200) return .info;
    if (code < 300) return .success;
    if (code < 400) return .info;
    if (code < 500) return .warn;
    return .danger;
}

/// 字节数缩写：`640 B` / `12.9 KB` / `3.4 MB`。
fn fmtBytes(buf: []u8, bytes: f64) []const u8 {
    if (bytes < 1024) {
        var tb: [8]u8 = undefined;
        const s = num.int(tb[0..], @intFromFloat(@max(0, bytes)));
        return std.fmt.bufPrint(buf, "{s} B", .{s}) catch "";
    }
    if (bytes < 1024 * 1024) {
        var tb: [12]u8 = undefined;
        const s = num.fixed(tb[0..], @floatCast(bytes / 1024.0), 1);
        return std.fmt.bufPrint(buf, "{s} KB", .{s}) catch "";
    }
    var tb: [12]u8 = undefined;
    const s = num.fixed(tb[0..], @floatCast(bytes / (1024.0 * 1024.0)), 1);
    return std.fmt.bufPrint(buf, "{s} MB", .{s}) catch "";
}

/// 一行响应摘要：状态码 + 原因 + 耗时 + 体积（状态色分档）。
pub fn responseStatus(ui: *core.Context, status: i32, seconds: f64, bytes: f64) void {
    const tone_c = trace.toneColor(statusTone(status));
    var sb: [24]u8 = undefined;
    const secs = blk: {
        if (seconds >= 1) {
            var tb: [12]u8 = undefined;
            const s = num.fixed(tb[0..], @floatCast(seconds), 2);
            break :blk std.fmt.bufPrint(sb[0..], "{s}s", .{s}) catch "";
        }
        var tb: [12]u8 = undefined;
        const s = num.int(tb[0..], @intFromFloat(@max(0, seconds * 1000.0)));
        break :blk std.fmt.bufPrint(sb[0..], "{s}ms", .{s}) catch "";
    };
    var bb: [24]u8 = undefined;
    const size = fmtBytes(bb[0..], bytes);
    var buf: [80]u8 = undefined;
    const line = if (httpReason(status).len > 0)
        (std.fmt.bufPrint(buf[0..], "{d} {s}  ·  {s}  ·  {s}", .{ status, httpReason(status), secs, size }) catch "")
    else
        (std.fmt.bufPrint(buf[0..], "{d}  ·  {s}  ·  {s}", .{ status, secs, size }) catch "");
    const row = ui.reserve(0, 20, true);
    ui.addText(.{ .x = row.x, .y = row.y + 2, .w = ui.measureText(line, theme.font_small).w + 2, .h = 18 }, ui.frameStr(line), theme.font_small, tone_c);
}

fn hexDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'A' + (v - 10);
}

/// 百分号解码（`+` 也当空格）；返回写入长度。
fn percentDecode(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < dst.len) {
        const c = src[i];
        if (c == '%' and i + 2 < src.len) {
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch {
                dst[n] = c;
                n += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch {
                dst[n] = c;
                n += 1;
                i += 1;
                continue;
            };
            dst[n] = hi * 16 + lo;
            n += 1;
            i += 3;
            continue;
        }
        dst[n] = if (c == '+') ' ' else c;
        n += 1;
        i += 1;
    }
    return n;
}

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
}

/// 把 URL 的查询串解成键值对（用 `devtools.KvPair` 承载），返回写了几对。
pub fn urlParams(url: []const u8, pairs: []devtools.KvPair) usize {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return 0;
    var rest = url[q + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '&');
    while (it.next()) |part| {
        if (part.len == 0 or n >= pairs.len) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=');
        const raw_k = if (eq) |e| part[0..e] else part;
        const raw_v = if (eq) |e| part[e + 1 ..] else "";
        var kb: [128]u8 = undefined;
        var vb: [256]u8 = undefined;
        const kn = percentDecode(kb[0..], raw_k);
        const vn = percentDecode(vb[0..], raw_v);
        pairs[n].reset();
        pairs[n].setKey(kb[0..kn]);
        pairs[n].setValue(vb[0..vn]);
        pairs[n].enabled = true;
        n += 1;
    }
    return n;
}

/// 用启用的键值对重建 URL 的查询串；放不下返回 false（`len` 保持不变）。
pub fn urlSetParams(buf: []u8, len: *usize, pairs: []const devtools.KvPair) bool {
    const url = buf[0..len.*];
    const base_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    var out: [1024]u8 = undefined;
    if (base_end > out.len) return false;
    @memcpy(out[0..base_end], url[0..base_end]);
    var n = base_end;
    var first = true;
    for (pairs) |p| {
        if (!p.enabled or p.key_len == 0) continue;
        if (n + 1 >= out.len) return false;
        out[n] = if (first) '?' else '&';
        n += 1;
        first = false;
        // 键
        for (p.keySlice()) |c| {
            if (isUnreserved(c)) {
                if (n + 1 > out.len) return false;
                out[n] = c;
                n += 1;
            } else {
                if (n + 3 > out.len) return false;
                out[n] = '%';
                out[n + 1] = hexDigit(c >> 4);
                out[n + 2] = hexDigit(c & 0xF);
                n += 3;
            }
        }
        if (p.value_len == 0) continue;
        if (n + 1 > out.len) return false;
        out[n] = '=';
        n += 1;
        for (p.valueSlice()) |c| {
            if (isUnreserved(c)) {
                if (n + 1 > out.len) return false;
                out[n] = c;
                n += 1;
            } else {
                if (n + 3 > out.len) return false;
                out[n] = '%';
                out[n + 1] = hexDigit(c >> 4);
                out[n + 2] = hexDigit(c & 0xF);
                n += 3;
            }
        }
    }
    if (n > buf.len) return false;
    @memcpy(buf[0..n], out[0..n]);
    len.* = n;
    return true;
}

// =============================================================== 异常调用栈

pub const StackFrame = struct {
    function: []const u8 = "",
    file: []const u8 = "",
    /// 1 起；0 不显示。
    line: i32 = 0,
    column: i32 = 0,
    /// 库 / 运行时帧：连续的一段默认折叠。
    external: bool = false,
    /// 这一帧附近的源码（`source[line - source_first]` 是出错行）。
    source: []const []const u8 = &.{},
    source_first: i32 = 0,
};

pub const StackTraceOpts = struct {
    /// 异常类型，如 "TypeError"。
    title: []const u8 = "",
    message: []const u8 = "",
    /// 源码着色的语言（与 `editor.Opts.lang` 同口径）；空 = 不着色。
    lang: []const u8 = "",
};

pub const StackTraceState = struct {
    /// 展开源码的帧，-1 = 都不展开。
    open: i32 = -1,
    /// 库帧是否展开。
    libs_open: bool = false,
};

pub const StackTraceResult = struct {
    /// 被点的帧，-1 = 无。
    clicked: i32 = -1,
    /// 本帧按下「复制」：调用方去写系统剪贴板。
    copy: bool = false,
};

/// 异常 + 调用栈：类型与消息，下面是各帧的函数与位置；连续的库帧折成一行，
/// 带源码的帧可展开看上下文（出错行高亮）。「Copy trace」只回一个标志。
pub fn stackTrace(ui: *core.Context, id: []const u8, frames: []const StackFrame, st: *StackTraceState, opts: StackTraceOpts) StackTraceResult {
    var res = StackTraceResult{};
    const key = idOf(id);
    // 标题行
    if (opts.title.len > 0 or opts.message.len > 0) {
        var hb: [96]u8 = undefined;
        const head = if (opts.message.len > 0)
            (std.fmt.bufPrint(hb[0..], "{s}: {s}", .{ opts.title, opts.message }) catch opts.title)
        else
            opts.title;
        const row = ui.reserve(0, 22, true);
        const hw = @max(20, row.w - 110);
        ui.addText(.{ .x = row.x, .y = row.y + 2, .w = hw, .h = 18 }, ui.frameStr(devviews.clipText(ui, head, theme.font_body, hw)), theme.font_body, trace.toneColor(.danger));
        const btn = t.Rect{ .x = row.x + row.w - 96, .y = row.y, .w = 96, .h = 22 };
        if (textButton(ui, kk(key, 0xD100, 0), btn, "Copy trace", false)) res.copy = true;
    }
    // 帧
    var i: usize = 0;
    while (i < frames.len) : (i += 1) {
        const f = frames[i];
        // 连续的库帧折成一行
        if (f.external and !st.libs_open) {
            var j = i;
            while (j < frames.len and frames[j].external) : (j += 1) {}
            const count = j - i;
            var lb: [32]u8 = undefined;
            const lbl = if (count == 1)
                "1 library frame"
            else
                (std.fmt.bufPrint(lb[0..], "{d} library frames", .{count}) catch "library frames");
            const row = ui.reserve(0, 22, true);
            const hit = ui.interactEx(kk(key, 0xD200, i), row, true);
            if (hit.hover) ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
            ui.addText(.{ .x = row.x + 16, .y = row.y + 2, .w = 14, .h = 18 }, ">", theme.font_small, theme.secondary);
            ui.addText(.{ .x = row.x + 30, .y = row.y + 2, .w = @max(20, row.w - 34), .h = 18 }, ui.frameStr(lbl), theme.font_small, theme.secondary);
            if (hit.clicked) st.libs_open = true;
            i = j - 1;
            continue;
        }
        const is_open = st.open == @as(i32, @intCast(i));
        const has_source = f.source.len > 0;
        const row = ui.reserve(0, 22, true);
        const hit = ui.interactEx(kk(key, 0xD300, i), row, true);
        if (hit.hover) ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
        if (has_source) {
            ui.addText(.{ .x = row.x + 16, .y = row.y + 2, .w = 14, .h = 18 }, if (is_open) "v" else ">", theme.font_small, theme.secondary);
        }
        const fn_x = row.x + 30;
        const fn_w = @max(40, row.w * 0.52);
        const fn_col = if (f.external) theme.secondary else theme.text;
        ui.addText(.{ .x = fn_x, .y = row.y + 2, .w = fn_w, .h = 18 }, devviews.clipText(ui, f.function, theme.font_body, fn_w), theme.font_body, fn_col);
        // 位置
        var pb: [64]u8 = undefined;
        var pos: []const u8 = f.file;
        if (f.line > 0) {
            var lb: [8]u8 = undefined;
            const ls = num.int(lb[0..], f.line);
            if (f.column > 0) {
                var cb: [8]u8 = undefined;
                const cs = num.int(cb[0..], f.column);
                pos = std.fmt.bufPrint(pb[0..], "{s}:{s}:{s}", .{ f.file, ls, cs }) catch f.file;
            } else {
                pos = std.fmt.bufPrint(pb[0..], "{s}:{s}", .{ f.file, ls }) catch f.file;
            }
        }
        const pos_x = fn_x + fn_w + 8;
        const pos_w = @max(20, row.x + row.w - pos_x);
        ui.addText(.{ .x = pos_x, .y = row.y + 2, .w = pos_w, .h = 18 }, ui.frameStr(devviews.clipText(ui, pos, theme.font_small, pos_w)), theme.font_small, theme.secondary);
        if (hit.clicked) {
            res.clicked = @intCast(i);
            if (has_source) st.open = if (is_open) -1 else @intCast(i);
        }
        // 源码上下文
        if (is_open and has_source) {
            for (f.source, 0..) |line, li| {
                const lineno = f.source_first + @as(i32, @intCast(li));
                const is_err = f.line > 0 and lineno == f.line;
                const srow = ui.reserve(0, 18, true);
                if (is_err) ui.addBox(srow, .{ .fill = theme.danger_bg, .radius = 3 });
                var nb: [12]u8 = undefined;
                const ns = num.int(nb[0..], lineno);
                const nw = ui.measureText(ns, theme.font_small).w;
                ui.addText(.{ .x = srow.x + 44 - nw, .y = srow.y + 1, .w = nw + 1, .h = 16 }, ui.frameStr(ns), theme.font_small, theme.secondary);
                const cx = srow.x + 52;
                const cw = @max(20, srow.w - 56);
                if (opts.lang.len > 0) {
                    editor.highlightLine(ui, opts.lang, line, cx, srow.y + 1, theme.font_small, cw);
                } else {
                    ui.addMonoText(.{ .x = cx, .y = srow.y + 1, .w = cw, .h = 16 }, line, theme.font_small, theme.text);
                }
            }
        }
    }
    return res;
}

// =============================================================== 请求栏

pub const RequestBarOpts = struct {
    /// 正在等响应：按钮变成「Cancel」。
    loading: bool = false,
    placeholder: []const u8 = "https://api.example.com/users",
};

pub const RequestBarResult = struct {
    send: bool = false,
    cancel: bool = false,
    changed: bool = false,
};

/// 方法 + URL + 发送/取消。点方法胶囊循环切换；URL 里按回车等于发送。
pub fn requestBar(
    ui: *core.Context,
    id: []const u8,
    method: *Method,
    url: []u8,
    len: *usize,
    caret: *usize,
    opts: RequestBarOpts,
) RequestBarResult {
    var res = RequestBarResult{};
    const key = idOf(id);
    const avail = ui.stack[ui.depth - 1].width;
    var row = ui.row(.{ .gap = 8 });
    defer row.end();
    // 方法胶囊
    const name = methodName(method.*);
    const mw = ui.measureText(name, theme.font_small).w + 24;
    const pill = ui.reserve(mw, 36, false);
    const mh = ui.interactEx(kk(key, 0xE100, 0), pill, true);
    ui.addBox(pill, .{
        .fill = theme.withAlpha(trace.toneColor(methodTone(method.*)), 34),
        .radius = 6,
        .border = theme.withAlpha(trace.toneColor(methodTone(method.*)), 140),
    });
    ui.addText(.{ .x = pill.x + 12, .y = pill.y + 10, .w = mw - 14, .h = 18 }, name, theme.font_small, trace.toneColor(methodTone(method.*)));
    if (mh.clicked) {
        method.* = nextMethod(method.*);
        res.changed = true;
    }
    // URL
    const btn_w: f32 = 84;
    const items: f32 = 3;
    const usable = @max(120, avail - mw - btn_w - (items - 1) * 8);
    var ib: [24]u8 = undefined;
    const iid = ui.frameStr(std.fmt.bufPrint(ib[0..], "{s}-url", .{id}) catch "url");
    if (widgets.input(ui, iid, url, len, caret, .{
        .placeholder = opts.placeholder,
        .width = usable,
    })) res.changed = true;
    // 回车 = 发送
    const focus_url = core.Context.idOf(iid) ^ 0x7FEB352D;
    if (ui.focus_id == focus_url and ui.input.keyPressed(.enter)) {
        if (opts.loading) res.cancel = true else res.send = true;
    }
    const btn = ui.reserve(btn_w, 36, false);
    if (textButton(ui, kk(key, 0xE200, 0), btn, if (opts.loading) "Cancel" else "Send", !opts.loading)) {
        if (opts.loading) res.cancel = true else res.send = true;
    }
    return res;
}

// =============================================================== 功能开关

pub const MAX_FLAG_ENVS = 8;

pub const FeatureFlag = struct {
    key: []const u8 = "",
    description: []const u8 = "",
    on: [MAX_FLAG_ENVS]bool = @splat(false),
    /// 开启时覆盖的用户百分比（1..100）。
    rollout: [MAX_FLAG_ENVS]i32 = @splat(100),
};

pub const FeatureFlagsOpts = struct {
    /// 0 = 按开关数自适应（最多 360）。
    height: f32 = 0,
};

pub const FeatureFlagsState = struct {
    query: [64]u8 = @splat(0),
    query_len: usize = 0,
    query_caret: usize = 0,
    /// 窄屏时显示哪个环境。
    env: usize = 0,
};

pub const FeatureFlagsResult = struct {
    /// 本帧改了哪个开关，-1 = 无。
    flag: i32 = -1,
    /// 改的是哪个环境，-1 = 无。
    env: i32 = -1,
};

/// 灰度预设：点百分比徽标时循环。
const rollout_presets = [_]i32{ 1, 5, 25, 50, 100 };

fn nextRollout(v: i32) i32 {
    for (rollout_presets, 0..) |p, i| {
        if (v == p) return rollout_presets[(i + 1) % rollout_presets.len];
    }
    return 100;
}

/// 开关矩阵：每行一个开关（键 + 描述），每列一个环境的「开关 + 灰度」。
/// 点开关切换、点百分比徽标循环预设；窄于 520 一次只显示一个环境（上面选环境）。
pub fn featureFlags(
    ui: *core.Context,
    id: []const u8,
    flags: []FeatureFlag,
    envs: []const []const u8,
    st: *FeatureFlagsState,
    opts: FeatureFlagsOpts,
) FeatureFlagsResult {
    var res = FeatureFlagsResult{};
    const key = idOf(id);
    const query = st.query[0..st.query_len];
    // 过滤
    var visible: [64]i32 = @splat(-1);
    var nvis: usize = 0;
    for (flags, 0..) |f, i| {
        if (!devtools.containsCi(f.key, query) and !devtools.containsCi(f.description, query)) continue;
        if (nvis < visible.len) {
            visible[nvis] = @intCast(i);
            nvis += 1;
        }
    }
    var fb: [24]u8 = undefined;
    const fid = ui.frameStr(std.fmt.bufPrint(fb[0..], "{s}-q", .{id}) catch "flags-q");
    _ = widgets.input(ui, fid, st.query[0..], &st.query_len, &st.query_caret, .{ .placeholder = "Filter flags", .width = 200 });

    const h: f32 = if (opts.height > 0) opts.height else @min(360, 30 + @as(f32, @floatFromInt(nvis)) * 40 + 8);
    var area = ui.scroll(.{ .id = id, .height = h });
    defer area.end();
    const avail = area.rect.w;
    const narrow = avail < 520;
    const envs_show: usize = if (narrow) 1 else @min(envs.len, MAX_FLAG_ENVS);
    if (narrow and envs.len > 1) {
        // 环境选择
        var row = ui.row(.{ .gap = 6 });
        defer row.end();
        for (envs, 0..) |e, ei| {
            const w = ui.measureText(e, theme.font_small).w + 18;
            const chip = ui.reserve(w, 22, false);
            const hit = ui.interactEx(kk(key, 0xF100, ei), chip, true);
            const on = st.env == ei;
            ui.addBox(chip, .{
                .fill = if (on) theme.accent_bg else theme.surface,
                .radius = 11,
                .border = if (on) theme.accent else theme.border,
            });
            ui.addText(.{ .x = chip.x + 9, .y = chip.y + 2, .w = w - 10, .h = 18 }, e, theme.font_small, if (on) theme.text else theme.secondary);
            if (hit.clicked) st.env = ei;
        }
    }
    // 表头
    const head = ui.reserve(0, 26, true);
    ui.addText(.{ .x = head.x + 4, .y = head.y + 5, .w = @max(60, head.w * 0.5), .h = 16 }, "Flag", theme.font_small, theme.secondary);
    const col_w: f32 = 92;
    var ci: usize = 0;
    while (ci < envs_show) : (ci += 1) {
        const ei = if (narrow) st.env else ci;
        if (ei >= envs.len) break;
        const x = head.x + avail - @as(f32, @floatFromInt(envs_show - ci)) * col_w;
        ui.addText(.{ .x = x, .y = head.y + 5, .w = col_w - 4, .h = 16 }, devviews.clipText(ui, envs[ei], theme.font_small, col_w - 4), theme.font_small, theme.secondary);
    }
    // 行
    var vi: usize = 0;
    while (vi < nvis) : (vi += 1) {
        const fi: usize = @intCast(visible[vi]);
        const f = &flags[fi];
        const row = ui.reserve(0, 38, true);
        if (vi % 2 == 1) ui.addBox(row, .{ .fill = theme.row_alt });
        const kw = @max(60, avail * 0.5);
        ui.addText(.{ .x = row.x + 4, .y = row.y + 3, .w = kw, .h = 18 }, devviews.clipText(ui, f.key, theme.font_body, kw), theme.font_body, theme.text);
        if (f.description.len > 0 and avail > 420) {
            const dw = @max(20, kw - 12);
            ui.addText(.{ .x = row.x + 4, .y = row.y + 21, .w = dw, .h = 16 }, devviews.clipText(ui, f.description, theme.font_small, dw), theme.font_small, theme.secondary);
        }
        var k: usize = 0;
        while (k < envs_show) : (k += 1) {
            const ei = if (narrow) st.env else k;
            if (ei >= envs.len or ei >= MAX_FLAG_ENVS) break;
            const x = row.x + avail - @as(f32, @floatFromInt(envs_show - k)) * col_w;
            const box = t.Rect{ .x = x + 6, .y = row.y + 11, .w = 16, .h = 16 };
            if (boxToggle(ui, kk(key, 0xF200 + @as(u64, @intCast(ei)) * 0x100, fi), box, f.on[ei])) {
                f.on[ei] = !f.on[ei];
                res.flag = @intCast(fi);
                res.env = @intCast(ei);
            }
            if (f.on[ei]) {
                var pb: [8]u8 = undefined;
                const pct = num.int(pb[0..], f.rollout[ei]);
                var lb: [12]u8 = undefined;
                const lbl = std.fmt.bufPrint(lb[0..], "{s}%", .{pct}) catch "";
                const bw = ui.measureText(lbl, theme.font_small).w + 12;
                const badge = t.Rect{ .x = box.x + 22, .y = row.y + 11, .w = bw, .h = 16 };
                const bh = ui.interactEx(kk(key, 0xF300 + @as(u64, @intCast(ei)) * 0x100, fi), badge, true);
                ui.addBox(badge, .{ .fill = theme.track, .radius = 8 });
                ui.addText(.{ .x = badge.x + 6, .y = badge.y + 1, .w = bw - 6, .h = 16 }, ui.frameStr(lbl), theme.font_small, theme.secondary);
                if (bh.clicked) {
                    f.rollout[ei] = nextRollout(f.rollout[ei]);
                    res.flag = @intCast(fi);
                    res.env = @intCast(ei);
                }
            }
        }
    }
    if (nvis == 0) {
        ui.addText(.{ .x = area.rect.x + 4, .y = area.rect.y + 6, .w = avail - 8, .h = 18 }, "No flags match", theme.font_body, theme.secondary);
    }
    return res;
}

// =============================================================== API 浏览

pub const ApiParam = struct {
    name: []const u8 = "",
    /// "path" / "query" / "header" / "body"。
    in: []const u8 = "query",
    type: []const u8 = "string",
    required: bool = false,
    description: []const u8 = "",
};

pub const ApiEndpoint = struct {
    method: []const u8 = "GET",
    path: []const u8 = "",
    summary: []const u8 = "",
    /// 分组；空 = "Other"。
    tag: []const u8 = "",
    deprecated: bool = false,
    params: []const ApiParam = &.{},
};

pub const ApiExplorerOpts = struct {
    height: f32 = 0,
    selected: ?*i32 = null,
};

pub const ApiExplorerState = struct {
    query: [64]u8 = @splat(0),
    query_len: usize = 0,
    query_caret: usize = 0,
    /// 展开参数的那个端点，-1 = 无。
    open: i32 = -1,
};

pub const ApiExplorerResult = struct {
    /// 选中的端点，-1 = 无。
    selected: i32 = -1,
    /// 本次被点的端点，-1 = 无。
    clicked: i32 = -1,
    /// 按了「Try it」的端点，-1 = 无。
    try_it: i32 = -1,
};

fn apiTone(m: []const u8) Tone {
    if (std.mem.eql(u8, m, "GET")) return .info;
    if (std.mem.eql(u8, m, "POST")) return .success;
    if (std.mem.eql(u8, m, "PUT") or std.mem.eql(u8, m, "PATCH")) return .warn;
    if (std.mem.eql(u8, m, "DELETE")) return .danger;
    return .neutral;
}

/// 端点列表：按 tag 分组，每行「方法 + 路径 + 摘要」，废弃的加标记；
/// 点一行展开它的参数与「Try it」。过滤框按路径/摘要筛。
pub fn apiExplorer(ui: *core.Context, id: []const u8, endpoints: []const ApiEndpoint, st: *ApiExplorerState, opts: ApiExplorerOpts) ApiExplorerResult {
    var res = ApiExplorerResult{};
    const key = idOf(id);
    const query = st.query[0..st.query_len];
    var fb: [24]u8 = undefined;
    const fid = ui.frameStr(std.fmt.bufPrint(fb[0..], "{s}-q", .{id}) catch "api-q");
    _ = widgets.input(ui, fid, st.query[0..], &st.query_len, &st.query_caret, .{ .placeholder = "Filter endpoints", .width = 220 });

    // 可见端点 + 分组（首见顺序）
    var vis: [96]i32 = @splat(-1);
    var nvis: usize = 0;
    var tags: [16][]const u8 = @splat("");
    var ntags: usize = 0;
    for (endpoints, 0..) |e, i| {
        if (!devtools.containsCi(e.path, query) and !devtools.containsCi(e.summary, query)) continue;
        if (nvis < vis.len) {
            vis[nvis] = @intCast(i);
            nvis += 1;
        }
        const tg = if (e.tag.len == 0) "Other" else e.tag;
        var found = false;
        for (tags[0..ntags]) |x| {
            if (std.mem.eql(u8, x, tg)) {
                found = true;
                break;
            }
        }
        if (!found and ntags < tags.len) {
            tags[ntags] = tg;
            ntags += 1;
        }
    }
    const h: f32 = if (opts.height > 0) opts.height else @min(400, 34 + @as(f32, @floatFromInt(nvis)) * 30 + 60);
    var area = ui.scroll(.{ .id = id, .height = h });
    defer area.end();
    const avail = area.rect.w;

    // 键盘
    const list_key = kk(key, 0xA100, 0);
    const list_hit = ui.interactEx(list_key, area.rect, true);
    const sel_now: i32 = if (opts.selected) |p| p.* else -1;
    if (list_hit.focused and nvis > 0) {
        if (ui.input.keyPressed(.down) or ui.input.keyPressed(.up)) {
            const step: i32 = if (ui.input.keyPressed(.down)) 1 else -1;
            var next = sel_now + step;
            if (next < 0) next = 0;
            if (next >= @as(i32, @intCast(nvis))) next = @intCast(nvis - 1);
            if (opts.selected) |p| p.* = next;
            st.open = vis[@intCast(next)];
        } else if (ui.input.keyPressed(.enter)) {
            if (sel_now >= 0 and sel_now < @as(i32, @intCast(nvis))) {
                st.open = vis[@intCast(sel_now)];
                res.try_it = st.open;
            }
        }
    }

    var ti: usize = 0;
    while (ti < ntags) : (ti += 1) {
        const tag = tags[ti];
        const grow = ui.reserve(0, 24, true);
        ui.addText(.{ .x = grow.x + 4, .y = grow.y + 4, .w = @max(40, avail - 8), .h = 16 }, devviews.clipText(ui, tag, theme.font_small, avail - 8), theme.font_small, theme.secondary);
        var vi: usize = 0;
        while (vi < nvis) : (vi += 1) {
            const ei: usize = @intCast(vis[vi]);
            const e = &endpoints[ei];
            const tg = if (e.tag.len == 0) "Other" else e.tag;
            if (!std.mem.eql(u8, tg, tag)) continue;
            const row = ui.reserve(0, 26, true);
            const hit = ui.interactEx(kk(key, 0xA200, ei), row, true);
            const sel = sel_now == @as(i32, @intCast(vi));
            if (sel) {
                ui.addBox(row, .{ .fill = theme.accent_bg, .radius = 4 });
            } else if (hit.hover) ui.addBox(row, .{ .fill = theme.track, .radius = 4 });
            // 方法徽标
            const tone_c = trace.toneColor(apiTone(e.method));
            const mw = @max(46, ui.measureText(e.method, theme.font_small).w + 12);
            const mb = t.Rect{ .x = row.x + 6, .y = row.y + 4, .w = mw, .h = 18 };
            ui.addBox(mb, .{ .fill = theme.withAlpha(tone_c, 34), .radius = 4 });
            ui.addText(.{ .x = mb.x + 6, .y = mb.y + 1, .w = mw - 6, .h = 16 }, e.method, theme.font_small, tone_c);
            // 路径 + 摘要
            const px = mb.x + mw + 10;
            const path_w = @min(ui.measureText(e.path, theme.font_body).w + 2, @max(60, avail * 0.45));
            const path_col = if (e.deprecated) theme.secondary else theme.text;
            ui.addText(.{ .x = px, .y = row.y + 3, .w = path_w, .h = 18 }, devviews.clipText(ui, e.path, theme.font_body, path_w), theme.font_body, path_col);
            if (e.deprecated) {
                // 删除线用一条细矩形
                ui.addBox(.{ .x = px, .y = row.y + 12, .w = @min(path_w, ui.measureText(e.path, theme.font_body).w), .h = 1 }, .{ .fill = theme.secondary });
            }
            const summary_x = px + path_w + 10;
            const summary_w = @max(20, row.x + row.w - summary_x - 8);
            if (summary_w > 20) {
                ui.addText(.{ .x = summary_x, .y = row.y + 4, .w = summary_w, .h = 16 }, devviews.clipText(ui, e.summary, theme.font_small, summary_w), theme.font_small, theme.secondary);
            }
            if (hit.clicked) {
                res.clicked = @intCast(ei);
                st.open = @intCast(ei);
                if (opts.selected) |p| p.* = @intCast(vi);
            }
            // 展开的参数
            if (st.open == @as(i32, @intCast(ei))) {
                if (e.params.len == 0) {
                    const r2 = ui.reserve(0, 20, true);
                    ui.addText(.{ .x = r2.x + 24, .y = r2.y + 2, .w = @max(20, r2.w - 28), .h = 16 }, "no parameters", theme.font_small, theme.secondary);
                }
                for (e.params) |p| {
                    const r2 = ui.reserve(0, 22, true);
                    var nb: [96]u8 = undefined;
                    const lbl = std.fmt.bufPrint(nb[0..], "{s}{s}", .{ p.name, if (p.required) " *" else "" }) catch p.name;
                    const nw = @min(ui.measureText(lbl, theme.font_small).w + 2, @max(40, avail * 0.3));
                    ui.addText(.{ .x = r2.x + 30, .y = r2.y + 3, .w = nw, .h = 16 }, ui.frameStr(lbl), theme.font_small, if (p.required) theme.text else theme.secondary);
                    var ib: [64]u8 = undefined;
                    const meta = std.fmt.bufPrint(ib[0..], "{s} · {s}", .{ p.in, p.type }) catch p.in;
                    const mw2 = @min(ui.measureText(meta, theme.font_small).w + 2, @max(40, avail * 0.22));
                    ui.addText(.{ .x = r2.x + 30 + nw + 8, .y = r2.y + 3, .w = mw2, .h = 16 }, ui.frameStr(meta), theme.font_small, theme.secondary);
                    const dx = r2.x + 30 + nw + 8 + mw2 + 8;
                    const dw = @max(20, (r2.x + r2.w) - dx - 8);
                    ui.addText(.{ .x = dx, .y = r2.y + 3, .w = dw, .h = 16 }, devviews.clipText(ui, p.description, theme.font_small, dw), theme.font_small, theme.secondary);
                }
                const r3 = ui.reserve(0, 30, true);
                const btn = t.Rect{ .x = r3.x + 30, .y = r3.y + 2, .w = 74, .h = 24 };
                if (textButton(ui, kk(key, 0xA300, ei), btn, "Try it", true)) res.try_it = @intCast(ei);
            }
        }
    }
    if (nvis == 0) {
        ui.addText(.{ .x = area.rect.x + 4, .y = area.rect.y + 6, .w = avail - 8, .h = 18 }, "No endpoints match", theme.font_body, theme.secondary);
    }
    res.selected = if (opts.selected) |p| p.* else -1;
    return res;
}
