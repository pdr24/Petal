import XCTest
import SwiftData
import Carbon.HIToolbox
@testable import Petal

// MARK: - Test support

/// Controllable clocks so tests never sleep and are fully deterministic.
final class FakeClock {
    var mono: TimeInterval = 10_000
    var wall: Date
    init(wall: Date) { self.wall = wall }
    func advance(_ seconds: TimeInterval) {
        mono += seconds
        wall = wall.addingTimeInterval(seconds)
    }
}

final class Box<T>: @unchecked Sendable { var value: T? }

enum TestCal {
    static func make(_ tz: String = "America/Chicago") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }
    static func date(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
}

@MainActor
class StoreTestCase: XCTestCase {
    var defaults: UserDefaults!
    var clock: FakeClock!
    var calendar: Calendar!

    func makeStore(at wall: Date? = nil, container: ModelContainer? = nil,
                   defaults reuse: UserDefaults? = nil, clock reuseClock: FakeClock? = nil) async -> StopwatchStore {
        if let reuse { defaults = reuse } else {
            let suite = "PetalTests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(true, forKey: StoreKeys.onboarded)
        }
        calendar = TestCal.make()
        clock = reuseClock ?? FakeClock(wall: wall ?? TestCal.date(calendar, 2026, 6, 10, 10))
        let queue = container.map { PersistenceQueue(container: $0) }
        let store = StopwatchStore(persistence: queue, settings: AppSettings(defaults: defaults),
                                   defaults: defaults, sideEffects: false)
        let c = clock!
        store.clock = { c.mono }
        store.wallClock = { c.wall }
        store.calendar = calendar
        store.load()
        await waitUntil { store.isLoaded && store.statsLoaded }
        return store
    }

    // @escaping: the closure is called after an `await`, so it outlives the call frame.
    func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for condition"); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func value(_ store: StopwatchStore, _ id: UUID) -> TimeInterval {
        store.value(store.model(id)!, at: clock.mono)
    }

    func sessions(_ container: ModelContainer) throws -> [SessionEntity] {
        try ModelContext(container).fetch(FetchDescriptor<SessionEntity>(sortBy: [SortDescriptor(\.startTime)]))
    }
}

// MARK: - State machine

@MainActor
final class StateMachineTests: StoreTestCase {
    func testCanonicalTransitions() async {
        let store = await makeStore()
        let id = store.create()!
        store.reset(id, haptic: false)                                   // IDLE → reset → IDLE
        XCTAssertEqual(value(store, id), 0)
        store.start(id, haptic: false); clock.advance(1)                 // exactly 1 s
        XCTAssertEqual(value(store, id), 1, accuracy: 1e-9)
        store.pause(id, haptic: false); clock.advance(500)               // paused time excluded
        XCTAssertEqual(value(store, id), 1, accuracy: 1e-9)
        store.start(id, haptic: false); clock.advance(59)                // 59 → 60
        XCTAssertEqual(value(store, id), 60, accuracy: 1e-9)
        store.reset(id, haptic: false)                                   // RUNNING → reset → IDLE
        XCTAssertFalse(store.model(id)!.isRunning)
        XCTAssertEqual(value(store, id), 0)
        XCTAssertEqual(store.todaySessions(id).count, 2)                 // history kept
    }

    func testDoubleStartAndIdlePauseAreNoOps() async {
        let store = await makeStore()
        let id = store.create()!
        store.pause(id, haptic: false)
        XCTAssertTrue(store.todaySessions(id).isEmpty)
        store.start(id, haptic: false); clock.advance(3)
        let session = store.model(id)!.currentSessionID
        store.start(id, haptic: false)
        XCTAssertEqual(store.model(id)!.currentSessionID, session)
        clock.advance(2)
        XCTAssertEqual(value(store, id), 5, accuracy: 1e-9)
        XCTAssertEqual(store.todaySessions(id).count, 1)
    }

    func testRapidToggleProducesOneSessionPerRunAndNoLostTime() async {
        let store = await makeStore()
        let id = store.create()!
        var expected: TimeInterval = 0
        for k in 0..<200 {
            store.toggle(id, haptic: false)
            let dt = Double(k % 7) * 0.013
            if store.model(id)!.isRunning { expected += dt }
            clock.advance(dt)
        }
        if store.model(id)!.isRunning { store.pause(id, haptic: false) }
        XCTAssertEqual(value(store, id), expected, accuracy: 1e-6)
        XCTAssertEqual(store.todaySessions(id).count, 100)
        XCTAssertGreaterThanOrEqual(value(store, id), 0)
    }

