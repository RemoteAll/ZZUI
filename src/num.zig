//! 数值格式化：**刻意不用 `std.fmt` 的浮点格式**（`{d:.2}` 之类会把 Zig 的浮点格式化实现
//! 整个拉进产物，实测让 hello 从 173 KB 涨到 247 KB）。这里用整数定点运算，体积可忽略。

/// 把 `v` 按 `decimals`（0..3）位小数写成十进制文本，结果写入 `buf` 并返回切片。
/// 负数带 `-`，小数位不足补零；缓冲区不够时截断（不会越界）。
pub fn fixed(buf: []u8, v: f32, decimals: u8) []const u8 {
    const d: u8 = if (decimals > 3) 3 else decimals;
    var scale: i64 = 1;
    var k: u8 = 0;
    while (k < d) : (k += 1) scale *= 10;

    const scaled_f = @as(f64, v) * @as(f64, @floatFromInt(scale));
    // 超出 i64 范围的值（Inf/NaN/极大值）按 0 处理，避免 @intFromFloat 触发未定义行为
    var scaled: i64 = if (scaled_f > -9.2e18 and scaled_f < 9.2e18)
        @intFromFloat(@round(scaled_f))
    else
        0;
    var neg = false;
    if (scaled < 0) {
        neg = true;
        scaled = -scaled;
    }
    const ip = @divTrunc(scaled, scale);
    const frac = @mod(scaled, scale);

    var n: usize = 0;
    if (neg and n < buf.len) {
        buf[n] = '-';
        n += 1;
    }
    var tmp: [24]u8 = undefined;
    var tn: usize = 0;
    var x = ip;
    if (x == 0) {
        tmp[0] = '0';
        tn = 1;
    }
    while (x > 0 and tn < tmp.len) : (x = @divTrunc(x, 10)) {
        tmp[tn] = @intCast('0' + @as(u8, @intCast(@mod(x, 10))));
        tn += 1;
    }
    while (tn > 0) {
        tn -= 1;
        if (n < buf.len) {
            buf[n] = tmp[tn];
            n += 1;
        }
    }
    if (d > 0) {
        if (n < buf.len) {
            buf[n] = '.';
            n += 1;
        }
        var div: i64 = @divTrunc(scale, 10);
        while (div > 0) : (div = @divTrunc(div, 10)) {
            const digit: u8 = @intCast(@mod(@divTrunc(frac, div), 10));
            if (n < buf.len) {
                buf[n] = '0' + digit;
                n += 1;
            }
        }
    }
    return buf[0..n];
}

/// 整数（有符号）转文本，`buf` 不够时截断。
pub fn int(buf: []u8, v: i64) []const u8 {
    return fixed(buf, @floatFromInt(v), 0);
}

/// 百分比文本（0..1 → "68%"），结果写入 `buf`。
pub fn percent(buf: []u8, ratio: f32) []const u8 {
    const v = if (ratio < 0) 0 else if (ratio > 1) 1 else ratio;
    const digits = fixed(buf[0 .. buf.len - 1], v * 100, 0);
    if (digits.len + 1 <= buf.len) {
        buf[digits.len] = '%';
        return buf[0 .. digits.len + 1];
    }
    return digits;
}

/// 金额文本：整数部分每三位一个逗号（`1234567.5` → `1,234,567.50`）。
/// 同样只用整数定点，**不引入 `std.fmt` 浮点格式化**。
pub fn money(buf: []u8, v: f32, decimals: u8) []const u8 {
    var tmp: [28]u8 = undefined;
    const plain = fixed(&tmp, v, decimals);

    var dot: usize = plain.len;
    var i: usize = 0;
    while (i < plain.len) : (i += 1) {
        if (plain[i] == '.') {
            dot = i;
            break;
        }
    }
    var start: usize = 0;
    var n: usize = 0;
    if (plain.len > 0 and plain[0] == '-') {
        if (n < buf.len) {
            buf[n] = '-';
            n += 1;
        }
        start = 1;
    }
    i = start;
    while (i < dot) : (i += 1) {
        const left = dot - i;
        if (n < buf.len) {
            buf[n] = plain[i];
            n += 1;
        }
        if (left > 1 and (left - 1) % 3 == 0 and n < buf.len) {
            buf[n] = ',';
            n += 1;
        }
    }
    i = dot;
    while (i < plain.len) : (i += 1) {
        if (n < buf.len) {
            buf[n] = plain[i];
            n += 1;
        }
    }
    return buf[0..n];
}

/// 宽松解析十进制数（可带正负号、小数点、千分位逗号）。
/// 手写而不用 `std.fmt.parseFloat`：后者会把整套浮点解析拉进产物（体积红线）。
pub fn parseF32(s: []const u8) ?f32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var int_part: f64 = 0;
    var seen = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c >= '0' and c <= '9') {
            int_part = int_part * 10 + @as(f64, @floatFromInt(c - '0'));
            seen = true;
        } else if (c == ',') {
            continue;
        } else break;
    }
    var frac: f64 = 0;
    var scale: f64 = 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            scale *= 10;
            frac = frac * 10 + @as(f64, @floatFromInt(s[i] - '0'));
            seen = true;
        }
    }
    if (!seen) return null;
    const v = int_part + frac / scale;
    const signed: f64 = if (neg) -v else v;
    if (signed > 3.4e38 or signed < -3.4e38) return null;
    return @floatCast(signed);
}
