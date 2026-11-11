//! 开发者面板族：调用栈、请求栏与 HTTP 辅助、功能开关、API 浏览。
//! 夹具一律放文件级（带 `draw` 的结构体声明在测试函数内部会遮蔽测试里的 `var ui`）。
const std = @import("std");
const core = @import("core.zig");
const devpanels = @import("devpanels.zig");
const devtools = @import("devtools.zig");
const types = @import("types.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

fn keysOf(k: types.Key) types.Input {
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = k;
    return .{ .keys = keys, .key_count = 1 };
}

fn frame(ui: *core.Context, w: f32, h: f32, st: anytype, input: types.Input) void {
    ui.input = input;
    ui.begin(w, h);
    st.draw(ui);
    ui.paint();
}

fn click(ui: *core.Context, w: f32, h: f32, st: anytype, x: f32, y: f32) void {
    frame(ui, w, h, st, .{ .mouse = at(x, y) });
    frame(ui, w, h, st, .{ .mouse = at(x, y), .click = at(x, y) });
}

fn kkk(key: u64, salt: u64, i: usize) u64 {
    return key ^ (salt +% @as(u64, @intCast(i)));
}

// ------------------------------------------------------------------ HTTP 辅助

test "devpanels: methods cycle and carry their names" {
    try std.testing.expectEqualStrings("GET", devpanels.methodName(.get));
    try std.testing.expectEqualStrings("OPTIONS", devpanels.methodName(.options));
    try std.testing.expectEqual(devpanels.Method.post, devpanels.nextMethod(.get));
    try std.testing.expectEqual(devpanels.Method.get, devpanels.nextMethod(.options));
}

test "devpanels: status reasons cover the common codes" {
    try std.testing.expectEqualStrings("OK", devpanels.httpReason(200));
    try std.testing.expectEqualStrings("Not Found", devpanels.httpReason(404));
    try std.testing.expectEqualStrings("Teapot", "Teapot");
    try std.testing.expectEqualStrings("Internal Server Error", devpanels.httpReason(500));
    try std.testing.expectEqualStrings("", devpanels.httpReason(299));
}

test "devpanels: url params decode and re-encode" {
    var pairs: [8]devtools.KvPair = @splat(.{});
    const n = devpanels.urlParams("/api/users?page=2&q=hello+world&x=%E4%B8%AD", pairs[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("page", pairs[0].keySlice());
    try std.testing.expectEqualStrings("2", pairs[0].valueSlice());
    try std.testing.expectEqualStrings("hello world", pairs[1].valueSlice());
    // 中文三字节解码后是 UTF-8 的「中」
    try std.testing.expectEqualStrings("\u{4e2d}", pairs[2].valueSlice());
    // 回写：只有启用的对进查询串
    pairs[1].enabled = false;
    var buf: [256]u8 = @splat(0);
    const base = "/api/users";
    @memcpy(buf[0..base.len], base);
    var len: usize = base.len;
    try std.testing.expect(devpanels.urlSetParams(buf[0..], &len, pairs[0..n]));
    try std.testing.expectEqualStrings("/api/users?page=2&x=%E4%B8%AD", buf[0..len]);
}

test "devpanels: a url that does not fit is left alone" {
    var pairs: [1]devtools.KvPair = @splat(.{});
    pairs[0].setKey("a");
    pairs[0].setValue("0123456789012345678901234567890123456789");
    var buf: [16]u8 = @splat(0);
    const base = "/x";
    @memcpy(buf[0..base.len], base);
    var len: usize = base.len;
    try std.testing.expect(!devpanels.urlSetParams(buf[0..], &len, pairs[0..1]));
    try std.testing.expectEqual(@as(usize, 2), len);
}

// ------------------------------------------------------------------ 调用栈

const stk_source = [_][]const u8{
    "const user = res.data.user;",
    "console.log(user.name);",
    "}",
};
const stk_frames = [_]devpanels.StackFrame{
    .{ .function = "renderProfile", .file = "src/profile.ts", .line = 42, .column = 9, .source = stk_source[0..], .source_first = 40 },
    .{ .function = "readField", .file = "node_modules/lib/index.js", .line = 7, .external = true },
    .{ .function = "next", .file = "node_modules/lib/next.js", .line = 12, .external = true },
    .{ .function = "main", .file = "src/main.ts", .line = 3, .column = 1 },
};

const StkF = struct {
    st: devpanels.StackTraceState = .{},
    res: devpanels.StackTraceResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devpanels.stackTrace(ui, "stk", stk_frames[0..], &self.st, .{
            .title = "TypeError",
            .message = "Cannot read properties of undefined (reading 'name')",
            .lang = "",
        });
    }
};

test "devpanels: the stack trace folds library runs and reports the copy button" {
    var ui = core.Context{};
    var f = StkF{};
    frame(&ui, 720, 400, &f, .{});
    try std.testing.expectEqual(@as(i32, -1), f.res.clicked);
    // 第 0 帧、库里那一段（一次折行）、第 3 帧都有行
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("stk"), 0xD300, 0)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("stk"), 0xD200, 1)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("stk"), 0xD300, 1)) == null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("stk"), 0xD300, 3)) != null);
    // 点复制按钮
    const copy = ui.lastRect(kkk(core.Context.idOf("stk"), 0xD100, 0)).?;
    click(&ui, 720, 400, &f, copy.x + copy.w * 0.5, copy.y + copy.h * 0.5);
    try std.testing.expect(f.res.copy);
    try std.testing.expect(!ui.overflowed);
}