    func testTenIndependentRunningStopwatches() async {
        let store = await makeStore()
        let ids = (0..<10).map { _ in store.create()! }
        for id in ids { store.start(id, haptic: false); clock.advance(1) }
        store.pause(ids[3], haptic: false)
        store.reset(ids[5], haptic: false)
        clock.advance(10)
        for (k, id) in ids.enumerated() {
            let expected: TimeInterval = k == 3 ? 7 : (k == 5 ? 0 : Double(10 - k) + 10)
            XCTAssertEqual(value(store, id), expected, accuracy: 1e-9, "stopwatch \(k)")
        }
        XCTAssertEqual(store.stopwatches.filter(\.isRunning).count, 8)
        XCTAssertEqual(store.menuBarTitle(now: clock.mono).hasSuffix(" ·8"), true)
    }

    func testExactlyOneDisplayTimerOnlyWhileRunning() async {
        let store = await makeStore()
        let a = store.create()!, b = store.create()!
        XCTAssertFalse(store.hasDisplayTimer)                          // idle: zero timers
        store.start(a, haptic: false); store.start(b, haptic: false)
        XCTAssertTrue(store.hasDisplayTimer)
        store.pause(a, haptic: false)
        XCTAssertTrue(store.hasDisplayTimer)
        store.pause(b, haptic: false)
        XCTAssertFalse(store.hasDisplayTimer)
    }

    func testMenuBarTitleRules() async {
        let store = await makeStore()
        store.settings.compactUnderHour = true
        let a = store.create()!, b = store.create()!
        XCTAssertEqual(store.menuBarTitle(now: clock.mono), "")
        store.start(a, haptic: false); clock.advance(65)
        XCTAssertEqual(store.menuBarTitle(now: clock.mono), "01:05")
        store.start(b, haptic: false); clock.advance(1)
        XCTAssertEqual(store.menuBarTitle(now: clock.mono), "00:01 ·2")
        store.pause(b, haptic: false)                                    // selected paused → most recent running
        XCTAssertEqual(store.menuBarTitle(now: clock.mono), "01:06")
        clock.advance(3600)
        XCTAssertEqual(store.menuBarTitle(now: clock.mono), "01:01:06")
        store.settings.menuBarShowsTime = false
        XCTAssertEqual(store.menuBarTitle(now: clock.mono), "")
    }

    func testDeleteSelectedRunningAndPositions() async {
        let store = await makeStore()
        let ids = (0..<22).map { _ in store.create()! }
        store.start(ids[1], haptic: false)
        store.route = ids[1]
        store.delete(ids[1])
        XCTAssertNil(store.model(ids[1]))
        XCTAssertNil(store.route)
        XCTAssertEqual(store.selectedID, ids[0])
        XCTAssertFalse(store.anyRunning)
        store.select(position: 0); store.select(position: 99)          // out of range: unchanged
        XCTAssertEqual(store.selectedID, ids[0])
        store.select(position: 8)
        XCTAssertEqual(store.selectedID, ids[8])                        // positions shift after delete
        for id in store.stopwatches.map(\.id) { store.delete(id) }
        XCTAssertNil(store.selectedID)
        XCTAssertNil(store.actionTarget)
    }

    func testLapsOnlyWhileRunningAndAttachToActiveSession() async {
        let store = await makeStore()
        let id = store.create()!
        store.lap(id, haptic: false)
        XCTAssertTrue(store.openLaps.isEmpty)
        store.start(id, haptic: false); clock.advance(4)
        store.lap(id, haptic: false); store.lap(id, haptic: false)
        let first = store.model(id)!.currentSessionID!
        store.pause(id, haptic: false)
        store.lap(id, haptic: false)                                    // ignored while paused
        store.start(id, haptic: false); clock.advance(1)
        store.lap(id, haptic: false)
        let sessions = store.todaySessions(id)                          // newest first
        XCTAssertEqual(sessions[1].id, first)
        XCTAssertEqual(sessions[1].laps.count, 2)
        XCTAssertEqual(sessions[1].laps[0].elapsedAtLap, 4, accuracy: 1e-9)
        XCTAssertEqual(sessions[0].laps.count, 1)
        XCTAssertTrue(sessions.allSatisfy { s in s.laps.allSatisfy { $0.sessionID == s.id } })
    }

