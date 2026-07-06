//! Day view: a chronological agenda for one day with per-event selection
//! (SPEC §7b). All-day events lead, the RSVP glyph shows YOUR status.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const time_mod = @import("../calendar/time.zig");
const event_mod = @import("../calendar/event.zig");
const snapshot_mod = @import("../snapshot.zig");

/// Upper bound on events rendered for one day (buffer size; a busier day
/// truncates with a +N footer).
pub const max_events = 64;

pub const State = struct {
    date: time_mod.CivilDate,
    selected_index: usize,
    zone: time_mod.Zone,
};

pub fn draw(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
) void {
    const weekday_name = time_mod.weekday_names_long[@intFromEnum(time_mod.weekday(state.date))];
    const header = std.fmt.allocPrint(scratch, "{s}, {s} {d} {d}", .{
        weekday_name,
        time_mod.month_names[state.date.month - 1],
        state.date.day,
        @as(u32, @intCast(state.date.year)),
    }) catch return;
    printAt(win, 1, 0, header, theme.title);

    const snap = snapshot orelse {
        printAt(win, 1, 2, "no calendar data", theme.warning);
        return;
    };

    var events_buffer: [max_events]event_mod.Event = undefined;
    const events = snap.eventsOnDay(&events_buffer, state.date, state.zone);
    if (events.len == 0) {
        printAt(win, 1, 2, "no events", theme.dim);
        return;
    }

    const total = snap.countOnDay(state.date, state.zone);
    for (events, 0..) |event, i| {
        const row = 2 + @as(u16, @intCast(i));
        if (row + 1 >= win.height) return;
        drawEventLine(win, scratch, row, event, i == state.selected_index, state);
    }
    if (total > events.len) {
        const row = 2 + @as(u16, @intCast(events.len));
        if (row + 1 >= win.height) return;
        const more = std.fmt.allocPrint(scratch, "  +{d} more (not shown)", .{total - events.len}) catch return;
        printAt(win, 1, row, more, theme.dim);
    }
}

fn drawEventLine(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    row: u16,
    event: event_mod.Event,
    is_selected: bool,
    state: State,
) void {
    const when = if (event.all_day)
        std.fmt.allocPrint(scratch, "all-day     ", .{}) catch return
    else blk: {
        const start = time_mod.civilFromUnix(event.start, state.zone);
        const end = time_mod.civilFromUnix(event.end, state.zone);
        break :blk std.fmt.allocPrint(scratch, "{d:0>2}:{d:0>2}–{d:0>2}:{d:0>2} ", .{
            start.time.hour, start.time.minute, end.time.hour, end.time.minute,
        }) catch return;
    };

    const line = std.fmt.allocPrint(scratch, " {s} {s} {s}  [{s}] {s}", .{
        if (is_selected) "▶" else " ",
        when,
        event.title,
        event.calendar_name,
        event.self_rsvp.glyph(),
    }) catch return;

    const style: vaxis.Style = if (is_selected)
        theme.selected
    else if (event.all_day)
        theme.subtle
    else
        .{ .fg = theme.calendarColor(event.calendar_color) };
    printAt(win, 1, row, line, style);
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = style }, .{});
}
