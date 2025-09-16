//
//
//
//
//
//    I. PCREz
//
//
//    `7MM"""Mq.   .g8"""bgd `7MM"""Mq.  `7MM"""YMM
//      MM   `MM..dP'     `M   MM   `MM.   MM    `7
//      MM   ,M9 dM'       `   MM   ,M9    MM   d    M"""MMV
//      MMmmdM9  MM            MMmmdM9     MMmmMM    '  AMV
//      MM       MM.           MM  YM.     MM   Y  ,   AMV
//      MM       `Mb.     ,'   MM   `Mb.   MM     ,M  AMV  ,
//    .JMML.       `"bmmmd'  .JMML. .JMM..JMMmmmmMMM AMMmmmM
//
//
//
//    II. Copyright (c) 2025-present Rocco Ruscitti
//
//
//    III. License
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, and to permit persons to whom the Software is
//    furnished to do so, subject to the following conditions:
//
//    The above copyright notice and this permission notice shall be included in all
//    copies or substantial portions of the Software.
//
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//    SOFTWARE.
//
//
//    IV. Acknowledgement
//    This file is based on the `RegEx` and `RegExMatch` classes from Godot Engine.
//    See /legal/attribution/godot_engine.fey for full attribution.
//
//
//
//
//

pub const RegexMatch = struct {
    subject: []const u8,
    data: AList(Range),
    names: SMap(usize),
    allocator: Allocator,

    const Range = struct {
        start: ?usize = 0,
        end: ?usize = 0,
    };

    pub fn init(alloc_: Allocator) RegexMatch {
        return RegexMatch{
            .subject = undefined,
            .data = AList(Range).init(alloc_),
            .names = SMap(usize).init(alloc_),
            .allocator = alloc_,
        };
    }

    pub fn deinit(self: *RegexMatch) void {
        self.data.deinit();
        self.names.deinit();
    }

    pub fn getSubject(self: *const RegexMatch) []const u8 {
        return self.subject orelse &"";
    }

    pub fn getGroupCount(self: *const RegexMatch) usize {
        if (self.data.len == 0) return 0;
        return self.data.len - 1;
    }

    pub fn getNames(self: *const RegexMatch) SMap(usize) {
        return self.names.clone();
    }

    pub fn getStrings(self: *const RegexMatch) AList([]const u8) {
        const result = AList([]const u8).init(self.allocator);
        for (self.data) |range| {
            if (range.start == -1) {
                result.append(""[0..]);
                continue;
            }
            result.append(self.subject[range.start..range.end]);
        }
    }

    // Groups
    pub fn getNamedString(self: *const RegexMatch, name_: []const u8) []const u8 {
        const index: ?usize = self.getNameIndex(name_);
        return self.getSubstr(index);
    }

    pub fn getStringAt(self: *const RegexMatch, index_: usize) []const u8 {
        const index: ?usize = self.verifyIndex(index_);
        return self.getSubstr(index);
    }

    pub fn getNamedStart(self: *const RegexMatch, name_: []const u8) ?usize {
        const index: ?usize = self.getNameIndex(name_);
        return if (index == null) null else self.data.items[index.?].start;
    }

    pub fn getStartAt(self: *const RegexMatch, index_: usize) ?usize {
        const index: ?usize = self.verifyIndex(index_);
        return if (index == null) null else self.data.items[index.?].start;
    }

    pub fn getNamedEnd(self: *const RegexMatch, name_: []const u8) ?usize {
        const index: ?usize = self.getNameIndex(name_);
        return if (index == null) 0 else self.data.items[index.?].end;
    }

    pub fn getEndAt(self: *const RegexMatch, index_: usize) ?usize {
        const index: ?usize = self.verifyIndex(index_);
        return if (index == null) null else self.data.items[index.?].end;
    }

    // helpers
    fn getNameIndex(self: *const RegexMatch, name_: []const u8) ?usize {
        return self.names.get(name_);
    }

    fn verifyIndex(self: *const RegexMatch, index_: usize) ?usize {
        if (index_ >= self.data.items.len) return null;
        return index_;
    }

    fn getSubstr(self: *const RegexMatch, index_: ?usize) []const u8 {
        if (index_ == null) return ""[0..];
        const range: Range = self.data.items[index_.?];
        if (range.start == null) return ""[0..];
        return self.subject[range.start.?..range.end.?];
    }
};

