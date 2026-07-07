# Contributing — docket

Contributions welcome! Maintainer: [@matthewmyrick](https://github.com/matthewmyrick).
This file is the operating manual: how to set up, build, verify, and get a
change merged. The design lives in [`ARCHITECTURE.md`](ARCHITECTURE.md); the
code rules live in [`CODING_STANDARDS.md`](CODING_STANDARDS.md) — both are
binding, read them before writing code. Licensed MIT; by contributing you
agree your work is too.

**Before starting anything sizeable, open an issue.** Especially anything
touching threading (§4), memory ownership (§12), or the ObjC shim (§5b) —
those have one-mutex/one-arena invariants that PRs must not erode, and it's
better to align before you've written the code.

---

## 1. Setup

```bash
# toolchain — the version in .zigversion is the only supported one
brew install zig
zig version                      # must match .zigversion / build.zig.zon

# milestone-1 data source + optional notification sink
brew tap BRO3886/tap && brew install ical
brew install terminal-notifier   # optional; osascript is the fallback

git clone https://github.com/matthewmyrick/docket.git
cd docket
zig build test                   # green before you touch anything
```

macOS Calendar permission: the native source (M4+) prompts on first run. To
reset while testing: `tccutil reset Calendar dev.matthewmyrick.docket`.

## 2. Commands

| Command | What |
|---|---|
| `zig build` | compile (debug) |
| `zig build run` | run the TUI |
| `zig build run -- --daemon` | headless poll + notify |
| `zig build run -- --agenda` | print today's events, exit |
| `zig build test` | unit tests (must always pass; leak-checked) |
| `zig build itest` | integration smoke tests (needs calendar access) |
| `zig fmt --check .` | formatting gate (CI-equivalent) |
| `zig build -Doptimize=ReleaseSafe` | release build (`ReleaseSafe`, not `ReleaseFast` — keep safety checks) |

## 3. Workflow

- **Everyone — including the maintainer — merges through PRs.** `main` is
  protected with admin enforcement: no direct pushes, CI (fmt + tests +
  release build) must pass. Contributors fork → branch → PR; the maintainer
  reviews everything (CODEOWNERS) and, having write access, may merge their
  own PRs once CI is green (zero-approval rule — GitHub forbids
  self-approval, and requiring one would deadlock a solo maintainer).
- **One logical change per PR**, and small, focused commits within it. A
  view, a bugfix, a provider row — each its own change. Never bundle an
  unrelated tweak into a feature PR; split it.
- **Commit messages are non-negotiable quality.** Imperative subject
  ≤ ~50 chars saying what changed *and* the point of it; a body whenever the
  change isn't self-explanatory (the *why*, the tradeoff, the verification).
  Banned subjects: `update`, `fix stuff`, `wip`, `changes`.

  ```
  poller: swap snapshots under mutex instead of copying

  Copying the event list on every poll doubled peak memory during the
  swap window. Build into a fresh arena and exchange pointers; the old
  arena is freed wholesale after the swap. Verified RSS stays flat over
  200 poll cycles.
  ```

- **Merging to main auto-releases** (see §6) — the maintainer controls the
  version bump via markers in the merge commit.

## 4. Pre-PR checklist

Every PR, no exceptions (this is also the PR template):

1. `zig fmt --check .` — clean.
2. `zig build test` — green, zero leaks reported.
3. `zig build run` — launch, navigate all views, quit with `q` **and** with
   Ctrl-C; confirm the terminal is restored both times (no raw-mode residue,
   cursor visible). TUI regressions hide here.
4. If you touched the poller/notifier: run once with a test event ~2 minutes
   out and watch a notification fire exactly once.
5. If behavior now differs from `ARCHITECTURE.md`: update the spec in the same commit.
6. Secrets check: this repo must contain no calendar data. Never commit real
   event dumps — `testdata/` fixtures are scrubbed/synthetic (fake names,
   fake emails, fake meeting URLs).

## 5. Extension guides

### Adding a view
1. New file `src/ui/<view>.zig` exposing `draw(ctx, snapshot, state)` and a
   key handler; no allocation in `draw` (scratch buffer only).
2. Register it in the `View` enum + dispatch in `src/app.zig` (exhaustive
   switch — the compiler will point at every site).
3. Add its keys to the help overlay table and README key table.

### Adding a notification sink
1. New variant in `src/notify/sink.zig`'s tagged union with `detect()` and
   `send(title, body, url)`.
2. Slot it into the priority order in ARCHITECTURE.md §9 and update the config enum.
3. Failure of a sink must fall through to the next sink, logged, non-fatal.

### Adding a video-call provider
One row in the provider table in `src/calendar/event.zig` + one test case.

### Touching the Objective-C shim
Read CODING_STANDARDS §7 first. Any ABI change: update the header docs, the
Zig wrapper, and `ek_free` semantics together — the header is the contract.

## 6. Versioning & releases

- **Releases are continuous**: every push to main that touches code
  (paths filter in `.github/workflows/release.yml`) auto-publishes a
  GitHub Release. The workflow computes the next version from the latest
  `v*` tag, builds ReleaseSafe on a macOS arm64 runner, and uploads the
  tarball + sha256. There is no manual release step.
- **Steering the bump from the commit message** (subject or body):
  - default → patch (`v0.6.0` → `v0.6.1`)
  - `[release:minor]` → minor, `[release:major]` → major
  - `[skip release]` → no release (CI gates still run)
- **Version at build time**: git tags are the source of truth; CI injects
  the computed tag via `-Dversion`. Local builds report
  `<build.zig.zon version>-dev` — if `--version` doesn't end in `-dev`,
  you're holding a release binary.
- Artifacts: `docket-vX.Y.Z-macos-arm64.tar.gz` containing the
  binary, `launchd/`, `scripts/`, and the README. arm64-only for now —
  x86_64 cross-compilation is blocked on Apple SDK header quirks in the
  ObjC shim (search "sysroot" in build.zig).
- Release builds: `ReleaseSafe`. Record measured idle RSS in the README per
  release (a tracked number, not a vibe — see ARCHITECTURE.md §12 for current values).
- CI (`.github/workflows/ci.yml`) runs fmt + tests + a ReleaseSafe compile
  on every push to main.

## 7. Design tiebreakers

Humans and AI agents both work on this repo; when a design question is
ambiguous, resolve it in favor of: **simpler memory story > simpler
concurrency story > fewer dependencies > prettier UI**. Other norms:

- Leave breadcrumbs: non-obvious decisions get a sentence in the commit body,
  not a TODO comment.
- `TODO` comments must reference an issue or an ARCHITECTURE.md section;
  orphan TODOs are deleted.
- Writes to calendars go through the `ical` CLI, never the EventKit shim —
  a bug in this app must not be able to corrupt a calendar store.
