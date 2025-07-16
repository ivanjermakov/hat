const std = @import("std");
const log = @import("log.zig");
const main = @import("main.zig");

pub fn registerAll() void {
    register(sig_handle.tstp);
    register(sig_handle.cont);
}

fn register(sig: SigHandle) void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = sig.handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig.sig, &action, null);
}

fn reset(sig: SigHandle) void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = std.c.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig.sig, &action, null);
}

const SigHandle = struct { sig: u8, handle: std.posix.Sigaction.handler_fn };

const sig_handle = .{
    .int = SigHandle{ .sig = std.posix.SIG.INT, .handle = handleSigInt },
    .tstp = SigHandle{ .sig = std.posix.SIG.TSTP, .handle = handleSigTstp },
    .cont = SigHandle{ .sig = std.posix.SIG.CONT, .handle = handleSigCont },
};

fn handleSigInt(sig: c_int) callconv(.C) void {
    _ = sig;
    log.log(@This(), "handling SIGINT\n", .{});
    std.posix.exit(0);
}

fn handleSigTstp(sig: c_int) callconv(.C) void {
    _ = sig;
    log.log(@This(), "handling SIGTSTP\n", .{});
    reset(sig_handle.tstp);
    defer std.posix.raise(sig_handle.tstp.sig) catch {};

    main.term.deinit();
}

fn handleSigCont(sig: c_int) callconv(.C) void {
    _ = sig;
    log.log(@This(), "handling SIGCONT\n", .{});
    register(sig_handle.tstp);

    main.term.setup() catch {};
    main.editor.dirty.draw = true;
}
