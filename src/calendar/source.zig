//! The calendar-source interface: a tagged union over the concrete sources
//! (SPEC §5 — exactly two variants ever, ical_cli now and eventkit at M4;
//! a tagged union beats a vtable for two variants, CODING_STANDARDS §6).

const std = @import("std");
const event_mod = @import("event.zig");
const ical_cli = @import("ical_cli.zig");
const eventkit = @import("eventkit.zig");

pub const FetchError = eventkit.FetchError;

pub const CalendarSource = union(enum) {
    ical_cli: ical_cli.IcalCliSource,
    eventkit: eventkit.EventKitSource,

    /// Fetch everything in [from, to] (unix seconds UTC). All returned memory
    /// is allocated into `arena` (the snapshot's arena) and freed wholesale.
    pub fn fetch(
        self: *CalendarSource,
        arena: std.mem.Allocator,
        from: i64,
        to: i64,
    ) FetchError![]event_mod.Event {
        return switch (self.*) {
            .ical_cli => |*source| source.fetch(arena, from, to),
            .eventkit => |*source| source.fetch(arena, from, to),
        };
    }

    /// Short name for the status bar ("source: eventkit").
    pub fn name(self: CalendarSource) []const u8 {
        return @tagName(self);
    }
};
