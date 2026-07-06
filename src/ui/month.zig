//! Month view: the calendar grid with event dots/titles, plus the
//! selected-day peek (SPEC §7a). The grid is responsive: cells grow with the
//! terminal, the grid centers horizontally, and wide cells show event titles
//! in place of dots. Formatted strings go into the caller's per-frame
//! scratch allocator — vaxis keeps references to printed text until render
//! (see App.scratch_buffer). No heap allocation.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const config_mod = @import("../config.zig");
const time_mod = @import("../calendar/time.zig");
const event_mod = @import("../calendar/event.zig");
const snapshot_mod = @import("../snapshot.zig");

const CivilDate = time_mod.CivilDate;

// Cell sizes include the shared border line on one edge; interiors are one
// less in each dimension. The grid itself adds a final closing edge.
const min_cell_width: u16 = 6;
const max_cell_width: u16 = 27;
const min_cell_height: u16 = 3;
const max_cell_height: u16 = 8;
/// Cell interiors at least this wide show event titles instead of dots.
const titles_from_width: u16 = 12;
/// Peek lines under the grid for the selected day's events.
const max_peek = 3;
/// Rows reserved outside the grid: title(1) + gap(1) + weekday header(1)
/// above; peek header + lines + gap below; status bar last.
const rows_above_grid: u16 = 3;
const rows_below_grid: u16 = max_peek + 3;

pub const State = struct {
    selected: CivilDate,
    today: CivilDate,
    zone: time_mod.Zone,
    source_name: []const u8,
    week_start: config_mod.WeekStart = .monday,
};

/// Grid geometry for the current terminal size.
const Layout = struct {
    cell_width: u16,
    cell_height: u16,
    left: u16, // grid centered horizontally
    weeks: u16,
    lead: u16, // column of day 1

    fn compute(win: vaxis.Window, state: State) Layout {
        const first = CivilDate{ .year = state.selected.year, .month = state.selected.month, .day = 1 };
        const lead = columnFor(first, state.week_start);
        const days: u16 = time_mod.daysInMonth(state.selected.year, state.selected.month);
        const weeks: u16 = (lead + days + 6) / 7;

        // -3: side margins plus the grid's closing right edge.
        const cell_width = std.math.clamp((win.width -| 3) / 7, min_cell_width, max_cell_width);
        const grid_height = win.height -| (rows_above_grid + rows_below_grid);
        const cell_height = std.math.clamp(
            if (weeks > 0) (grid_height -| 1) / weeks else min_cell_height,
            min_cell_height,
            max_cell_height,
        );
        return .{
            .cell_width = cell_width,
            .cell_height = cell_height,
            .left = (win.width -| (cell_width * 7 + 1)) / 2,
            .weeks = weeks,
            .lead = lead,
        };
    }
};

/// Grid column (0..6) for a date under the configured week start.
fn columnFor(date: CivilDate, week_start: config_mod.WeekStart) u16 {
    const iso: u16 = @intFromEnum(time_mod.weekday(date)); // 0 = Monday
    return switch (week_start) {
        .monday => iso,
        .sunday => (iso + 1) % 7,
    };
}

pub fn draw(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
) void {
    const layout = Layout.compute(win, state);
    drawHeader(win, scratch, state, layout);
    drawWeekdayHeader(win, state.week_start, layout);
    drawGrid(win, scratch, snapshot, state, layout);
    drawPeek(win, scratch, snapshot, state, layout);
}

fn drawHeader(win: vaxis.Window, scratch: std.mem.Allocator, state: State, layout: Layout) void {
    const title = std.fmt.allocPrint(scratch, "{s} {d}", .{
        time_mod.month_names[state.selected.month - 1],
        @as(u32, @intCast(state.selected.year)),
    }) catch return;
    printAt(win, layout.left + 1, 0, title, theme.title);

    const source_label = std.fmt.allocPrint(scratch, "source: {s}", .{state.source_name}) catch return;
    const width: u16 = @intCast(source_label.len); // ASCII
    if (win.width > width + 1) {
        printAt(win, win.width - width - 1, 0, source_label, theme.dim);
    }
}

fn drawWeekdayHeader(win: vaxis.Window, week_start: config_mod.WeekStart, layout: Layout) void {
    for (0..7) |column| {
        const iso: usize = switch (week_start) {
            .monday => column,
            .sunday => (column + 6) % 7,
        };
        const name = time_mod.weekday_names_short[iso];
        const x = layout.left + @as(u16, @intCast(column)) * layout.cell_width + 2;
        printAt(win, x, 2, name, theme.subtle);
    }
}