    func testTagRules() async {
        let store = await makeStore()
        let id = store.create()!
        XCTAssertTrue(store.addTag(id, "  research  "))
        XCTAssertFalse(store.addTag(id, "RESEARCH"))
        XCTAssertFalse(store.addTag(id, "   "))
        XCTAssertFalse(store.addTag(id, ""))
        for i in 0..<10 { store.addTag(id, "t\(i)") }
        XCTAssertEqual(store.model(id)!.tags.count, 8)
        let other = store.create()!
        store.addTag(other, String(repeating: "🌸", count: 40))
        XCTAssertEqual(store.model(other)!.tags.first?.count, 20)
    }

    func testRenameRules() async {
        let store = await makeStore()
        let a = store.create()!, b = store.create()!
        store.rename(a, to: "   ")
        XCTAssertEqual(store.model(a)!.name, "Timer 1")
        store.rename(a, to: "Écriture ✍️ 日本語")
        store.rename(b, to: "Écriture ✍️ 日本語")                     // duplicates allowed
        XCTAssertEqual(store.model(a)!.name, store.model(b)!.name)
        store.rename(a, to: String(repeating: "x", count: 500))
        XCTAssertEqual(store.model(a)!.name.count, 60)
    }
}

// MARK: - Time & calendar

@MainActor
final class CalendarTests: StoreTestCase {
    func testRunningAcrossMidnightRollsDisplayedValueOver() async {
        let store = await makeStore(at: TestCal.date(TestCal.make(), 2026, 6, 10, 23, 59))
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(120)
        XCTAssertEqual(value(store, id), 60, accuracy: 1e-9)          // before any tick
        store.tick()
        XCTAssertEqual(value(store, id), 60, accuracy: 1e-9)
        XCTAssertEqual(store.todaySeconds(id), 60, accuracy: 1e-9)
        store.pause(id, haptic: false)
        XCTAssertEqual(store.dayTotals[id]?[TestCal.date(calendar, 2026, 6, 10)] ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(store.dayTotals[id]?[TestCal.date(calendar, 2026, 6, 11)] ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(store.allTimeSeconds(id), 120, accuracy: 1e-9)
        XCTAssertEqual(store.todaySessions(id).count, 1)               // one session, not split
    }

    func testPauseAfterMidnightBeforeAnyTickDoesNotFoldYesterday() async {
        let store = await makeStore(at: TestCal.date(TestCal.make(), 2026, 6, 10, 23))
        let id = store.create()!
        store.start(id, haptic: false)
        clock.advance(7200)                                            // asleep: no ticks
        store.pause(id, haptic: false)
        XCTAssertEqual(store.model(id)!.accumulatedSeconds, 3600, accuracy: 1e-9)
        XCTAssertEqual(value(store, id), 3600, accuracy: 1e-9)
    }

    func testPausedValueIsZeroNextDayEvenWithoutTick() async {
        let store = await makeStore(at: TestCal.date(TestCal.make(), 2026, 6, 10, 22))
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(600); store.pause(id, haptic: false)
        clock.advance(4 * 3600)
        XCTAssertEqual(value(store, id), 0)
        XCTAssertEqual(store.allTimeSeconds(id), 600, accuracy: 1e-9)
    }

    func testWeekIsMondayToSundayAndSplitsAcrossSundayMonday() async {
        let cal = TestCal.make()
        let week = DayMath.weekInterval(containing: TestCal.date(cal, 2026, 12, 31, 12), calendar: cal)
        XCTAssertEqual(week.start, TestCal.date(cal, 2026, 12, 28))
        XCTAssertEqual(week.end, TestCal.date(cal, 2027, 1, 4))
        let store = await makeStore(at: TestCal.date(cal, 2026, 6, 14, 23, 30))   // Sunday 23:30
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(3600); store.pause(id, haptic: false)
        XCTAssertEqual(store.weekSeconds(id), 1800, accuracy: 1e-9)     // Monday's half only
        XCTAssertEqual(store.todaySeconds(id), 1800, accuracy: 1e-9)
    }

    func testStreakBoundaries() async {
        let store = await makeStore()
        let a = store.create()!
        for secs in [60.0, 60.0, 59.0] {
            store.start(a, haptic: false); clock.advance(secs); store.pause(a, haptic: false)
            clock.advance(86_400 - secs); store.tick()
        }
        XCTAssertEqual(store.streak(a), 0)                              // yesterday: 59 s
        store.start(a, haptic: false); clock.advance(60)
        XCTAssertEqual(store.streak(a), 1)
        store.pause(a, haptic: false)
        let b = store.create()!
        for _ in 0..<3 {
            store.start(b, haptic: false); clock.advance(120); store.pause(b, haptic: false)
            clock.advance(86_400 - 120); store.tick()
        }
        XCTAssertEqual(store.streak(b), 3)
        store.start(b, haptic: false); clock.advance(59)
        XCTAssertEqual(store.streak(b), 3)
        clock.advance(1)
        XCTAssertEqual(store.streak(b), 4)
        store.pause(b, haptic: false)
        clock.advance(2 * 86_400); store.tick()
        XCTAssertEqual(store.streak(b), 0)                              // skipped a day
    }

    func testStreakCountsCrossMidnightSessionForBothDays() async {
        let store = await makeStore(at: TestCal.date(TestCal.make(), 2026, 6, 10, 23, 59))
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(120); store.tick()
        XCTAssertEqual(store.streak(id), 2)
    }

    func testGoalBoundariesAndOncePerDay() async {
        let store = await makeStore()
        let id = store.create()!
        store.setGoal(id, seconds: 1800)
        store.start(id, haptic: false)
        clock.advance(1799); store.tick()
        XCTAssertFalse(store.isGoalNotifiedToday(id))                  // just below
        clock.advance(1); store.tick()
        XCTAssertTrue(store.isGoalNotifiedToday(id))                   // exactly at goal
        let flash = store.goalFlash[id]
        for _ in 0..<50 { clock.advance(1); store.tick() }
        XCTAssertEqual(store.goalFlash[id], flash)                     // not re-fired every tick
        clock.advance(86_400); store.tick()                            // next day: new evaluation
        XCTAssertTrue(store.isGoalNotifiedToday(id))
        XCTAssertNotNil(store.goalFlash[id])                           // flash survives the day change
        XCTAssertNotEqual(store.goalFlash[id], flash)
    }

    func testGoalAlreadyMetWhenSetIsMarkedSilently() async {
        let store = await makeStore()
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(4000); store.pause(id, haptic: false)
        store.setGoal(id, seconds: 3600)
        XCTAssertTrue(store.isGoalNotifiedToday(id))
        XCTAssertNil(store.goalFlash[id])
        store.setGoal(id, seconds: 0)
        XCTAssertNil(store.model(id)!.dailyGoalSeconds)
    }

    func testTimeZoneChangeDoesNotZeroTodaysValue() async {
        let store = await makeStore()
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(600); store.pause(id, haptic: false)
        store.calendar = TestCal.make("America/New_York")               // traveled east, same date
        store.timeZoneChanged()
        XCTAssertEqual(value(store, id), 600, accuracy: 1e-9)
    }

    func testPomodoroFreezesWhilePausedAndDisableCleansUp() async {
        let store = await makeStore()
        let id = store.create()!
        store.setPomodoro(id, enabled: true)
        store.start(id, haptic: false); clock.advance(60)
        store.pause(id, haptic: false); clock.advance(600)
        XCTAssertEqual(store.pomodoro[id]!.remaining(at: clock.mono), 25 * 60 - 60, accuracy: 1e-6)
        store.start(id, haptic: false); clock.advance(30)
        XCTAssertEqual(store.pomodoro[id]!.remaining(at: clock.mono), 25 * 60 - 90, accuracy: 1e-6)
        store.setPomodoro(id, enabled: false)
        XCTAssertNil(store.pomodoro[id])
    }

    func testPomodoroBackstopCompletesWhenCallbackIsLate() async {
        let store = await makeStore()
        let id = store.create()!
        store.setPomodoro(id, enabled: true)
        store.start(id, haptic: false)
        clock.advance(25 * 60 + 2); store.tick()                        // dispatch source never fired
        let p = store.pomodoro[id]!
        XCTAssertEqual(p.phase, .rest)
        XCTAssertTrue(p.awaitingStart)                                  // auto-start off by default
        store.startNextPomodoroPhase(id)
        XCTAssertEqual(store.pomodoro[id]!.remaining(at: clock.mono), 5 * 60, accuracy: 1e-6)
    }
}

// MARK: - Persistence (real SwiftData, in-memory)

@MainActor
final class PersistenceTests: StoreTestCase {
    func container() throws -> ModelContainer { try PersistenceController.makeContainer(inMemory: true) }

    func testSessionsOpenAndCloseWithTransitionsAndResetKeepsHistory() async throws {
        let c = try container()
        let store = await makeStore(container: c)
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(10)
        await store.flush()
        XCTAssertEqual(try sessions(c).filter { $0.endTime == nil }.count, 1)
        store.pause(id, haptic: false)
        store.start(id, haptic: false); clock.advance(5)
        store.reset(id, haptic: false)
        await store.flush()
        let all = try sessions(c)
        XCTAssertEqual(all.count, 2)                                     // no duplicates, none lost
        XCTAssertTrue(all.allSatisfy { $0.endTime != nil })
        XCTAssertEqual(all.map { $0.endTime!.timeIntervalSince($0.startTime) }, [10, 5])
        let entity = try ModelContext(c).fetch(FetchDescriptor<StopwatchEntity>()).first!
        XCTAssertEqual(entity.accumulatedSeconds, 0)
    }

    func testSoftDeleteKeepsSessionsAndDoesNotCascade() async throws {
        let c = try container()
        let store = await makeStore(container: c)
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(10); store.lap(id, haptic: false)
        store.delete(id)                                                 // deletes while running
        await store.flush()
        let ctx = ModelContext(c)
        let entity = try ctx.fetch(FetchDescriptor<StopwatchEntity>()).first
        XCTAssertNotNil(entity?.deletedAt)
        XCTAssertEqual(try sessions(c).count, 1)
        XCTAssertNotNil(try sessions(c).first?.endTime)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<LapEntity>()).count, 1)
        // Relaunch: the deleted stopwatch is not loaded, its history remains.
        let store2 = await makeStore(container: c, defaults: defaults, clock: clock)
        XCTAssertTrue(store2.stopwatches.isEmpty)
        XCTAssertEqual(try sessions(c).count, 1)
    }

