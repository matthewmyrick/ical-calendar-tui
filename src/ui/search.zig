//! Fuzzy event search: the `/` overlay. Case-insensitive subsequence
//! matching over every event in the loaded window, best matches first.
//! Matching is pure and table-tested; drawing follows the overlay pattern
//! (help.zig).

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const time_mod = @import("../calendar/time.zig");
const event_mod = @import("../calendar/event.zig");

pub const max_query = 64;
pub const max_results = 10;

pub const Match = struct {
    event: event_mod.Event,
    score: u32, // lower is better
};

/// Score a case-insensitive subsequence match of `pattern` in `text`.
/// Null when pattern characters can't be found in order. Lower is better:
/// contiguous matches near the start of short titles win.
pub fn fuzzyScore(pattern: []const u8, text: []const u8) ?u32 {
    if (pattern.len == 0) return @intCast(@min(text.len, 4096));
    var score: u32 = 0;
    var text_index: usize = 0;
    var previous_hit: ?usize = null;
    for (pattern) |pattern_char| {
        const want = std.ascii.toLower(pattern_char);
        const found = while (text_index < text.len) : (text_index += 1) {
            if (std.ascii.toLower(text[text_index]) == want) break text_index;
        } else return null;
        if (previous_hit) |prev| {
            score += @intCast(@min(found - prev - 1, 256) * 4); // gap penalty
        } else {
            score += @intCast(@min(found, 256) * 2); // late-start penalty
        }
        previous_hit = found;
        text_index = found + 1;
    }
    score += @intCast(@min(text.len, 256)); // shorter titles first on ties
    return score;
}

/// Best `max_results` matches for `query`, ordered by score then start time.
/// Results reference the snapshot's arena — use them under the poller lock.
pub fn search(events: []const event_mod.Event, query: []const u8, out: *[max_results]Match) []Match {
    var count: usize = 0;
    for (events) |event| {
        const score = fuzzyScore(query, event.title) orelse continue;
        const match: Match = .{ .event = event, .score = score };
        // Insertion sort into the bounded result list.
        var insert_at = count;
        while (insert_at > 0 and better(match, out[insert_at - 1])) insert_at -= 1;
        if (insert_at >= out.len) continue;
        const tail_end = @min(count + 1, out.len);
        var move = tail_end;
        while (move > insert_at + 1) : (move -= 1) out[move - 1] = out[move - 2];
        out[insert_at] = match;
        if (count < out.len) count += 1;
    }
    return out[0..count];
}

fn better(a: Match, b: Match) bool {
    if (a.score != b.score) return a.score < b.score;
    return a.event.start < b.event.start;
}

pub const State = struct {
    query: []const u8,
    selected_index: usize,
    zone: time_mod.Zone,
};

/// Draw the search overlay; returns the number of results so the caller can
/// clamp its selection.
pub fn draw(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    events: []const event_mod.Event,
    state: State,
) usize {
    var results_buffer: [max_results]Match = undefined;
    const results = search(events, state.query, &results_buffer);

    const width: u16 = @min(72, win.width -| 4);
    const height: u16 = @as(u16, @intCast(results.len)) + 4;
    if (win.width < width + 2 or win.height < height + 2) return results.len;

    const box = win.child(.{
        .x_off = (win.width - width) / 2,
        .y_off = (win.height -| height) / 3,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .style = theme.border },
    });
    box.fill(.{ .style = .{ .bg = theme.color(theme.mocha.mantle) } });

    const prompt = std.fmt.allocPrint(scratch, "/ {s}▏", .{state.query}) catch return results.len;
    printAt(box, 2, 0, prompt, theme.title);

    if (results.len == 0) {
        printAt(box, 2, 2, "no matching events", theme.dim);
        return 0;
    }

    const selected = @min(state.selected_index, results.len - 1);
    for (results, 0..) |match, i| {
        const row: u16 = 2 + @as(u16, @intCast(i));
        const event = match.event;
        const start = time_mod.civilFromUnix(event.start, state.zone);
        const when = if (event.all_day)
            std.fmt.allocPrint(scratch, "{s} {d: >2} all-day", .{
                time_mod.month_names[start.date.month - 1][0..3], start.date.day,
            }) catch return results.len
        else
            std.fmt.allocPrint(scratch, "{s} {d: >2} {d:0>2}:{d:0>2}", .{
                time_mod.month_names[start.date.month - 1][0..3], start.date.day,
                start.time.hour,                                  start.time.minute,
            }) catch return results.len;

        const line_style = if (i == selected) theme.selected else theme.text;
        if (i == selected) {
            const row_win = box.child(.{ .y_off = row, .width = box.width, .height = 1 });
            row_win.fill(.{ .style = line_style });
        }
        printAt(box, 2, row, when, if (i == selected) line_style else theme.subtle);
        const title_win = box.child(.{
            .x_off = 16,
            .y_off = row,
            .width = box.width -| 17,
            .height = 1,
        });
        _ = title_win.printSegment(.{ .text = event.title, .style = if (i == selected)
            line_style
        else
            .{ .fg = theme.calendarColor(event.calendar_color) } }, .{});
    }
    return results.len;
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    var overlay_style = style;
    if (overlay_style.bg == .default) overlay_style.bg = theme.color(theme.mocha.mantle);
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = overlay_style }, .{});
}

test "fuzzyScore: subsequence, case-insensitive, ranked sensibly" {
    // Non-matches.
    try std.testing.expectEqual(@as(?u32, null), fuzzyScore("xyz", "Team Standup"));
    try std.testing.expectEqual(@as(?u32, null), fuzzyScore("standupz", "Standup"));

    // Case-insensitive subsequence hits.
    try std.testing.expect(fuzzyScore("standup", "Team Standup") != null);
    try std.testing.expect(fuzzyScore("tsu", "Team Standup") != null);
    try std.testing.expect(fuzzyScore("INFRA", "Infra Monthly Sync") != null);

    // Prefix beats scattered; exact-ish beats longer.
    const prefix = fuzzyScore("infra", "Infra Monthly Sync").?;
    const scattered = fuzzyScore("infra", "In for a rainy day").?;
    try std.testing.expect(prefix < scattered);

    // Empty query matches everything.
    try std.testing.expect(fuzzyScore("", "anything") != null);
}

test "search: bounded, ordered, ties broken by start" {
    const mk = struct {
        fn event(title: []const u8, start: i64) event_mod.Event {
            return .{
                .id = title,
                .calendar_name = "",
                .calendar_color = 0,
                .title = title,
                .start = start,
                .end = start + 1,
                .all_day = false,
                .location = "",
                .notes = "",
                .url = "",
                .video_link = "",
                .attendees = &.{},
                .is_recurring = false,
                .self_rsvp = .unknown,
            };
        }
    };
    const events = [_]event_mod.Event{
        mk.event("Infra Monthly Sync", 300),
        mk.event("Lunch w/ Sam", 100),
        mk.event("Infra Monthly Sync", 200), // same title, earlier: wins tie
    };
    var buffer: [max_results]Match = undefined;
    const results = search(&events, "infra", &buffer);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(i64, 200), results[0].event.start);
    try std.testing.expectEqual(@as(i64, 300), results[1].event.start);

    const all = search(&events, "", &buffer);
    try std.testing.expectEqual(@as(usize, 3), all.len);
}
