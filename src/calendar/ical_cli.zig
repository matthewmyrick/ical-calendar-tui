//! Milestone-1 calendar source: spawns the `ical` CLI (brew tap BRO3886/tap)
//! and parses its JSON output into the snapshot arena. The JSON schema was
//! captured from ical v0.12.1 (see testdata/ical-list-sample.json); attendee
//! `status` is Apple's EKParticipantStatus as an int, event-level
//! `self_status` is the same enum stringified.

const std = @import("std");
const event_mod = @import("event.zig");
const time_mod = @import("time.zig");

const Event = event_mod.Event;
const Attendee = event_mod.Attendee;
const Rsvp = event_mod.Rsvp;

pub const FetchError = error{
    IcalNotInstalled,
    IcalFailed,
    MalformedOutput,
    OutOfMemory,
};

/// Raw JSON shapes emitted by `ical -o json`. Unknown fields are ignored so
/// CLI upgrades don't break us; missing optionals default to empty.
const IcalAttendee = struct {
    name: []const u8 = "",
    email: []const u8 = "",
    status: i64 = 0,
};

const IcalEvent = struct {
    id: []const u8,
    title: []const u8 = "(untitled)",
    start_date: []const u8,
    end_date: []const u8,
    all_day: bool = false,
    calendar: []const u8 = "",
    calendar_id: []const u8 = "",
    /// Only the EventKit shim emits this; the CLI path joins `ical
    /// calendars` by calendar_id instead.
    calendar_color: []const u8 = "",
    location: []const u8 = "",
    notes: []const u8 = "",
    url: []const u8 = "",
    conference_url: []const u8 = "",
    self_status: []const u8 = "",
    organizer: []const u8 = "",
    attendees: []IcalAttendee = &.{},
    recurring: bool = false,
};

const IcalCalendar = struct {
    id: []const u8,
    title: []const u8 = "",
    color: []const u8 = "",
};

pub const IcalCliSource = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    /// Fetch all events in [from, to] (unix seconds UTC). Result and every
    /// string it references are owned by `arena` and freed wholesale when
    /// the snapshot is dropped. Called from the poller thread only.
    pub fn fetch(self: *IcalCliSource, arena: std.mem.Allocator, from: i64, to: i64) FetchError![]Event {
        var from_buffer: [24]u8 = undefined;
        var to_buffer: [24]u8 = undefined;
        const from_str = formatRfc3339Utc(&from_buffer, from);
        const to_str = formatRfc3339Utc(&to_buffer, to);

        const list_json = try self.runIcal(&.{
            "ical", "list", "-f", from_str, "-t", to_str, "-o", "json",
        });
        defer self.gpa.free(list_json);

        const calendars_json = try self.runIcal(&.{ "ical", "calendars", "-o", "json" });
        defer self.gpa.free(calendars_json);

        return parse(arena, list_json, calendars_json);
    }

    /// Run one ical invocation, returning trimmed stdout owned by `self.gpa`.
    fn runIcal(self: *IcalCliSource, argv: []const []const u8) FetchError![]u8 {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(64 * 1024 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => return error.IcalNotInstalled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.IcalFailed,
        };
        defer self.gpa.free(result.stderr);
        errdefer self.gpa.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.IcalFailed,
            else => return error.IcalFailed,
        }
        return result.stdout;
    }
};

/// Parse `ical list` + `ical calendars` JSON into arena-owned events, joined
/// by calendar_id for colors. Pure function — tested against fixtures.
/// Result is owned by `arena`; freed when the snapshot is dropped.
pub fn parse(
    arena: std.mem.Allocator,
    list_json: []const u8,
    calendars_json: []const u8,
) FetchError![]Event {
    const parse_options: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };
    const raw_events = std.json.parseFromSliceLeaky(
        []IcalEvent,
        arena,
        list_json,
        parse_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedOutput,
    };
    const raw_calendars = std.json.parseFromSliceLeaky(
        []IcalCalendar,
        arena,
        calendars_json,
        parse_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedOutput,
    };

    const events = try arena.alloc(Event, raw_events.len);
    for (raw_events, events) |raw, *out| {
        const start = time_mod.parseRfc3339(raw.start_date) catch return error.MalformedOutput;
        const end = time_mod.parseRfc3339(raw.end_date) catch return error.MalformedOutput;

        const attendees = try arena.alloc(Attendee, raw.attendees.len);
        for (raw.attendees, attendees) |raw_attendee, *attendee| {
            attendee.* = .{
                .name = raw_attendee.name,
                .email = raw_attendee.email,
                .rsvp = rsvpFromParticipantStatus(raw_attendee.status),
                .is_organizer = isOrganizer(raw, raw_attendee),
                .is_self = false, // the CLI doesn't identify "you" in the list
            };
        }

        // Flatten HTML (Google/Exchange notes) before link detection so
        // detected URLs never end at a markup boundary like "...<br>".
        const notes = try event_mod.htmlToText(arena, raw.notes);
        const video_link = if (raw.conference_url.len > 0)
            raw.conference_url
        else
            event_mod.detectVideoLink(&.{ raw.url, raw.location, notes }) orelse "";

        out.* = .{
            .id = raw.id,
            .calendar_name = raw.calendar,
            .calendar_color = parseHexColor(raw.calendar_color) orelse
                colorForCalendar(raw_calendars, raw.calendar_id),
            .title = raw.title,
            .start = start,
            .end = end,
            .all_day = raw.all_day,
            .location = raw.location,
            .notes = notes,
            .url = raw.url,
            .video_link = video_link,
            .attendees = attendees,
            .is_recurring = raw.recurring,
            .self_rsvp = rsvpFromSelfStatus(raw.self_status),
        };
    }

    std.mem.sort(Event, events, {}, event_mod.lessThan);
    return events;
}