test "devpanels: clicking a frame opens its source and clicking again closes it" {
    var ui = core.Context{};
    var f = StkF{};
    frame(&ui, 720, 400, &f, .{});
    const row = ui.lastRect(kkk(core.Context.idOf("stk"), 0xD300, 0)).?;
    click(&ui, 720, 400, &f, row.x + 60, row.y + 8);
    try std.testing.expectEqual(@as(i32, 0), f.st.open);
    try std.testing.expectEqual(@as(i32, 0), f.res.clicked);
    // 源码三行都在（第 4 帧整体往下挪）
    frame(&ui, 720, 400, &f, .{});
    const last = ui.lastRect(kkk(core.Context.idOf("stk"), 0xD300, 3)).?;
    try std.testing.expect(last.y > row.y + row.h * 3);
    click(&ui, 720, 400, &f, row.x + 60, row.y + 8);
    try std.testing.expectEqual(@as(i32, -1), f.st.open);
    try std.testing.expect(!ui.overflowed);
}

test "devpanels: the library run expands when clicked" {
    var ui = core.Context{};
    var f = StkF{};
    frame(&ui, 720, 400, &f, .{});
    const libs = ui.lastRect(kkk(core.Context.idOf("stk"), 0xD200, 1)).?;
    click(&ui, 720, 400, &f, libs.x + 60, libs.y + 8);
    try std.testing.expect(f.st.libs_open);
    frame(&ui, 720, 400, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("stk"), 0xD300, 1)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("stk"), 0xD300, 2)) != null);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 请求栏

const RqF = struct {
    method: devpanels.Method = .get,
    url: [256]u8 = @splat(0),
    len: usize = 0,
    caret: usize = 0,
    loading: bool = false,
    res: devpanels.RequestBarResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devpanels.requestBar(ui, "rq", &self.method, self.url[0..], &self.len, &self.caret, .{ .loading = self.loading });
    }
};

test "devpanels: the request bar cycles the method on click" {
    var ui = core.Context{};
    var f = RqF{};
    frame(&ui, 700, 160, &f, .{});
    const pill = ui.lastRect(kkk(core.Context.idOf("rq"), 0xE100, 0)).?;
    click(&ui, 700, 160, &f, pill.x + pill.w * 0.5, pill.y + pill.h * 0.5);
    try std.testing.expectEqual(devpanels.Method.post, f.method);
    try std.testing.expect(f.res.changed);
    try std.testing.expect(!ui.overflowed);
}

test "devpanels: enter in the url sends and the button cancels while loading" {
    var ui = core.Context{};
    var f = RqF{};
    const text = "https://api.test/users";
    @memcpy(f.url[0..text.len], text);
    f.len = text.len;
    f.caret = text.len;
    frame(&ui, 700, 160, &f, .{});
    ui.focus_id = core.Context.idOf("rq-url") ^ 0x7FEB352D;
    frame(&ui, 700, 160, &f, keysOf(.enter));
    try std.testing.expect(f.res.send);
    // 生成中：按钮变 Cancel
    f.loading = true;
    frame(&ui, 700, 160, &f, .{});
    const btn = ui.lastRect(kkk(core.Context.idOf("rq"), 0xE200, 0)).?;
    click(&ui, 700, 160, &f, btn.x + btn.w * 0.5, btn.y + btn.h * 0.5);
    try std.testing.expect(f.res.cancel);
    try std.testing.expect(!ui.overflowed);
}

test "devpanels: the response status line draws for any code" {
    const St = struct {
        fn draw(ui: *core.Context) void {
            devpanels.responseStatus(ui, 0, 0, 0);
        }
    };
    const F = struct {
        fn draw(self: *@This(), ui: *core.Context) void {
            _ = self;
            devpanels.responseStatus(ui, 200, 0.042, 8_412);
            devpanels.responseStatus(ui, 500, 1.25, 3_200_000);
        }
    };
    var ui = core.Context{};
    var f = F{};
    _ = St.draw;
    frame(&ui, 600, 120, &f, .{});
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 功能开关

var flag_envs = [_][]const u8{ "dev", "staging", "prod" };

/// 功能开关夹具：数组字段有固定长度（MAX_FLAG_ENVS），只能先 `@splat` 再逐位赋值。
fn mkFlag(key: []const u8, desc: []const u8) devpanels.FeatureFlag {
    return .{ .key = key, .description = desc };
}

var flag_list = [_]devpanels.FeatureFlag{
    mkFlag("new-checkout", "One page checkout"),
    mkFlag("dark-mode", "System dark theme"),
};

const FlgF = struct {
    st: devpanels.FeatureFlagsState = .{},
    res: devpanels.FeatureFlagsResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devpanels.featureFlags(ui, "flg", flag_list[0..], flag_envs[0..], &self.st, .{});
    }
};