// TODO: inherits from `RefCounted`
pub const Regex = struct {
    generalCtx: ?*anyopaque,
    code: ?*anyopaque,
    pattern: ?[]const u8 = null,
    allocator: Allocator,

    pub const CompileError = error{
        Failure,
        Compiled,
    };

    pub fn init(alloc_: Allocator) Regex {
        return Regex{
            .generalCtx = re.pcre2_general_context_create_8(&regex_alloc, &regex_free, null),
            .code = null,
            .allocator = alloc_,
        };
    }

    pub fn from(pattern_: []const u8, showError_: bool, alloc_: Allocator) !Regex {
        var regex = Regex.init(alloc_);
        const result: CompileError = regex.compile(pattern_, showError_);
        return switch (result) {
            CompileError.Failure => result,
            CompileError.Compiled => regex,
        };
    }

    pub fn deinit(self: *const Regex) void {
        if (self.code != null) {
            re.pcre2_code_free_8(@as(*re.pcre2_code_8, @ptrCast(self.code)));
        }
        re.pcre2_general_context_free_8(@as(*re.pcre2_general_context_8, @ptrCast(self.generalCtx)));
    }

    pub fn clear(self: *Regex) void {
        if (self.code != null) {
            re.pcre2_code_free_8(@as(*re.pcre2_code_8, @ptrCast(self.code)));
            self.code = null;
        }
    }

    pub fn compile(self: *Regex, pattern_: []const u8, show_error_: bool) CompileError {
        self.pattern = pattern_;
        self.clear();

        var err: c_int = undefined;
        var offset: re.PCRE2_SIZE = undefined;
        const flags: c_uint = re.PCRE2_DUPNAMES;

        const genCtx: *re.pcre2_general_context_8 = @ptrCast(self.generalCtx);
        const compCtx: ?*re.pcre2_compile_context_8 = re.pcre2_compile_context_create_8(genCtx);
        const p: re.PCRE2_SPTR8 = @ptrCast(self.pattern);

        self.code = re.pcre2_compile_8(p, self.pattern.?.len, flags, &err, &offset, compCtx);
        re.pcre2_compile_context_free_8(compCtx);

        if (self.code == null) {
            if (show_error_) {
                var buffer: [256]re.PCRE2_UCHAR8 = [_]u8{0} ** 256;
                _ = re.pcre2_get_error_message_8(err, buffer[0..], 256);
                std.debug.print("{d}: Error compiling regular expression: {s}", .{ offset, buffer[0..] });
            }
            return CompileError.Failure;
        }
        return CompileError.Compiled;
    }

    pub fn search(self: *Regex, subject_: []const u8, offset_: ?usize, end_: ?c_int) ?RegexMatch {
        if (!self.isValid()) {
            std.debug.print("regex is not valid", .{});
            return null;
        }

        const offset = offset_ orelse 0;
        const end = end_ orelse -1;

        var length: usize = subject_.len;
        if (end >= 0 and end < length) {
            length = @intCast(end);
        }

        const code: *re.pcre2_code_8 = @ptrCast(self.code);
        const genCtx: *re.pcre2_general_context_8 = @ptrCast(self.generalCtx);
        const matchCtx: ?*re.pcre2_match_context_8 = re.pcre2_match_context_create_8(genCtx);
        const subject: re.PCRE2_SPTR8 = @ptrCast(subject_);

        const matchData: ?*re.pcre2_match_data_8 = re.pcre2_match_data_create_from_pattern_8(code, genCtx);

        const result: c_int = re.pcre2_match_8(code, subject, length, offset, 0, matchData, matchCtx);

        if (result < 0) {
            re.pcre2_match_data_free_8(matchData);
            re.pcre2_match_context_free_8(matchCtx);
            return null;
        }

        const size: c_uint = re.pcre2_get_ovector_count_8(matchData);
        const ovector: [*c]usize = re.pcre2_get_ovector_pointer_8(matchData);

        var match: RegexMatch = RegexMatch.init(self.allocator);

        for (0..size) |i| {
            const index: usize = i * 2;
            const rangeStart: ?usize = if (ovector[index] == -1) null else ovector[index];
            const rangeEnd: ?usize = if (ovector[index + 1] == -1) null else ovector[index + 1];
            match.data.append(RegexMatch.Range{ .start = rangeStart, .end = rangeEnd }) catch |err| {
                std.debug.print("Error appending range: {any}", .{err});
                re.pcre2_match_data_free_8(matchData);
                re.pcre2_match_context_free_8(matchCtx);
                return null;
            };
        }

        re.pcre2_match_data_free_8(matchData);
        re.pcre2_match_context_free_8(matchCtx);

        match.subject = subject_;

        var count: c_uint = undefined;
        var table: [*c]c_char = undefined;
        var entrySize: c_uint = undefined;

        self.patternInfo(re.PCRE2_INFO_NAMECOUNT, @ptrCast(&count));
        self.patternInfo(re.PCRE2_INFO_NAMETABLE, @ptrCast(&table));
        self.patternInfo(re.PCRE2_INFO_NAMEENTRYSIZE, @ptrCast(&entrySize));

        for (0..count) |i| {
            const id: c_short = table[i * entrySize];
            if (match.data.items[@intCast(id)].start == null) {
                continue;
            }
            const len = std.mem.len(@as([*c]u8, @ptrCast(&table[i * entrySize + 2])));
            const name: []const u8 = @ptrCast(@as([*]u8, @ptrCast(&table[i * entrySize + 2]))[0..len]);
            if (match.names.contains(name)) {
                continue;
            }
            match.names.put(name, @intCast(id)) catch |err| {
                std.debug.print("Error adding name: {s}\n{any}", .{ name, err });
            };
        }

        return match;
    }

    pub fn searchAll(self: *Regex, subject_: []const u8, offset_: ?usize, end_: ?c_int) AList(RegexMatch) {
        var offset = offset_ orelse 0;
        const end = end_ orelse -1;

        // var lastEnd: usize = 0;
        var matches = AList(RegexMatch).init(self.allocator);

        while (true) {
            var match: ?RegexMatch = self.search(subject_, offset, end);
            if (match == null) break;
            offset = match.?.getEndAt(0).?;
            if (match.?.getStartAt(0).? == offset) {
                offset += 1;
            }

            matches.append(match.?) catch |err| {
                std.debug.print("Error appending match: {any}", .{err});
            };
        }

        return matches;
    }

    pub fn sub(self: *Regex, subject_: []const u8, replacement_: []const u8, all_: ?bool, offset_: ?usize, end_: ?usize) ?AList(u8) {
        if (!self.isValid()) {
            std.debug.print("regex is not valid", .{});
            return null;
        }

        const all = all_ orelse false;
        const offset = offset_ orelse 0;

        var flags: c_uint = re.PCRE2_SUBSTITUTE_OVERFLOW_LENGTH | re.PCRE2_SUBSTITUTE_UNSET_EMPTY;
        if (all) {
            flags |= re.PCRE2_SUBSTITUTE_GLOBAL;
        }

        var outString: AList(u8) = AList(u8).init(self.allocator);
        const result: c_int = self._sub(subject_, replacement_, offset, end_, flags, &outString);

        if (result < 0) {
            var buffer: [256]re.PCRE2_UCHAR8 = [_]u8{0} ** 256;
            _ = re.pcre2_get_error_message_8(result, buffer[0..], 256);
            std.debug.print("PCRE2 Error: {s}", .{buffer[0..]});

            if (result == re.PCRE2_ERROR_NOSUBSTRING) {
                flags |= re.PCRE2_SUBSTITUTE_UNKNOWN_UNSET;
                _ = self._sub(subject_, replacement_, offset, end_, flags, &outString);
            }
        }

        return outString;
    }

    fn _sub(self: *Regex, subject_: []const u8, replacement_: []const u8, offset_: usize, end_: ?usize, flags_: c_uint, outString_: *AList(u8)) c_int {
        // var outLength: re.PCRE2_SIZE = subject_.len + 1;
        var outLength: re.PCRE2_SIZE = subject_.len;
        outString_.resize(outLength) catch |err| {
            std.debug.print("Error ensuring total capacity: {any}", .{err});
            return re.PCRE2_ERROR_NOMEMORY;
        };

        var length: usize = subject_.len;
        if (end_ != null and end_.? < length) {
            length = end_.?;
        }

        const code: *re.pcre2_code_8 = @ptrCast(self.code);
        const genCtx: *re.pcre2_general_context_8 = @ptrCast(self.generalCtx);
        const matchCtx: ?*re.pcre2_match_context_8 = re.pcre2_match_context_create_8(genCtx);
        const subject: re.PCRE2_SPTR8 = @ptrCast(subject_);
        const replacement: re.PCRE2_SPTR8 = @ptrCast(replacement_);
        var output: *re.PCRE2_UCHAR8 = @ptrCast(outString_.items.ptr);

        const matchData: ?*re.pcre2_match_data_8 = re.pcre2_match_data_create_from_pattern_8(code, genCtx);

        var result: c_int = re.pcre2_substitute_8(code, subject, length, offset_, flags_, matchData, matchCtx, replacement, replacement_.len, output, &outLength);

        if (result == re.PCRE2_ERROR_NOMEMORY) {
            outString_.resize(outLength) catch |err| {
                std.debug.print("Error ensuring total capacity: {any}", .{err});
                return re.PCRE2_ERROR_NOMEMORY;
            };

            output = @ptrCast(outString_.items.ptr);
            result = re.pcre2_substitute_8(code, subject, length, offset_, flags_, matchData, matchCtx, replacement, replacement_.len, output, &outLength);
        } else {
            outString_.resize(outLength) catch |err| {
                std.debug.print("Error resizing: {any}", .{err});
                return re.PCRE2_ERROR_NOMEMORY;
            };
        }

        re.pcre2_match_data_free_8(matchData);
        re.pcre2_match_context_free_8(matchCtx);

        return result;
    }

    pub fn isValid(self: *Regex) bool {
        return self.code != null;
    }

    pub fn getPattern(self: *Regex) ?[]const u8 {
        return self.pattern;
    }

    pub fn getGroupCount(self: *Regex) u32 {
        if (!self.isValid()) return 0;

        var count: c_uint = undefined;
        self.patternInfo(re.PCRE2_INFO_CAPTURECOUNT, &count);

        return @intCast(count);
    }

    pub fn getNames(self: *Regex) SAMap(void) {
        var names = SAMap(void).init(self.allocator);

        var count: c_uint = undefined;
        var table: [*c]c_char = undefined;
        var entrySize: c_uint = undefined;

        self.patternInfo(re.PCRE2_INFO_NAMECOUNT, @ptrCast(&count));
        self.patternInfo(re.PCRE2_INFO_NAMETABLE, @ptrCast(&table));
        self.patternInfo(re.PCRE2_INFO_NAMEENTRYSIZE, @ptrCast(&entrySize));

        for (0..count) |i| {
            const len = std.mem.len(@as([*c]u8, @ptrCast(&table[i * entrySize + 2])));
            const name: []const u8 = @ptrCast(@as([*]u8, @ptrCast(&table[i * entrySize + 2]))[0..len]);

            names.put(@ptrCast(name), {}) catch |err| {
                std.debug.print("Error adding name: {s}\n{any}", .{ name, err });
            };
        }

        return names;
    }

    pub fn deinitMatchList(_: *Regex, matches: *AList(RegexMatch)) void {
        for (0..matches.items.len) |i| {
            matches.items[i].deinit();
        }
        matches.deinit();
    }

    fn patternInfo(self: *Regex, what_: c_int, where_: ?*anyopaque) void {
        _ = re.pcre2_pattern_info_8(@ptrCast(self.code), @intCast(what_), where_);
    }
};

