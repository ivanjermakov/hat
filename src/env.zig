const std = @import("std");
const reg = @import("regex");

/// Given string str, expand env variables
/// Variable is a sequence in format of /\$[A-Z0-Z]+/
/// Not resolved vars substituted with ""
pub fn expand(allocator: std.mem.Allocator, str: []const u8, getenv: *const @TypeOf(std.posix.getenv)) ![]const u8 {
    var res = std.ArrayList(u8).init(allocator);

    var re = try reg.Regex.compile(allocator, "\\$[A-Z0-Z]+");
    defer re.deinit();

    var cursor: usize = 0;
    var captures_opt = try re.captures(str);
    if (captures_opt) |*captures| {
        defer captures.deinit();

        for (0..captures.len()) |i| {
            const variable = captures.sliceAt(i).?;
            const span = captures.boundsAt(i).?;
            if (cursor < span.lower) {
                try res.appendSlice(str[cursor..span.lower]);
            }
            // without dollar sign
            const val = getenv(variable[1..]) orelse "";
            try res.appendSlice(val);
            cursor = span.upper;
        }
    }
    // append rest of the string
    try res.appendSlice(str[cursor..]);
    return res.toOwnedSlice();
}
