//! AI 界面族：推理折叠、工具调用、计划轨道、状态药丸、来源与引用、上下文环、
//! 回复操作、提示建议、模型选择、聊天输入框、语音球。
//!
//! 夹具一律放在文件级：把带 `draw` 的结构体声明在测试函数内部，会让 `draw` 的
//! `ui` 参数遮蔽测试里的 `var ui`（Zig 报 "shadows local variable"）。
const std = @import("std");
const core = @import("core.zig");
const ai = @import("ai.zig");
const theme = @import("theme.zig");
const trace = @import("trace.zig");
const types = @import("types.zig");

fn at(x: f32, y: f32) types.Point {
    return .{ .x = x, .y = y };
}

fn keysOf(k: types.Key) types.Input {
    var keys: [8]types.Key = @splat(.unknown);
    keys[0] = k;
    return .{ .keys = keys, .key_count = 1 };
}

/// 出一帧：`st` 必须是带 `draw(self, *core.Context)` 方法的结构体指针。
fn frame(ui: *core.Context, w: f32, h: f32, st: anytype, input: types.Input) void {
    ui.input = input;
    ui.begin(w, h);
    st.draw(ui);
    ui.paint();
}

/// 鼠标停在 (x, y) 连出两帧（先把命中矩形登记好）。
fn hover(ui: *core.Context, w: f32, h: f32, st: anytype, x: f32, y: f32) void {
    var input = types.Input{ .mouse = at(x, y) };
    frame(ui, w, h, st, input);
    input.mouse = at(x, y);
    frame(ui, w, h, st, input);
}

/// 鼠标移到 (x, y) 完成一次点击（`input.click` 在释放帧生效）。
fn click(ui: *core.Context, w: f32, h: f32, st: anytype, x: f32, y: f32) void {
    var input = types.Input{ .mouse = at(x, y) };
    frame(ui, w, h, st, input);
    input.click = at(x, y);
    frame(ui, w, h, st, input);
}

// ------------------------------------------------------------------ 推理折叠

const RzF = struct {
    st: ai.ReasoningState = .{},
    thinking: bool = true,
    seconds: f32 = 0,
    open: bool = false,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.open = ai.reasoningBegin(ui, "rz", &self.st, .{ .thinking = self.thinking, .seconds = self.seconds });
        ai.reasoningEnd(ui, &self.st);
    }
};

test "ai: the reasoning block starts open, toggles on click, and reports thinking" {
    var ui = core.Context{};
    var f = RzF{};
    frame(&ui, 420, 260, &f, .{});
    try std.testing.expect(f.open);
    try std.testing.expect(!ui.overflowed);
    try std.testing.expect(ui.need_frame); // 思考中要持续出帧
    const row = ui.lastRect(core.Context.idOf("rz") ^ 0x4A11).?;
    click(&ui, 420, 260, &f, row.x + 40, row.y + 10);
    try std.testing.expect(!f.open);
    click(&ui, 420, 260, &f, row.x + 40, row.y + 10);
    try std.testing.expect(f.open);
    try std.testing.expect(!ui.overflowed);
    // 思考结束（给秒数）→ 不再要求出帧
    f.thinking = false;
    f.seconds = 12;
    frame(&ui, 420, 260, &f, .{});
    try std.testing.expect(!ui.need_frame);
}

// ------------------------------------------------------------------ 工具调用

const TcF = struct {
    st: ai.ToolCallState = .{},
    with_body: bool = false,
    fn draw(self: *@This(), ui: *core.Context) void {
        if (self.with_body) {
            ai.toolCall(ui, "tc", &self.st, "web.search", .{
                .status = .done,
                .detail = "3 results",
                .input = "{\"q\":\"zig\"}",
                .output = "{\"n\":3}",
                .seconds = 2,
            });
        } else {
            ai.toolCall(ui, "tc", &self.st, "web.search", .{ .status = .running, .detail = "3 results" });
        }
    }
};

