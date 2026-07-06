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
const statusbar = @import("ui/statusbar.zig");

const CivilDate = time_mod.CivilDate;
const Snapshot = snapshot_mod.Snapshot;

/// Fetch window relative to the viewed month when navigation leaves the
/// loaded range (SPEC §5).
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
    scratch_buffer: [scratch_size]u8 = undefined, // written before every read via FixedBufferAllocator
    /// Stable copy of a link for subprocess use after the lock is dropped.
    link_buffer: [512]u8 = undefined,

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
        if (key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }
        // Search consumes every key while open — typed text must not
        // trigger bindings (a query containing "q" is not "back").
        if (self.search_active) {
            self.handleSearchKey(key);
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
        });
        if (self.help_visible) help_view.draw(win);
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
