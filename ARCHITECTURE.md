# Architecture

How ical-calendar-tui works and why it's built this way. Code comments cite
sections here as `ARCHITECTURE.md §N`. The coding rules that enforce these
invariants live in [`CODING_STANDARDS.md`](CODING_STANDARDS.md); both are
binding for contributions (see [`CONTRIBUTING.md`](CONTRIBUTING.md)).

Sections are numbered for stable cross-references from code; the numbering
is historical (it descends from the original build spec) and intentionally
non-contiguous.

## §1 What this is

A macOS calendar TUI in Zig: reads the local EventKit store (everything
Calendar.app sees — iCloud, Google, Exchange), renders month/day/event views
with libvaxis, polls in the background, and fires meeting notifications.
Reads are native; **writes go through the [`ical`](https://ical.sidv.dev/)
CLI** (RSVP, create, edit) so a bug here can never corrupt a calendar store.

## §2 Technology choices

- **Zig** — tiny binary, explicit allocators (memory rules are requirements,
  not vibes), first-class C interop for the EventKit shim.
- **libvaxis, low-level API** — the de-facto Zig TUI library; we use our own
  event loop and cell-level drawing, not the vxfw widget framework, keeping
  the render path allocation-free.
- **ObjC shim, not raw objc_msgSend** — all EventKit access lives in one
  reviewed file behind a plain C ABI (§5b).
- **`ical` CLI for writes and as a fallback read source** — one
  battle-tested tool owns every mutation.

## §3 Toolchain

Pinned in `.zigversion` + `build.zig.zon` (`minimum_zig_version`); the
README's Toolchain table records exact versions. Never develop on a
different Zig — minor versions break code. Upgrades are their own commit.

## §4 Process architecture

Single process, two threads, strict boundaries:

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

Rules (the complete concurrency design — additions require updating this
section first):

- The **UI thread never fetches**. It reads the current snapshot; manual
  refresh (`r`) wakes the poller.
- The **snapshot is immutable** once published. All strings/slices in it are
  owned by its arena. Swap = pointer exchange under the mutex; the retired
  arena is freed wholesale (`--daemon` reuses poller+notifier with no UI
  thread).
- Exactly **one mutex** (the snapshot pointer) and **one wake event**
  (`std.Io.Event.waitTimeout` — 0.16's `std.Io` has no condvar `timedWait`).
  If you feel the need for a second lock, redesign.
- The UI thread holds the mutex from the start of a draw through the end of
  `vx.render()` — vaxis keeps *references* to printed text until the frame
  is written, so the poller must not free the old arena mid-frame. Draw +
  render is single-digit milliseconds; the poller blocking that long once a
  minute is the simple, correct trade.
- Calendar writes (`a` create, `e` edit, `y`/`n`/`m` RSVP) run
  non-interactive `ical` subprocesses on the UI thread — a brief frozen
  frame with a flash result beats concurrency machinery for a keypress.
  The event form (`src/ui/eventform.zig`) is the single write UI; there is
  deliberately no drop-out to `ical`'s own interactive prompts.

## §5 Data sources

One interface, two implementations, selected by config
(`.auto | .eventkit | .ical_cli`) — `.auto` tries EventKit and falls back to
the CLI on permission denial:

```zig
// src/calendar/source.zig — tagged union, not a vtable: two variants.
pub fn fetch(self: *CalendarSource, arena: Allocator, from: i64, to: i64) FetchError![]Event
```

All returned memory is allocated into the snapshot's arena. The fetch window
is bounded (roughly −8 days … +62 days around the viewed month); navigating
beyond it triggers an on-demand refetch, never accumulation.

**Both sources produce the same JSON schema** (the `ical -o json` field
names), so one `std.json` → `Event` parser serves both. Fixtures in
`testdata/` are synthetic — never commit real calendar data.

### §5a IcalCliSource

Spawns `ical list -f <from> -t <to> -o json` plus `ical calendars -o json`
(joined by `calendar_id` for colors). Failures degrade: keep the previous
snapshot, surface a status-bar warning. Needs no calendar permission of its
own (the `ical` binary holds it).

### §5b EventKitSource (the ObjC shim)

`native/eventkit_shim.h` is the **only** interop surface (three functions:
request access, fetch-to-JSON-buffer, free). The ABI carries only int error
codes, double unix timestamps, and `char* + len` UTF-8 buffers. One
process-lifetime `EKEventStore` (per-fetch stores are slow and re-prompt).
Serialization to JSON happens inside the shim (NSJSONSerialization) so Zig
reuses the shared parser. ARC (`-fobjc-arc`); returned buffers are malloc'd
copies freed by `ek_free`. Blocking calls only, from the poller thread.

## §6 The event model

`src/calendar/event.zig`. All strings are slices into the snapshot arena —
nothing is freed individually. Notable fields:

- `self_rsvp` — YOUR response, event-level (`ical`'s `self_status`,
  EventKit's current-user participant). The CLI source can't identify which
  attendee is "you", so `Attendee.is_self` stays false there.
- `video_link` — derived in Zig (shared by both sources) from a table-driven
  provider list (Zoom/Meet/Teams/Whereby/Webex); adding a provider is one
  table row + one test case.
- Notes arrive as HTML from Google/Exchange; `htmlToText` flattens them at
  parse time (tags stripped, `<br>` → newline, entities decoded) before
  link detection runs.
- Sort order everywhere: all-day first, then start, then title.

## §7 The TUI

Three stacked views + overlays. `q`/`Esc` go back; `Q`/`Ctrl-C` quits; `/`
fuzzy-search; `a` quick-add; `?` help. The full key table lives in the
README and the help overlay (`src/ui/help.zig`) — update both together.

- **§7a Month view** — responsive grid (cells scale with the terminal, wide
  cells show event titles, narrow cells show dots), shared borders between
  cells, today boxed in the accent color, selected-day peek, persistent
  status bar (countdown, refresh age, active source, flash messages).
- **§7b Day view** — chronological agenda; RSVP glyph = your status;
  `←`/`→` change day without leaving the view.
- **§7c Event detail** — full metadata, scrollable; `o` open / `c` copy the
  video link; `e` edit.
- **§7d Help overlay** — data-driven rows so bindings and docs review
  side by side.
- **§7e Theme** — Catppuccin Mocha, one table in `src/ui/theme.zig`, no hex
  literals in draw code. Background stays terminal-default (transparency).

Drawing never heap-allocates: formatted strings go into an App-owned
per-frame `FixedBufferAllocator` reset at the *start* of each frame — vaxis
references printed text until render, so stack-local fmt buffers render as
garbage.

## §8 Polling

Poller loop: fetch → build snapshot → swap → notify-scan →
`waitTimeout(poll_interval)`. Default 60 s, clamped to [15, 3600]. Manual
refresh sets the wake event; the UI never fetches. Failure policy: keep the
last good snapshot, count consecutive failures, escalate from a quiet
status-bar warning to a banner at 5. The sleep uses the `.real` clock so a
laptop wake fires an immediate catch-up poll; notification windows are
computed from *absolute* event times each cycle, never tick counting.

## §9 Notifications

For each event (skip: all-day unless `all_day_notify_at` is set,
declined-by-you, already started): fire once per
`(event id, occurrence start, lead)` when `now ∈ [start − lead, start)`.
Default leads: 10 and 1 minutes.

**Dedup is persistent and multi-process.** An append-only, flock-coordinated
log at `~/.cache/ical-calendar-tui/notified.log` lets the TUI and daemon run
simultaneously — whoever fires first wins; both re-read the log tail each
cycle. Pruned to 7 days at startup. Bounded in memory.

**Sinks**, auto-detected in priority order (config can force one):
1. **herdr** — `herdr notification show <title> --body <body>` (toasts).
2. **terminal-notifier** — supports click-to-join via `-open`.
3. **osascript** — always present; no click-through.
A failing sink falls through to the next. Titles carry a `📅 ` prefix so our
toasts are distinguishable from macOS Calendar's own alerts (which users
typically keep on — ours are additive, so defaults must not be spammy).

Do **not** attempt Apple's UserNotifications framework: it requires a signed
app bundle and will not work from a bare CLI binary.

## §10 Daemon mode and one-shots

`--daemon` runs poller + notifier only (no vaxis); launchd assets and
`scripts/install-daemon.sh` install it as a login agent. Logs one line per
cycle at debug level (visible with `ICAL_TUI_DEBUG=1`), silent otherwise.
Daemon + TUI concurrently is safe (§9 dedup log). `--agenda` prints today's
events and exits — for scripts and shell greetings.

## §11 Configuration

`~/.config/ical-calendar-tui/config.zon` (ZON via `std.zon`; missing file =
all defaults; **unknown keys are a hard error naming the key** — silent
typos are how configs rot). Keys and defaults are documented in the README.
`calendars_exclude`/`show_declined` filter at snapshot-build time — sources
always fetch everything, keeping both simple.

## §12 Memory

1. **Snapshot arena lifetime**: each poll builds into a fresh
   `ArenaAllocator`; publish = pointer swap; the old arena deinits whole.
   There is no per-event free anywhere in the program.
2. **Zero heap allocation in the draw path** (per-frame fixed buffer, §7).
3. Debug builds run under `GeneralPurposeAllocator` with leak detection;
   a leaking test is a failing test.
4. **Budget**: app-controlled memory stays bounded and flat. Measured
   (ReleaseSafe, 45-day window): ~21 MB RSS idle with the EventKit source —
   ~10 MB of that is EventKit/AppKit framework-resident pages, inherent to
   linking them in-process — and ~11 MB with `ical_cli`. Record the number
   in the README per release. The enforceable requirement is *flatness*:
   memory must not grow with uptime.
5. Every unbounded input (buffers, windows, attendee lists, dedup log) has
   an explicit cap with a named constant.

## §13 macOS permissions (TCC)

EventKit access from a bare binary needs the usage string discoverable, or
macOS denies without prompting. `native/Info.plist`
(`CFBundleIdentifier` = `dev.matthewmyrick.ical-calendar-tui`,
`NSCalendarsFullAccessUsageDescription`) embeds into the executable via an
exported `linksection("__TEXT,__info_plist")` constant in `main.zig` —
byte-identical to the classic `-sectcreate` trick, which Zig 0.16's linker
driver can't pass through. TCC ties grants to binary identity: rebuilding
may re-prompt; reset for testing with
`tccutil reset Calendar dev.matthewmyrick.ical-calendar-tui`.
The `.auto` source requests access *before* the TUI takes the terminal so
the system prompt isn't hidden behind the alt screen.

## §15 History

Built milestone by milestone (tags `v0.0`–`v0.5`): scaffold → month view on
CLI data → day/detail/help → poller+notifications+config → native EventKit
source → daemon+agenda. Releases have been continuous since (see
CONTRIBUTING §6).

## §16 Roadmap-ish

Owner-approved directions, PRs welcome (open an issue first for anything
architectural): week view, reminders (EKReminder) as a tab, x86_64 release
builds (blocked on Apple SDK header quirks cross-compiling the shim — see
the sysroot note in `build.zig`), a Homebrew tap, richer quick-add.
