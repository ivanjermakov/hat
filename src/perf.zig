const std = @import("std");

pub const report_perf_threshold_ns = 10 * std.time.ns_per_ms;

pub const PerfInfo = struct {
    input: u64,
    mapping: u64,
    parse: u64,
    did_change: u64,
    draw: u64,
    commit: u64,
    sync: u64,
    total: u64,

    pub fn format(self: *const PerfInfo, writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print(
            "total: {}, input: {}, parse: {}, mapping: {}, did_change: {}, draw: {}, commit: {}, sync: {}\n",
            .{
                self.total / std.time.ns_per_us,
                self.input / std.time.ns_per_us,
                self.parse / std.time.ns_per_us,
                self.mapping / std.time.ns_per_us,
                self.did_change / std.time.ns_per_us,
                self.draw / std.time.ns_per_us,
                self.commit / std.time.ns_per_us,
                self.sync / std.time.ns_per_us,
            },
        );
    }
};
