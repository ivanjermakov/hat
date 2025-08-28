const std = @import("std");

pub fn findPatches(allocator: std.mem.Allocator) ![]const []const u8 {
    var patch_names = std.array_list.Managed([]const u8).init(allocator);
    var patch_dir = try std.fs.cwd().openDir("patch", .{ .iterate = true });
    defer patch_dir.close();
    var dir_iter = patch_dir.iterate();
    while (try dir_iter.next()) |d| {
        try patch_names.append(try allocator.dupe(u8, d.name));
    }
    std.debug.print("found {} patches:", .{patch_names.items.len});
    for (patch_names.items) |n| std.debug.print(" {s}", .{n});
    std.debug.print("\n", .{});

    return try patch_names.toOwnedSlice();
}

pub fn runCmd(
    allocator: std.mem.Allocator,
    cmd: []const []const u8,
    exit_code: ?*u8,
) ![]const u8 {
    std.debug.print("running command:", .{});
    for (cmd) |c| std.debug.print(" {s}", .{c});
    std.debug.print("\n", .{});

    var child = std.process.Child.init(cmd, allocator);
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    const res = child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));

    const code = (try child.wait()).Exited;
    if (exit_code) |c| c.* = code;

    return res;
}
