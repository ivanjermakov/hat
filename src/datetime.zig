// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2022, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //

// Some of this is ported from cpython's datetime module
const std = @import("std");
const time = std.time;
const math = std.math;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const testing = std.testing;
const assert = std.debug.assert;

pub const MIN_YEAR: u16 = 1;
pub const MAX_YEAR: u16 = 9999;
pub const MAX_ORDINAL: u32 = 3652059;

const DAYS_IN_MONTH = [12]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
const DAYS_BEFORE_MONTH = [12]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };

pub fn isLeapYear(year: u32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

pub fn isLeapDay(year: u32, month: u32, day: u32) bool {
    return isLeapYear(year) and month == 2 and day == 29;
}

// Number of days before Jan 1st of year
pub fn daysBeforeYear(year: u32) u32 {
    const y: u32 = year - 1;
    return y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
}

// Days before 1 Jan 1970
const EPOCH = daysBeforeYear(1970) + 1;

// Number of days in that month for the year
pub fn daysInMonth(year: u32, month: u32) u8 {
    assert(1 <= month and month <= 12);
    if (month == 2 and isLeapYear(year)) return 29;
    return DAYS_IN_MONTH[month - 1];
}

// Number of days in year preceding the first day of month
pub fn daysBeforeMonth(year: u32, month: u32) u32 {
    assert(month >= 1 and month <= 12);
    var d = DAYS_BEFORE_MONTH[month - 1];
    if (month > 2 and isLeapYear(year)) d += 1;
    return d;
}

// Return number of days since 01-Jan-0001
fn ymd2ord(year: u16, month: u8, day: u8) u32 {
    assert(month >= 1 and month <= 12);
    assert(day >= 1 and day <= daysInMonth(year, month));
    return daysBeforeYear(year) + daysBeforeMonth(year, month) + day;
}

pub const Date = struct {
    year: u16,
    month: u4 = 1, // Month of year
    day: u8 = 1, // Day of month

    // Create and validate the date
    pub fn create(year: u32, month: u32, day: u32) !Date {
        if (year < MIN_YEAR or year > MAX_YEAR) return error.InvalidDate;
        if (month < 1 or month > 12) return error.InvalidDate;
        if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDate;
        // Since we just validated the ranges we can now safely cast
        return Date{
            .year = @intCast(year),
            .month = @intCast(month),
            .day = @intCast(day),
        };
    }

    // Create a Date from the number of days since 01-Jan-0001
    pub fn fromOrdinal(ordinal: u32) Date {
        // n is a 1-based index, starting at 1-Jan-1.  The pattern of leap years
        // repeats exactly every 400 years.  The basic strategy is to find the
        // closest 400-year boundary at or before n, then work with the offset
        // from that boundary to n.  Life is much clearer if we subtract 1 from
        // n first -- then the values of n at 400-year boundaries are exactly
        // those divisible by DI400Y:
        //
        //     D  M   Y            n              n-1
        //     -- --- ----        ----------     ----------------
        //     31 Dec -400        -DI400Y        -DI400Y -1
        //      1 Jan -399        -DI400Y +1     -DI400Y       400-year boundary
        //     ...
        //     30 Dec  000        -1             -2
        //     31 Dec  000         0             -1
        //      1 Jan  001         1              0            400-year boundary
        //      2 Jan  001         2              1
        //      3 Jan  001         3              2
        //     ...
        //     31 Dec  400         DI400Y        DI400Y -1
        //      1 Jan  401         DI400Y +1     DI400Y        400-year boundary
        assert(ordinal >= 1 and ordinal <= MAX_ORDINAL);

        var n = ordinal - 1;
        const DI400Y = comptime daysBeforeYear(401); // Num of days in 400 years
        const DI100Y = comptime daysBeforeYear(101); // Num of days in 100 years
        const DI4Y = comptime daysBeforeYear(5); // Num of days in 4   years
        const n400 = @divFloor(n, DI400Y);
        n = @mod(n, DI400Y);
        var year = n400 * 400 + 1; //  ..., -399, 1, 401, ...

        // Now n is the (non-negative) offset, in days, from January 1 of year, to
        // the desired date.  Now compute how many 100-year cycles precede n.
        // Note that it's possible for n100 to equal 4!  In that case 4 full
        // 100-year cycles precede the desired day, which implies the desired
        // day is December 31 at the end of a 400-year cycle.
        const n100 = @divFloor(n, DI100Y);
        n = @mod(n, DI100Y);

        // Now compute how many 4-year cycles precede it.
        const n4 = @divFloor(n, DI4Y);
        n = @mod(n, DI4Y);

        // And now how many single years.  Again n1 can be 4, and again meaning
        // that the desired day is December 31 at the end of the 4-year cycle.
        const n1 = @divFloor(n, 365);
        n = @mod(n, 365);

        year += n100 * 100 + n4 * 4 + n1;

        if (n1 == 4 or n100 == 4) {
            assert(n == 0);
            return Date.create(year - 1, 12, 31) catch unreachable;
        }

        // Now the year is correct, and n is the offset from January 1.  We find
        // the month via an estimate that's either exact or one too large.
        const leapyear = (n1 == 3) and (n4 != 24 or n100 == 3);
        assert(leapyear == isLeapYear(year));
        var month = (n + 50) >> 5;
        if (month == 0) month = 12; // Loop around
        var preceding = daysBeforeMonth(year, month);

        if (preceding > n) { // estimate is too large
            month -= 1;
            if (month == 0) month = 12; // Loop around
            preceding -= daysInMonth(year, month);
        }
        n -= preceding;
        // assert(n > 0 and n < daysInMonth(year, month));

        // Now the year and month are correct, and n is the offset from the
        // start of that month:  we're done!
        return Date.create(year, month, n + 1) catch unreachable;
    }

    // Returns todays date
    pub fn now() Date {
        return Date.fromTimestamp(time.milliTimestamp());
    }

    // Create a date from the number of seconds since 1 Jan 1970
    pub fn fromSeconds(seconds: f64) Date {
        const r = math.modf(seconds);
        const timestamp: i64 = @intFromFloat(r.ipart); // Seconds
        const days = @divFloor(timestamp, time.s_per_day) + @as(i64, EPOCH);
        assert(days >= 0 and days <= MAX_ORDINAL);
        return Date.fromOrdinal(@intCast(days));
    }

    // Create a date from a UTC timestamp in milliseconds relative to Jan 1st 1970
    pub fn fromTimestamp(timestamp: i64) Date {
        const days = @divFloor(timestamp, time.ms_per_day) + @as(i64, EPOCH);
        assert(days >= 0 and days <= MAX_ORDINAL);
        return Date.fromOrdinal(@intCast(days));
    }

    pub fn eql(self: Date, other: Date) bool {
        return self.cmp(other) == .eq;
    }

    pub fn cmp(self: Date, other: Date) Order {
        if (self.year > other.year) return .gt;
        if (self.year < other.year) return .lt;
        if (self.month > other.month) return .gt;
        if (self.month < other.month) return .lt;
        if (self.day > other.day) return .gt;
        if (self.day < other.day) return .lt;
        return .eq;
    }

    // Parse date in format YYYY-MM-DD. Numbers must be zero padded.
    pub fn parseIso(ymd: []const u8) !Date {
        const value = std.mem.trim(u8, ymd, " ");
        if (value.len != 10) return error.InvalidFormat;
        const year = std.fmt.parseInt(u16, value[0..4], 10) catch return error.InvalidFormat;
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidFormat;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch return error.InvalidFormat;
        return Date.create(year, month, day);
    }

    // Return date in ISO format YYYY-MM-DD
    const ISO_DATE_FMT = "{:0>4}-{:0>2}-{:0>2}";

    pub fn formatIso(self: Date, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, ISO_DATE_FMT, .{ self.year, self.month, self.day });
    }

    pub fn formatIsoBuf(self: Date, buf: []u8) ![]u8 {
        return std.fmt.bufPrint(buf, ISO_DATE_FMT, .{ self.year, self.month, self.day });
    }

    pub fn writeIso(self: Date, writer: anytype) !void {
        try std.fmt.format(writer, ISO_DATE_FMT, .{ self.year, self.month, self.day });
    }
};

