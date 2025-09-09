/// Adapted zig/lib/compiler/test_runner.zig
const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const builtin = @import("builtin");

var log_err_count: usize = 0;
var fba = std.heap.FixedBufferAllocator.init(&fba_buffer);
var fba_buffer: [8192]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;

pub fn main() void {
    @disableInstrumentation();

    const args = std.process.argsAlloc(fba.allocator()) catch @panic("unable to parse command line args");

    var opt_cache_dir: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--cache-dir")) {
            opt_cache_dir = arg["--cache-dir=".len..];
        } else {
            @panic("unrecognized command line argument");
        }
    }

    fba.reset();

    return mainTerminal();
}

fn mainTerminal() void {
    @disableInstrumentation();
    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    const stderr = std.fs.File.stderr();
    var stderr_writer = stderr.writer(&.{});
    const log = &stderr_writer.interface;

    var leaks: usize = 0;
    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        defer {
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
            }
        }

        log.print("[{d}/{d}] {s}...", .{ i + 1, test_fn_list.len, test_fn.name }) catch {};
        if (test_fn.func()) |_| {
            ok_count += 1;
            log.print("{f}ok{f}\n", .{ AnsiColor.green, AnsiColor.reset }) catch {};
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                log.print("{f}skip{f}\n", .{ AnsiColor.yellow, AnsiColor.reset }) catch {};
            },
            else => {
                fail_count += 1;
                log.print("{f}fail{f}\n", .{ AnsiColor.red, AnsiColor.reset }) catch {};
                if (@errorReturnTrace()) |trace| {
                    log.print("{f}\n", .{trace.*}) catch {};
                }
            },
        }
    }
    if (ok_count == test_fn_list.len) {
        log.print("All {d} tests {f}passed{f}.\n", .{ ok_count, AnsiColor.green, AnsiColor.reset }) catch {};
    } else {
        log.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count }) catch {};
    }
    if (log_err_count != 0) {
        log.print("{d} errors were logged.\n", .{log_err_count}) catch {};
    }
    if (leaks != 0) {
        log.print("{d} tests leaked memory.\n", .{leaks}) catch {};
    }
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

pub const AnsiColor = enum(u8) {
    black = 0,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    reset,

    pub fn format(self: AnsiColor, writer: *std.io.Writer) std.io.Writer.Error!void {
        const escapeCode = "\x1b[38;5;";
        if (self == .reset) {
            try writer.writeAll("\x1b[0m");
        } else {
            try writer.print("{s}{}{s}", .{ escapeCode, @intFromEnum(self), "m" });
        }
    }
};
