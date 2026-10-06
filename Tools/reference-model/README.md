# Reference model

An executable Python port of Petal's timing, state machine, calendar statistics, crash
recovery and CSV escaping (function names mirror `App.swift`). It exists because the logic
was verified on a machine without a Swift toolchain; it tests the *algorithms*, not the
Swift code itself — run the XCTest suite (⌘U) for that.

    python3 test_model.py          # before/after comparison
    python3 test_model.py after    # fixed logic only

It runs deterministic boundary tests plus a randomized adversarial fuzzer (rapid toggles,
resets, laps, deletes, 25+ stopwatches, delayed/missing ticks, midnight/DST jumps in four
time zones, partially-applied persistence queues, crashes and clean quits) and checks every
step against brute-force oracles computed from raw session records.
