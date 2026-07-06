//! Entry point: argument parsing, allocator setup, and (for M0) a minimal
//! vaxis window proving the toolchain + terminal integration work end to end.

const std = @import("std");
const vaxis = @import("vaxis");

pub const panic = vaxis.panic_handler;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var tty_buffer: [4096]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) return;
            },
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();

        const title: vaxis.Segment = .{ .text = "ical-calendar-tui" };
        const hint: vaxis.Segment = .{ .text = "press q to quit" };
        const center = vaxis.widgets.alignment.center(win, 17, 3);
        _ = center.printSegment(title, .{});
        const hint_win = win.child(.{
            .x_off = center.x_off + 1,
            .y_off = center.y_off + 2,
            .width = 15,
            .height = 1,
        });
        _ = hint_win.printSegment(hint, .{});

        try vx.render(tty.writer());
    }
}

test {
    std.testing.refAllDecls(@This());
}
