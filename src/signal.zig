const std = @import("std");

const log = @import("log.zig");
const main = @import("main.zig");
const ter = @import("terminal.zig");

pub const SigHandle = struct { sig: u8, handle: std.posix.Sigaction.handler_fn };

pub const sig_handle = .{
    .int = SigHandle{ .sig = std.posix.SIG.INT, .handle = handleSigInt },
    .tstp = SigHandle{ .sig = std.posix.SIG.TSTP, .handle = handleSigTstp },
    .cont = SigHandle{ .sig = std.posix.SIG.CONT, .handle = handleSigCont },
    .winch = SigHandle{ .sig = std.posix.SIG.WINCH, .handle = handleSigWinch },
};

pub fn registerAll() void {
    register(sig_handle.tstp);
    register(sig_handle.cont);
    register(sig_handle.int);
    register(sig_handle.winch);
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

fn handleSigInt(sig: c_int) callconv(.c) void {
    _ = sig;
    log.info(@This(), "handling SIGINT\n", .{});
    main.editor.sendMessage("press q to close buffer") catch {};
}

fn handleSigTstp(sig: c_int) callconv(.c) void {
    _ = sig;
    log.info(@This(), "handling SIGTSTP\n", .{});
    reset(sig_handle.tstp);
    defer std.posix.raise(sig_handle.tstp.sig) catch {};

    main.term.deinit();
}

fn handleSigCont(sig: c_int) callconv(.c) void {
    _ = sig;
    log.info(@This(), "handling SIGCONT\n", .{});
    register(sig_handle.tstp);

    main.term.setup() catch {};
    main.editor.dirty.draw = true;
}

fn handleSigWinch(sig: c_int) callconv(.c) void {
    _ = sig;
    log.info(@This(), "handling SIGWINCH\n", .{});
    main.term.dimensions = ter.terminalSize() catch return;
    main.editor.dirty.draw = true;
}