pub const Time = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    nanosecond: u32 = 0,

    pub fn now() Time {
        return Time.fromTimestamp(time.milliTimestamp());
    }

    // Create a Time struct and validate that all fields are in range
    pub fn create(hour: u32, minute: u32, second: u32, nanosecond: u32) !Time {
        if (hour > 23 or minute > 59 or second > 59 or nanosecond > 999999999) {
            return error.InvalidTime;
        }
        return Time{
            .hour = @intCast(hour),
            .minute = @intCast(minute),
            .second = @intCast(second),
            .nanosecond = nanosecond,
        };
    }

    // Create Time from a UTC Timestamp in milliseconds
    pub fn fromTimestamp(timestamp: i64) Time {
        const remainder = @mod(timestamp, time.ms_per_day);
        var t: u64 = @abs(remainder);
        // t is now only the time part of the day
        const h: u32 = @intCast(@divFloor(t, time.ms_per_hour));
        t -= h * time.ms_per_hour;
        const m: u32 = @intCast(@divFloor(t, time.ms_per_min));
        t -= m * time.ms_per_min;
        const s: u32 = @intCast(@divFloor(t, time.ms_per_s));
        t -= s * time.ms_per_s;
        const ns: u32 = @intCast(t * time.ns_per_ms);
        return Time.create(h, m, s, ns) catch unreachable;
    }

    // From seconds since the start of the day
    pub fn fromSeconds(seconds: f64) Time {
        assert(seconds >= 0);
        // Convert to s and us
        const r = math.modf(seconds);
        var s: u32 = @intFromFloat(@mod(r.ipart, time.s_per_day)); // s
        const h = @divFloor(s, time.s_per_hour);
        s -= h * time.s_per_hour;
        const m = @divFloor(s, time.s_per_min);
        s -= m * time.s_per_min;

        // Rounding seems to only be accurate to within 100ns
        // for normal timestamps
        var frac = math.round(r.fpart * time.ns_per_s / 100) * 100;
        if (frac >= time.ns_per_s) {
            s += 1;
            frac -= time.ns_per_s;
        } else if (frac < 0) {
            s -= 1;
            frac += time.ns_per_s;
        }
        const ns: u32 = @intFromFloat(frac);
        return Time.create(h, m, s, ns) catch unreachable; // If this fails it's a bug
    }

    // Convert to a time in seconds including the nanosecond component
    pub fn toSeconds(self: Time) f64 {
        const s: f64 = @floatFromInt(self.totalSeconds());
        const ns = @as(f64, @floatFromInt(self.nanosecond)) / time.ns_per_s;
        return s + ns;
    }

    // Convert to a timestamp in milliseconds from UTC
    pub fn toTimestamp(self: Time) i64 {
        const h = @as(i64, @intCast(self.hour)) * time.ms_per_hour;
        const m = @as(i64, @intCast(self.minute)) * time.ms_per_min;
        const s = @as(i64, @intCast(self.second)) * time.ms_per_s;
        const ms: i64 = @intCast(self.nanosecond / time.ns_per_ms);
        return h + m + s + ms;
    }

    // Total seconds from the start of day
    pub fn totalSeconds(self: Time) i32 {
        const h = @as(i32, @intCast(self.hour)) * time.s_per_hour;
        const m = @as(i32, @intCast(self.minute)) * time.s_per_min;
        const s: i32 = @intCast(self.second);
        return h + m + s;
    }

    pub fn eql(self: Time, other: Time) bool {
        return self.cmp(other) == .eq;
    }

    pub fn cmp(self: Time, other: Time) Order {
        const t1 = self.totalSeconds();
        const t2 = other.totalSeconds();
        if (t1 > t2) return .gt;
        if (t1 < t2) return .lt;
        if (self.nanosecond > other.nanosecond) return .gt;
        if (self.nanosecond < other.nanosecond) return .lt;
        return .eq;
    }

    pub fn gt(self: Time, other: Time) bool {
        return self.cmp(other) == .gt;
    }

    pub fn gte(self: Time, other: Time) bool {
        const r = self.cmp(other);
        return r == .eq or r == .gt;
    }

    pub fn lt(self: Time, other: Time) bool {
        return self.cmp(other) == .lt;
    }

    pub fn lte(self: Time, other: Time) bool {
        const r = self.cmp(other);
        return r == .eq or r == .lt;
    }

    pub fn amOrPm(self: Time) []const u8 {
        return if (self.hour > 12) return "PM" else "AM";
    }

    const ISO_HM_FORMAT = "T{d:0>2}:{d:0>2}";
    const ISO_HMS_FORMAT = "T{d:0>2}:{d:0>2}:{d:0>2}";

    pub fn writeIsoHM(self: Time, writer: anytype) !void {
        try std.fmt.format(writer, ISO_HM_FORMAT, .{ self.hour, self.minute });
    }

    pub fn writeIsoHMS(self: Time, writer: anytype) !void {
        try std.fmt.format(writer, ISO_HMS_FORMAT, .{ self.hour, self.minute, self.second });
    }
};

