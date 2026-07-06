//! Entry point: config, poller thread, vaxis wiring, and orderly shutdown
//! (CODING_STANDARDS §8): quit → stop poller → join → deinit vaxis
//! (restoring the terminal) → free arenas. --daemon/--agenda land at M5.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const poller_mod = @import("poller.zig");
const notifier_mod = @import("notify/notifier.zig");
const sink_mod = @import("notify/sink.zig");
const source_mod = @import("calendar/source.zig");
const eventkit_mod = @import("calendar/eventkit.zig");
const time_mod = @import("calendar/time.zig");

pub const panic = vaxis.panic_handler;

/// Info.plist embedded into the executable so TCC finds the calendar usage
/// description in a bare (non-bundled) binary — SPEC §13, minus the
/// -sectcreate linker flag (0.16's linker driver has no passthrough; an
/// exported linksection constant produces the identical section).
export const info_plist: [info_plist_bytes.len]u8 linksection("__TEXT,__info_plist") = info_plist_bytes.*;
const info_plist_bytes = @embedFile("Info.plist");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    snapshot_updated,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Config + paths live in one arena for the process lifetime.
    var config_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_arena.deinit();
    const paths = resolvePaths(config_arena.allocator(), init.environ_map) catch {
        return fail(io, "cannot determine HOME — set $HOME and retry");
    };

    var config_error: [256]u8 = @splat(0);
    const config = config_mod.load(
        config_arena.allocator(),
        io,
        paths.config_file,
        &config_error,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return fail(io, config_mod.errorMessage(&config_error)),
    };

    var zone = time_mod.Zone.loadLocal(gpa, io);
    defer zone.deinit();

    // Source selection (SPEC §5): .auto tries EventKit and falls back to
    // the CLI; the access request may show the TCC prompt — before the TUI
    // takes the terminal, so the dialog isn't hidden behind an alt screen.
    var source: source_mod.CalendarSource = switch (config.source) {
        .ical_cli => .{ .ical_cli = .{ .gpa = gpa, .io = io } },
        .eventkit => blk: {
            eventkit_mod.EventKitSource.requestAccess() catch {
                return fail(io, "calendar access denied — grant it in System Settings → " ++
                    "Privacy & Security → Calendars, or set .source = .ical_cli");
            };
            break :blk .{ .eventkit = .{ .gpa = gpa } };
        },
        .auto => blk: {
            eventkit_mod.EventKitSource.requestAccess() catch {
                break :blk .{ .ical_cli = .{ .gpa = gpa, .io = io } };
            };
            break :blk .{ .eventkit = .{ .gpa = gpa } };
        },
    };

    const sink = sink_mod.detect(gpa, io, init.environ_map, config.notify_sink);
    var notifier = try notifier_mod.Notifier.init(
        gpa,
        io,
        paths.cache_dir,
        sink,
        config.lead_times_minutes,
        config.all_day_notify_minutes,
        poller_mod.nowUnix(io),
    );
    defer notifier.deinit();

    var poller: poller_mod.Poller = .{
        .gpa = gpa,
        .io = io,
        .source = &source,
        .notifier = &notifier,
        .zone = zone,
        .poll_interval_seconds = config.poll_interval_seconds,
        .filter = .{
            .calendars_exclude = config.calendars_exclude,
            .show_declined = config.show_declined,
        },
    };

    var app = app_mod.App.init(io, zone, &poller, config.week_start);

    var tty_buffer: [4096]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, init.environ_map, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    // The poller posts snapshot_updated after every cycle so the UI repaints
    // countdowns and fresh data without polling on its own.
    poller.on_cycle = postSnapshotUpdated;
    poller.on_cycle_context = &loop;
    var poller_future = try io.concurrent(poller_mod.Poller.run, .{&poller});
    // Stop the poller before the loop/vaxis defers unwind (LIFO).
    defer {
        poller.stop();
        poller_future.await(io);
    }

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    while (!app.should_quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| app.handleKey(key),
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
            .snapshot_updated => {}, // repaint below
        }

        // Hold the poller mutex through render: vaxis reads snapshot strings
        // until the frame is written (see App.draw doc).
        app.lockPoller();
        defer app.unlockPoller();
        app.draw(vx.window());
        try vx.render(tty.writer());
    }
}

fn postSnapshotUpdated(context: *anyopaque) void {
    const loop: *vaxis.Loop(Event) = @ptrCast(@alignCast(context));
    _ = loop.tryPostEvent(.snapshot_updated) catch {}; // full queue = redraw already pending
}

const Paths = struct {
    config_file: []const u8,
    cache_dir: []const u8,
};

/// XDG-style paths with macOS-conventional fallbacks under $HOME.
fn resolvePaths(arena: std.mem.Allocator, environ_map: *std.process.Environ.Map) !Paths {
    const home = environ_map.get("HOME") orelse return error.NoHome;
    const config_base = environ_map.get("XDG_CONFIG_HOME");
    const cache_base = environ_map.get("XDG_CACHE_HOME");
    return .{
        .config_file = if (config_base) |base|
            try std.fmt.allocPrint(arena, "{s}/ical-calendar-tui/config.zon", .{base})
        else
            try std.fmt.allocPrint(arena, "{s}/.config/ical-calendar-tui/config.zon", .{home}),
        .cache_dir = if (cache_base) |base|
            try std.fmt.allocPrint(arena, "{s}/ical-calendar-tui", .{base})
        else
            try std.fmt.allocPrint(arena, "{s}/.cache/ical-calendar-tui", .{home}),
    };
}

/// Print a startup problem to stderr and exit nonzero. Only used before the
/// TUI takes the terminal.
fn fail(io: std.Io, message: []const u8) error{StartupFailed} {
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, message) catch {};
    stderr.writeStreamingAll(io, "\n") catch {};
    return error.StartupFailed;
}

test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("poller.zig");
    _ = @import("snapshot.zig");
    _ = @import("calendar/event.zig");
    _ = @import("calendar/eventkit.zig");
    _ = @import("calendar/ical_cli.zig");
    _ = @import("calendar/source.zig");
    _ = @import("calendar/time.zig");
    _ = @import("notify/notifier.zig");
    _ = @import("notify/sink.zig");
    _ = @import("ui/month.zig");
    _ = @import("ui/day.zig");
    _ = @import("ui/detail.zig");
    _ = @import("ui/help.zig");
    _ = @import("ui/statusbar.zig");
    _ = @import("ui/theme.zig");
}
