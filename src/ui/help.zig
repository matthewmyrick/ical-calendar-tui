//! Help overlay: a centered floating box listing every key binding
//! (SPEC §7d). Data-driven rows so the table and the actual bindings are
//! reviewed side by side.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

const Row = struct {
    keys: []const u8,
    action: []const u8,
    /// Non-empty starts a new section with this heading.
    section: []const u8 = "",
};

/// Single source of truth for the overlay; update alongside README keys.
const rows = [_]Row{
    .{ .section = "everywhere", .keys = "?", .action = "toggle this help" },
    .{ .keys = "q / Ctrl-C", .action = "quit" },
    .{ .keys = "Esc", .action = "back / close" },
    .{ .keys = "r", .action = "refresh now" },
    .{ .keys = "t", .action = "jump to today" },
    .{ .section = "month", .keys = "← → / h l", .action = "previous / next day" },
    .{ .keys = "↑ ↓ / k j", .action = "same weekday ± a week" },
    .{ .keys = "[ ] / PgUp PgDn", .action = "previous / next month" },
    .{ .keys = "Enter", .action = "open day" },
    .{ .section = "day", .keys = "← → / h l", .action = "previous / next day" },
    .{ .keys = "↑ ↓ / k j", .action = "select event" },
    .{ .keys = "Enter", .action = "event detail" },
    .{ .section = "event detail", .keys = "↑ ↓ / k j", .action = "scroll" },
    .{ .keys = "o", .action = "open video link / url" },
    .{ .keys = "c", .action = "copy link to clipboard" },
};

const keys_column_width = 18;

pub fn draw(win: vaxis.Window) void {
    var height: u16 = 2; // top/bottom padding
    for (rows) |row| {
        if (row.section.len > 0) height += 2;
        height += 1;
    }
    const width: u16 = 52;
    if (win.width < width + 2 or win.height < height + 2) return;

    const box = win.child(.{
        .x_off = (win.width - width) / 2,
        .y_off = (win.height - height) / 2,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .style = theme.border },
    });
    box.fill(.{ .style = .{ .bg = theme.color(theme.mocha.mantle) } });

    var row_y: u16 = 1;
    for (rows) |row| {
        if (row.section.len > 0) {
            row_y += 1;
            printAt(box, 2, row_y - 1, row.section, theme.accent);
            row_y += 1;
        }
        printAt(box, 4, row_y - 1, row.keys, theme.title);
        printAt(box, 4 + keys_column_width, row_y - 1, row.action, theme.text);
        row_y += 1;
    }
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    var overlay_style = style;
    overlay_style.bg = theme.color(theme.mocha.mantle);
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = overlay_style }, .{});
}