fn regex_alloc(size: usize, _: ?*anyopaque) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

fn regex_free(ptr: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (ptr == null) return;
    std.c.free(ptr);
}

// NAMES
const std = @import("std");
const tests = std.testing;
const re = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const Allocator = std.mem.Allocator;
const AList = std.array_list.Managed;
const SMap = std.StringHashMap;
const SAMap = std.StringArrayHashMap;

const PCRE2_ZERO_TERMINATED = ~@as(re.PCRE2_SIZE, 0);

// TESTING
test "Regex.init()" {
    var regex = Regex.init(tests.allocator);
    defer regex.deinit();

    try tests.expect(regex.generalCtx != null);
    try tests.expectEqual(null, regex.code);
}

test "Regex.clear()" {
    var regex = try Regex.from("a(b|c)d", true, tests.allocator);
    defer regex.deinit();
    try tests.expect(regex.code != null);

    regex.clear();
    try tests.expect(regex.code == null);
}

test "Regex.from()" {
    var regexComp = try Regex.from("a(b|c)d", true, tests.allocator);
    defer regexComp.deinit();
    try tests.expect(regexComp.code != null);

    const regexFail = Regex.from("a)b|c(d", false, tests.allocator);
    if (regexFail) |regex| {
        defer regex.deinit();
    } else |err| {
        try tests.expect(err == Regex.CompileError.Failure);
    }
}