fn drawGrid(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
    layout: Layout,
) void {
    drawGridLines(win, layout);

    const first = CivilDate{ .year = state.selected.year, .month = state.selected.month, .day = 1 };
    var today_cell: ?struct { column: u16, week: u16 } = null;
    var week: u16 = 0;
    while (week < layout.weeks) : (week += 1) {
        var column: u16 = 0;
        while (column < 7) : (column += 1) {
            const slot: i64 = @as(i64, week) * 7 + column - layout.lead;
            const date = time_mod.addDays(first, slot);
            if (date.eql(state.today)) today_cell = .{ .column = column, .week = week };
            const interior = win.child(.{
                .x_off = layout.left + column * layout.cell_width + 1,
                .y_off = rows_above_grid + week * layout.cell_height + 1,
                .width = layout.cell_width - 1,
                .height = layout.cell_height - 1,
            });
            drawDayCell(interior, scratch, date, date.month == state.selected.month, snapshot, state);
        }
    }
    // Today's box repaints its border segments in the accent color, on top
    // of the shared grid lines.
    if (today_cell) |cell| drawCellBox(win, layout, cell.column, cell.week, theme.today);
}

/// The shared grid: one line between neighboring cells, junction glyphs at
/// crossings (SPEC §7a).
fn drawGridLines(win: vaxis.Window, layout: Layout) void {
    const top = rows_above_grid;
    const right_edge = layout.left + layout.cell_width * 7;

    var line: u16 = 0;
    while (line <= layout.weeks) : (line += 1) {
        const y = top + line * layout.cell_height;
        var x = layout.left;
        while (x <= right_edge) : (x += 1) {
            const on_column = (x - layout.left) % layout.cell_width == 0;
            const glyph = if (!on_column)
                "─"
            else if (line == 0)
                (if (x == layout.left) "┌" else if (x == right_edge) "┐" else "┬")
            else if (line == layout.weeks)
                (if (x == layout.left) "└" else if (x == right_edge) "┘" else "┴")
            else
                (if (x == layout.left) "├" else if (x == right_edge) "┤" else "┼");
            writeGlyph(win, x, y, glyph, theme.border);
        }
    }

    var column: u16 = 0;
    while (column <= 7) : (column += 1) {
        const x = layout.left + column * layout.cell_width;
        var y = top + 1;
        while (y < top + layout.weeks * layout.cell_height) : (y += 1) {
            if ((y - top) % layout.cell_height == 0) continue; // junction row
            writeGlyph(win, x, y, "│", theme.border);
        }
    }
}

/// Repaint one cell's border rectangle in `style` (plain corners — reads as
/// a highlight box sitting on top of the grid).
fn drawCellBox(win: vaxis.Window, layout: Layout, column: u16, week: u16, style: vaxis.Style) void {
    const x0 = layout.left + column * layout.cell_width;
    const y0 = rows_above_grid + week * layout.cell_height;
    const x1 = x0 + layout.cell_width;
    const y1 = y0 + layout.cell_height;

    writeGlyph(win, x0, y0, "┌", style);
    writeGlyph(win, x1, y0, "┐", style);
    writeGlyph(win, x0, y1, "└", style);
    writeGlyph(win, x1, y1, "┘", style);
    var x = x0 + 1;
    while (x < x1) : (x += 1) {
        writeGlyph(win, x, y0, "─", style);
        writeGlyph(win, x, y1, "─", style);
    }
    var y = y0 + 1;
    while (y < y1) : (y += 1) {
        writeGlyph(win, x0, y, "│", style);
        writeGlyph(win, x1, y, "│", style);
    }
}

/// One day-cell interior: number row (full-width highlight when selected),
/// then either event-title lines (wide cells) or a dot row (narrow cells).
fn drawDayCell(
    cell: vaxis.Window,
    scratch: std.mem.Allocator,
    date: CivilDate,
    in_month: bool,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
) void {
    const is_selected = date.eql(state.selected);
    const is_today = date.eql(state.today);

    const number_style = if (is_selected)
        theme.selected
    else if (is_today)
        theme.today
    else if (in_month)
        theme.text
    else
        theme.dim;
    if (is_selected) {
        const number_row = cell.child(.{ .width = cell.width, .height = 1 });
        number_row.fill(.{ .style = number_style });
    }
    const label = std.fmt.allocPrint(scratch, "{d: >3}", .{date.day}) catch return;
    printAt(cell, 0, 0, label, number_style);

    const snap = snapshot orelse return;
    const count = snap.countOnDay(date, state.zone);
    if (count == 0) return;

    if (cell.width >= titles_from_width and cell.height >= 2) {
        drawCellTitles(cell, scratch, snap, date, state, count);
    } else {
        drawCellDots(cell, scratch, snap, date, state, count);
    }
}

