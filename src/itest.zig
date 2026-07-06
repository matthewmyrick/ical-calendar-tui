//! Integration smoke tests (`zig build itest` — NOT part of `zig build
//! test`). Requires a machine with calendar access granted and the `ical`
//! CLI installed; compares the two calendar sources end to end (SPEC §15
//! M4 acceptance).

const std = @import("std");
const source_mod = @import("calendar/source.zig");
const eventkit_mod = @import("calendar/eventkit.zig");
const time_mod = @import("calendar/time.zig");
const event_mod = @import("calendar/event.zig");

test "eventkit and ical_cli sources agree on the same window" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    try eventkit_mod.EventKitSource.requestAccess();

    // A fixed 30-day window starting from a stable recent instant would go
    // stale; fetch around "now" but compare only source-vs-source.
    const now = std.Io.Clock.real.now(io).toSeconds();
    const from = now - 86400;
    const to = now + 30 * 86400;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cli_source: source_mod.CalendarSource = .{ .ical_cli = .{ .gpa = gpa, .io = io } };
    var native_source: source_mod.CalendarSource = .{ .eventkit = .{ .gpa = gpa } };

    const cli_events = try cli_source.fetch(arena, from, to);
    const native_events = try native_source.fetch(arena, from, to);

    try std.testing.expectEqual(cli_events.len, native_events.len);

    // Both are sorted canonically; compare the fields both sources must
    // agree on. (Colors can differ in rounding; ids in identifier form.)
    for (cli_events, native_events) |cli_event, native_event| {
        try std.testing.expectEqualStrings(cli_event.title, native_event.title);
        try std.testing.expectEqual(cli_event.start, native_event.start);
        try std.testing.expectEqual(cli_event.all_day, native_event.all_day);
        try std.testing.expectEqual(cli_event.self_rsvp, native_event.self_rsvp);
        try std.testing.expectEqualStrings(cli_event.calendar_name, native_event.calendar_name);
    }
}