pub const Datetime = struct {
    date: Date,
    time: Time,

    // An absolute or relative delta
    // if years is defined a date is date
    pub const Delta = struct {
        years: i16 = 0,
        days: i32 = 0,
        seconds: i64 = 0,
        nanoseconds: i32 = 0,
        relative_to: ?Datetime = null,

        pub fn sub(self: Delta, other: Delta) Delta {
            return Delta{
                .years = self.years - other.years,
                .days = self.days - other.days,
                .seconds = self.seconds - other.seconds,
                .nanoseconds = self.nanoseconds - other.nanoseconds,
                .relative_to = self.relative_to,
            };
        }

        pub fn add(self: Delta, other: Delta) Delta {
            return Delta{
                .years = self.years + other.years,
                .days = self.days + other.days,
                .seconds = self.seconds + other.seconds,
                .nanoseconds = self.nanoseconds + other.nanoseconds,
                .relative_to = self.relative_to,
            };
        }

        // Total seconds in the duration ignoring the nanoseconds fraction
        pub fn totalSeconds(self: Delta) i64 {
            // Calculate the total number of days we're shifting
            var days = self.days;
            if (self.relative_to) |dt| {
                if (self.years != 0) {
                    const a = daysBeforeYear(dt.date.year);
                    // Must always subtract greater of the two
                    if (self.years > 0) {
                        const y: u32 = @intCast(self.years);
                        const b = daysBeforeYear(dt.date.year + y);
                        days += @intCast(b - a);
                    } else {
                        const y: u32 = @intCast(-self.years);
                        assert(y < dt.date.year); // Does not work below year 1
                        const b = daysBeforeYear(dt.date.year - y);
                        days -= @intCast(a - b);
                    }
                }
            } else {
                // Cannot use years without a relative to date
                // otherwise any leap days will screw up results
                assert(self.years == 0);
            }
            var s = self.seconds;
            var ns = self.nanoseconds;
            if (ns >= time.ns_per_s) {
                const ds = @divFloor(ns, time.ns_per_s);
                ns -= ds * time.ns_per_s;
                s += ds;
            } else if (ns <= -time.ns_per_s) {
                const ds = @divFloor(ns, -time.ns_per_s);
                ns += ds * time.us_per_s;
                s -= ds;
            }
            return (days * time.s_per_day + s);
        }
    };

    pub fn now() Datetime {
        return Datetime.fromTimestamp(time.milliTimestamp());
    }

    pub fn create(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32, nanosecond: u32) !Datetime {
        return Datetime{
            .date = try Date.create(year, month, day),
            .time = try Time.create(hour, minute, second, nanosecond),
        };
    }

    pub fn fromDate(year: u16, month: u8, day: u8) !Datetime {
        return Datetime{
            .date = try Date.create(year, month, day),
            .time = try Time.create(0, 0, 0, 0),
        };
    }

    // From seconds since 1 Jan 1970
    pub fn fromSeconds(seconds: f64) Datetime {
        return Datetime{
            .date = Date.fromSeconds(seconds),
            .time = Time.fromSeconds(seconds),
        };
    }

    // From POSIX timestamp in milliseconds relative to 1 Jan 1970
    pub fn fromTimestamp(timestamp: i64) Datetime {
        const t = @divFloor(timestamp, time.ms_per_day);
        const d: u64 = @abs(t);
        const days = if (timestamp >= 0) d + EPOCH else EPOCH - d;
        assert(days >= 0 and days <= MAX_ORDINAL);
        return Datetime{
            .date = Date.fromOrdinal(@intCast(days)),
            .time = Time.fromTimestamp(timestamp - @as(i64, @intCast(d)) * time.ns_per_day),
        };
    }

    // From a file modified time in ns
    pub fn fromModifiedTime(mtime: i128) Datetime {
        const ts: i64 = @intCast(@divFloor(mtime, time.ns_per_ms));
        return Datetime.fromTimestamp(ts);
    }

    pub fn eql(self: Datetime, other: Datetime) bool {
        return self.cmp(other) == .eq;
    }

    pub fn cmp(self: Datetime, other: Datetime) Order {
        return self.time.cmp(other.time);
    }

    /// Format datetime to ISO8601 format
    /// e.g. "2023-06-10T14:06:40.015006"
    pub fn formatISO8601Alloc(self: Datetime, allocator: Allocator, with_micro: bool) ![]const u8 {
        var micro_part_len: u3 = 0;
        var micro_part: [7]u8 = undefined;
        if (with_micro) {
            _ = try std.fmt.bufPrint(&micro_part, ".{:0>6}", .{self.time.nanosecond / 1000});
            micro_part_len = 7;
        }

        return try std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}",
            .{
                self.date.year,
                self.date.month,
                self.date.day,
                self.time.hour,
                self.time.minute,
                self.time.second,
                micro_part[0..micro_part_len],
            },
        );
    }

    pub fn formatISO8601Buf(self: Datetime, buf: []u8, with_micro: bool) ![]const u8 {
        var micro_part_len: usize = 0;
        var micro_part: [7]u8 = undefined;
        if (with_micro) {
            _ = try std.fmt.bufPrint(&micro_part, ".{:0>6}", .{self.time.nanosecond / 1000});
            micro_part_len = 7;
        }

        return try std.fmt.bufPrint(
            buf,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}",
            .{
                self.date.year,
                self.date.month,
                self.date.day,
                self.time.hour,
                self.time.minute,
                self.time.second,
                micro_part[0..micro_part_len],
            },
        );
    }
};

