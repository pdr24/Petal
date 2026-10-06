# Petal 🌸 — macOS menu bar stopwatch

Native Swift/SwiftUI/SwiftData, zero dependencies, macOS 14+. Almost everything is in
`Petal/App.swift`; tests are in `PetalTests/PetalTests.swift`.

## Build & run

    brew install xcodegen          # one time
    ./build.sh                     # → build/Build/Products/Release/Petal.app
    open build/Build/Products/Release/Petal.app

Or `xcodegen generate`, open `Petal.xcodeproj`, press ⌘R. Run tests with ⌘U.
For a signed, notarized `.dmg`: `TEAM_ID=XXXXXXXXXX ./release.sh` (see script header).

## How timing stays accurate

- Live time uses `mach_continuous_time` — monotonic, counts through sleep, and immune to
  clock edits, NTP corrections and time-zone changes. Elapsed = accumulated + (now − start);
  nothing is ever tick-counted, so there is zero drift.
- Each stopwatch is a plain value with its own start instant; there is no per-stopwatch
  timer, so one stopwatch can never affect or overwrite another.
- Session records get `end = start + monotonic duration`, so history always agrees with
  the stopwatch even if the wall clock changed mid-session.
- All disk writes go through one FIFO queue to a background SwiftData actor, so "start"
  can never be overtaken by "stop".

- The stopwatch value is **today's** time since the last reset (PRD §5.1/§6.10): it returns
  to zero at midnight. A run crossing midnight keeps one session record; the history splits
  it per calendar day. The value is computed day-aware at read time, so it is correct even if
  no timer tick has happened since midnight (e.g. the Mac was asleep).

## How it stays out of the way

- One 1 Hz timer total, alive only while something runs (idle = no timers at all), with
  0.1 s tolerance for wake-up coalescing, phase-aligned to the displayed second.
- With the popover closed, a tick only rewrites the menu bar string when it changes; SwiftUI
  isn't touched. The LIVE pulse animation exists only while the popover is visible.
- No network entitlement (the OS blocks sockets), no analytics, no Accessibility permission.

## Where this differs from the PRD (all marked `PRD-DEVIATION` in code)

1. **Global shortcuts** use Carbon `RegisterEventHotKey`. The PRD's `NSEvent` global key
   monitor needs Accessibility permission (which the PRD forbids) and can't swallow keys.
2. **Crash recovery** closes orphaned sessions at the last 30-second heartbeat, not at
   relaunch time (which would credit hours or days the app wasn't running).
3. **Daily summary** is posted by an in-app wall-clock timer; macOS can't compute a local
   notification's content at fire time.
4. **History** opens as a window, not a sheet: a sheet on a transient popover closes on
   the first click, and 300 pt is too narrow for charts.
5. **Popover navigation** is a hand-rolled slide: `NavigationStack` draws no back button
   inside an `NSPopover`.
6. **App Nap** is disabled only while a stopwatch runs, so the menu bar label doesn't freeze.
7. **Entitlement**: `files.downloads.read-write` (no write-only variant exists).
8. CSV has one extra trailing column, `interrupted`.

## Testing

- `⌘U` runs 38 XCTests, including SwiftData integration tests against an in-memory store
  (crash guard, soft delete vs cascade, 30-day purge, lap/session relationships, relaunch).
- `Tools/reference-model/` holds an executable model of the core logic with a randomized
  adversarial fuzzer (see its README).

Ambiguities resolved (marked `PRD-AMBIGUITY`): running stopwatches are paused, not resumed,
across quit; daily summary defaults to off (permission only on enable); tag removal uses
the same two-tap confirm as Reset/Delete; ⌃⌥Space conflicts with macOS's input-source
switcher if you use several keyboard layouts — rebind it in Preferences if so.
