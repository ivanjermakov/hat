const std = @import("std");
const dl = std.DynLib;
const main = @import("main.zig");
const env = @import("env.zig");
const ts = @import("ts.zig");
const lsp = @import("lsp.zig");

const nvim_parser_path = "$HOME/.local/share/nvim/lazy/nvim-treesitter/parser/";

pub const FileTypeConfig = struct {
    ts: ?TsConfig,
    lsp: ?lsp.LspConfig,
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

    pub fn loadLanguage(self: *const TsConfig) !*const fn () *ts.ts.struct_TSLanguage {
        var language_lib = try dl.open(self.lib_path);
        var language: *const fn () *ts.ts.struct_TSLanguage = undefined;
        language = language_lib.lookup(@TypeOf(language), @ptrCast(self.lib_symbol)) orelse return error.NoSymbol;
        return language;
    }

    pub fn deinit(self: *TsConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.lib_path);
        allocator.free(self.lib_symbol);
    }
};

pub var file_type: std.StringHashMap(FileTypeConfig) = undefined;

pub const plain: FileTypeConfig = .{ .ts = null, .lsp = null };

pub fn initFileTypes(allocator: std.mem.Allocator) !void {
    file_type = std.StringHashMap(FileTypeConfig).init(allocator);
    try file_type.put(".c", .{
        .ts = .{
            .lib_path = try allocator.dupe(u8, "/usr/lib/tree_sitter/c.so"),
            .lib_symbol = try allocator.dupe(u8, "tree_sitter_c"),
        },
        .lsp = null,
    });
    try file_type.put(".ts", .{
        .ts = try TsConfig.from_nvim(allocator, "typescript"),
        .lsp = .{
            .cmd = &[_][]const u8{ "typescript-language-server", "--stdio" },
        },
    });
}

pub fn deinitFileTypes(allocator: std.mem.Allocator) void {
    var value_iter = file_type.valueIterator();
    while (value_iter.next()) |v| {
        if (v.ts) |*ts_conf| ts_conf.deinit(allocator);
    }
    file_type.deinit();
}