test "datetime-now" {
    _ = Datetime.now();
}

test "datetime-format-ISO8601" {
    const allocator = std.testing.allocator;

    var dt = try Datetime.create(2023, 6, 10, 9, 12, 52, 49612000);
    var dt_str = try dt.formatISO8601Alloc(allocator, false);
    try testing.expectEqualStrings("2023-06-10T09:12:52", dt_str);
    allocator.free(dt_str);

    // test positive tz
    dt = try Datetime.create(2023, 6, 10, 18, 12, 52, 49612000);
    dt_str = try dt.formatISO8601Alloc(allocator, false);
    try testing.expectEqualStrings("2023-06-10T18:12:52", dt_str);
    allocator.free(dt_str);

    // test negative tz
    dt = try Datetime.create(2023, 6, 10, 6, 12, 52, 49612000);
    dt_str = try dt.formatISO8601Alloc(allocator, false);
    try testing.expectEqualStrings("2023-06-10T06:12:52", dt_str);
    allocator.free(dt_str);

    // test tz offset div and mod
    dt = try Datetime.create(2023, 6, 10, 22, 57, 52, 49612000);
    dt_str = try dt.formatISO8601Alloc(allocator, false);
    try testing.expectEqualStrings("2023-06-10T22:57:52", dt_str);
    allocator.free(dt_str);

    // test microseconds
    dt = try Datetime.create(2023, 6, 10, 5, 57, 52, 49612000);
    dt_str = try dt.formatISO8601Alloc(allocator, true);
    try testing.expectEqualStrings("2023-06-10T05:57:52.049612", dt_str);
    allocator.free(dt_str);

    // test format buf
    var buf: [64]u8 = undefined;
    dt = try Datetime.create(2023, 6, 10, 14, 6, 40, 15006000);
    dt_str = try dt.formatISO8601Buf(&buf, true);
    try testing.expectEqualStrings("2023-06-10T14:06:40.015006", dt_str);
}

