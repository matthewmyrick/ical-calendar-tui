# ical-calendar-tui

A macOS calendar TUI in **Zig** — reads the local Mac calendar (everything
Calendar.app sees: iCloud, Google, Exchange), navigable month/day/event views,
background polling, and meeting notifications (Notification Center or herdr
toasts). Catppuccin, keyboard-driven, memory-frugal.

> **Status: v1 feature-complete** (milestones M0–M5 landed; see SPEC §15).

## Documents

| Doc | What |
|---|---|
| [`SPEC.md`](SPEC.md) | Complete build specification — architecture, TUI design, data sources, notifications, milestones. **Start here.** |
| [`CODING_STANDARDS.md`](CODING_STANDARDS.md) | Binding Zig standards: memory/allocator rules, errors, interop, testing. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Setup, commands, workflow, pre-commit checklist. |

## Usage

```bash
ical-calendar-tui              # the TUI: arrows move days, Enter drills in
ical-calendar-tui --daemon     # headless poll + notify (launchd)
ical-calendar-tui --agenda     # print today's events and exit
```

Install the notification daemon (runs at login, survives the TUI closing):

```bash
scripts/install-daemon.sh      # builds ReleaseSafe, installs launchd agent
```

Logs land in `~/Library/Logs/ical-calendar-tui.log`; set `ICAL_TUI_DEBUG=1`
for per-cycle lines.

## Configuration

`~/.config/ical-calendar-tui/config.zon` (all keys optional; unknown keys
are an error):

```zon
.{
    .poll_interval_seconds = 60,        // clamped to [15, 3600]
    .source = .auto,                    // .auto | .eventkit | .ical_cli
    .lead_times_minutes = .{ 10, 1 },
    .all_day_notify_at = null,          // e.g. "09:00"
    .notify_sink = .auto,               // .auto | .herdr | .terminal_notifier | .osascript | .none
    .week_start = .monday,              // .monday | .sunday
    .calendars_exclude = .{},           // e.g. .{ "Birthdays", "Siri Suggestions" }
    .show_declined = false,
}
```

## Keys

| Key | Where | Action |
|---|---|---|
| `← →` / `h l` | month, day | previous / next day |
| `↑ ↓` / `k j` | month | same weekday ± a week |
| `↑ ↓` / `k j` | day | select event · detail: scroll |
| `[ ]` / `PgUp PgDn` | month | previous / next month |
| `Enter` | month → day → detail | drill down |
| `q` / `Esc` | anywhere | back / close |
| `/` | anywhere | fuzzy-search events (type, `↑↓`, `Enter`) |
| `t` | anywhere | jump to today |
| `r` | anywhere | refresh now |
| `o` / `c` | detail | open / copy video link or url |
| `?` | anywhere | help overlay |
| `Q` / `Ctrl-C` | anywhere | quit |

## Toolchain

Pinned at milestone 0 (see SPEC §3):

| Tool | Version | Source |
|---|---|---|
| Zig | 0.16.0 (`.zigversion`) | `brew install zig` |
| [libvaxis](https://github.com/rockorager/libvaxis) | 0.6.0 @ `ca781b3c` (pinned by hash in `build.zig.zon`) | `zig fetch` |
| [`ical`](https://ical.sidv.dev/) | 0.12.1 | `brew tap BRO3886/tap && brew install ical` |

Native EventKit shim landed at milestone 4 (`source: eventkit`, with
`ical_cli` fallback).

## Memory

Measured idle RSS, ReleaseSafe, 45-day window (recorded per release —
SPEC §12): **~21 MB** with the native EventKit source (≈10 MB of that is
EventKit/AppKit framework-resident pages), **~11 MB** with the `ical_cli`
source. App-controlled memory is arena-bounded and flat over uptime.

macOS permission note: TCC ties the calendar grant to the binary's identity;
after rebuilding you may need to re-grant. Reset for testing with
`tccutil reset Calendar dev.matthewmyrick.ical-calendar-tui`.
