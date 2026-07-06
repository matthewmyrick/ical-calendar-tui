//! Entry point: allocator + vaxis wiring, the terminal event loop, and
//! orderly shutdown (CODING_STANDARDS §8). Argument parsing (--daemon,
//! --agenda) lands at M5.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");

pub const panic = vaxis.panic_handler;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = app_mod.App.init(gpa, io);
    defer app.deinit();
    // Initial fetch before entering the alt screen: a sub-second block at
    // startup beats flashing an empty grid.
    app.refresh();

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

    while (!app.should_quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| app.handleKey(key),
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
        }

        app.draw(vx.window());
        try vx.render(tty.writer());
    }
}

test {
    _ = @import("app.zig");
    _ = @import("snapshot.zig");
    _ = @import("calendar/event.zig");
    _ = @import("calendar/ical_cli.zig");
    _ = @import("calendar/source.zig");
    _ = @import("calendar/time.zig");
    _ = @import("ui/month.zig");
    _ = @import("ui/day.zig");
    _ = @import("ui/detail.zig");
    _ = @import("ui/help.zig");
    _ = @import("ui/statusbar.zig");
    _ = @import("ui/theme.zig");
}