test "leapyear" {
    try testing.expect(isLeapYear(2019) == false);
    try testing.expect(isLeapYear(2018) == false);
    try testing.expect(isLeapYear(2017) == false);
    try testing.expect(isLeapYear(2016) == true);
    try testing.expect(isLeapYear(2000) == true);
    try testing.expect(isLeapYear(1900) == false);
}

test "daysBeforeYear" {
    try testing.expect(daysBeforeYear(1996) == 728658);
    try testing.expect(daysBeforeYear(2019) == 737059);
}

test "daysInMonth" {
    try testing.expect(daysInMonth(2019, 1) == 31);
    try testing.expect(daysInMonth(2019, 2) == 28);
    try testing.expect(daysInMonth(2016, 2) == 29);
}

test "ymd2ord" {
    try testing.expect(ymd2ord(1970, 1, 1) == 719163);
    try testing.expect(ymd2ord(28, 2, 29) == 9921);
    try testing.expect(ymd2ord(2019, 11, 27) == 737390);
    try testing.expect(ymd2ord(2019, 11, 28) == 737391);
}

test "days-before-year" {
    const DI400Y = daysBeforeYear(401); // Num of days in 400 years
    const DI100Y = daysBeforeYear(101); // Num of days in 100 years
    const DI4Y = daysBeforeYear(5); // Num of days in 4   years

    // A 4-year cycle has an extra leap day over what we'd get from pasting
    // together 4 single years.
    try testing.expect(DI4Y == 4 * 365 + 1);

    // Similarly, a 400-year cycle has an extra leap day over what we'd get from
    // pasting together 4 100-year cycles.
    try testing.expect(DI400Y == 4 * DI100Y + 1);

    // OTOH, a 100-year cycle has one fewer leap day than we'd get from
    // pasting together 25 4-year cycles.
    try testing.expect(DI100Y == 25 * DI4Y - 1);
}

