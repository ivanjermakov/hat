const std = @import("std");

const reg = @import("regex");

/// Given string str, expand env variables
/// Variable is a sequence in format of /\$[A-Z0-Z]+/
/// Not resolved vars substituted with ""
pub fn expand(allocator: std.mem.Allocator, str: []const u8, getenv: *const @TypeOf(std.posix.getenv)) ![]const u8 {
    var res = std.array_list.Managed(u8).init(allocator);

    var re = try reg.Regex.from("\\$[A-Z0-Z]+", false, allocator);
    defer re.deinit();

    var cursor: usize = 0;
    var matches = re.searchAll(str, 0, -1);
    defer re.deinitMatchList(&matches);
    for (matches.items) |match| {
        const match_text = match.getStringAt(0);
        const start = match.getStartAt(0).?;
        const end = match.getEndAt(0).?;
        if (cursor < start) {
            try res.appendSlice(str[cursor..match.getStartAt(0).?]);
        }
        // without dollar sign
        const val = getenv(match_text[1..]) orelse "";
        try res.appendSlice(val);
        cursor = end;
    }
    // append rest of the string
    try res.appendSlice(str[cursor..]);
    return res.toOwnedSlice();
}
