const std = @import("std");
const Instant = std.time.Instant;

const log = @import("log.zig");

pub var report_lock_threshold_ns: u64 = 1 * std.time.ns_per_ms;

pub const Mutex = struct {
    mutex: std.Thread.Mutex = .{},
    locked_at: ?Instant = null,

    pub fn lock(self: *Mutex) void {
        const locking_start = now();

        self.mutex.lock();

        self.locked_at = now();
        const acq = self.locked_at.?.since(locking_start);
        if (log.enabled(.debug) and acq > report_lock_threshold_ns) {
            log.debug(@This(), "lock acquisition took {}us\n", .{acq / std.time.ns_per_us});
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.mutex.unlock();

        const locked_for = now().since(self.locked_at.?);
        if (log.enabled(.debug) and locked_for > report_lock_threshold_ns) {
            log.debug(@This(), "locked for {}us\n", .{locked_for / std.time.ns_per_us});
        }
        self.locked_at = null;
    }
};

fn now() Instant {
    return Instant.now() catch unreachable;
}