/// Wide cells: one truncated, calendar-colored title per line.
fn drawCellTitles(
    cell: vaxis.Window,
    scratch: std.mem.Allocator,
    snap: *const snapshot_mod.Snapshot,
    date: CivilDate,
    state: State,
    count: usize,
) void {
    const lines: usize = cell.height - 1;
    var events_buffer: [max_cell_height]event_mod.Event = undefined;
    const events = snap.eventsOnDay(events_buffer[0..lines], date, state.zone);

    for (events, 0..) |event, i| {
        const row: u16 = 1 + @as(u16, @intCast(i));
        const shows_more = count > events.len and i == events.len - 1;
        if (shows_more) {
            const more = std.fmt.allocPrint(scratch, "+{d} more", .{count - events.len + 1}) catch return;
            printAt(cell, 1, row, more, theme.dim);
            return;
        }
        const marker: []const u8 = if (event.all_day) "◦" else "●";
        printAt(cell, 1, row, marker, .{ .fg = theme.calendarColor(event.calendar_color) });
        const title_win = cell.child(.{
            .x_off = 3,
            .y_off = row,
            .width = cell.width -| 4,
            .height = 1,
        });
        _ = title_win.printSegment(.{ .text = event.title, .style = .{
            .fg = theme.calendarColor(event.calendar_color),
        } }, .{});
    }
}

/// Narrow cells: colored dots, +N overflow.
fn drawCellDots(
    cell: vaxis.Window,
    scratch: std.mem.Allocator,
    snap: *const snapshot_mod.Snapshot,
    date: CivilDate,
    state: State,
    count: usize,
) void {
    if (cell.height < 2) return;
    const max_dots: usize = @min(cell.width -| 3, 4);
    var events_buffer: [4]event_mod.Event = undefined;
    const events = snap.eventsOnDay(events_buffer[0..max_dots], date, state.zone);
    var dot_x: u16 = 1;
    for (events) |event| {
        cell.writeCell(dot_x, 1, .{
            .char = .{ .grapheme = "●", .width = 1 },
            .style = .{ .fg = theme.calendarColor(event.calendar_color) },
        });
        dot_x += 1;
    }
    if (count > events.len) {
        const more = std.fmt.allocPrint(scratch, "+{d}", .{count - events.len}) catch return;
        printAt(cell, dot_x, 1, more, theme.dim);
    }
}

fn drawPeek(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
    layout: Layout,
) void {
    // +1 past the grid's closing bottom edge, +1 breathing room.
    const row = rows_above_grid + layout.weeks * layout.cell_height + 2;
    if (row + 1 >= win.height) return;
    const snap = snapshot orelse return;
    const left = layout.left + 1;

    const total = snap.countOnDay(state.selected, state.zone);
    const weekday_name = time_mod.weekday_names_short[@intFromEnum(time_mod.weekday(state.selected))];
    const header = std.fmt.allocPrint(scratch, "{s} {s} {d} — {d} event{s}", .{
        weekday_name,
        time_mod.month_names[state.selected.month - 1][0..3],
        state.selected.day,
        total,
        if (total == 1) "" else "s",
    }) catch return;
    printAt(win, left, row, header, theme.accent);

    var events_buffer: [max_peek]event_mod.Event = undefined;
    const events = snap.eventsOnDay(&events_buffer, state.selected, state.zone);
    for (events, 0..) |event, i| {
        const line_row = row + 1 + @as(u16, @intCast(i));
        if (line_row + 1 >= win.height) return;
        drawPeekLine(win, scratch, left, line_row, event, state);
    }
    if (total > events.len) {
        const line_row = row + 1 + @as(u16, @intCast(events.len));
        if (line_row + 1 >= win.height) return;
        const more = std.fmt.allocPrint(scratch, "  +{d} more", .{total - events.len}) catch return;
        printAt(win, left, line_row, more, theme.dim);
    }
}

fn drawPeekLine(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    left: u16,
    row: u16,
    event: event_mod.Event,
    state: State,
) void {
    const when = if (event.all_day)
        "all-day"
    else blk: {
        const start = time_mod.civilFromUnix(event.start, state.zone);
        break :blk std.fmt.allocPrint(scratch, "{d:0>2}:{d:0>2}", .{
            start.time.hour,
            start.time.minute,
        }) catch return;
    };
    printAt(win, left + 1, row, when, theme.subtle);

    const title_x = left + 1 + 8;
    const title_win = win.child(.{
        .x_off = title_x,
        .y_off = row,
        .width = win.width -| title_x,
        .height = 1,
    });
    _ = title_win.printSegment(.{ .text = event.title, .style = .{
        .fg = theme.calendarColor(event.calendar_color),
    } }, .{});
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = style }, .{});
}

fn writeGlyph(win: vaxis.Window, x: u16, y: u16, glyph: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    win.writeCell(x, y, .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
}
