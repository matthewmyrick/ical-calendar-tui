//! Entry point: argument parsing (--daemon/--agenda), shared setup (config,
//! timezone, source selection), and the three run modes. Shutdown is
//! orderly (CODING_STANDARDS §8): quit → stop poller → join → deinit vaxis
//! (restoring the terminal) → free arenas.

const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("app.zig");
const config_mod = @import("config.zig");
const log_mod = @import("log.zig");
const poller_mod = @import("poller.zig");
const notifier_mod = @import("notify/notifier.zig");
const sink_mod = @import("notify/sink.zig");
const snapshot_mod = @import("snapshot.zig");
const source_mod = @import("calendar/source.zig");
const eventkit_mod = @import("calendar/eventkit.zig");
const time_mod = @import("calendar/time.zig");

pub const panic = vaxis.panic_handler;

pub const std_options: std.Options = .{
    .logFn = log_mod.logFn,
    .log_level = .debug, // runtime-filtered in log.zig
};

/// Info.plist embedded into the executable so TCC finds the calendar usage
/// description in a bare (non-bundled) binary — ARCHITECTURE.md §13, minus the
/// -sectcreate linker flag (0.16's linker driver has no passthrough; an
/// exported linksection constant produces the identical section).
export const info_plist: [info_plist_bytes.len]u8 linksection("__TEXT,__info_plist") = info_plist_bytes.*;
const info_plist_bytes = @embedFile("Info.plist");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    snapshot_updated,
};

const Mode = enum { tui, daemon, agenda };

const usage =
    \\usage: ical-calendar-tui [--daemon | --agenda | --version]
    \\
    \\  (no flags)  interactive calendar TUI
    \\  --daemon    headless poll + notify (for launchd)
    \\  --agenda    print today's events and exit
    \\  --version   print version and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // argv[0]
    var mode: Mode = .tui;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) {
            mode = .daemon;
        } else if (std.mem.eql(u8, arg, "--agenda")) {
            mode = .agenda;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const stdout = std.Io.File.stdout();
            stdout.writeStreamingAll(io, "ical-calendar-tui " ++ @import("build_options").version ++ "\n") catch {};
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return writeStderr(io, usage);
        } else {
            writeStderr(io, usage);
            return error.UnknownArgument;
        }
    }

    if (mode != .tui) {
        log_mod.mode = .stderr;
        if (init.environ_map.get("ICAL_TUI_DEBUG") != null) log_mod.min_level = .debug;
    }

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

    // Source selection (ARCHITECTURE.md §5): .auto tries EventKit and falls back to
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

    const filter: snapshot_mod.Filter = .{
        .calendars_exclude = config.calendars_exclude,
        .show_declined = config.show_declined,
    };

    if (mode == .agenda) return runAgenda(gpa, io, &source, zone, filter);

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
        .filter = filter,
    };

    switch (mode) {
        // Daemon: the poller loop IS the program; launchd terminates it.
        .daemon => poller.run(),
        .tui => try runTui(init, &poller, zone, config.week_start),
        .agenda => unreachable, // returned above
    }
}

fn runTui(
    init: std.process.Init,
    poller: *poller_mod.Poller,
    zone: time_mod.Zone,
    week_start: config_mod.WeekStart,
) !void {
    const io = init.io;
    const gpa = init.gpa;

    var app = app_mod.App.init(io, zone, poller, week_start);

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
    var poller_future = try io.concurrent(poller_mod.Poller.run, .{poller});
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

/// --agenda: print today's events as plain text and exit 0 (ARCHITECTURE.md §10) —
/// for scripts, herdr launchers, and shell greetings.
fn runAgenda(
    gpa: std.mem.Allocator,
    io: std.Io,
    source: *source_mod.CalendarSource,
    zone: time_mod.Zone,
    filter: snapshot_mod.Filter,
) !void {
    const now = poller_mod.nowUnix(io);
    const today = time_mod.localDate(now, zone);
    const bounds = time_mod.dayBounds(today, zone);

    const snapshot = snapshot_mod.Snapshot.build(gpa, source, bounds.start, bounds.end, now, filter) catch |err| {
        var message: [128]u8 = undefined;
        return fail(io, std.fmt.bufPrint(&message, "calendar fetch failed: {t}", .{err}) catch "calendar fetch failed");
    };
    defer snapshot.deinit();

    var out_buffer: [4096]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var file_writer = stdout.writer(io, &out_buffer);
    const writer = &file_writer.interface;

    if (snapshot.events.len == 0) {
        try writer.writeAll("no events today\n");
        try writer.flush();
        return;
    }
    for (snapshot.events) |event| {
        if (event.all_day) {
            try writer.print("all-day      {s}  [{s}]\n", .{ event.title, event.calendar_name });
        } else {
            const start = time_mod.civilFromUnix(event.start, zone);
            const end = time_mod.civilFromUnix(event.end, zone);
            try writer.print("{d:0>2}:{d:0>2}–{d:0>2}:{d:0>2}  {s}  [{s}]\n", .{
                start.time.hour, start.time.minute,
                end.time.hour,   end.time.minute,
                event.title,     event.calendar_name,
            });
        }
    }
    try writer.flush();
}

fn writeStderr(io: std.Io, message: []const u8) void {
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, message) catch {};
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
    writeStderr(io, message);
    writeStderr(io, "\n");
    return error.StartupFailed;
}

test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("log.zig");
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
    _ = @import("ui/search.zig");
    _ = @import("ui/eventform.zig");
    _ = @import("ui/statusbar.zig");
    _ = @import("ui/theme.zig");
}
