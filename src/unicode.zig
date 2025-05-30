const nc = @cImport({
    @cInclude("ncurses.h");
});

pub fn codepoint_to_cchar(codepoint: u21) nc.cchar_t {
    return nc.cchar_t{ .attr = 0, .chars = [_]c_int{ codepoint, 0, 0, 0, 0 } };
}