test "Regex.Compile()" {
    var regex = Regex.init(tests.allocator);
    defer regex.deinit();

    try tests.expectEqual(Regex.CompileError.Compiled, regex.compile("a(b|c)d", true));
    try tests.expectEqual(Regex.CompileError.Failure, regex.compile("a)b|c(d", false));
    try tests.expectEqual(Regex.CompileError.Compiled, regex.compile("a(x|y)d", true));
}

test "Regex.search()" {
    var regex = try Regex.from("a(b|c)d", true, tests.allocator);
    defer regex.deinit();

    const subject = "ffabdgg";
    var matchor: ?RegexMatch = regex.search(subject, 0, -1);
    if (matchor == null) return;
    defer matchor.?.deinit();
    try tests.expect(matchor != null);

    if (matchor) |match| {
        try tests.expect(std.mem.eql(u8, "abd", match.getStringAt(0)));
        try tests.expectEqual(2, match.getStartAt(0));
        try tests.expectEqual(5, match.getEndAt(0));

        try tests.expect(std.mem.eql(u8, "b", match.getStringAt(1)));
        try tests.expectEqual(3, match.getStartAt(1));
        try tests.expectEqual(4, match.getEndAt(1));
    }
}

test "Regex.searchAll()" {
    var regex = try Regex.from("a(b|c)d", true, tests.allocator);
    defer regex.deinit();

    const subject = "abd acd";
    var matches: AList(RegexMatch) = regex.searchAll(subject, 0, -1);
    defer regex.deinitMatchList(&matches);

    try tests.expectEqual(2, matches.items.len);

    try tests.expect(std.mem.eql(u8, "abd", matches.items[0].getStringAt(0)));
    try tests.expectEqual(0, matches.items[0].getStartAt(0));
    try tests.expectEqual(3, matches.items[0].getEndAt(0));

    try tests.expect(std.mem.eql(u8, "b", matches.items[0].getStringAt(1)));
    try tests.expectEqual(1, matches.items[0].getStartAt(1));
    try tests.expectEqual(2, matches.items[0].getEndAt(1));

    try tests.expect(std.mem.eql(u8, "acd", matches.items[1].getStringAt(0)));
    try tests.expectEqual(4, matches.items[1].getStartAt(0));
    try tests.expectEqual(7, matches.items[1].getEndAt(0));

    try tests.expect(std.mem.eql(u8, "c", matches.items[1].getStringAt(1)));
    try tests.expectEqual(5, matches.items[1].getStartAt(1));
    try tests.expectEqual(6, matches.items[1].getEndAt(1));
}

