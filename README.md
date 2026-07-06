# ical-calendar-tui

A macOS calendar TUI in **Zig** — reads the local Mac calendar (everything
Calendar.app sees: iCloud, Google, Exchange), navigable month/day/event views,
background polling, and meeting notifications (Notification Center or herdr
toasts). Catppuccin, keyboard-driven, memory-frugal.

> **Status: v1 feature-complete** (milestones M0–M5 landed; see ARCHITECTURE.md §15).

## Documents

| Doc | What |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Design: threading, data sources, memory rules, notifications, TCC. **Start here before changing code.** |
| [`CODING_STANDARDS.md`](CODING_STANDARDS.md) | Binding Zig standards: memory/allocator rules, errors, interop, testing. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Setup, commands, workflow, pre-commit checklist. |

## Install

Grab the `-macos-arm64.tar.gz` from the
[latest release](https://github.com/matthewmyrick/ical-calendar-tui/releases/latest)
(Apple Silicon), or with `gh`:

```bash
gh release download --repo matthewmyrick/ical-calendar-tui --pattern '*.tar.gz'
tar -xzf ical-calendar-tui-*-macos-arm64.tar.gz
./ical-calendar-tui/ical-calendar-tui            # or move it onto your PATH
```

Or build from source (toolchain below): `zig build -Doptimize=ReleaseSafe`.

First run prompts for calendar access (System Settings → Privacy & Security →
Calendars). A downloaded binary carries the quarantine flag; if Gatekeeper
objects: `xattr -d com.apple.quarantine ical-calendar-tui`.

## Usage

```bash
ical-calendar-tui              # the TUI: arrows move days, Enter drills in
ical-calendar-tui --daemon     # headless poll + notify (launchd)
ical-calendar-tui --agenda     # print today's events and exit
ical-calendar-tui --version    # print version and exit
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
| `a` | anywhere | new event (form: title, when, until, all-day, calendar, location, invites — blank = skip) |
| `y` `n` `m` | day, detail | RSVP: accept / decline / tentative |
| `e` | day, detail | edit selected event (same form, prefilled) |
| `t` | anywhere | jump to today |
| `r` | anywhere | refresh now |
| `o` / `c` | detail | open / copy video link or url |
| `?` | anywhere | help overlay |
| `Q` / `Ctrl-C` | anywhere | quit |

## Toolchain

Pinned at milestone 0 (see ARCHITECTURE.md §3):

| Tool | Version | Source |
|---|---|---|
| Zig | 0.16.0 (`.zigversion`) | `brew install zig` |
| [libvaxis](https://github.com/rockorager/libvaxis) | 0.6.0 @ `ca781b3c` (pinned by hash in `build.zig.zon`) | `zig fetch` |
| [`ical`](https://ical.sidv.dev/) | 0.12.1 | `brew tap BRO3886/tap && brew install ical` |

Native EventKit shim landed at milestone 4 (`source: eventkit`, with
`ical_cli` fallback).

## Memory

Measured idle RSS, ReleaseSafe, 45-day window (recorded per release —
ARCHITECTURE.md §12): **~21 MB** with the native EventKit source (≈10 MB of that is
EventKit/AppKit framework-resident pages), **~11 MB** with the `ical_cli`
source. App-controlled memory is arena-bounded and flat over uptime.

macOS permission note: TCC ties the calendar grant to the binary's identity;
after rebuilding you may need to re-grant. Reset for testing with
`tccutil reset Calendar dev.matthewmyrick.ical-calendar-tui`.

## Contributing

PRs welcome — start with [`CONTRIBUTING.md`](CONTRIBUTING.md) (workflow,
gates) and [`ARCHITECTURE.md`](ARCHITECTURE.md) (the invariants your change
must keep). For anything sizeable, open an issue first. Maintained by
[@matthewmyrick](https://github.com/matthewmyrick).

## License

[MIT](LICENSE)