test "date-now" {
    _ = Date.now();
}

test "date-create" {
    try testing.expectError(error.InvalidDate, Date.create(2019, 2, 29));

    var date = Date.fromTimestamp(1574908586928);
    try testing.expect(date.eql(try Date.create(2019, 11, 28)));
}

test "date-parse-iso" {
    try testing.expectEqual(try Date.create(2018, 12, 15), try Date.parseIso("2018-12-15"));
    try testing.expectEqual(try Date.create(2021, 1, 7), try Date.parseIso("2021-01-07"));
    try testing.expectError(error.InvalidDate, Date.parseIso("2021-13-01"));
    try testing.expectError(error.InvalidFormat, Date.parseIso("20-01-01"));
    try testing.expectError(error.InvalidFormat, Date.parseIso("2000-1-1"));
}

test "date-format-iso" {
    const date_strs = [_][]const u8{
        "0959-02-05",
        "2018-12-15",
    };

    for (date_strs) |date_str| {
        var d = try Date.parseIso(date_str);
        const parsed_date_str = try d.formatIso(std.testing.allocator);
        defer std.testing.allocator.free(parsed_date_str);
        try testing.expectEqualStrings(date_str, parsed_date_str);
    }
}

test "date-format-iso-buf" {
    const date_strs = [_][]const u8{
        "0959-02-05",
        "2018-12-15",
    };

    for (date_strs) |date_str| {
        var d = try Date.parseIso(date_str);
        var buf: [32]u8 = undefined;
        try testing.expectEqualStrings(date_str, try d.formatIsoBuf(buf[0..]));
    }
}

