//! Milestone-4 calendar source: the native EventKit shim. This is the only
//! file allowed to touch the C ABI (CODING_STANDARDS §7); raw C values are
//! converted to Zig types at this boundary and travel no further inland.
//!
//! The shim emits the same JSON field names as `ical -o json` plus a
//! per-event "calendar_color", so both sources share one parser
//! (ical_cli.parse).

const std = @import("std");
const event_mod = @import("event.zig");
const ical_cli = @import("ical_cli.zig");

const shim = @cImport(@cInclude("eventkit_shim.h"));

pub const FetchError = ical_cli.FetchError || error{AccessDenied};

pub const EventKitSource = struct {
    gpa: std.mem.Allocator,

    /// Trigger the TCC prompt (first run) or read the existing grant.
    /// Blocks; call from the poller thread only.
    pub fn requestAccess() error{AccessDenied}!void {
        if (shim.ek_request_access() != shim.EK_OK) return error.AccessDenied;
    }

    /// Fetch all events in [from, to]. Result is owned by `arena`; freed
    /// when the snapshot is dropped. Poller thread only.
    pub fn fetch(self: *EventKitSource, arena: std.mem.Allocator, from: i64, to: i64) FetchError![]event_mod.Event {
        _ = self;
        var json_ptr: [*c]u8 = null;
        var json_len: usize = 0;
        const rc = shim.ek_fetch_events(
            @floatFromInt(from),
            @floatFromInt(to),
            &json_ptr,
            &json_len,
        );
        switch (rc) {
            shim.EK_OK => {},
            shim.EK_ERR_ACCESS_DENIED => return error.AccessDenied,
            shim.EK_ERR_OOM => return error.OutOfMemory,
            else => return error.MalformedOutput,
        }
        defer shim.ek_free(json_ptr);
        // Convert to a slice at the boundary, immediately, with its length.
        const json: []const u8 = json_ptr[0..json_len];
        return ical_cli.parse(arena, json, "[]");
    }
};
