//! App state machine: which view is on screen, the selected day, key
//! dispatch. The UI thread never fetches — data arrives via the poller; the
//! UI reads the current snapshot under the poller's mutex, held from draw
//! through render so snapshot strings referenced by vaxis stay alive.

const std = @import("std");
const vaxis = @import("vaxis");

const config_mod = @import("config.zig");
const poller_mod = @import("poller.zig");
const time_mod = @import("calendar/time.zig");
const event_mod = @import("calendar/event.zig");
const snapshot_mod = @import("snapshot.zig");
const month_view = @import("ui/month.zig");
const day_view = @import("ui/day.zig");
const detail_view = @import("ui/detail.zig");
const help_view = @import("ui/help.zig");
const search_view = @import("ui/search.zig");
const eventform = @import("ui/eventform.zig");
const statusbar = @import("ui/statusbar.zig");

const CivilDate = time_mod.CivilDate;
const Snapshot = snapshot_mod.Snapshot;

/// Fetch window relative to the viewed month when navigation leaves the
/// loaded range (ARCHITECTURE.md §5).
const window_back_days: i64 = 8;
const window_forward_days: i64 = 62;

/// Per-frame scratch for formatted strings. vaxis stores *references* to
/// printed text until render, so this memory is owned by App (not the stack)
/// and reset at the start of each frame, not the end.
const scratch_size = 8 * 1024;

pub const View = enum { month, day, detail };

