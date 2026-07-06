# ical-calendar-tui — Build Specification

A macOS calendar TUI written in **Zig**: reads the local Mac calendar (everything
Calendar.app sees — iCloud, Google, Exchange, local), renders a navigable
month/day/event interface in the terminal, polls for changes in the background,
and fires meeting notifications.

This document is the **complete, decision-ready spec** for the implementing
agent. Read it top to bottom before writing code. Where a fact depends on the
fast-moving Zig ecosystem it is marked **[VERIFY AT KICKOFF]** — check it, then
proceed; do not silently substitute different choices.

Companion documents:
- [`CODING_STANDARDS.md`](CODING_STANDARDS.md) — Zig style, memory, and error rules. **Binding.**
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — workflow, commands, commit conventions.

---

## Table of contents

1. [Goals and non-goals](#1-goals-and-non-goals)
2. [Why these technology choices](#2-why-these-technology-choices)
3. [Bootstrap (machine has no Zig)](#3-bootstrap-machine-has-no-zig)
4. [Architecture](#4-architecture)
5. [Data layer: two calendar sources](#5-data-layer-two-calendar-sources)
6. [The event model](#6-the-event-model)
7. [TUI specification](#7-tui-specification)
8. [Polling](#8-polling)
9. [Notifications](#9-notifications)
10. [Daemon mode](#10-daemon-mode)
11. [Configuration](#11-configuration)
12. [Memory-efficiency requirements](#12-memory-efficiency-requirements)
13. [macOS permissions (TCC) — the Info.plist trick](#13-macos-permissions-tcc--the-infoplist-trick)
14. [Repository layout](#14-repository-layout)
15. [Milestones with acceptance criteria](#15-milestones-with-acceptance-criteria)
16. [Out of scope for v1](#16-out-of-scope-for-v1)

---

## 1. Goals and non-goals

### Goals (v1)

| # | Feature | Summary |
|---|---------|---------|
| 1 | **Local Mac calendar** | Read the same EventKit store Calendar.app uses. No CalDAV sync, no Google API keys. |
| 2 | **TUI navigation** | Month grid → arrow keys move day to day → `Enter` opens the day → `Enter` on an event shows full metadata (attendees, RSVP status, organizer, location, video link, notes). |
| 3 | **Notifications** | Alerts N minutes before events (configurable lead times), delivered via macOS Notification Center, with herdr-toast support when running inside herdr. |
| 4 | **Polling** | Background refresh of calendar data every 60 s (configurable). The UI never blocks on fetches. |
| 5 | **Memory efficiency** | Bounded, predictable memory. Arena-based lifetimes, no per-frame heap allocation, leak-free under Zig's GPA leak detection. Target: **< 10 MB RSS idle**. |
| 6 | **Daemon mode** | `--daemon` runs headless (poll + notify only) under launchd, so notifications work even when the TUI isn't open. |

### Non-goals (v1)

- Event **creation/editing** in the TUI. Writes are delegated to the `ical` CLI
  (`ical add -i` etc.). A later version may shell out from a keybinding.
- Windows/Linux support. This is macOS-only by design (EventKit).
- Reminders (EventKit reminders/tasks). Later.
- Week view. Later (the view architecture must not preclude it).

---

## 2. Why these technology choices

### Zig
Owner's choice. Also genuinely fits: tiny static-feeling binary, explicit
allocators (feature 5 is a *requirement*, not a vibe), first-class C interop
for the EventKit shim, `build.zig` can compile Objective-C.

### libvaxis for the TUI
[`rockorager/libvaxis`](https://github.com/rockorager/libvaxis) is the de-facto
standard Zig TUI library: runtime capability detection (no terminfo), true
color, kitty keyboard protocol, bracketed paste — all relevant since the owner
uses **Ghostty**.

- Use the **low-level API** (own event loop + cell-level drawing), *not* the
  higher-level `vxfw` widget framework. A calendar grid is custom drawing
  either way, and the low-level API keeps the render path allocation-free.
- **[VERIFY AT KICKOFF]** libvaxis `main` tracks Zig **0.16.x** as of mid-2026.
  Pin the libvaxis commit/release that matches the Zig toolchain you install,
  record both in `build.zig.zon` (`minimum_zig_version`) and `.zigversion`.

### Objective-C shim for EventKit (not pure-Zig objc_msgSend)
EventKit is an Objective-C framework. Calling it from Zig through raw
`objc_msgSend` is possible but brittle and unreadable. Instead:

- `native/eventkit_shim.m` — a small Objective-C file exposing a **plain C ABI**
  (functions + C structs, no ObjC types across the boundary).
- `native/eventkit_shim.h` — the single interop header. Zig imports only this.
- `build.zig` compiles the `.m` file and links `-framework EventKit
  -framework Foundation`.

This confines all unsafety to one reviewed file and keeps the Zig side 100%
idiomatic.

### `ical` CLI as the bootstrap data source
[`ical`](https://ical.sidv.dev/) (`brew tap BRO3886/tap && brew install ical`)
already reads EventKit and emits JSON. **Milestone 1 uses it as the data
source** so the TUI is usable end-to-end early; **Milestone 4 replaces it**
with the native shim behind the same interface. Both sources ship — the CLI
source remains as a fallback (`source = .ical_cli` in config).

---

## 3. Bootstrap (machine has no Zig)

The dev machine does **not** have Zig installed. First actions:

```bash
brew install zig                      # [VERIFY AT KICKOFF] brew's zig version
zig version                           # must satisfy libvaxis' minimum
```

If brew's Zig is **older** than libvaxis `main` requires, pin the newest
libvaxis **release** that supports brew's Zig rather than installing Zig from
a tarball — prefer boring installs. If brew's Zig is **newer** than libvaxis
supports, check libvaxis' issue tracker; use the matching release tag.

Then scaffold:

```bash
cd ~/GitHub/matthewmyrick/ical-calendar-tui
zig init                              # generates build.zig, build.zig.zon, src/
zig fetch --save git+https://github.com/rockorager/libvaxis  # pins hash in build.zig.zon
brew tap BRO3886/tap && brew install ical                    # M1 data source
echo "<the zig version>" > .zigversion
```

Record the chosen versions (zig, libvaxis commit, ical version) in the README's
"Toolchain" section in the first commit.

---

## 4. Architecture

Single process, three concerns, strict boundaries:

```
┌────────────────────────────────────────────────────────────┐
│ main thread — TUI                                          │
│   vaxis event loop: key events, resize, redraw             │
│   draws from a read-only *snapshot* of calendar data       │
├────────────────────────────────────────────────────────────┤
│ poller thread                                              │
│   every poll_interval: fetch events (source interface)     │
│   builds a NEW snapshot in a fresh arena                   │
│   swaps it in under a mutex; frees the old arena           │
│   posts a user event to vaxis → UI redraws                 │
├────────────────────────────────────────────────────────────┤
│ notifier (runs on the poller thread after each poll)       │
│   scans snapshot for events entering a lead-time window    │
│   dedup check → fire sink (herdr / terminal-notifier /     │
│   osascript)                                               │
└────────────────────────────────────────────────────────────┘
```

Rules:
- The **UI thread never fetches**. It only reads the current snapshot.
- The **snapshot is immutable** once published. All strings/slices in it are
  owned by its arena. Swap = pointer exchange under mutex; old arena freed
  after swap (`--daemon` mode reuses the same poller+notifier with no UI
  thread).
- Exactly **one mutex** in the program (snapshot swap). No other shared
  mutable state. If you feel the need for a second lock, redesign.
- The UI thread holds that mutex from the start of a draw through the end of
  `vx.render()` — vaxis keeps references to snapshot strings until the frame
  is written, so the poller must not free the old arena mid-frame. Draw +
  render is single-digit milliseconds; the poller blocking that long once a
  minute is the simple, correct trade.

---

## 5. Data layer: two calendar sources

Define one interface; implement it twice.

```zig
// src/calendar/source.zig
pub const CalendarSource = struct {
    // vtable-style interface (ptr + fn pointers), or a tagged union of the
    // two concrete sources — implementer's choice; tagged union is simpler
    // and there are exactly two variants. Fetch everything in [from, to].
    // All returned memory is allocated into `arena` (the snapshot's arena).
    pub fn fetch(self: *Self, arena: Allocator, from: i64, to: i64) FetchError![]Event
};
```

Fetch window: `now - 1 day` … `now + 45 days` (covers the month grid plus the
notification horizon, with slack for month navigation; navigating beyond the
window triggers an on-demand wider fetch).

### 5a. `IcalCliSource` (Milestone 1)

- Spawns: `ical list -f <from> -t <to> -o json` via `std.process.Child`.
- Parses stdout with `std.json` **directly into the snapshot arena**.
- Handles: `ical` not installed (clear error screen with install hint),
  non-zero exit, malformed JSON (keep previous snapshot, surface a status-bar
  warning — never crash the UI because a fetch failed).
- **[VERIFY AT KICKOFF]** Run `ical list -o json` once manually and write the
  actual field names into the JSON parsing code + a checked-in
  `testdata/ical-list-sample.json` fixture. Do not guess the schema.

### 5b. `EventKitSource` (Milestone 4)

C ABI exposed by `native/eventkit_shim.h` (sketch — final signatures may vary,
but keep the *shape*: caller-provided callbacks or a single
serialize-into-buffer call; no ObjC types leak):

```c
// All functions return 0 on success, negative error codes otherwise.
int ek_request_access(void);              // blocks; triggers the TCC prompt
int ek_fetch_events(double from_unix, double to_unix,
                    /* out */ char **json_utf8, size_t *len);
void ek_free(char *ptr);
```

Implementation notes for the shim:
- Use `EKEventStore` + `requestFullAccessToEventsWithCompletion:` (macOS 14+
  API; the older `requestAccessToEntityType:` is deprecated). Block on a
  semaphore for the completion — the shim is called from the poller thread,
  never the UI thread.
- Keep **one** `EKEventStore` instance for the process lifetime (creating one
  per fetch is slow and re-prompts in some macOS versions).
- Serialize events to JSON inside the shim (NSJSONSerialization) and hand Zig
  one buffer. This keeps the ABI to `char* + len` instead of a forest of C
  structs, and lets the Zig side reuse the *same* `std.json` → `Event` parser
  the CLI source uses. One parser, two sources.
- Attendee RSVP: map `EKParticipantStatus` to `accepted | declined |
  tentative | needs_action | unknown`. Organizer: `EKEvent.organizer`.
  Video link: pass through `EKEvent.URL` and `notes`; link *detection* happens
  in Zig (see §6), not in the shim.

### Source selection

`config.source = .auto | .eventkit | .ical_cli`. `.auto` (default): try
EventKit; if access denied or shim errors, fall back to `ical_cli` and show
which source is active in the status bar.

---

## 6. The event model

```zig
// src/calendar/event.zig
pub const Rsvp = enum { accepted, declined, tentative, needs_action, unknown };

pub const Attendee = struct {
    name: []const u8,        // may be empty
    email: []const u8,       // may be empty
    rsvp: Rsvp,
    is_organizer: bool,
    is_self: bool,           // "you" — used to show YOUR rsvp prominently
};

pub const Event = struct {
    id: []const u8,          // stable identifier (eventIdentifier / ical id)
    calendar_name: []const u8,
    calendar_color: u24,     // 0xRRGGBB; fall back to theme color if absent
    title: []const u8,
    start: i64,              // unix seconds, UTC
    end: i64,
    all_day: bool,
    location: []const u8,
    notes: []const u8,
    url: []const u8,
    video_link: []const u8,  // derived — see below
    attendees: []Attendee,
    is_recurring: bool,
    self_rsvp: Rsvp,         // YOUR rsvp, event-level — see note below
};
```

- `self_rsvp`: both sources report your own RSVP at event level (`ical`'s
  `self_status` string, EventKit's current-user participant). The CLI source
  cannot identify which attendee is "you", so `Attendee.is_self` stays false
  there and UI code showing "your RSVP" reads `self_rsvp` instead.

- **All strings are slices into the snapshot arena.** No individual frees.
- `video_link` derivation (in Zig, shared by both sources): scan `url`,
  `location`, and `notes` for the first match of
  `https://` + one of: `zoom.us/j/`, `meet.google.com/`,
  `teams.microsoft.com/l/meetup-join`, `whereby.com/`, `webex.com/meet`.
  Keep the matcher table-driven so adding providers is a one-line change.
- Sort order everywhere: all-day events first, then by `start`, then title.

---

## 7. TUI specification

Three stacked views + overlays. `Esc` always goes back/up; `q` quits from any
view (with no confirmation — this is a viewer).

### 7a. Month view (home)

```
┌─ July 2026 ──────────────────────────── source: eventkit ─┐
│  Mon   Tue   Wed   Thu   Fri   Sat   Sun                  │
│  29    30     1     2     3     4     5                    │
│         ●●          ●                                      │
│   6     7     8     9    10    11    12                    │
│  ●●●   ●    [13]   ●●                                      │
│  ...                                                       │
│                                                            │
│ Tue Jul 7 — 3 events                                       │
│  09:00 Team Standup · 12:30 Lunch w/ Sam · 16:00 1:1      │
├────────────────────────────────────────────────────────────┤
│ next: Team Standup in 32m   ·   refreshed 14s ago   ·  ?  │
└────────────────────────────────────────────────────────────┘
```

- Grid of the focused month; **today** highlighted; **selected day** in a
  distinct style (reverse video / accent border).
- Each day cell shows up to 3 event dots colored by `calendar_color`; more
  than 3 → `+N`.
- Below the grid: a 1–3 line **peek** of the selected day's events.
- Status bar (persistent across views): countdown to next event, seconds
  since last successful poll, active source, `?` hint. A failed poll shows
  `⚠ refresh failed (using cached)` here.

**Keys**

| Key | Action |
|---|---|
| `←` `→` (and `h` `l`) | previous / next day |
| `↑` `↓` (and `k` `j`) | same weekday previous / next week |
| `[` `]` (and `PgUp` `PgDn`) | previous / next month |
| `t` | jump to today |
| `Enter` | open Day view for the selected day |
| `r` | force refresh now |
| `?` | help overlay |
| `q` / `Ctrl-C` | quit |

### 7b. Day view

Chronological agenda for one day.

```
┌─ Tuesday, July 7 2026 ─────────────────────────────────────┐
│ all-day  ◦ Q3 Planning Week                    [Work]      │
│ 09:00–09:30  Team Standup                      [Work] ✓    │
│ 12:30–13:30  Lunch w/ Sam                      [Personal]  │
│ 16:00–16:30  1:1 with Dana                     [Work] ?    │
└────────────────────────────────────────────────────────────┘
```

- `✓ / ✗ / ? / ·` glyph = **your** RSVP (accepted/declined/tentative/none).
- `←` `→` move to the previous/next **day** without leaving Day view.
- `↑`/`↓` (or `j`/`k`) select an event; `Enter` → Event detail; `Esc` → Month.

### 7c. Event detail

Everything we know about one event; scrollable if long.

```
┌─ Team Standup ─────────────────────────────────────────────┐
│ Tue Jul 7 · 09:00 – 09:30 (30m)          [Work] recurring  │
│ location   Zoom                                            │
│ video      https://zoom.us/j/9144...        (o to open)    │
│ organizer  Dana K <dana@corp.com>                          │
│                                                            │
│ attendees (5)                                              │
│   ✓ you                                                    │
│   ✓ Dana K            dana@corp.com                        │
│   ? Sam T             sam@corp.com                         │
│   ✗ Lee W             lee@corp.com                         │
│                                                            │
│ notes                                                      │
│   Daily sync. Bring blockers.                              │
└────────────────────────────────────────────────────────────┘
```

**Keys:** `o` open `video_link` (else `url`) via `open <url>`; `c` copy the
link to clipboard (`pbcopy`); `↑`/`↓` scroll; `Esc` back.

### 7d. Help overlay

`?` from anywhere: centered floating box listing every key. Same pattern as
the owner's nvim cheat-sheet — data-driven rows, aligned columns.

### 7e. Theme

Catppuccin **Mocha**, hard-coded palette in `src/ui/theme.zig` (the owner's
entire setup is catppuccin). Respect terminal background transparency: default
background = terminal default (no painted bg), like the owner's btop/k9s
configs. Colors are the published catppuccin-mocha hex values — put them in
one table; no hex literals sprinkled through draw code.

---

## 8. Polling

- Dedicated thread started at launch; loop:
  `fetch → build snapshot → swap → notify-scan → sleep(poll_interval)`.
- `poll_interval_seconds` from config, **default 60**, clamp to `[15, 3600]`.
- Manual `r` posts a wake to the poller (condition variable / event), it does
  **not** fetch on the UI thread.
- Failure policy: keep the last good snapshot, set `status.last_error`,
  retry at the normal interval (no exponential backoff needed at 60 s), and
  after **5 consecutive failures** show a prominent banner instead of the
  quiet status-bar warning.
- The poller must tolerate wall-clock jumps (sleep/wake): compute
  notification windows from *absolute* event times each cycle, never from
  "time since last tick".

---

## 9. Notifications

### When
For each event in the snapshot (skip: all-day unless configured, declined-by-you
events, events already started): fire once per `(event id, occurrence start,
lead)` when `now >= start - lead` and `now < start`.

- `lead_times_minutes` config, **default `[10, 1]`**.
- All-day events: config `all_day_notify_at` (`"09:00"` local) or `null`
  (default **null** = no all-day notifications).

### Dedup (critical — poller fires every minute)
- Persistent dedup log: `~/.cache/ical-calendar-tui/notified.log`, one line per
  fired notification: `<unix-ts> <lead> <occurrence-start> <event-id>`.
- Loaded into a `StringHashMap` at startup; appended (and `flock`ed) on fire.
  The flock also coordinates TUI + daemon running simultaneously — whoever
  fires first wins; the other sees the entry on next check. Both processes
  re-read the file's new entries each cycle (cheap: it's append-only, track
  offset).
- Prune lines older than 7 days at startup.

### Sinks (auto-detected, priority order; config can force one)

1. **herdr** — if `HERDR_SOCKET_PATH` is set or `herdr` is on PATH and
   responds: `herdr notification show --title <t> --body <b>`.
   **[VERIFY AT KICKOFF]** confirm the exact `herdr notification` subcommand
   syntax via `herdr notification --help`; the owner runs herdr ≥ 0.7.
2. **terminal-notifier** — if installed (`brew install terminal-notifier`):
   `terminal-notifier -title <t> -message <b> -open <video_link>` (click →
   joins the meeting).
3. **osascript** — always available:
   `osascript -e 'display notification "body" with title "title" sound name "Glass"'`.
   (No click-through URL support — that's why it's last.)

Notification content: title = event title; body =
`"in 10m · 09:00–09:30 · Zoom"` (lead, time range, location or video
provider name). Keep it one line; this may render as a herdr toast.

### Important honesty note for the implementer
Do **not** attempt Apple's `UserNotifications` framework from the shim: it
requires a signed app bundle with a bundle identifier and will not work from a
bare CLI binary. The three sinks above are the correct approach. Also note the
owner keeps macOS Calendar's own alerts on — our notifications are *additive*
(custom leads, herdr toasts), so defaults must not be spammy.

---

## 10. Daemon mode

`ical-calendar-tui --daemon`:
- No TUI, no vaxis. Runs poller + notifier only. Logs one line per cycle to
  stderr at debug level, silent otherwise.
- Ship `launchd/dev.matthewmyrick.ical-calendar-tui.plist` (Program +
  `--daemon`, `RunAtLoad`, `KeepAlive`) and a `zig build install-daemon` step
  (or a small `scripts/install-daemon.sh`) that copies it to
  `~/Library/LaunchAgents` and runs `launchctl bootstrap gui/$UID <plist>`.
- Daemon + TUI concurrently is safe (shared flocked dedup log, §9).
- `--agenda` bonus mode (see §16 stretch): print today's events as plain text
  and exit — for scripts, herdr launchers, and the owner's shell greeting.

---

## 11. Configuration

Path: `~/.config/ical-calendar-tui/config.zon` (ZON = Zig Object Notation,
parsed with `std.zon` — in-std, zero deps). **[VERIFY AT KICKOFF]** `std.zon`
parse API is present in the pinned Zig (it landed in 0.14); if it's been
reorganized, prefer whatever the std-native structured config parse is —
fall back to JSON config only if ZON parsing is genuinely unavailable.

Defaults (all keys optional; missing file = all defaults; unknown keys =
**hard error** with the offending key named — silent typos are how configs rot):

```zon
.{
    .poll_interval_seconds = 60,
    .source = .auto,                    // .auto | .eventkit | .ical_cli
    .lead_times_minutes = .{ 10, 1 },
    .all_day_notify_at = null,          // e.g. "09:00"
    .notify_sink = .auto,               // .auto | .herdr | .terminal_notifier | .osascript | .none
    .week_start = .monday,              // .monday | .sunday
    .calendars_exclude = .{},           // e.g. .{ "Birthdays", "Siri Suggestions" }
    .show_declined = false,
}
```

`calendars_exclude` filters at snapshot-build time (source still fetches all —
keeps both sources simple).

---

## 12. Memory-efficiency requirements

These are **requirements with numbers**, not aspirations. See
`CODING_STANDARDS.md` §Memory for the binding rules; summary:

1. **Snapshot arena lifetime.** Each poll builds into a fresh
   `std.heap.ArenaAllocator`; publish = swap pointer; old arena `deinit()`d
   whole. There is no per-event free anywhere in the program.
2. **Zero heap allocation in the draw path.** Drawing uses a per-frame
   scratch `FixedBufferAllocator` (a few KB, reset each frame) for formatted
   strings (`std.fmt.bufPrint` style). If a draw needs more, the buffer size
   is wrong — fix the constant, don't reach for the GPA.
3. **Debug builds run under `std.heap.GeneralPurposeAllocator(.{})`** with
   leak detection; `zig build test` and a manual quit path must report zero
   leaks. Release builds may use `std.heap.smp_allocator` /
   `page_allocator`-backed arenas as appropriate.
4. **Budget:** app-controlled memory (snapshots, UI buffers, dedup log) stays
   bounded and flat; measure RSS with `ps -o rss= -p <pid>` and record the
   number in the README per release. *Measured reality (M4):* macOS charges
   the process ~11 MB baseline (dyld/libc/threads + vaxis) and in-process
   EventKit+AppKit adds ~10 MB of framework-resident pages, so idle RSS is
   ~21 MB with the native source (~11 MB with `ical_cli`). The original
   "< 10 MB RSS" figure predated that discovery and is not reachable while
   linking EventKit; the enforceable budget is the *flatness* requirement
   in item 5, which catches every leak the RSS number would have.
5. Event window is bounded (§5); navigation beyond it triggers refetch, not
   accumulation. The app's memory does not grow with uptime — verify by
   leaving it running 24 h (RSS delta < 1 MB).

---

## 13. macOS permissions (TCC) — the Info.plist trick

EventKit access from a **bare binary** (no .app bundle) requires the usage
strings to be discoverable, or macOS denies without prompting. The trick:
embed an Info.plist into the executable via a linker section.

- `native/Info.plist` containing at minimum:
  `CFBundleIdentifier` (`dev.matthewmyrick.ical-calendar-tui`),
  `NSCalendarsFullAccessUsageDescription` (one honest sentence).
- In `build.zig`: pass linker args
  `-sectcreate __TEXT __info_plist native/Info.plist` for the exe.
- First run of the EventKit source then produces the normal system prompt;
  the grant appears in System Settings → Privacy & Security → Calendars.
- Document in the README: re-granting may be needed after the binary changes
  (TCC ties grants to the binary's identity); `tccutil reset Calendar
  dev.matthewmyrick.ical-calendar-tui` resets state for testing.
- The `IcalCliSource` path needs **no** permissions of its own (the `ical`
  binary holds them) — one more reason it's the M1 bootstrap.

---

## 14. Repository layout

```
ical-calendar-tui/
├── README.md                  # user-facing: install, keys, config, toolchain
├── SPEC.md                    # this file
├── CODING_STANDARDS.md
├── CONTRIBUTING.md
├── .zigversion                # pinned toolchain, e.g. "0.16.0"
├── build.zig
├── build.zig.zon              # deps pinned by hash; minimum_zig_version
├── native/
│   ├── eventkit_shim.h        # the ONLY interop surface
│   ├── eventkit_shim.m
│   └── Info.plist
├── launchd/
│   └── dev.matthewmyrick.ical-calendar-tui.plist
├── scripts/
│   └── install-daemon.sh
├── src/
│   ├── main.zig               # arg parsing (--daemon/--agenda), wiring, shutdown
│   ├── app.zig                # App state machine: view stack, key dispatch
│   ├── config.zig             # load/validate config.zon
│   ├── poller.zig             # thread, snapshot swap, wake handling
│   ├── snapshot.zig           # Snapshot struct + arena ownership
│   ├── calendar/
│   │   ├── event.zig          # Event/Attendee/Rsvp + video-link detection
│   │   ├── source.zig         # source interface (tagged union)
│   │   ├── ical_cli.zig       # M1 source (subprocess + std.json)
│   │   └── eventkit.zig       # M4 source (wraps the C shim)
│   ├── notify/
│   │   ├── notifier.zig       # window scan + dedup log
│   │   └── sink.zig           # herdr / terminal-notifier / osascript
│   └── ui/
│       ├── theme.zig          # catppuccin mocha table
│       ├── month.zig
│       ├── day.zig
│       ├── detail.zig
│       ├── help.zig
│       └── statusbar.zig
└── testdata/
    └── ical-list-sample.json  # real captured `ical -o json` output
```

---

## 15. Milestones with acceptance criteria

Each milestone = one or more focused commits, ends with `zig build test` green,
`zig fmt --check .` clean, and the acceptance checks below done manually.

### M0 — Scaffold
- brew install zig; `zig init`; libvaxis dep pinned; `.zigversion`;
  hello-vaxis window that draws "ical-calendar-tui" and quits on `q`.
- ✅ `zig build run` shows the window in Ghostty; `q` exits cleanly
  (terminal state restored — no mouse/altscreen residue).

### M1 — Month view on `ical` CLI data
- `IcalCliSource`, event model, snapshot (single fetch at startup, no poller
  yet), month grid + day navigation + day-peek + status bar.
- ✅ arrows move the selection; `[`/`]` change month (triggers refetch when
  outside window); events on the grid match Calendar.app for the same days.

### M2 — Day view + Event detail
- `Enter` drill-down, full metadata rendering, `o`/`c` link actions, help
  overlay, `t` today.
- ✅ an event with attendees shows organizer + per-attendee RSVP glyphs
  matching Calendar.app; `o` opens the Zoom/Meet link in the browser.

### M3 — Poller + notifications + config
- Poller thread + snapshot swap + `r`; config.zon loading; notifier with
  dedup log; all three sinks; countdown in status bar.
- ✅ create a test event 11 minutes out → notification at ~10 m and ~1 m,
  exactly once each, across an app restart in between (dedup file works);
  works inside a herdr pane (toast) and outside (Notification Center).

### M4 — Native EventKit source
- Shim (.m/.h), build.zig compiles/links it, Info.plist embedding, `.auto`
  source selection + fallback, permission-denied UX.
- ✅ first run prompts for Calendar access; after grant, output matches the
  CLI source (diff the two sources' snapshots in a test); RSS < 10 MB idle.

### M5 — Daemon + polish
- `--daemon`, launchd plist + install script, `--agenda` one-shot, 24 h
  soak (RSS stable), README user docs complete.
- ✅ `launchctl` runs the daemon at login; killing the TUI doesn't stop
  notifications; `--agenda` prints today's events and exits 0.

---

## 16. Out of scope for v1 / stretch ideas (owner-approved directions)

- **Week view** (`w`) — grid of 7 columns with time slots.
- **Event creation** — `a` in Day view shells out to `ical add -i` in a
  suspended-TUI subshell, then force-refreshes.
- **Reminders** (EventKit EKReminder) as a separate tab.
- **herdr prefix launcher** — a `[[keys.command]]` entry in the owner's
  dotfiles (`herdr/config.toml`) popping `--agenda` or the full TUI in a pane.
  Lives in the dotfiles repo, not here — coordinate, don't duplicate.
- **Shell greeting** — `--agenda --short` for the owner's zshrc banner.

---

*Spec written 2026-07-06. Ecosystem facts current as of that date; every
[VERIFY AT KICKOFF] item must be re-checked before the first line of code.*