    func testPurgeAfter30DaysRemovesSessionsAndLapsOnly29DaysKeeps() async throws {
        let c = try container()
        let actor = PersistenceActor(modelContainer: c)
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let keep = UUID(), purge = UUID()
        for (id, deletedDaysAgo) in [(keep, 29.0), (purge, 31.0)] {
            await actor.apply(.upsertStopwatch(StopwatchSnapshot(id: id, name: "x", colorName: "sky", tags: [],
                dailyGoalSeconds: nil, sortOrder: 0, createdAt: t0, accumulatedSeconds: 0, accumulatedDay: t0)))
            let sid = UUID()
            await actor.apply(.startSession(id: sid, stopwatchID: id, start: t0))
            await actor.apply(.addLap(LapRecord(id: UUID(), sessionID: sid, timestamp: t0, elapsedAtLap: 1)))
            await actor.apply(.endSession(id: sid, end: t0.addingTimeInterval(60)))
            await actor.apply(.softDelete(id: id, at: t0.addingTimeInterval(-deletedDaysAgo * 86_400 + 40 * 86_400)))
        }
        let now = t0.addingTimeInterval(40 * 86_400)
        await actor.apply(.load(heartbeat: nil, now: now, today: DateInterval(start: now, duration: 86_400), reply: { _ in }))
        let ctx = ModelContext(c)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StopwatchEntity>()).map(\.id), [keep])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SessionEntity>()).map(\.stopwatchID), [keep])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<LapEntity>()).count, 1)
    }

    func testCrashGuardClosesOrphansAtHeartbeatWithoutDoubleCounting() async throws {
        let c = try container()
        let actor = PersistenceActor(modelContainer: c)
        let cal = TestCal.make()
        let today = TestCal.date(cal, 2026, 6, 10)
        let start = TestCal.date(cal, 2026, 6, 10, 9)
        let a = UUID(), b = UUID()
        for id in [a, b] {
            await actor.apply(.upsertStopwatch(StopwatchSnapshot(id: id, name: "t", colorName: "sage", tags: [],
                dailyGoalSeconds: nil, sortOrder: 0, createdAt: start, accumulatedSeconds: 100, accumulatedDay: start)))
        }
        await actor.apply(.startSession(id: UUID(), stopwatchID: a, start: start))                    // orphan 1
        await actor.apply(.startSession(id: UUID(), stopwatchID: b, start: start.addingTimeInterval(30))) // orphan 2
        let heartbeat = start.addingTimeInterval(90)
        let result = Box<LoadResult>()
        await actor.apply(.load(heartbeat: heartbeat, now: start.addingTimeInterval(86_000 - 9 * 3600),
                                today: DateInterval(start: today, duration: 86_400), reply: { result.value = $0 }))
        XCTAssertEqual(result.value?.recoveredSessions, 2)
        let all = try sessions(c)
        XCTAssertTrue(all.allSatisfy { $0.endTime != nil && $0.wasInterrupted })
        XCTAssertEqual(all.map { $0.endTime! }, [heartbeat, heartbeat])   // not launch time
        let values = Dictionary(uniqueKeysWithValues: result.value!.stopwatches.map { ($0.id, $0.accumulatedSeconds) })
        XCTAssertEqual(values[a], 190)                                   // 100 + 90
        XCTAssertEqual(values[b], 160)                                   // 100 + 60
        // A second launch must not add anything again.
        await actor.apply(.load(heartbeat: heartbeat, now: heartbeat, today: DateInterval(start: today, duration: 86_400),
                                reply: { result.value = $0 }))
        XCTAssertEqual(result.value?.recoveredSessions, 0)
        XCTAssertEqual(result.value!.stopwatches.first { $0.id == a }?.accumulatedSeconds, 190)
    }

    func testCrashGuardCountsOnlyTodaysPortionAcrossMidnight() async throws {
        let c = try container()
        let actor = PersistenceActor(modelContainer: c)
        let cal = TestCal.make()
        let start = TestCal.date(cal, 2026, 6, 10, 23, 50)
        let today = TestCal.date(cal, 2026, 6, 11)
        let id = UUID()
        await actor.apply(.upsertStopwatch(StopwatchSnapshot(id: id, name: "t", colorName: "sky", tags: [],
            dailyGoalSeconds: nil, sortOrder: 0, createdAt: start, accumulatedSeconds: 500, accumulatedDay: start)))
        await actor.apply(.startSession(id: UUID(), stopwatchID: id, start: start))
        let result = Box<LoadResult>()
        await actor.apply(.load(heartbeat: start.addingTimeInterval(1200), now: start.addingTimeInterval(1800),
                                today: DateInterval(start: today, duration: 86_400), reply: { result.value = $0 }))
        XCTAssertEqual(result.value!.stopwatches.first!.accumulatedSeconds, 600)  // 00:00–00:10 only
    }

    func testRelaunchRestoresEditsAndQuitWhileRunningClosesEverything() async throws {
        let c = try container()
        let store = await makeStore(container: c)
        let a = store.create()!, b = store.create()!
        store.rename(a, to: "Research, \"deep\"")
        store.setColor(a, .lavender)
        store.addTag(a, "phd")
        store.setGoal(a, seconds: 7200)
        store.start(a, haptic: false); clock.advance(30); store.lap(a, haptic: false)
        store.start(b, haptic: false); clock.advance(20)
        let done = expectation(description: "terminated")
        store.prepareForTermination { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(try sessions(c).allSatisfy { $0.endTime != nil })
        let store2 = await makeStore(container: c, defaults: defaults, clock: clock)
        let r = store2.model(a)!
        XCTAssertEqual(r.name, "Research, \"deep\"")
        XCTAssertEqual(r.color, .lavender)
        XCTAssertEqual(r.tags, ["phd"])
        XCTAssertEqual(r.dailyGoalSeconds, 7200)
        XCTAssertEqual(store2.value(r, at: clock.mono), 50, accuracy: 1e-6)
        XCTAssertEqual(store2.value(store2.model(b)!, at: clock.mono), 20, accuracy: 1e-6)
        XCTAssertFalse(store2.anyRunning)                                // paused, not auto-resumed
        XCTAssertEqual(store2.allTimeSeconds(a), 50, accuracy: 1e-6)
        XCTAssertEqual(store2.todaySessions(a).first?.laps.count, 1)
    }

    func testRelaunchNextDayZeroesValueButKeepsHistory() async throws {
        let c = try container()
        let store = await makeStore(container: c)
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(500); store.pause(id, haptic: false)
        await store.flush()
        clock.advance(86_400)
        let store2 = await makeStore(container: c, defaults: defaults, clock: clock)
        XCTAssertEqual(store2.value(store2.model(id)!, at: clock.mono), 0)
        XCTAssertEqual(store2.allTimeSeconds(id), 500, accuracy: 1e-6)
        XCTAssertEqual(store2.todaySeconds(id), 0)
    }

    func testStatsStayExactWhenPausingDuringInFlightFetch() async throws {
        let c = try container()
        let store = await makeStore(container: c)
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(10)
        store.loadStats()                                               // fetch queued, not yet applied
        store.pause(id, haptic: false); clock.advance(5)
        store.start(id, haptic: false); clock.advance(5); store.pause(id, haptic: false)
        await waitUntil { store.statsLoaded }
        await store.flush()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.allTimeSeconds(id), 15, accuracy: 1e-6)    // not 25, not 5
        XCTAssertEqual(store.sessionCounts[id], 2)
    }

    func testDeleteAllDataEmptiesStore() async throws {
        let c = try container()
        let store = await makeStore(container: c)
        let id = store.create()!
        store.start(id, haptic: false); clock.advance(3); store.lap(id, haptic: false)
        store.deleteAllData()
        await store.flush()
        let ctx = ModelContext(c)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<StopwatchEntity>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<SessionEntity>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<LapEntity>()).count, 0)
        XCTAssertTrue(store.stopwatches.isEmpty)
        XCTAssertFalse(store.hasDisplayTimer)
    }
}

