//! The event form: one overlay for creating (`a`) and editing (`e`) events.
//! Every field except title and when is optional — blank simply means
//! "default" or "unchanged". Submission becomes a non-interactive `ical
//! add`/`ical update`; the CLI owns date parsing and validation.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

pub const max_field = 96;

pub const Mode = enum { add, edit };

pub const Field = enum {
    title,
    start,
    end,
    all_day,
    calendar,
    location,
    invite,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .title => "title   ",
            .start => "when    ",
            .end => "until   ",
            .all_day => "all-day ",
            .calendar => "calendar",
            .location => "location",
            .invite => "invite  ",
        };
    }

    /// Grayed hint shown while the field is empty and inactive.
    fn hint(self: Field, mode: Mode) []const u8 {
        return switch (self) {
            .title => "(required)",
            .start => "(required — natural language ok: \"tomorrow 2pm\")",
            .end => if (mode == .add) "(1h)" else "(unchanged)",
            .all_day => "(y for all-day)",
            .calendar => if (mode == .add) "(default)" else "(unchanged)",
            .location => "",
            .invite => "(emails, comma-separated — sends invitations)",
        };
    }
};

pub const field_count = @typeInfo(Field).@"enum".fields.len;

/// Fields shown per mode: `ical update` can't add invitees, so edit hides
/// that field.
pub fn fields(mode: Mode) []const Field {
    const all = comptime std.enums.values(Field);
    return switch (mode) {
        .add => all,
        .edit => all[0 .. field_count - 1],
    };
}

pub const State = struct {
    mode: Mode,
    values: [field_count][]const u8,
    active_index: usize,
};

pub fn draw(win: vaxis.Window, scratch: std.mem.Allocator, state: State) void {
    const visible = fields(state.mode);
    const width: u16 = @min(72, win.width -| 4);
    const height: u16 = @as(u16, @intCast(visible.len)) + 4;
    if (win.width < width + 2 or win.height < height + 2) return;

    const box = win.child(.{
        .x_off = (win.width - width) / 2,
        .y_off = (win.height -| height) / 3,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .style = theme.border },
    });
    box.fill(.{ .style = .{ .bg = theme.color(theme.mocha.mantle) } });

    printAt(box, 2, 0, switch (state.mode) {
        .add => "new event",
        .edit => "edit event",
    }, theme.title);

    for (visible, 0..) |field, i| {
        const row: u16 = 2 + @as(u16, @intCast(i));
        const is_active = i == state.active_index;
        const value = state.values[@intFromEnum(field)];
        const cursor: []const u8 = if (is_active) "▏" else "";
        const hint: []const u8 = if (value.len == 0 and !is_active) field.hint(state.mode) else "";
        const line = std.fmt.allocPrint(scratch, "{s}  {s}{s}{s}", .{
            field.label(), value, cursor, hint,
        }) catch return;
        printAt(box, 2, row, line, if (is_active) theme.text else theme.subtle);
    }

    printAt(
        box,
        2,
        height - 2,
        "Enter/Tab next · ↑↓ move · Enter on last saves · Esc cancels",
        theme.dim,
    );
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    var overlay_style = style;
    if (overlay_style.bg == .default) overlay_style.bg = theme.color(theme.mocha.mantle);
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = overlay_style }, .{});
}

test "edit mode hides the invite field" {
    try std.testing.expectEqual(@as(usize, field_count), fields(.add).len);
    try std.testing.expectEqual(@as(usize, field_count - 1), fields(.edit).len);
    try std.testing.expectEqual(Field.location, fields(.edit)[fields(.edit).len - 1]);
}
