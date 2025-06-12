const std = @import("std");
const main = @import("main.zig");
const env = @import("env.zig");

const nvim_parser_path = "$HOME/.local/share/nvim/lazy/nvim-treesitter/parser/";

pub const FileType = struct {
    name: []const u8,
    lib_path: []const u8,
    lib_symbol: []const u8,

    fn from_nvim(name: []const u8) !FileType {
        return .{
            .name = name,
            .lib_path = try env.expand(main.allocator, try std.fmt.allocPrint(main.allocator, "{s}{s}.so", .{ nvim_parser_path, name })),
            .lib_symbol = try std.fmt.allocPrint(main.allocator, "tree_sitter_{s}", .{name}),
        };
    }
};

pub var file_type: ?std.StringHashMap(FileType) = null;

pub fn init_file_types() !void {
    file_type = std.StringHashMap(FileType).init(main.allocator);
    try file_type.?.put(".c", FileType{
        .name = "c",
        .lib_path = "/usr/lib/tree_sitter/c.so",
        .lib_symbol = "tree_sitter_c",
    });
    try file_type.?.put(".ts", try FileType.from_nvim("typescript"));
}
