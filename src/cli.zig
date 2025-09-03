const std = @import("std");
const Allocator = std.mem.Allocator;
const env = @import("env.zig");

pub const usage =
    \\Usage:
    \\  hat [options] [file]
    \\
    \\Options:
    \\  -h, --help          Print this help message
    \\  -r, --readonly      Open buffer in read-only mode
    \\  -p, --printer       Printer mode: print [file] to stdout and exit
    \\  --highlight-line=R  Printer mode: highlight line R (1-based index)
    \\  --term-height=H     Printer mode: speicfy terminal height in rows
    \\                        offset buffer so that the highlight line is in
    \\                        the middle of the terminal
    \\
;

pub const Args = struct {
    path: ?[]const u8 = null,
    help: bool = false,
    printer: bool = false,
    read_only: bool = false,
    highlight_line: ?usize = null,
    term_height: ?usize = null,

    pub fn parse(allocator: Allocator) !Args {
        var args = Args{};
        var cmd_args = std.process.args();
        _ = cmd_args.skip();
        const eql = std.mem.eql;
        while (cmd_args.next()) |arg| {
            if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
                args.help = true;
                continue;
            } else if (eql(u8, arg, "-p") or eql(u8, arg, "--printer")) {
                args.printer = true;
                args.read_only = true;
                continue;
            } else if (eql(u8, arg, "-r") or eql(u8, arg, "--readonly")) {
                args.read_only = true;
                continue;
            } else if (std.mem.startsWith(u8, arg, "--highlight-line=")) {
                const val = arg[17..];
                const val_exp = try env.expand(allocator, val, std.posix.getenv);
                args.highlight_line = try std.fmt.parseInt(usize, val_exp, 10) - 1;
                continue;
            } else if (std.mem.startsWith(u8, arg, "--term-height=")) {
                const val = arg[14..];
                const val_exp = try env.expand(allocator, val, std.posix.getenv);
                args.term_height = try std.fmt.parseInt(usize, val_exp, 10);
                continue;
            }
            args.path = @constCast(arg);
        }
        return args;
    }
};