test "ai: a tool call expands only when it carries input or output" {
    var ui = core.Context{};
    var f = TcF{};
    frame(&ui, 460, 300, &f, .{});
    const row = ui.lastRect(core.Context.idOf("tc") ^ 0xA11D).?;
    click(&ui, 460, 300, &f, row.x + 60, row.y + 12);
    try std.testing.expect(!f.st.open); // 没输入输出 → 点了也不展开
    f.with_body = true;
    frame(&ui, 460, 300, &f, .{});
    click(&ui, 460, 300, &f, row.x + 60, row.y + 12);
    try std.testing.expect(f.st.open);
    frame(&ui, 460, 300, &f, .{});
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 计划

const plan_steps = [_]ai.PlanStep{
    .{ .title = "Read the repo", .status = .done },
    .{ .title = "Write the code", .status = .running, .detail = "editing ai.zig" },
    .{ .title = "Run the tests", .status = .pending },
    .{ .title = "Summarize", .status = .skipped },
};

const PlF = struct {
    hit: i32 = -9,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.hit = ai.agentPlan(ui, "pl", plan_steps[0..], .{ .title = "Steps" });
    }
};

test "ai: the plan lists every step and reports the clicked index" {
    var ui = core.Context{};
    var f = PlF{};
    frame(&ui, 480, 320, &f, .{});
    try std.testing.expectEqual(@as(i32, -1), f.hit);
    const third = ui.lastRect(core.Context.idOf("pl") ^ (0x91F0 + 2)).?;
    click(&ui, 480, 320, &f, third.x + 60, third.y + 10);
    try std.testing.expectEqual(@as(i32, 2), f.hit);
    try std.testing.expect(!ui.overflowed);
    try std.testing.expect(ui.need_frame); // 有 running 步骤 → 持续出帧
}

// ------------------------------------------------------------------ 状态药丸

/// 药丸的宽度（圆角 13 的矩形就是药丸本体）。
fn pillWidth(ui: *core.Context) f32 {
    for (ui.cmds[0..ui.cmd_count]) |c| {
        if (c != .rect) continue;
        const r = c.rect.rect;
        if (c.rect.radius < 12.5 or c.rect.radius > 13.5) continue;
        if (r.h < 20 or r.h > 32) continue;
        return r.w;
    }
    return 0;
}

const StF = struct {
    seconds: f32 = 0,
    status: ai.Status = .running,
    fn draw(self: *@This(), ui: *core.Context) void {
        ai.agentStatus(ui, "Searching the web", .{ .status = self.status, .seconds = self.seconds });
    }
};

test "ai: the agent status pill grows with the elapsed time" {
    var ui = core.Context{};
    var f = StF{};
    frame(&ui, 420, 160, &f, .{});
    const w0 = pillWidth(&ui);
    try std.testing.expect(w0 > 40);
    f.seconds = 125; // 「2m 5s」比不带秒数更宽
    frame(&ui, 420, 160, &f, .{});
    try std.testing.expect(pillWidth(&ui) > w0);
    try std.testing.expect(ui.need_frame);
    // 完成态不再呼吸
    f.status = .done;
    frame(&ui, 420, 160, &f, .{});
    try std.testing.expect(!ui.need_frame);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 来源与引用

const sources = [_]ai.Source{
    .{ .title = "Zig language reference", .url = "https://ziglang.org", .snippet = "Comptime is a way of..." },
    .{ .title = "std docs", .url = "https://ziglang.org/documentation" },
    .{ .title = "release notes" },
};

const SlF = struct {
    hit: i32 = -9,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.hit = ai.sourceList(ui, "sl", sources[0..]);
    }
};

test "ai: the source list reports the clicked card" {
    var ui = core.Context{};
    var f = SlF{};
    frame(&ui, 480, 320, &f, .{});
    try std.testing.expectEqual(@as(i32, -1), f.hit);
    const first = ui.lastRect(core.Context.idOf("sl") ^ 0x50C0).?;
    const second = ui.lastRect(core.Context.idOf("sl") ^ (0x50C0 + 1)).?;
    try std.testing.expect(first.h > second.h); // 带摘要的卡片更高
    click(&ui, 480, 320, &f, second.x + 60, second.y + 10);
    try std.testing.expectEqual(@as(i32, 1), f.hit);
    try std.testing.expect(!ui.overflowed);
}

const cite_src = ai.Source{
    .title = "Zig 0.17 release notes",
    .url = "https://ziglang.org/download",
    .snippet = "New @splat syntax",
};

const CiF = struct {
    hit: bool = false,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.hit = ai.citation(ui, 3, cite_src);
    }
};

