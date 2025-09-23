const std = @import("std");
const dl = std.DynLib;
const Allocator = std.mem.Allocator;

const env = @import("env.zig");
const log = @import("log.zig");
const main = @import("main.zig");
const ts = @import("ts.zig");

pub const file_type = std.StaticStringMap(FileTypeConfig).initComptime(.{
    .{ ".c", FileTypeConfig{ .name = "c", .ts = .init("c") } },
    .{ ".ts", FileTypeConfig{ .name = "typescript", .ts = .init("typescript") } },
    .{ ".tsx", FileTypeConfig{ .name = "tsx", .ts = .init("tsx") } },
    .{ ".zig", FileTypeConfig{ .name = "zig", .ts = .init("zig") } },
    .{ ".md", FileTypeConfig{ .name = "markdown", .ts = .init("markdown") } },
    .{ ".json", FileTypeConfig{ .name = "json", .ts = .init("json") } },
});

pub const FileTypeConfig = struct {
    name: []const u8,
    ts: ?TsConfig = null,
    /// Number of spaces corresponding to a single indentation level
    indent_spaces: usize = 4,
    /// Display width of a tab character in terminal cells
    tab_width: usize = 4,
};

pub const TsConfig = struct {
    lib_path: []const u8,
    lib_symbol: []const u8,
    highlight_query: ?[]const u8 = null,
    indent_query: ?[]const u8 = null,
    symbol_query: ?[]const u8 = null,

    pub fn init(comptime name: []const u8) TsConfig {
        return .{
            .lib_path = nvim_ts_path ++ "/parser/" ++ name ++ ".so",
            .lib_symbol = "tree_sitter_" ++ name,
            .highlight_query = hat_ts_path ++ "/queries/" ++ name ++ "/highlights.scm",
            .indent_query = hat_ts_path ++ "/queries/" ++ name ++ "/indents.scm",
            .symbol_query = nvim_aerial_path ++ "/queries/" ++ name ++ "/aerial.scm",
        };
    }

    pub fn loadLanguage(self: *const TsConfig, allocator: Allocator) !*const fn () *ts.ts.struct_TSLanguage {
        const lib_path_exp = try env.expand(allocator, self.lib_path, std.posix.getenv);
        defer allocator.free(lib_path_exp);

        log.debug(@This(), "loading TS language: {s} {s}\n", .{ lib_path_exp, self.lib_symbol });
        var language_lib = try dl.open(lib_path_exp);
        var language: *const fn () *ts.ts.struct_TSLanguage = undefined;
        language = language_lib.lookup(@TypeOf(language), @ptrCast(self.lib_symbol)) orelse return error.NoSymbol;
        return language;
    }

    pub fn loadQuery(allocator: Allocator, path: []const u8) ![]const u8 {
        log.debug(@This(), "loading TS query: {s}\n", .{path});
        const query_path = try env.expand(allocator, path, std.posix.getenv);
        defer allocator.free(query_path);
        return try std.fs.cwd().readFileAlloc(allocator, query_path, std.math.maxInt(usize));
    }

    const hat_ts_path = "$HOME/.config/hat/tree-sitter";
    const nvim_ts_path = "$HOME/.local/share/nvim/lazy/nvim-treesitter";
    const nvim_aerial_path = "$HOME/.local/share/nvim/lazy/aerial.nvim";
};

pub const plain: FileTypeConfig = .{ .name = "plain", .ts = null };
