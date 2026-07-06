//! App state machine: which view is on screen, the selected day, key
//! dispatch, and snapshot ownership. The UI thread reads snapshots; it never
//! fetches on its own once the poller exists (M3) — until then, refreshes
//! are synchronous and explicit.

const std = @import("std");
const vaxis = @import("vaxis");

const source_mod = @import("calendar/source.zig");
const time_mod = @import("calendar/time.zig");
const event_mod = @import("calendar/event.zig");
const snapshot_mod = @import("snapshot.zig");
const month_view = @import("ui/month.zig");
const day_view = @import("ui/day.zig");
const detail_view = @import("ui/detail.zig");
const help_view = @import("ui/help.zig");
const statusbar = @import("ui/statusbar.zig");

const CivilDate = time_mod.CivilDate;
const Snapshot = snapshot_mod.Snapshot;

/// Fetch window relative to the viewed month (SPEC §5): generous enough to
/// cover the grid plus notification horizon; navigation outside triggers a
/// refetch, not accumulation.
const window_back_days: i64 = 8;
const window_forward_days: i64 = 62;

/// Per-frame scratch for formatted strings. vaxis stores *references* to
/// printed text until render, so this memory is owned by App (not the stack)
/// and reset at the start of each frame, not the end.
const scratch_size = 8 * 1024;

pub const View = enum { month, day, detail };

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    zone: time_mod.Zone,
    source: source_mod.CalendarSource,
    snapshot: ?*Snapshot = null,
    view: View = .month,
    selected: CivilDate,
    fetch_failed: bool = false,
    should_quit: bool = false,
    /// Selected event within the day view (index into eventsOnDay).
    day_index: usize = 0,
    detail_scroll: usize = 0,
    help_visible: bool = false,
    scratch_buffer: [scratch_size]u8 = undefined, // written before every read via FixedBufferAllocator

    /// Loads the local timezone and picks the calendar source. Call
    /// `refresh()` for the initial data load. Deinit with `deinit()`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) App {
        const zone = time_mod.Zone.loadLocal(gpa, io);
        const today = time_mod.localDate(nowUnix(io), zone);
        return .{
            .gpa = gpa,
            .io = io,
            .zone = zone,
            .source = .{ .ical_cli = .{ .gpa = gpa, .io = io } },
            .selected = today,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.snapshot) |snapshot| snapshot.deinit();
        self.snapshot = null;
        self.zone.deinit();
    }

    /// Synchronous fetch covering the currently viewed month. On failure the
    /// previous snapshot stays on screen and the status bar shows a warning
    /// (CODING_STANDARDS §4: the UI never crashes on data problems).
    pub fn refresh(self: *App) void {
        const month_start = CivilDate{ .year = self.selected.year, .month = self.selected.month, .day = 1 };
        const from = time_mod.dayBounds(time_mod.addDays(month_start, -window_back_days), self.zone).start;
        const to = time_mod.dayBounds(time_mod.addDays(month_start, window_forward_days), self.zone).end;

        const fresh = Snapshot.build(self.gpa, &self.source, from, to, nowUnix(self.io)) catch {
            self.fetch_failed = true;
            return;
        };
        if (self.snapshot) |old| old.deinit();
        self.snapshot = fresh;
        self.fetch_failed = false;
    }

    /// Refetch when the selection has navigated outside the loaded window.
    fn ensureWindowCovers(self: *App) void {
        const snapshot = self.snapshot orelse return;
        const bounds = time_mod.dayBounds(self.selected, self.zone);
        if (bounds.start < snapshot.window_from or bounds.end > snapshot.window_to) {
            self.refresh();
        }
    }

    pub fn handleKey(self: *App, key: vaxis.Key) void {
        if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
            self.should_quit = true;
            return;
        }
        if (self.help_visible) {
            // Any key dismisses the overlay; ? and Esc feel natural.
            self.help_visible = false;
            return;
        }
        if (key.matches('?', .{})) {
            self.help_visible = true;
            return;
        }
        if (key.matches('r', .{})) {
            self.refresh();
            return;
        }
        if (key.matches('t', .{})) {
            self.selected = time_mod.localDate(nowUnix(self.io), self.zone);
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
        if (key.matches(vaxis.Key.escape, .{})) {
            self.view = .month;
        } else if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
            self.moveSelection(-1);
            self.day_index = 0;
        } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
            self.moveSelection(1);
            self.day_index = 0;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.day_index -|= 1;
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            const count = self.dayEventCount();
            if (count > 0 and self.day_index + 1 < count) self.day_index += 1;
        } else if (key.matches(vaxis.Key.enter, .{})) {
            if (self.selectedEvent() != null) {
                self.detail_scroll = 0;
                self.view = .detail;
            }
        }
    }

    fn handleDetailKey(self: *App, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.view = .day;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
            self.detail_scroll -|= 1;
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
            self.detail_scroll += 1; // clamped against content in draw
        } else if (key.matches('o', .{})) {
            if (self.selectedEvent()) |event| {
                const link = if (event.video_link.len > 0) event.video_link else event.url;
                if (link.len > 0) self.openUrl(link);
            }
        } else if (key.matches('c', .{})) {
            if (self.selectedEvent()) |event| {
                const link = if (event.video_link.len > 0) event.video_link else event.url;
                if (link.len > 0) self.copyToClipboard(link);
            }
        }
    }

    fn dayEventCount(self: *App) usize {
        const snapshot = self.snapshot orelse return 0;
        return @min(
            snapshot.countOnDay(self.selected, self.zone),
            day_view.max_events,
        );
    }

    /// The event the day cursor is on. Recomputed from the snapshot (never
    /// stored) so a refresh can't leave a dangling pointer.
    fn selectedEvent(self: *App) ?event_mod.Event {
        const snapshot = self.snapshot orelse return null;
        var events_buffer: [day_view.max_events]event_mod.Event = undefined;
        const events = snapshot.eventsOnDay(&events_buffer, self.selected, self.zone);
        if (events.len == 0) return null;
        self.day_index = @min(self.day_index, events.len - 1);
        return events[self.day_index];
    }

    /// Launch the default browser; fire and forget (`open` returns fast).
    fn openUrl(self: *App, url: []const u8) void {
        const result = std.process.run(self.gpa, self.io, .{
            .argv = &.{ "open", url },
        }) catch return; // best-effort: a broken opener must not kill the TUI
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
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

    pub fn draw(self: *App, win: vaxis.Window) void {
        win.clear();
        var scratch_state = std.heap.FixedBufferAllocator.init(&self.scratch_buffer);
        const scratch = scratch_state.allocator();
        const now = nowUnix(self.io);
        const snapshot: ?*const Snapshot = self.snapshot;
        switch (self.view) {
            .month => month_view.draw(win, scratch, snapshot, .{
                .selected = self.selected,
                .today = time_mod.localDate(now, self.zone),
                .zone = self.zone,
                .source_name = self.source.name(),
            }),
            .day => day_view.draw(win, scratch, snapshot, .{
                .date = self.selected,
                .selected_index = self.day_index,
                .zone = self.zone,
            }),
            .detail => {
                if (self.selectedEvent()) |event| {
                    self.detail_scroll = detail_view.draw(win, scratch, event, .{
                        .zone = self.zone,
                        .scroll = self.detail_scroll,
                    });
                } else {
                    self.view = .day; // event vanished on refresh; fall back
                }
            },
        }
        statusbar.draw(win, scratch, snapshot, .{ .now = now, .fetch_failed = self.fetch_failed });
        if (self.help_visible) help_view.draw(win);
    }
};

fn nowUnix(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
