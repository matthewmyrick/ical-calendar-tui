//! Catppuccin Mocha palette and the app's semantic styles. The one place hex
//! values live (ARCHITECTURE.md §7e). Default background is the terminal's own —
//! transparency-friendly, no painted bg.

const vaxis = @import("vaxis");
const event_mod = @import("../calendar/event.zig");

/// Published catppuccin-mocha hex values.
pub const mocha = struct {
    pub const rosewater: u24 = 0xf5e0dc;
    pub const flamingo: u24 = 0xf2cdcd;
    pub const pink: u24 = 0xf5c2e7;
    pub const mauve: u24 = 0xcba6f7;
    pub const red: u24 = 0xf38ba8;
    pub const maroon: u24 = 0xeba0ac;
    pub const peach: u24 = 0xfab387;
    pub const yellow: u24 = 0xf9e2af;
    pub const green: u24 = 0xa6e3a1;
    pub const teal: u24 = 0x94e2d5;
    pub const sky: u24 = 0x89dceb;
    pub const sapphire: u24 = 0x74c7ec;
    pub const blue: u24 = 0x89b4fa;
    pub const lavender: u24 = 0xb4befe;
    pub const text: u24 = 0xcdd6f4;
    pub const subtext1: u24 = 0xbac2de;
    pub const subtext0: u24 = 0xa6adc8;
    pub const overlay2: u24 = 0x9399b2;
    pub const overlay1: u24 = 0x7f849c;
    pub const overlay0: u24 = 0x6c7086;
    pub const surface2: u24 = 0x585b70;
    pub const surface1: u24 = 0x45475a;
    pub const surface0: u24 = 0x313244;
    pub const base: u24 = 0x1e1e2e;
    pub const mantle: u24 = 0x181825;
    pub const crust: u24 = 0x11111b;
};

pub fn color(hex: u24) vaxis.Color {
    return .{ .rgb = .{
        @intCast((hex >> 16) & 0xff),
        @intCast((hex >> 8) & 0xff),
        @intCast(hex & 0xff),
    } };
}

/// Calendar color with theme fallback for sources that report none.
pub fn calendarColor(hex: u24) vaxis.Color {
    return color(if (hex == 0) mocha.blue else hex);
}

// Semantic styles. bg stays default everywhere (terminal transparency).
pub const text: vaxis.Style = .{ .fg = color(mocha.text) };
pub const dim: vaxis.Style = .{ .fg = color(mocha.overlay0) };
pub const subtle: vaxis.Style = .{ .fg = color(mocha.subtext0) };
pub const title: vaxis.Style = .{ .fg = color(mocha.lavender), .bold = true };
pub const today: vaxis.Style = .{ .fg = color(mocha.peach), .bold = true };
pub const selected: vaxis.Style = .{ .fg = color(mocha.base), .bg = color(mocha.lavender), .bold = true };
pub const border: vaxis.Style = .{ .fg = color(mocha.surface1) };
pub const accent: vaxis.Style = .{ .fg = color(mocha.mauve) };
pub const warning: vaxis.Style = .{ .fg = color(mocha.yellow) };
pub const err: vaxis.Style = .{ .fg = color(mocha.red), .bold = true };
pub const ok: vaxis.Style = .{ .fg = color(mocha.green) };

/// RSVP status color, shared by day and detail views: green yes, red no,
/// yellow maybe, bold-yellow "you haven't answered".
pub fn rsvpStyle(rsvp: event_mod.Rsvp) vaxis.Style {
    return switch (rsvp) {
        .accepted => ok,
        .declined => err,
        .tentative => warning,
        .needs_action => .{ .fg = color(mocha.yellow), .bold = true },
        .unknown => subtle,
    };
}