pub const App = struct {
    io: std.Io,
    zone: time_mod.Zone,
    poller: *poller_mod.Poller,
    week_start: config_mod.WeekStart,
    view: View = .month,
    selected: CivilDate,
    should_quit: bool = false,
    /// Selected event within the day view (index into eventsOnDay).
    day_index: usize = 0,
    detail_scroll: usize = 0,
    help_visible: bool = false,
    search_active: bool = false,
    search_buffer: [search_view.max_query]u8 = undefined, // valid up to search_len
    search_len: usize = 0,
    search_index: usize = 0,
    /// The event form (`a` create / `e` edit); buffers valid up to lens.
    form_active: bool = false,
    form_mode: eventform.Mode = .add,
    form_index: usize = 0,
    form_buffers: [eventform.field_count][eventform.max_field]u8 = undefined,
    form_lens: [eventform.field_count]usize = @splat(0),
    /// One-line transient result of the last action (static strings only);
    /// cleared on the next keypress.
    flash: ?[]const u8 = null,
    scratch_buffer: [scratch_size]u8 = undefined, // written before every read via FixedBufferAllocator
    /// Stable copy of a link for subprocess use after the lock is dropped.
    link_buffer: [512]u8 = undefined,
    /// Target event id for an Interactive.edit, copied out under the lock.
    command_id_buffer: [512]u8 = undefined,
    command_id_len: usize = 0,

    pub fn init(
        io: std.Io,
        zone: time_mod.Zone,
        poller: *poller_mod.Poller,
        week_start: config_mod.WeekStart,
    ) App {
        return .{
            .io = io,
            .zone = zone,
            .poller = poller,
            .week_start = week_start,
            .selected = time_mod.localDate(poller_mod.nowUnix(io), zone),
        };
    }

    pub fn handleKey(self: *App, key: vaxis.Key) void {
        self.flash = null; // any keypress dismisses the last action result
        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }
        // Text-input overlays consume every key while open — typed text
        // must not trigger bindings (a query containing "q" is not "back").
        if (self.search_active) {
            self.handleSearchKey(key);
            return;
        }
        if (self.form_active) {
            self.handleFormKey(key);
            return;
        }
        if (key.matches('Q', .{})) {
            self.should_quit = true;
            return;
        }
        if (self.help_visible) {
            // Any key dismisses the overlay.
            self.help_visible = false;
            return;
        }
        if (key.matches('?', .{})) {
            self.help_visible = true;
            return;
        }
        if (key.matches('/', .{})) {
            self.search_active = true;
            self.search_len = 0;
            self.search_index = 0;
            return;
        }
        if (key.matches('a', .{})) {
            self.openForm(.add);
            return;
        }
        if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
            self.back();
            return;
        }
        if (key.matches('r', .{})) {
            self.poller.wake();
            return;
        }
        if (key.matches('t', .{})) {
            self.selected = time_mod.localDate(poller_mod.nowUnix(self.io), self.zone);
            self.day_index = 0;
            self.ensureWindowCovers();
            return;
        }
        // RSVP on the selected event works from day and detail views.
        if (self.view == .day or self.view == .detail) {
            if (key.matches('y', .{})) {
                self.rsvpSelected("accepted");
                return;
            }
            if (key.matches('n', .{})) {
                self.rsvpSelected("declined");
                return;
            }
            if (key.matches('m', .{})) {
                self.rsvpSelected("tentative");
                return;
            }
            if (key.matches('e', .{})) {
                self.openForm(.edit);
                return;
            }
        }
        switch (self.view) {
            .month => self.handleMonthKey(key),
            .day => self.handleDayKey(key),
            .detail => self.handleDetailKey(key),
        }
    }

    /// One level up the view stack; no-op at the month view (Q quits).
    fn back(self: *App) void {
        switch (self.view) {
            .month => {},
            .day => self.view = .month,
            .detail => self.view = .day,
        }
    }

    fn handleSearchKey(self: *App, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.search_active = false;
        } else if (key.matches(vaxis.Key.enter, .{})) {
            self.jumpToSearchResult();
        } else if (key.matches(vaxis.Key.up, .{})) {
            self.search_index -|= 1;
        } else if (key.matches(vaxis.Key.down, .{})) {
            self.search_index += 1; // clamped against results in draw
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            // Drop the last UTF-8 sequence, not just the last byte.
            while (self.search_len > 0) {
                self.search_len -= 1;
                if (self.search_buffer[self.search_len] & 0xC0 != 0x80) break;
            }
        } else if (key.text) |text| {
            if (self.search_len + text.len <= self.search_buffer.len) {
                @memcpy(self.search_buffer[self.search_len..][0..text.len], text);
                self.search_len += text.len;
                self.search_index = 0;
            }
        }
    }

    fn jumpToSearchResult(self: *App) void {
        self.lockPoller();
        defer self.unlockPoller();
        const snapshot = self.poller.snapshot orelse return;

        var results_buffer: [search_view.max_results]search_view.Match = undefined;
        const results = search_view.search(
            snapshot.events,
            self.search_buffer[0..self.search_len],
            &results_buffer,
        );
        if (results.len == 0) return;
        const target = results[@min(self.search_index, results.len - 1)].event;

        self.selected = time_mod.localDate(target.start, self.zone);
        self.search_active = false;
        self.view = .detail;
        self.detail_scroll = 0;
        // Point the day cursor at the target so Esc lands on it in Day view.
        var events_buffer: [day_view.max_events]event_mod.Event = undefined;
        const day_events = snapshot.eventsOnDay(&events_buffer, self.selected, self.zone);
        self.day_index = for (day_events, 0..) |event, i| {
            if (event.start == target.start and std.mem.eql(u8, event.id, target.id)) break i;
        } else 0;
    }

    fn handleMonthKey(self: *App, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
            self.moveSelection(-1);
        } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
            self.moveSelection(1);
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.moveSelection(-7);
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.moveSelection(7);
        } else if (key.matches('[', .{}) or key.matches(vaxis.Key.page_up, .{})) {
            self.moveMonth(-1);
        } else if (key.matches(']', .{}) or key.matches(vaxis.Key.page_down, .{})) {
            self.moveMonth(1);
        } else if (key.matches(vaxis.Key.enter, .{})) {
            self.day_index = 0;
            self.view = .day;
        }
    }

    fn handleDayKey(self: *App, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
            self.moveSelection(-1);
            self.day_index = 0;
        } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
            self.moveSelection(1);
            self.day_index = 0;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.day_index -|= 1;
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.lockPoller();
            defer self.unlockPoller();
            const count = self.dayEventCountLocked();
            if (count > 0 and self.day_index + 1 < count) self.day_index += 1;
        } else if (key.matches(vaxis.Key.enter, .{})) {
            self.lockPoller();
            defer self.unlockPoller();
            if (self.selectedEventLocked() != null) {
                self.detail_scroll = 0;
                self.view = .detail;
            }
        }
    }

    fn handleDetailKey(self: *App, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.detail_scroll -|= 1;
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.detail_scroll += 1; // clamped against content in draw
        } else if (key.matches('o', .{})) {
            if (self.copySelectedLink()) |link| self.openUrl(link);
        } else if (key.matches('c', .{})) {
            if (self.copySelectedLink()) |link| self.copyToClipboard(link);
        }
    }

    /// The edit target captured when the form opened.
    fn commandId(self: *const App) []const u8 {
        return self.command_id_buffer[0..self.command_id_len];
    }

    /// Copy the selected event's id out of the snapshot under the lock, so
    /// subprocess argv points at stable memory.
    fn copySelectedId(self: *App) ?[]const u8 {
        self.lockPoller();
        defer self.unlockPoller();
        const event = self.selectedEventLocked() orelse return null;
        if (event.id.len == 0 or event.id.len > self.command_id_buffer.len) return null;
        @memcpy(self.command_id_buffer[0..event.id.len], event.id);
        self.command_id_len = event.id.len;
        return self.commandId();
    }

    /// Send an RSVP for the selected event via `ical rsvp`. Runs on the UI
    /// thread — a server round-trip can take a beat, and a frozen frame
    /// with a flash result beats concurrency machinery for a keypress.
    fn rsvpSelected(self: *App, status: []const u8) void {
        const id = self.copySelectedId() orelse {
            self.flash = "no event selected";
            return;
        };
        const result = std.process.run(self.poller.gpa, self.io, .{
            .argv = &.{ "ical", "rsvp", status, id },
        }) catch {
            self.flash = "RSVP failed — is `ical` installed?";
            return;
        };
        defer self.poller.gpa.free(result.stdout);
        defer self.poller.gpa.free(result.stderr);
        const ok = result.term == .exited and result.term.exited == 0;
        self.flash = if (!ok)
            "RSVP failed (not an invitation?)"
        else if (std.mem.eql(u8, status, "accepted"))
            "RSVP sent: accepted ✓"
        else if (std.mem.eql(u8, status, "declined"))
            "RSVP sent: declined ✗"
        else
            "RSVP sent: tentative ?";
        if (ok) self.poller.wake();
    }

    /// Open the event form: blank-ish for add (date prefilled from the
    /// selection), fully prefilled from the selected event for edit.
    fn openForm(self: *App, mode: eventform.Mode) void {
        self.form_mode = mode;
        self.form_index = 0;
        self.form_lens = @splat(0);

        switch (mode) {
            .add => {
                // Prefill the date you're standing on; type the time after it.
                self.setFormFieldFmt(.start, "{d:0>4}-{d:0>2}-{d:0>2} ", .{
                    @as(u32, @intCast(self.selected.year)),
                    self.selected.month,
                    self.selected.day,
                });
            },
            .edit => {
                self.lockPoller();
                defer self.unlockPoller();
                const event = self.selectedEventLocked() orelse {
                    self.flash = "no event selected";
                    return;
                };
                if (event.id.len == 0 or event.id.len > self.command_id_buffer.len) {
                    self.flash = "event has no editable id";
                    return;
                }
                @memcpy(self.command_id_buffer[0..event.id.len], event.id);
                self.command_id_len = event.id.len;

                self.setFormField(.title, event.title);
                self.setFormFieldTime(.start, event.start);
                self.setFormFieldTime(.end, event.end);
                if (event.all_day) self.setFormField(.all_day, "y");
                self.setFormField(.calendar, event.calendar_name);
                self.setFormField(.location, event.location);
            },
        }
        self.form_active = true;
    }

    fn setFormField(self: *App, field: eventform.Field, value: []const u8) void {
        const i = @intFromEnum(field);
        const len = @min(value.len, self.form_buffers[i].len);
        @memcpy(self.form_buffers[i][0..len], value[0..len]);
        self.form_lens[i] = len;
    }

    fn setFormFieldFmt(self: *App, field: eventform.Field, comptime fmt: []const u8, args: anytype) void {
        const i = @intFromEnum(field);
        const written = std.fmt.bufPrint(&self.form_buffers[i], fmt, args) catch return;
        self.form_lens[i] = written.len;
    }

    /// Local "YYYY-MM-DD HH:MM" — the format `ical` prints and parses.
    fn setFormFieldTime(self: *App, field: eventform.Field, unix: i64) void {
        const civil = time_mod.civilFromUnix(unix, self.zone);
        self.setFormFieldFmt(field, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(civil.date.year)),
            civil.date.month,
            civil.date.day,
            civil.time.hour,
            civil.time.minute,
        });
    }

    fn formValue(self: *const App, field: eventform.Field) []const u8 {
        const i = @intFromEnum(field);
        return std.mem.trim(u8, self.form_buffers[i][0..self.form_lens[i]], " ");
    }

    fn handleFormKey(self: *App, key: vaxis.Key) void {
        const visible = eventform.fields(self.form_mode);
        if (key.matches(vaxis.Key.escape, .{})) {
            self.form_active = false;
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.form_index + 1 < visible.len) {
                self.form_index += 1;
            } else {
                self.submitForm();
            }
            return;
        }
        if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
            self.form_index = (self.form_index + 1) % visible.len;
            return;
        }
        if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
            self.form_index = if (self.form_index == 0) visible.len - 1 else self.form_index - 1;
            return;
        }
        const i = @intFromEnum(visible[self.form_index]);
        const buffer = &self.form_buffers[i];
        const len = &self.form_lens[i];
        if (key.matches(vaxis.Key.backspace, .{})) {
            while (len.* > 0) {
                len.* -= 1;
                if (buffer[len.*] & 0xC0 != 0x80) break; // full UTF-8 sequence
            }
        } else if (key.text) |text| {
            if (len.* + text.len <= buffer.len) {
                @memcpy(buffer[len.*..][0..text.len], text);
                len.* += text.len;
            }
        }
    }

    /// Build and run the `ical add`/`ical update` invocation. The CLI owns
    /// date parsing and validation; we surface pass/fail.
    fn submitForm(self: *App) void {
        const title = self.formValue(.title);
        const start = self.formValue(.start);
        if (title.len == 0 or start.len == 0) {
            self.flash = "title and when are required";
            return;
        }
        const all_day = std.ascii.startsWithIgnoreCase(self.formValue(.all_day), "y");

        // Bounded argv assembly: base + 5 flag pairs + 8 invitations.
        var argv_buffer: [32][]const u8 = undefined;
        var argc: usize = 0;
        const push = struct {
            fn push(storage: *[32][]const u8, count: *usize, arg: []const u8) void {
                if (count.* < storage.len) {
                    storage[count.*] = arg;
                    count.* += 1;
                }
            }
        }.push;

        push(&argv_buffer, &argc, "ical");
        switch (self.form_mode) {
            .add => {
                push(&argv_buffer, &argc, "add");
                push(&argv_buffer, &argc, title);
                if (all_day) push(&argv_buffer, &argc, "-a");
            },
            .edit => {
                push(&argv_buffer, &argc, "update");
                push(&argv_buffer, &argc, "--id");
                push(&argv_buffer, &argc, self.commandId());
                push(&argv_buffer, &argc, "-T");
                push(&argv_buffer, &argc, title);
                push(&argv_buffer, &argc, "-a");
                push(&argv_buffer, &argc, if (all_day) "true" else "false");
            },
        }
        push(&argv_buffer, &argc, "-s");
        push(&argv_buffer, &argc, start);
        if (self.formValue(.end).len > 0) {
            push(&argv_buffer, &argc, "-e");
            push(&argv_buffer, &argc, self.formValue(.end));
        }
        if (self.formValue(.calendar).len > 0) {
            push(&argv_buffer, &argc, "-c");
            push(&argv_buffer, &argc, self.formValue(.calendar));
        }
        if (self.formValue(.location).len > 0) {
            push(&argv_buffer, &argc, "-l");
            push(&argv_buffer, &argc, self.formValue(.location));
        }
        if (self.form_mode == .add) {
            var invitees = std.mem.tokenizeAny(u8, self.formValue(.invite), ", ");
            while (invitees.next()) |email| {
                push(&argv_buffer, &argc, "--invite");
                push(&argv_buffer, &argc, email);
            }
        }

        const result = std.process.run(self.poller.gpa, self.io, .{
            .argv = argv_buffer[0..argc],
        }) catch {
            self.flash = "save failed — is `ical` installed?";
            return;
        };
        defer self.poller.gpa.free(result.stdout);
        defer self.poller.gpa.free(result.stderr);
        const ok = result.term == .exited and result.term.exited == 0;
        if (ok) {
            self.flash = switch (self.form_mode) {
                .add => "event created ✓",
                .edit => "event updated ✓",
            };
            self.form_active = false;
            self.poller.wake();
        } else {
            // Most common failure: ical couldn't parse the date. Keep the
            // form open so the text can be fixed.
            self.flash = "save failed — check the date text";
        }
    }

    fn moveSelection(self: *App, delta_days: i64) void {
        self.selected = time_mod.addDays(self.selected, delta_days);
        self.ensureWindowCovers();
    }

    fn moveMonth(self: *App, delta: i32) void {
        const target = time_mod.addMonths(self.selected, delta);
        self.selected = .{
            .year = target.year,
            .month = target.month,
            .day = time_mod.clampedDay(target.year, target.month, self.selected.day),
        };
        self.ensureWindowCovers();
    }

    /// Ask the poller for a wider window when the selection leaves the
    /// loaded one. The stale grid stays visible until the fetch lands.
    fn ensureWindowCovers(self: *App) void {
        const bounds = time_mod.dayBounds(self.selected, self.zone);
        var needs_fetch = false;
        {
            self.lockPoller();
            defer self.unlockPoller();
            const snapshot = self.poller.snapshot orelse return;
            needs_fetch = bounds.start < snapshot.window_from or bounds.end > snapshot.window_to;
        }
        if (needs_fetch) {
            const month_start = CivilDate{ .year = self.selected.year, .month = self.selected.month, .day = 1 };
            const from = time_mod.dayBounds(time_mod.addDays(month_start, -window_back_days), self.zone).start;
            const to = time_mod.dayBounds(time_mod.addDays(month_start, window_forward_days), self.zone).end;
            self.poller.requestWindow(from, to);
        }
    }

    /// Copy the selected event's video link (or url) out of the snapshot
    /// under the lock, so the subprocess runs on a stable copy.
    fn copySelectedLink(self: *App) ?[]const u8 {
        self.lockPoller();
        defer self.unlockPoller();
        const event = self.selectedEventLocked() orelse return null;
        const link = if (event.video_link.len > 0) event.video_link else event.url;
        if (link.len == 0 or link.len > self.link_buffer.len) return null;
        @memcpy(self.link_buffer[0..link.len], link);
        return self.link_buffer[0..link.len];
    }

    /// Callers must hold the poller mutex.
    fn dayEventCountLocked(self: *App) usize {
        const snapshot = self.poller.snapshot orelse return 0;
        return @min(snapshot.countOnDay(self.selected, self.zone), day_view.max_events);
    }

    /// The event the day cursor is on; callers must hold the poller mutex
    /// and drop the result before unlocking (strings live in the arena).
    fn selectedEventLocked(self: *App) ?event_mod.Event {
        const snapshot = self.poller.snapshot orelse return null;
        var events_buffer: [day_view.max_events]event_mod.Event = undefined;
        const events = snapshot.eventsOnDay(&events_buffer, self.selected, self.zone);
        if (events.len == 0) return null;
        self.day_index = @min(self.day_index, events.len - 1);
        return events[self.day_index];
    }

    /// Launch the default browser; best-effort (a broken opener must not
    /// kill the TUI).
    fn openUrl(self: *App, url: []const u8) void {
        const result = std.process.run(self.poller.gpa, self.io, .{
            .argv = &.{ "open", url },
        }) catch return;
        self.poller.gpa.free(result.stdout);
        self.poller.gpa.free(result.stderr);
    }

    fn copyToClipboard(self: *App, text: []const u8) void {
        var child = std.process.spawn(self.io, .{
            .argv = &.{"pbcopy"},
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return; // best-effort
        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(self.io, text) catch {}; // best-effort
            stdin.close(self.io);
            child.stdin = null;
        }
        _ = child.wait(self.io) catch {}; // best-effort
    }

    pub fn lockPoller(self: *App) void {
        self.poller.mutex.lockUncancelable(self.io);
    }

    pub fn unlockPoller(self: *App) void {
        self.poller.mutex.unlock(self.io);
    }

    /// Draw the current view. The caller (main loop) holds the poller mutex
    /// from before this call until after vx.render() — snapshot strings are
    /// referenced by vaxis until then.
    pub fn draw(self: *App, win: vaxis.Window) void {
        win.clear();
        var scratch_state = std.heap.FixedBufferAllocator.init(&self.scratch_buffer);
        const scratch = scratch_state.allocator();
        const now = poller_mod.nowUnix(self.io);
        const snapshot: ?*const Snapshot = self.poller.snapshot;
        switch (self.view) {
            .month => month_view.draw(win, scratch, snapshot, .{
                .selected = self.selected,
                .today = time_mod.localDate(now, self.zone),
                .zone = self.zone,
                .source_name = self.poller.source.name(),
                .week_start = self.week_start,
            }),
            .day => day_view.draw(win, scratch, snapshot, .{
                .date = self.selected,
                .selected_index = self.day_index,
                .zone = self.zone,
            }),
            .detail => {
                if (self.selectedEventLocked()) |event| {
                    self.detail_scroll = detail_view.draw(win, scratch, event, .{
                        .zone = self.zone,
                        .scroll = self.detail_scroll,
                    });
                } else {
                    self.view = .day; // event vanished on refresh; fall back
                }
            },
        }
        statusbar.draw(win, scratch, snapshot, .{
            .now = now,
            .consecutive_failures = self.poller.consecutive_failures,
            .flash = self.flash,
        });
        if (self.help_visible) help_view.draw(win);
        if (self.form_active) {
            var values: [eventform.field_count][]const u8 = undefined;
            for (0..eventform.field_count) |i| {
                values[i] = self.form_buffers[i][0..self.form_lens[i]];
            }
            eventform.draw(win, scratch, .{
                .mode = self.form_mode,
                .values = values,
                .active_index = self.form_index,
            });
        }
        if (self.search_active) {
            const events: []const event_mod.Event = if (snapshot) |snap| snap.events else &.{};
            const result_count = search_view.draw(win, scratch, events, .{
                .query = self.search_buffer[0..self.search_len],
                .selected_index = self.search_index,
                .zone = self.zone,
            });
            if (result_count > 0) self.search_index = @min(self.search_index, result_count - 1);
        }
    }
};
