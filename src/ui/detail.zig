//! Event detail view: everything we know about one event, scrollable
//! (ARCHITECTURE.md §7c). Content rows are built into the per-frame scratch, then a
//! scroll window of them is drawn.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const time_mod = @import("../calendar/time.zig");
const event_mod = @import("../calendar/event.zig");

/// Bounded content: attendees and wrapped note lines beyond these caps are
/// summarized, not rendered (CODING_STANDARDS §3.8).
const max_attendees_shown = 32;
const max_lines = 256;

pub const State = struct {
    zone: time_mod.Zone,
    scroll: usize,
};

const Line = struct {
    text: []const u8,
    style: vaxis.Style,
    indent: u16 = 0,
};

/// Returns the scroll offset actually applied (clamped) so the caller can
/// store it back and keep key handling in range.
pub fn draw(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    event: event_mod.Event,
    state: State,
) usize {
    printAt(win, 1, 0, event.title, theme.title);

    var lines_buffer: [max_lines]Line = undefined;
    const lines = buildLines(scratch, &lines_buffer, event, state.zone, win.width -| 4);

    const visible: usize = win.height -| 3;
    const max_scroll = lines.len -| visible;
    const scroll = @min(state.scroll, max_scroll);

    for (lines[scroll..], 0..) |line, i| {
        const row = 2 + @as(u16, @intCast(i));
        if (row + 1 >= win.height) break;
        printAt(win, 1 + line.indent, row, line.text, line.style);
    }
    if (max_scroll > 0) {
        const marker = std.fmt.allocPrint(scratch, "({d}/{d})", .{ scroll + visible, lines.len }) catch return scroll;
        printAt(win, win.width -| @as(u16, @intCast(marker.len + 1)), 0, marker, theme.dim);
    }
    return scroll;
}

fn buildLines(
    scratch: std.mem.Allocator,
    buffer: []Line,
    event: event_mod.Event,
    zone: time_mod.Zone,
    width: u16,
) []Line {
    var count: usize = 0;

    appendWhenLine(scratch, buffer, &count, event, zone);

    if (event.location.len > 0)
        appendField(scratch, buffer, &count, "location", event.location, theme.text);
    if (event.video_link.len > 0)
        appendField(scratch, buffer, &count, "video", event.video_link, theme.ok);
    if (event.url.len > 0 and !std.mem.eql(u8, event.url, event.video_link))
        appendField(scratch, buffer, &count, "url", event.url, theme.text);
    if (event.video_link.len > 0 or event.url.len > 0)
        append(buffer, &count, .{ .text = "o open · c copy link", .style = theme.dim, .indent = 12 });

    appendOrganizer(scratch, buffer, &count, event);

    if (event.attendees.len > 0) {
        append(buffer, &count, .{ .text = "", .style = theme.text });
        const header = std.fmt.allocPrint(scratch, "attendees ({d})", .{event.attendees.len}) catch return buffer[0..count];
        append(buffer, &count, .{ .text = header, .style = theme.accent });

        const you = std.fmt.allocPrint(scratch, "{s} you", .{event.self_rsvp.glyph()}) catch return buffer[0..count];
        append(buffer, &count, .{ .text = you, .style = theme.rsvpStyle(event.self_rsvp), .indent = 2 });

        const shown = @min(event.attendees.len, max_attendees_shown);
        for (event.attendees[0..shown]) |attendee| {
            const name = if (attendee.name.len > 0) attendee.name else attendee.email;
            const text = std.fmt.allocPrint(scratch, "{s} {s: <20} {s}", .{
                attendee.rsvp.glyph(), name, attendee.email,
            }) catch return buffer[0..count];
            append(buffer, &count, .{ .text = text, .style = theme.rsvpStyle(attendee.rsvp), .indent = 2 });
        }
        if (event.attendees.len > shown) {
            const more = std.fmt.allocPrint(scratch, "+{d} more", .{event.attendees.len - shown}) catch return buffer[0..count];
            append(buffer, &count, .{ .text = more, .style = theme.dim, .indent = 2 });
        }
    }

    if (event.notes.len > 0) {
        append(buffer, &count, .{ .text = "", .style = theme.text });
        append(buffer, &count, .{ .text = "notes", .style = theme.accent });
        appendWrapped(buffer, &count, event.notes, @max(width, 20), theme.subtle);
    }

    return buffer[0..count];
}

