const std = @import("std");
const main = @import("main.zig");
const env = @import("env.zig");

const nvim_parser_path = "$HOME/.local/share/nvim/lazy/nvim-treesitter/parser/";

pub const FileTypeConfig = struct {
    ts_config: TsConfig,
};

pub const TsConfig = struct {
    lib_path: []const u8,
    lib_symbol: []const u8,

    pub fn from_nvim(allocator: std.mem.Allocator, name: []const u8) !TsConfig {
        return .{
            .lib_path = b: {
                const str = try std.fmt.allocPrint(allocator, "{s}{s}.so", .{ nvim_parser_path, name });
                defer allocator.free(str);
                break :b try env.expand(allocator, str);
            },
            .lib_symbol = try std.fmt.allocPrint(allocator, "tree_sitter_{s}", .{name}),
        };
    }

    pub fn deinit(self: *TsConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.lib_path);
        allocator.free(self.lib_symbol);
    }
};

pub var file_type: std.StringHashMap(FileTypeConfig) = undefined;

pub fn initFileTypes(allocator: std.mem.Allocator) !void {
    file_type = std.StringHashMap(FileTypeConfig).init(allocator);
    try file_type.put(".c", .{
        .ts_config = .{
            .lib_path = try allocator.dupe(u8, "/usr/lib/tree_sitter/c.so"),
            .lib_symbol = try allocator.dupe(u8, "tree_sitter_c"),
        },
    });
    try file_type.put(".ts", .{
        .ts_config = try TsConfig.from_nvim(allocator, "typescript"),
    });
}