// MARK: - Pure logic

final class PureLogicTests: XCTestCase {
    func testTimeFormatterEdgeCases() {
        XCTAssertEqual(TimeFormatter.clock(0), "00:00:00")
        XCTAssertEqual(TimeFormatter.clock(1), "00:00:01")
        XCTAssertEqual(TimeFormatter.clock(59.999), "00:00:59")
        XCTAssertEqual(TimeFormatter.clock(60), "00:01:00")
        XCTAssertEqual(TimeFormatter.clock(3599), "00:59:59")
        XCTAssertEqual(TimeFormatter.clock(3600), "01:00:00")
        XCTAssertEqual(TimeFormatter.clock(86_400 + 1), "24:00:01")
        XCTAssertEqual(TimeFormatter.clock(99 * 3600 + 59 * 60 + 59), "99:59:59")
        XCTAssertEqual(TimeFormatter.clock(360_000), "100:00:00")
        XCTAssertEqual(TimeFormatter.clock(-5), "00:00:00")
        XCTAssertEqual(TimeFormatter.clock(.nan), "00:00:00")
        XCTAssertEqual(TimeFormatter.clock(.infinity), "00:00:00")
        XCTAssertEqual(TimeFormatter.menuBar(65, compactUnderHour: true), "01:05")
        XCTAssertEqual(TimeFormatter.menuBar(65, compactUnderHour: false), "00:01:05")
        XCTAssertEqual(TimeFormatter.menuBar(3600, compactUnderHour: true), "01:00:00")
        XCTAssertEqual(TimeFormatter.short(7680), "2h 08m")
        XCTAssertEqual(TimeFormatter.countdown(1500), "25:00")
        XCTAssertEqual(TimeFormatter.countdown(0.2), "00:01")
        XCTAssertEqual(TimeFormatter.countdown(0), "00:00")
        XCTAssertEqual(TimeFormatter.goal(1800), "30 min")
        XCTAssertEqual(TimeFormatter.goal(5400), "1h 30m")
    }