test "ai: a citation shows its card on hover and reports clicks" {
    var ui = core.Context{};
    var f = CiF{};
    // 首帧把鼠标放远（默认 (0,0) 正好压在引用块上）
    frame(&ui, 420, 200, &f, .{ .mouse = at(400, 190) });
    const box = ui.lastRect(core.Context.idOf("citation") ^ (3 *% 0x9E37)).?;
    try std.testing.expectEqual(@as(usize, 0), ui.overlay_count);
    const cx = box.x + box.w * 0.5;
    const cy = box.y + box.h * 0.5;
    hover(&ui, 420, 200, &f, cx, cy);
    try std.testing.expect(ui.overlay_count > 0); // 悬停 → 浮层卡
    try std.testing.expect(!f.hit);
    click(&ui, 420, 200, &f, cx, cy);
    try std.testing.expect(f.hit);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 上下文环

const CmF = struct {
    used: f32 = 0,
    limit: f32 = 100,
    fn draw(self: *@This(), ui: *core.Context) void {
        ai.contextMeter(ui, "cm", .{ .used = self.used, .limit = self.limit });
    }
};

test "ai: the context meter steps through green, amber and red" {
    try std.testing.expectEqual(trace.Tone.success, ai.contextTone(0.1));
    try std.testing.expectEqual(trace.Tone.success, ai.contextTone(0.8));
    try std.testing.expectEqual(trace.Tone.warn, ai.contextTone(0.81));
    try std.testing.expectEqual(trace.Tone.warn, ai.contextTone(0.95));
    try std.testing.expectEqual(trace.Tone.danger, ai.contextTone(0.96));
    var ui = core.Context{};
    var f = CmF{};
    frame(&ui, 360, 140, &f, .{});
    const ring = ui.lastRect(core.Context.idOf("cm") ^ 0x3C07).?;
    try std.testing.expect(ring.w > 20);
    hover(&ui, 360, 140, &f, ring.x + 10, ring.y + 10);
    try std.testing.expect(ui.overlay_count > 0); // 悬停出 token 明细
    // 越界值不 panic（超上限 / 零上限 / NaN）
    f.used = 1.0e30;
    f.limit = 0;
    frame(&ui, 360, 140, &f, .{});
    try std.testing.expect(!ui.overflowed);
    f.used = std.math.nan(f32);
    f.limit = 100;
    frame(&ui, 360, 140, &f, .{});
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 回复操作

const RaF = struct {
    vote: i8 = 0,
    flags: u32 = 0,
    opts: ai.ResponseActionsOpts = .{},
    fn draw(self: *@This(), ui: *core.Context) void {
        self.flags = ai.responseActions(ui, "ra", &self.vote, self.opts);
    }
};

test "ai: response actions return bit flags and toggle the vote" {
    var ui = core.Context{};
    var f = RaF{};
    frame(&ui, 480, 160, &f, .{});
    try std.testing.expectEqual(@as(u32, 0), f.flags);
    const copy = ui.lastRect(core.Context.idOf("ra") ^ 0x0C01).?;
    const up = ui.lastRect(core.Context.idOf("ra") ^ 0x0C03).?;
    const down = ui.lastRect(core.Context.idOf("ra") ^ 0x0C04).?;
    click(&ui, 480, 160, &f, up.x + up.w * 0.5, up.y + up.h * 0.5);
    try std.testing.expectEqual(ai.RESPONSE_UP, f.flags);
    try std.testing.expectEqual(@as(i8, 1), f.vote);
    // 再点 → 取消赞
    click(&ui, 480, 160, &f, up.x + up.w * 0.5, up.y + up.h * 0.5);
    try std.testing.expectEqual(@as(u32, 0), f.flags);
    try std.testing.expectEqual(@as(i8, 0), f.vote);
    // 踩
    click(&ui, 480, 160, &f, down.x + down.w * 0.5, down.y + down.h * 0.5);
    try std.testing.expectEqual(ai.RESPONSE_DOWN, f.flags);
    try std.testing.expectEqual(@as(i8, -1), f.vote);
    // 复制
    click(&ui, 480, 160, &f, copy.x + copy.w * 0.5, copy.y + copy.h * 0.5);
    try std.testing.expectEqual(ai.RESPONSE_COPY, f.flags);
    // 关掉 regenerate / share 后这两颗不再声明
    f.opts = .{ .has_regenerate = false, .has_share = false };
    frame(&ui, 480, 160, &f, .{});
    try std.testing.expect(ui.lastRect(core.Context.idOf("ra") ^ 0x0C02) == null);
    try std.testing.expect(ui.lastRect(core.Context.idOf("ra") ^ 0x0C05) == null);
    try std.testing.expect(ui.lastRect(core.Context.idOf("ra") ^ 0x0C01) != null);
}

// ------------------------------------------------------------------ 提示建议

const sugg = [_]ai.PromptSuggestion{
    .{ .icon = "*", .title = "Explain this", .detail = "Walk through the code" },
    .{ .icon = "*", .title = "Write tests", .detail = "Cover the edge cases" },
    .{ .icon = "*", .title = "Refactor", .detail = "Split long functions" },
};

const PsF = struct {
    hit: i32 = -9,
    cols: usize = 2,
    fn draw(self: *@This(), ui: *core.Context) void {
        var col = ui.column(.{ .pad = 12, .gap = 8 });
        defer col.end();
        self.hit = ai.promptSuggestions(ui, "ps", sugg[0..], self.cols);
    }
};

test "ai: prompt suggestions wrap into columns and report the card" {
    var ui = core.Context{};
    var f = PsF{};
    frame(&ui, 560, 340, &f, .{});
    const first = ui.lastRect(core.Context.idOf("ps") ^ 0x7B00).?;
    const second = ui.lastRect(core.Context.idOf("ps") ^ 0x7B01).?;
    const third = ui.lastRect(core.Context.idOf("ps") ^ 0x7B02).?;
    // 两列：同一行并排、第三张换行且 x 与第一张对齐
    try std.testing.expect(second.x > first.x + first.w - 2);
    try std.testing.expectApproxEqAbs(first.y, second.y, 0.5);
    try std.testing.expectApproxEqAbs(first.x, third.x, 0.5);
    try std.testing.expect(third.y > first.y + first.h - 2);
    click(&ui, 560, 340, &f, third.x + 20, third.y + 20);
    try std.testing.expectEqual(@as(i32, 2), f.hit);
    // 单列：各占一行、更宽
    f.cols = 1;
    frame(&ui, 560, 420, &f, .{});
    const a = ui.lastRect(core.Context.idOf("ps") ^ 0x7B00).?;
    const b = ui.lastRect(core.Context.idOf("ps") ^ 0x7B01).?;
    try std.testing.expect(b.y > a.y + a.h - 2);
    try std.testing.expect(a.w > first.w + 1);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 模型选择

const models = [_]ai.Model{
    .{ .name = "DeepSeek V4.1 Flash", .detail = "fast, 128k context", .badge = "fast" },
    .{ .name = "DeepSeek V4.1 Pro", .detail = "deeper reasoning" },
};

const MpF = struct {
    st: ai.ModelPickerState = .{},
    sel: usize = 0,
    changed: bool = false,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.changed = ai.modelPicker(ui, "mp", &self.st, models[0..], &self.sel, false);
    }
};

test "ai: the model picker opens, selects and closes" {
    var ui = core.Context{};
    var f = MpF{};
    frame(&ui, 460, 320, &f, .{});
    try std.testing.expect(!f.st.open);
    const btn = ui.lastRect(core.Context.idOf("mp") ^ 0x3D00).?;
    // 按钮上带徽标 → 比纯文本宽
    try std.testing.expect(btn.w > ui.measureText(models[0].name, theme.font_small).w + 20);
    click(&ui, 460, 320, &f, btn.x + 20, btn.y + 12);
    try std.testing.expect(f.st.open);
    try std.testing.expect(!f.changed);
    frame(&ui, 460, 320, &f, .{});
    const row1 = ui.lastRect(core.Context.idOf("mp") ^ (0x3E00 + 1)).?;
    try std.testing.expect(row1.y > btn.y + btn.h - 2); // 浮层在按钮下方
    click(&ui, 460, 320, &f, row1.x + 30, row1.y + 12);
    try std.testing.expect(f.changed);
    try std.testing.expectEqual(@as(usize, 1), f.sel);
    try std.testing.expect(!f.st.open); // 选完收起
    try std.testing.expect(!ui.overflowed);
    // 再点按钮 → 打开；点列表外面 → 收起
    click(&ui, 460, 320, &f, btn.x + 20, btn.y + 12);
    try std.testing.expect(f.st.open);
    frame(&ui, 460, 320, &f, .{});
    click(&ui, 460, 320, &f, 430, 300);
    try std.testing.expect(!f.st.open);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 聊天输入框

const attach = [_][]const u8{ "notes.md", "main.zig" };

const CmpF = struct {
    st: ai.ComposerState = .{},
    mp: ai.ModelPickerState = .{},
    sel: usize = 0,
    busy: bool = false,
    flags: u32 = 0,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.flags = ai.chatComposer(ui, "cmp", &self.st, models[0..], &self.sel, &self.mp, .{
            .attachments = attach[0..],
            .busy = self.busy,
        });
    }
};

test "ai: the composer removes attachments, sends on enter and switches to stop" {
    var ui = core.Context{};
    var f = CmpF{};
    frame(&ui, 520, 340, &f, .{});
    const chip0 = ui.lastRect(core.Context.idOf("cmp") ^ 0x4A00).?;
    const chip1 = ui.lastRect(core.Context.idOf("cmp") ^ 0x4A01).?;
    try std.testing.expect(chip1.x > chip0.x); // 两个附件片并排
    // 点第二个片右侧的叉
    click(&ui, 520, 340, &f, chip1.x + chip1.w - 8, chip1.y + chip1.h * 0.5);
    try std.testing.expectEqual(ai.COMPOSER_REMOVE, f.flags);
    try std.testing.expectEqual(@as(i32, 1), f.st.removed);
    // 输入 "hi" 后回车 → 发送，且回车写进去的换行被撤掉
    f.st.buf[0] = 'h';
    f.st.buf[1] = 'i';
    f.st.len = 2;
    f.st.caret = 2;
    ui.focus_id = core.Context.idOf("cmp") ^ 0x7A47E;
    frame(&ui, 520, 340, &f, .{});
    frame(&ui, 520, 340, &f, keysOf(.enter));
    try std.testing.expectEqual(ai.COMPOSER_SEND, f.flags);
    try std.testing.expectEqualStrings("hi", f.st.buf[0..f.st.len]);
    // 生成中回车 → 停止
    f.busy = true;
    frame(&ui, 520, 340, &f, .{});
    frame(&ui, 520, 340, &f, keysOf(.enter));
    try std.testing.expectEqual(ai.COMPOSER_STOP, f.flags);
    try std.testing.expect(!ui.overflowed);
}

const Cmp2F = struct {
    st: ai.ComposerState = .{},
    mp: ai.ModelPickerState = .{},
    sel: usize = 0,
    flags: u32 = 0,
    send: ?types.Rect = null,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.flags = ai.chatComposer(ui, "cmp2", &self.st, &.{}, &self.sel, &self.mp, .{});
        // Send 是底部行最右侧的按钮
        var found: ?types.Rect = null;
        for (ui.hits_curr[0..ui.hits_curr_n]) |h| {
            if (h.rect.h < 26 or h.rect.h > 40) continue;
            if (found == null or h.rect.x > found.?.x) found = h.rect;
        }
        self.send = found;
    }
};

test "ai: the composer hides the model picker without models and sends from the button" {
    var ui = core.Context{};
    var f = Cmp2F{};
    f.st.buf[0] = 'x';
    f.st.len = 1;
    f.st.caret = 1;
    frame(&ui, 520, 300, &f, .{});
    try std.testing.expect(ui.lastRect(core.Context.idOf("cmp2") ^ 0x3D00) == null); // 无模型 → 不声明
    try std.testing.expect(f.send != null);
    const p = f.send.?;
    click(&ui, 520, 300, &f, p.x + p.w * 0.5, p.y + p.h * 0.5);
    try std.testing.expectEqual(ai.COMPOSER_SEND, f.flags);
    try std.testing.expect(!ui.overflowed);
}

// ------------------------------------------------------------------ 语音球

const VoF = struct {
    state: ai.VoiceState = .idle,
    level: f32 = 0,
    hit: bool = false,
    fn draw(self: *@This(), ui: *core.Context) void {
        self.hit = ai.voiceOrb(ui, "vo", self.state, self.level, 72);
    }
};

test "ai: the voice orb reports clicks and keeps animating while active" {
    var ui = core.Context{};
    var f = VoF{};
    frame(&ui, 320, 200, &f, .{});
    try std.testing.expect(!ui.need_frame); // 静止不空转
    const orb = ui.lastRect(core.Context.idOf("vo") ^ 0x0A11).?;
    try std.testing.expectApproxEqAbs(@as(f32, 72), orb.w, 0.5);
    f.state = .listening;
    f.level = 0.8;
    frame(&ui, 320, 200, &f, .{});
    try std.testing.expect(ui.need_frame);
    click(&ui, 320, 200, &f, orb.x + orb.w * 0.5, orb.y + orb.h * 0.5);
    try std.testing.expect(f.hit);
    try std.testing.expect(!ui.overflowed);
}