/// EKParticipantStatus int → Rsvp (0 unknown, 1 pending, 2 accepted,
/// 3 declined, 4 tentative — from go-eventkit's enum).
fn rsvpFromParticipantStatus(status: i64) Rsvp {
    return switch (status) {
        1 => .needs_action,
        2 => .accepted,
        3 => .declined,
        4 => .tentative,
        else => .unknown,
    };
}

fn rsvpFromSelfStatus(status: []const u8) Rsvp {
    const map = std.StaticStringMap(Rsvp).initComptime(.{
        .{ "accepted", .accepted },
        .{ "declined", .declined },
        .{ "tentative", .tentative },
        .{ "pending", .needs_action },
    });
    return map.get(status) orelse .unknown;
}

/// The CLI reports organizer as one display string (name or email); match it
/// against either attendee field.
fn isOrganizer(raw: IcalEvent, attendee: IcalAttendee) bool {
    if (raw.organizer.len == 0) return false;
    return (attendee.name.len > 0 and std.mem.eql(u8, raw.organizer, attendee.name)) or
        (attendee.email.len > 0 and std.mem.eql(u8, raw.organizer, attendee.email));
}

fn colorForCalendar(calendars: []const IcalCalendar, calendar_id: []const u8) u24 {
    for (calendars) |calendar| {
        if (std.mem.eql(u8, calendar.id, calendar_id)) {
            return parseHexColor(calendar.color) orelse 0;
        }
    }
    return 0; // theme fallback applied at draw time
}

/// "#RRGGBB" → 0xRRGGBB. Anything else → null.
fn parseHexColor(s: []const u8) ?u24 {
    if (s.len != 7 or s[0] != '#') return null;
    return std.fmt.parseInt(u24, s[1..], 16) catch null;
}

/// Format unix seconds as "YYYY-MM-DDTHH:MM:SSZ" into a caller buffer
/// (>= 20 bytes). `ical list -f/-t` accepts ISO 8601.
fn formatRfc3339Utc(buffer: []u8, unix: i64) []u8 {
    const civil = time_mod.civilFromUnix(unix, .utc);
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(civil.date.year)), // fetch windows are always CE years
        civil.date.month,
        civil.date.day,
        civil.time.hour,
        civil.time.minute,
        civil.time.second,
    }) catch unreachable; // 20 bytes always fits the caller's 24-byte buffer
}

const sample_list = @embedFile("ical-list-sample.json");
const sample_calendars = @embedFile("ical-calendars-sample.json");

test "parse fixture: field mapping, colors, sort order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const events = try parse(arena_state.allocator(), sample_list, sample_calendars);

    try std.testing.expectEqual(@as(usize, 5), events.len);

    // All-day events sort first (Independence Day Jul 4 before Planning Week Jul 6).
    try std.testing.expectEqualStrings("Independence Day", events[0].title);
    try std.testing.expect(events[0].all_day);
    try std.testing.expectEqual(@as(u24, 0xCB30E0), events[0].calendar_color);
    try std.testing.expectEqualStrings("Q3 Planning Week", events[1].title);

    const standup = events[2];
    try std.testing.expectEqualStrings("Team Standup", standup.title);
    try std.testing.expectEqualStrings("Work", standup.calendar_name);
    try std.testing.expectEqual(@as(u24, 0x0088FF), standup.calendar_color);
    try std.testing.expect(standup.is_recurring);
    try std.testing.expectEqual(Rsvp.accepted, standup.self_rsvp);
    try std.testing.expectEqualStrings("https://zoom.us/j/91441122334", standup.video_link);
    try std.testing.expectEqual(@as(usize, 4), standup.attendees.len);
    try std.testing.expect(standup.attendees[0].is_organizer); // Dana by name
    try std.testing.expectEqual(Rsvp.tentative, standup.attendees[1].rsvp);
    try std.testing.expectEqual(Rsvp.declined, standup.attendees[2].rsvp);
    try std.testing.expectEqual(Rsvp.needs_action, standup.attendees[3].rsvp);

    const lunch = events[3];
    try std.testing.expectEqualStrings("Lunch w/ Sam", lunch.title);
    try std.testing.expectEqual(Rsvp.needs_action, lunch.self_rsvp); // "pending"
    // Video link detected from notes when conference_url is absent.
    try std.testing.expectEqualStrings("https://meet.google.com/fak-efak-efk", lunch.video_link);

    const one_on_one = events[4];
    try std.testing.expectEqualStrings("1:1 with Dana", one_on_one.title);
    try std.testing.expect(one_on_one.attendees[0].is_organizer); // Dana by email
    try std.testing.expect(!one_on_one.attendees[1].is_organizer);
    try std.testing.expectEqualStrings("", one_on_one.video_link); // url is not a meeting
}

test "parse rejects malformed JSON and bad timestamps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.MalformedOutput, parse(arena, "not json", "[]"));
    try std.testing.expectError(error.MalformedOutput, parse(
        arena,
        \\[{"id":"x","title":"t","start_date":"garbage","end_date":"2026-07-07T16:00:00Z"}]
    ,
        "[]",
    ));
}

test "formatRfc3339Utc round-trips through parseRfc3339" {
    var buffer: [24]u8 = undefined;
    const ts = try time_mod.parseRfc3339("2026-07-07T16:00:00Z");
    const formatted = formatRfc3339Utc(&buffer, ts);
    try std.testing.expectEqualStrings("2026-07-07T16:00:00Z", formatted);
    try std.testing.expectEqual(ts, try time_mod.parseRfc3339(formatted));
}
