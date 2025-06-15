const std = @import("std");
const main = @import("main.zig");
const env = @import("env.zig");

const nvim_parser_path = "$HOME/.local/share/nvim/lazy/nvim-treesitter/parser/";

pub const FileType = struct {
    name: []const u8,
    lib_path: []const u8,
    lib_symbol: []const u8,

    fn from_nvim(allocator: std.mem.Allocator, name: []const u8) !FileType {
        return .{
            .name = name,
            .lib_path = b: {
                const str = try std.fmt.allocPrint(allocator, "{s}{s}.so", .{ nvim_parser_path, name });
                defer allocator.free(str);
                break :b try env.expand(allocator, str);
            },
            .lib_symbol = try std.fmt.allocPrint(allocator, "tree_sitter_{s}", .{name}),
        };
    }
};

pub var file_type: std.StringHashMap(FileType) = undefined;

pub fn init_file_types(allocator: std.mem.Allocator) !void {
    file_type = std.StringHashMap(FileType).init(allocator);
    try file_type.put(".c", FileType{
        .name = "c",
        .lib_path = try allocator.dupe(u8, "/usr/lib/tree_sitter/c.so"),
        .lib_symbol = try allocator.dupe(u8, "tree_sitter_c"),
    });
    try file_type.put(".ts", try FileType.from_nvim(allocator, "typescript"));
}
