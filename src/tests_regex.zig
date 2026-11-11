//! 正则引擎测试（对位 `cui_regex_search`）。
const std = @import("std");
const regex = @import("regex.zig");

fn find(pat: []const u8, flags: u32, text: []const u8, from: usize) struct { r: regex.Result, m: regex.Match } {
    var m = regex.Match{};
    const r = regex.search(pat, flags, text, from, &m, null);
    return .{ .r = r, .m = m };
}

test "regex: a literal match reports byte offsets" {
    const got = find("abc", 0, "xxabcyy", 0);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(i32, 2), got.m.start);
    try std.testing.expectEqual(@as(i32, 5), got.m.end);
}

test "regex: from skips earlier matches" {
    const got = find("a", 0, "aaa", 2);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(i32, 2), got.m.start);
    const none = find("a", 0, "aaa", 5);
    try std.testing.expectEqual(regex.Result.none, none.r);
}

test "regex: character classes and escapes" {
    const d = find("\\d+", 0, "id=42;", 0);
    try std.testing.expectEqual(regex.Result.found, d.r);
    try std.testing.expectEqual(@as(i32, 3), d.m.start);
    try std.testing.expectEqual(@as(i32, 5), d.m.end);

    const w = find("[a-z]+", 0, "  Hello", 0);
    try std.testing.expectEqual(regex.Result.found, w.r);
    try std.testing.expectEqual(@as(i32, 3), w.m.start); // 大写 H 不在 [a-z] 里，从 'e' 起
    try std.testing.expectEqual(@as(i32, 7), w.m.end);

    const neg = find("[^0-9]+", 0, "12ab34", 0);
    try std.testing.expectEqual(regex.Result.found, neg.r);
    try std.testing.expectEqual(@as(i32, 2), neg.m.start);
    try std.testing.expectEqual(@as(i32, 4), neg.m.end);
}

test "regex: dot, DOTALL and MULTILINE" {
    const dot = find("a.c", 0, "a\nc", 0);
    try std.testing.expectEqual(regex.Result.none, dot.r);
    const dotall = find("a.c", regex.DOTALL, "a\nc", 0);
    try std.testing.expectEqual(regex.Result.found, dotall.r);

    const bol = find("^b", 0, "a\nb", 0);
    try std.testing.expectEqual(regex.Result.none, bol.r);
    const multi = find("^b", regex.MULTILINE, "a\nb", 0);
    try std.testing.expectEqual(regex.Result.found, multi.r);
    try std.testing.expectEqual(@as(i32, 2), multi.m.start);
}

test "regex: groups capture and report counts" {
    const got = find("(a)(b+)", 0, "xabbbz", 0);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(usize, 2), got.m.groups);
    try std.testing.expectEqual(@as(i32, 1), got.m.group_start[0]);
    try std.testing.expectEqual(@as(i32, 2), got.m.group_end[0]);
    try std.testing.expectEqual(@as(i32, 2), got.m.group_start[1]);
    try std.testing.expectEqual(@as(i32, 5), got.m.group_end[1]);
}

test "regex: named groups keep their names" {
    const got = find("(?<year>\\d{4})-(?<mon>\\d{2})", 0, "on 2026-11", 0);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(i32, 3), got.m.start);
    try std.testing.expectEqualStrings("year", std.mem.sliceTo(&got.m.group_name[0], 0));
    try std.testing.expectEqualStrings("mon", std.mem.sliceTo(&got.m.group_name[1], 0));
}

test "regex: alternation picks the first branch that fits" {
    const got = find("cat|dog", 0, "a dog", 0);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(i32, 2), got.m.start);
    try std.testing.expectEqual(@as(i32, 5), got.m.end);
}

test "regex: greedy and lazy quantifiers differ" {
    const greedy = find("<.+>", 0, "<a><b>", 0);
    try std.testing.expectEqual(@as(i32, 6), greedy.m.end); // 贪婪吃到最后一个 '>'
    const lazy = find("<.+?>", 0, "<a><b>", 0);
    try std.testing.expectEqual(@as(i32, 3), lazy.m.end);
}

test "regex: bounded repeat" {
    const got = find("a{2,3}", 0, "aaaa", 0);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(i32, 0), got.m.start);
    try std.testing.expectEqual(@as(i32, 3), got.m.end); // 贪婪到上限
    const bounded = find("^a{2}$", 0, "aaa", 0);
    try std.testing.expectEqual(regex.Result.none, bounded.r);
}

test "regex: word boundaries" {
    const got = find("\\bcat\\b", 0, "concatenate cat", 0);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(i32, 12), got.m.start);
}

test "regex: icase flag" {
    const plain = find("abc", 0, "ABC", 0);
    try std.testing.expectEqual(regex.Result.none, plain.r);
    const icase = find("abc", regex.ICASE, "ABC", 0);
    try std.testing.expectEqual(regex.Result.found, icase.r);
}

test "regex: an invalid pattern is reported, not crashed on" {
    var m = regex.Match{};
    var err: []const u8 = "";
    try std.testing.expectEqual(regex.Result.invalid_pattern, regex.search("[abc", 0, "x", 0, &m, &err));
    try std.testing.expect(err.len > 0);
    var err2: []const u8 = "";
    try std.testing.expectEqual(regex.Result.invalid_pattern, regex.search("(a", 0, "x", 0, &m, &err2));
}

test "regex: an empty pattern matches at the start" {
    const got = find("", 0, "abc", 0);
    try std.testing.expectEqual(regex.Result.found, got.r);
    try std.testing.expectEqual(@as(i32, 0), got.m.start);
    try std.testing.expectEqual(@as(i32, 0), got.m.end);
}