test "devpanels: a feature flag switch flips and reports flag plus env" {
    flag_list[0] = mkFlag("new-checkout", "One page checkout");
    flag_list[0].on[0] = true;
    flag_list[0].on[1] = true;
    flag_list[0].rollout[1] = 25;
    var ui = core.Context{};
    var f = FlgF{};
    frame(&ui, 760, 300, &f, .{});
    try std.testing.expectEqual(@as(i32, -1), f.res.flag);
    const box = ui.lastRect(kkk(core.Context.idOf("flg"), 0xF200 + 0, 1)).?;
    click(&ui, 760, 300, &f, box.x + box.w * 0.5, box.y + box.h * 0.5);
    try std.testing.expectEqual(@as(i32, 1), f.res.flag);
    try std.testing.expectEqual(@as(i32, 0), f.res.env);
    try std.testing.expect(!ui.overflowed);
}

test "devpanels: clicking the percentage cycles the rollout presets" {
    flag_list[0] = mkFlag("new-checkout", "One page checkout");
    flag_list[0].on[0] = true;
    flag_list[0].rollout[0] = 25;
    var ui = core.Context{};
    var f = FlgF{};
    frame(&ui, 760, 300, &f, .{});
    const badge = ui.lastRect(kkk(core.Context.idOf("flg"), 0xF300 + 0, 0)).?;
    click(&ui, 760, 300, &f, badge.x + badge.w * 0.5, badge.y + badge.h * 0.5);
    try std.testing.expectEqual(@as(i32, 50), flag_list[0].rollout[0]);
    try std.testing.expect(!ui.overflowed);
}

test "devpanels: the filter narrows the flag list" {
    var ui = core.Context{};
    var f = FlgF{};
    f.st.query_len = 5;
    @memcpy(f.st.query[0..5], "dark-");
    frame(&ui, 760, 300, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("flg"), 0xF200, 1)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("flg"), 0xF200, 0)) == null);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ API 浏览

const api_params = [_]devpanels.ApiParam{
    .{ .name = "id", .in = "path", .type = "string", .required = true, .description = "user id" },
    .{ .name = "expand", .in = "query", .type = "string", .description = "relations to inline" },
};
const api_list = [_]devpanels.ApiEndpoint{
    .{ .method = "GET", .path = "/users/{id}", .summary = "Read a user", .tag = "Users", .params = api_params[0..] },
    .{ .method = "DELETE", .path = "/users/{id}", .summary = "Delete a user", .tag = "Users", .deprecated = true },
    .{ .method = "POST", .path = "/orders", .summary = "Create an order", .tag = "Orders" },
};

const ApiF = struct {
    st: devpanels.ApiExplorerState = .{},
    sel: i32 = -1,
    res: devpanels.ApiExplorerResult = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.res = devpanels.apiExplorer(ui, "api", api_list[0..], &self.st, .{ .selected = &self.sel });
    }
};

test "devpanels: the api explorer lists endpoints and opens parameters" {
    var ui = core.Context{};
    var f = ApiF{};
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("api"), 0xA200, 0)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("api"), 0xA200, 2)) != null);
    const row = ui.lastRect(kkk(core.Context.idOf("api"), 0xA200, 0)).?;
    click(&ui, 760, 400, &f, row.x + 80, row.y + 10);
    try std.testing.expectEqual(@as(i32, 0), f.res.clicked);
    try std.testing.expectEqual(@as(i32, 0), f.st.open);
    // 参数与 Try it 出现
    frame(&ui, 760, 400, &f, .{});
    const try_btn = ui.lastRect(kkk(core.Context.idOf("api"), 0xA300, 0)).?;
    click(&ui, 760, 400, &f, try_btn.x + try_btn.w * 0.5, try_btn.y + try_btn.h * 0.5);
    try std.testing.expectEqual(@as(i32, 0), f.res.try_it);
    try std.testing.expect(!ui.overflowed);
}

test "devpanels: the api filter and keyboard selection work" {
    var ui = core.Context{};
    var f = ApiF{};
    f.st.query_len = 6;
    @memcpy(f.st.query[0..6], "orders");
    frame(&ui, 760, 400, &f, .{});
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("api"), 0xA200, 2)) != null);
    try std.testing.expect(ui.lastRect(kkk(core.Context.idOf("api"), 0xA200, 0)) == null);
    // 焦点给列表，按下键选第一个
    const list_key = kkk(core.Context.idOf("api"), 0xA100, 0);
    const area = ui.lastRect(list_key).?;
    click(&ui, 760, 400, &f, area.x + 4, area.y + 4);
    frame(&ui, 760, 400, &f, keysOf(.down));
    try std.testing.expectEqual(@as(i32, 0), f.sel);
    try std.testing.expect(!ui.overflowed);
}