test "date-write-iso" {
    const date_strs = [_][]const u8{
        "0959-02-05",
        "2018-12-15",
    };

    for (date_strs) |date_str| {
        var buf: [32]u8 = undefined;
        var stream = std.io.fixedBufferStream(buf[0..]);
        var d = try Date.parseIso(date_str);
        try d.writeIso(stream.writer());
        try testing.expectEqualStrings(date_str, stream.getWritten());
    }
}

test "time-create" {
    const t = Time.fromTimestamp(1574908586928);
    try testing.expect(t.hour == 2);
    try testing.expect(t.minute == 36);
    try testing.expect(t.second == 26);
    try testing.expect(t.nanosecond == 928000000);

    try testing.expectError(error.InvalidTime, Time.create(25, 1, 1, 0));
    try testing.expectError(error.InvalidTime, Time.create(1, 60, 1, 0));
    try testing.expectError(error.InvalidTime, Time.create(12, 30, 281, 0));
    try testing.expectError(error.InvalidTime, Time.create(12, 30, 28, 1000000000));
}

test "time-now" {
    _ = Time.now();
}

test "time-from-seconds" {
    var seconds: f64 = 15.12;
    var t = Time.fromSeconds(seconds);
    try testing.expect(t.hour == 0);
    try testing.expect(t.minute == 0);
    try testing.expect(t.second == 15);
    try testing.expect(t.nanosecond == 120000000);
    try testing.expect(t.toSeconds() == seconds);

    seconds = 315.12; // + 5 min
    t = Time.fromSeconds(seconds);
    try testing.expect(t.hour == 0);
    try testing.expect(t.minute == 5);
    try testing.expect(t.second == 15);
    try testing.expect(t.nanosecond == 120000000);
    try testing.expect(t.toSeconds() == seconds);

    seconds = 36000 + 315.12; // + 10 hr
    t = Time.fromSeconds(seconds);
    try testing.expect(t.hour == 10);
    try testing.expect(t.minute == 5);
    try testing.expect(t.second == 15);
    try testing.expect(t.nanosecond == 120000000);
    try testing.expect(t.toSeconds() == seconds);

    seconds = 108000 + 315.12; // + 30 hr
    t = Time.fromSeconds(seconds);
    try testing.expect(t.hour == 6);
    try testing.expect(t.minute == 5);
    try testing.expect(t.second == 15);
    try testing.expect(t.nanosecond == 120000000);
    try testing.expectEqual(t.totalSeconds(), 6 * 3600 + 315);
    //testing.expectAlmostEqual(t.toSeconds(), seconds-time.s_per_day);
}

test "time-compare" {
    const t1 = try Time.create(8, 30, 0, 0);
    const t2 = try Time.create(9, 30, 0, 0);
    const t3 = try Time.create(8, 0, 0, 0);
    const t4 = try Time.create(9, 30, 17, 0);

    try testing.expect(t1.lt(t2));
    try testing.expect(t1.gt(t3));
    try testing.expect(t2.lt(t4));
    try testing.expect(t3.lt(t4));
}

test "time-write-iso-hm" {
    const t = Time.fromTimestamp(1574908586928);

    var buf: [6]u8 = undefined;
    var fbs = std.io.fixedBufferStream(buf[0..]);

    try t.writeIsoHM(fbs.writer());

    try testing.expectEqualSlices(u8, "T02:36", fbs.getWritten());
}

test "time-write-iso-hms" {
    const t = Time.fromTimestamp(1574908586928);

    var buf: [9]u8 = undefined;
    var fbs = std.io.fixedBufferStream(buf[0..]);

    try t.writeIsoHMS(fbs.writer());

    try testing.expectEqualSlices(u8, "T02:36:26", fbs.getWritten());
}