test "Regex.sub()" {
    var regex = try Regex.from("a(b|c)d", true, tests.allocator);
    defer regex.deinit();

    const subject = "abd acd";
    const replacement = "x";

    const result: ?AList(u8) = regex.sub(subject, replacement, false, 0, null);
    try tests.expect(result != null);

    if (result) |res| {
        defer res.deinit();
        try tests.expect(std.mem.eql(u8, "x acd", res.items));
    }

    const resultGlobal: ?AList(u8) = regex.sub(subject, replacement, true, 0, null);
    try tests.expect(resultGlobal != null);

    if (resultGlobal) |res| {
        defer res.deinit();
        try tests.expect(std.mem.eql(u8, "x x", res.items));
    }
}

test "Regex.getPattern()" {
    var regex = try Regex.from("a(b|c)d", true, tests.allocator);
    defer regex.deinit();

    try tests.expect(std.mem.eql(u8, "a(b|c)d", regex.getPattern().?));
}

test "Regex.getGroupCount()" {
    var regex = try Regex.from(".*(a(b|c)d).*", true, tests.allocator);
    defer regex.deinit();

    try tests.expectEqual(2, regex.getGroupCount());
}

test "Regex.getNames()" {
    var regex = try Regex.from("(?'first'ab)(?'second'cd)", true, tests.allocator);
    defer regex.deinit();

    var names: SAMap(void) = regex.getNames();
    defer names.deinit();

    try tests.expectEqual(2, names.count());
    try tests.expect(names.contains("first"));
    try tests.expect(names.contains("second"));
}
