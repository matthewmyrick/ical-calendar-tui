# ical-calendar-tui

A macOS calendar TUI in **Zig** — reads the local Mac calendar (everything
Calendar.app sees: iCloud, Google, Exchange), navigable month/day/event views,
background polling, and meeting notifications (Notification Center or herdr
toasts). Catppuccin, keyboard-driven, memory-frugal.

> **Status: pre-implementation.** The full build spec is written; code lands
> milestone by milestone.

## Documents

| Doc | What |
|---|---|
| [`SPEC.md`](SPEC.md) | Complete build specification — architecture, TUI design, data sources, notifications, milestones. **Start here.** |
| [`CODING_STANDARDS.md`](CODING_STANDARDS.md) | Binding Zig standards: memory/allocator rules, errors, interop, testing. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Setup, commands, workflow, pre-commit checklist. |

## Planned usage

```bash
ical-calendar-tui              # the TUI: arrows move days, Enter drills in
ical-calendar-tui --daemon     # headless poll + notify (launchd)
ical-calendar-tui --agenda     # print today's events and exit
```

## Toolchain

Pinned at milestone 0 (see SPEC §3):

| Tool | Version | Source |
|---|---|---|
| Zig | 0.16.0 (`.zigversion`) | `brew install zig` |
| [libvaxis](https://github.com/rockorager/libvaxis) | 0.6.0 @ `ca781b3c` (pinned by hash in `build.zig.zon`) | `zig fetch` |
| [`ical`](https://ical.sidv.dev/) | 0.12.1 | `brew tap BRO3886/tap && brew install ical` |

Native EventKit shim lands at milestone 4.
