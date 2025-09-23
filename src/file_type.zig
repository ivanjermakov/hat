const std = @import("std");
const dl = std.DynLib;
const Allocator = std.mem.Allocator;

const env = @import("env.zig");
const log = @import("log.zig");
const main = @import("main.zig");
const ts = @import("ts.zig");

pub const file_type = std.StaticStringMap(FileTypeConfig).initComptime(.{});

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
    highlight_query: ?[]const u8,
    indent_query: ?[]const u8,
    symbol_query: ?[]const u8,

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
};

pub const plain: FileTypeConfig = .{ .name = "plain", .ts = null };