fn appendWhenLine(
    scratch: std.mem.Allocator,
    buffer: []Line,
    count: *usize,
    event: event_mod.Event,
    zone: time_mod.Zone,
) void {
    const start = time_mod.civilFromUnix(event.start, zone);
    const weekday_name = time_mod.weekday_names_short[@intFromEnum(time_mod.weekday(start.date))];
    const month_name = time_mod.month_names[start.date.month - 1][0..3];
    const recurring = if (event.is_recurring) "  recurring" else "";

    const text = if (event.all_day)
        std.fmt.allocPrint(scratch, "{s} {s} {d} · all-day    [{s}]{s}", .{
            weekday_name, month_name, start.date.day, event.calendar_name, recurring,
        }) catch return
    else blk: {
        const end = time_mod.civilFromUnix(event.end, zone);
        // Unsigned for {d:0>2}: zero-fill on signed ints prints "+30".
        const minutes: u64 = @intCast(@max(@divFloor(event.end - event.start, 60), 0));
        var duration_buffer: [24]u8 = undefined;
        const duration = if (minutes >= 60)
            std.fmt.bufPrint(&duration_buffer, "{d}h {d:0>2}m", .{ minutes / 60, minutes % 60 }) catch return
        else
            std.fmt.bufPrint(&duration_buffer, "{d}m", .{minutes}) catch return;
        break :blk std.fmt.allocPrint(scratch, "{s} {s} {d} · {d:0>2}:{d:0>2} – {d:0>2}:{d:0>2} ({s})    [{s}]{s}", .{
            weekday_name,    month_name,        start.date.day,
            start.time.hour, start.time.minute, end.time.hour,
            end.time.minute, duration,          event.calendar_name,
            recurring,
        }) catch return;
    };
    append(buffer, count, .{ .text = text, .style = theme.text });
}

fn appendOrganizer(
    scratch: std.mem.Allocator,
    buffer: []Line,
    count: *usize,
    event: event_mod.Event,
) void {
    for (event.attendees) |attendee| {
        if (!attendee.is_organizer) continue;
        const name = if (attendee.name.len > 0) attendee.name else attendee.email;
        const text = if (attendee.email.len > 0 and attendee.name.len > 0)
            std.fmt.allocPrint(scratch, "{s} <{s}>", .{ name, attendee.email }) catch return
        else
            name;
        appendField(scratch, buffer, count, "organizer", text, theme.text);
        return;
    }
}

/// One "label   value" row; the label column is 12 wide.
fn appendField(
    scratch: std.mem.Allocator,
    buffer: []Line,
    count: *usize,
    label: []const u8,
    value: []const u8,
    style: vaxis.Style,
) void {
    const text = std.fmt.allocPrint(scratch, "{s: <11} {s}", .{ label, value }) catch return;
    append(buffer, count, .{ .text = text, .style = style });
}

fn append(buffer: []Line, count: *usize, line: Line) void {
    if (count.* >= buffer.len) return;
    buffer[count.*] = line;
    count.* += 1;
}

/// Word-wrap `text` (which may contain newlines) into lines of at most
/// `width` display columns, appending each as a Line. Subslices only — no
/// copying.
fn appendWrapped(buffer: []Line, count: *usize, text: []const u8, width: u16, style: vaxis.Style) void {
    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        if (paragraph.len == 0) {
            append(buffer, count, .{ .text = "", .style = style, .indent = 2 });
            continue;
        }
        var rest = paragraph;
        while (rest.len > width) {
            // Break at the last space inside the width, else hard-break.
            const cut = std.mem.lastIndexOfScalar(u8, rest[0..width], ' ') orelse width;
            append(buffer, count, .{ .text = rest[0..cut], .style = style, .indent = 2 });
            rest = if (cut < rest.len and rest[cut] == ' ') rest[cut + 1 ..] else rest[cut..];
        }
        append(buffer, count, .{ .text = rest, .style = style, .indent = 2 });
    }
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = style }, .{});
}

test "appendWrapped: word wrap, hard break, newlines" {
    var buffer: [16]Line = undefined;
    var count: usize = 0;
    appendWrapped(&buffer, &count, "hello world this is long", 12, theme.text);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("hello world", buffer[0].text);
    try std.testing.expectEqualStrings("this is long", buffer[1].text);

    count = 0;
    appendWrapped(&buffer, &count, "aaaaaaaaaaaaaaaa", 8, theme.text);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("aaaaaaaa", buffer[0].text);

    count = 0;
    appendWrapped(&buffer, &count, "one\n\ntwo", 20, theme.text);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("", buffer[1].text);
}