    func testDaySplitAcrossDSTTransitions() {
        let cal = TestCal.make("America/New_York")
        let spring = DayMath.split(start: TestCal.date(cal, 2026, 3, 7, 23), end: TestCal.date(cal, 2026, 3, 9, 1), calendar: cal)
        XCTAssertEqual(spring.map(\.seconds), [3600, 23 * 3600, 3600])       // 23-hour day
        let fall = DayMath.split(start: TestCal.date(cal, 2026, 11, 1), end: TestCal.date(cal, 2026, 11, 2), calendar: cal)
        XCTAssertEqual(fall.map(\.seconds), [25 * 3600])                      // 25-hour day
        let year = DayMath.split(start: TestCal.date(cal, 2026, 12, 31, 23), end: TestCal.date(cal, 2027, 1, 1, 1), calendar: cal)
        XCTAssertEqual(year.map(\.seconds), [3600, 3600])
    }

    func testSplitDegenerateInputs() {
        let d = Date()
        XCTAssertTrue(DayMath.split(start: d, end: d, calendar: .current).isEmpty)
        XCTAssertTrue(DayMath.split(start: d, end: d.addingTimeInterval(-5), calendar: .current).isEmpty)
    }

    func testCSVEscapingAndFormulaInjection() {
        XCTAssertEqual(ExportManager.escape("plain"), "plain")
        XCTAssertEqual(ExportManager.escape(""), "")
        XCTAssertEqual(ExportManager.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(ExportManager.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ExportManager.escape("line1\r\nline2"), "\"line1\r\nline2\"")
        XCTAssertEqual(ExportManager.escape("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(ExportManager.escape("=HYPERLINK(1)"), "'=HYPERLINK(1)")
        XCTAssertEqual(ExportManager.escape("@SUM"), "'@SUM")
        XCTAssertEqual(ExportManager.escape("🌸 petal"), "🌸 petal")
    }

    /// Minimal RFC 4180 reader used to prove the output round-trips.
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text.unicodeScalars)[...]
        while let ch = chars.popFirst() {
            if quoted {
                if ch == "\"" {
                    if chars.first == "\"" { field.unicodeScalars.append("\""); chars.removeFirst() } else { quoted = false }
                } else { field.unicodeScalars.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\r" { continue }
            else if ch == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.unicodeScalars.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    func testCSVRoundTripsHostileContent() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let laps = [LapRecord(id: UUID(), sessionID: UUID(), timestamp: start, elapsedAtLap: 494, label: nil),
                    LapRecord(id: UUID(), sessionID: UUID(), timestamp: start, elapsedAtLap: 900, label: "split, \"a\"")]
        let session = SessionRecord(id: UUID(), stopwatchID: UUID(), start: start, end: start.addingTimeInterval(90.4),
                                    note: "lit review,\nch.3 \"draft\" 🌸", wasInterrupted: true, laps: laps)
        let open = SessionRecord(id: UUID(), stopwatchID: UUID(), start: start, end: nil,
                                 note: nil, wasInterrupted: false, laps: [])
        let csv = ExportManager.csv(rows: [
            ExportRow(stopwatchName: "Research, \"PhD\"", colorName: "blush", tags: ["a,b", "c"], session: session),
            ExportRow(stopwatchName: "日本語", colorName: "sky", tags: [], session: open),
        ], now: start.addingTimeInterval(30), timeZone: TimeZone(identifier: "UTC")!)
        let rows = parseCSV(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.count == ExportManager.columns.count })
        XCTAssertEqual(rows[1][0], "Research, \"PhD\"")
        XCTAssertEqual(rows[1][2], "a,b; c")
        XCTAssertEqual(rows[1][6], "90")
        XCTAssertEqual(rows[1][7], "lit review,\nch.3 \"draft\" 🌸")
        XCTAssertEqual(rows[1][8], "Lap 1 00:08:14 | split, \"a\" 00:15:00")
        XCTAssertEqual(rows[1][9], "true")
        XCTAssertEqual(rows[2][5], "")                                   // open session: no end
        XCTAssertEqual(rows[2][6], "30")
    }

    func testCSVEmptyHistoryIsHeaderOnly() {
        let csv = ExportManager.csv(rows: [], now: Date())
        XCTAssertEqual(csv, ExportManager.columns.joined(separator: ",") + "\r\n")
    }

    func testCSVWriteNeverOverwritesAndReportsFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try ExportManager.write("a", date: date, directory: dir)
        let second = try ExportManager.write("b", date: date, directory: dir)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" (2).csv"))
        XCTAssertEqual(try Data(contentsOf: first), Data("\u{FEFF}a".utf8))   // BOM + content, byte-exact
        let missing = dir.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try ExportManager.write("c", date: date, directory: missing))
    }

    func testInstanceLockAdmitsOneHolderAndFreesOnRelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Petal.instance-lock")   // parent doesn't exist yet
        var first: InstanceLock? = InstanceLock(url: url)
        XCTAssertNotNil(first)
        XCTAssertNil(InstanceLock(url: url), "a second copy must not get the lock")
        first = nil   // the holder quits (the kernel does the same on a crash)
        XCTAssertNotNil(InstanceLock(url: url))
        _ = first
    }

    @MainActor
    func testShortcutConflictsAreDetected() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "PetalShortcuts-\(UUID().uuidString)")!)
        let startPause = settings.combo(for: .startPause)
        XCTAssertEqual(settings.conflict(for: startPause, excluding: .lap), ShortcutAction.startPause.title)
        XCTAssertNil(settings.conflict(for: startPause, excluding: .startPause))
        XCTAssertEqual(settings.conflict(for: .controlOption(kVK_ANSI_3, "3"), excluding: .lap), "Select timer 3")
        XCTAssertNil(settings.conflict(for: .controlOption(kVK_ANSI_9, "9"), excluding: .lap))
    }
}
