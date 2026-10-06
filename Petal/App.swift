//
//  App.swift — Petal, a macOS menu bar stopwatch (PRD v1.0)
//
//  Almost the whole app lives in this file, by request. Sections:
//    1. Clock & formatting         7. Store (the timer state machine)
//    2. Palette & icon             8. Services (haptics, sound, notifications, hotkeys)
//    3. Value models               9. Status bar item + popover
//    4. Day math & CSV export     10. Popover views
//    5. Persistence (SwiftData)   11. History & Preferences windows
//    6. Settings & shortcuts      12. App entry point
//
//  Comments tagged `PRD-DEVIATION:` or `PRD-AMBIGUITY:` mark places where the PRD
//  was contradictory or not technically possible, and say what was done instead.
//

import SwiftUI
import AppKit
import SwiftData
import Charts
import Carbon.HIToolbox
import UserNotifications
import ServiceManagement
import os

let petalLog = Logger(subsystem: "com.local.petal", category: "app")

// MARK: - 1. Clock & formatting

/// Monotonic clock for all live timing.
///
/// `mach_continuous_time` keeps counting while the Mac sleeps (so a running
/// stopwatch includes sleep time, as the PRD requires) but — unlike `Date()` — it is
/// immune to NTP corrections, manual clock edits and time-zone changes. That makes
/// live elapsed time drift-free and impossible to "jump". Wall-clock `Date`s are only
/// used for *recording* when a session happened.
enum MonoClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func now() -> TimeInterval {
        Double(mach_continuous_time()) * secondsPerTick
    }
}

enum TimeFormatter {
    /// Whole seconds, clamped to a safe range (negative/NaN/∞ → 0) so `Int(...)` can never trap.
    static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 1e12).rounded(.down))
    }

    static func components(_ seconds: TimeInterval) -> (h: Int, m: Int, s: Int) {
        let t = wholeSeconds(seconds)
        return (t / 3600, (t % 3600) / 60, t % 60)
    }

    /// Zero-pads to two digits without `String(format:)` (cheaper; this runs every second).
    static func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    /// HH:MM:SS. Hours are never truncated (e.g. "123:04:05").
    static func clock(_ seconds: TimeInterval) -> String {
        let c = components(seconds)
        return "\(two(c.h)):\(two(c.m)):\(two(c.s))"
    }

    static func menuBar(_ seconds: TimeInterval, compactUnderHour: Bool) -> String {
        let c = components(seconds)
        if compactUnderHour && c.h == 0 { return "\(two(c.m)):\(two(c.s))" }
        return clock(seconds)
    }

    /// Countdown display (MM:SS). Rounds *up* so a 25-minute interval starts at 25:00
    /// and only shows 00:00 when it has actually finished.
    static func countdown(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let t = Int(min(seconds, 1e9).rounded(.up))
        return "\(two(t / 60)):\(two(t % 60))"
    }

    /// "2h 08m"
    static func short(_ seconds: TimeInterval) -> String {
        let t = wholeSeconds(seconds)
        return "\(t / 3600)h \(two((t % 3600) / 60))m"
    }

    /// Goal labels: "30 min", "1h", "1h 30m".
    static func goal(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(two(m))m"
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return f
    }()
}

// MARK: - 2. Palette & icon

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum PastelColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case blush, peach, butter, sage, sky, lavender, rose, mint

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var hex: UInt32 {
        switch self {
        case .blush: return 0xF0908A
        case .peach: return 0xF0B870
        case .butter: return 0xEDD870
        case .sage: return 0x90C49A
        case .sky: return 0x88BBEE
        case .lavender: return 0xB49AEE
        case .rose: return 0xEE90B8
        case .mint: return 0x88EED8
        }
    }

    var color: Color { Color(hex: hex) }

    init(name: String) { self = PastelColor(rawValue: name) ?? .blush }
}

/// The menu bar mark: four petals in an X, drawn in code as a template image so it
/// adapts to light/dark menu bars and needs no asset.
enum PetalIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            for i in 0..<4 {
                // A petal pointing "up" from the origin, rotated around the centre.
                let petal = NSBezierPath(ovalIn: NSRect(x: -2.4, y: 0.8, width: 4.8, height: 6.6))
                petal.transform(using: AffineTransform(rotationByDegrees: CGFloat(i) * 90 + 45))
                petal.transform(using: AffineTransform(translationByX: rect.midX, byY: rect.midY))
                petal.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Petal"
        return image
    }
}

// MARK: - 3. Value models

/// Persisted-shape snapshot of a stopwatch (Sendable, crosses to the persistence actor).
struct StopwatchSnapshot: Sendable, Equatable {
    let id: UUID
    var name: String
    var colorName: String
    var tags: [String]
    var dailyGoalSeconds: Int?
    var sortOrder: Int
    var createdAt: Date
    var accumulatedSeconds: TimeInterval
    /// The calendar day `accumulatedSeconds` belongs to (PRD §5.1: "…today").
    var accumulatedDay: Date?
}

struct LapRecord: Sendable, Identifiable, Hashable {
    let id: UUID
    let sessionID: UUID
    let timestamp: Date
    let elapsedAtLap: TimeInterval
    var label: String?
}

struct SessionRecord: Sendable, Identifiable, Hashable {
    let id: UUID
    let stopwatchID: UUID
    let start: Date
    var end: Date?            // nil = still running
    var note: String?
    var wasInterrupted: Bool
    var laps: [LapRecord]

    func overlaps(_ interval: DateInterval) -> Bool {
        start < interval.end && (end ?? start) >= interval.start
    }
}

struct ExportRow: Sendable {
    let stopwatchName: String
    let colorName: String
    let tags: [String]
    let session: SessionRecord
}

struct LoadResult: Sendable {
    let stopwatches: [StopwatchSnapshot]
    let recoveredSessions: Int
    let error: String?
}

/// Live, in-memory state of one stopwatch. A plain value type: no timers, no references.
struct StopwatchModel: Identifiable, Equatable {
    let id: UUID
    var name: String
    var color: PastelColor
    var tags: [String]
    var dailyGoalSeconds: Int?
    var sortOrder: Int
    var createdAt: Date
    /// Stopwatch value from completed runs, for the day `accumulatedDay` (PRD §5.1: the
    /// displayed value is *today's* time since the last reset; it rolls over at midnight).
    var accumulatedSeconds: TimeInterval
    var accumulatedDay: Date

    // Run state — non-nil only while running.
    var runStartMono: TimeInterval?   // monotonic start of the current run (session length)
    var countStartMono: TimeInterval? // where the *displayed* value counts from: the run start,
                                      // or the most recent midnight if the run crossed one
    var runStartWall: Date?           // wall-clock start, used for session records
    var currentSessionID: UUID?

    var isRunning: Bool { runStartMono != nil }

    init(id: UUID = UUID(), name: String, color: PastelColor, tags: [String] = [],
         dailyGoalSeconds: Int? = nil, sortOrder: Int, createdAt: Date, accumulatedSeconds: TimeInterval = 0,
         accumulatedDay: Date? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.tags = tags
        self.dailyGoalSeconds = dailyGoalSeconds
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.accumulatedSeconds = accumulatedSeconds
        self.accumulatedDay = accumulatedDay ?? createdAt
    }

    init(snapshot s: StopwatchSnapshot) {
        let value = s.accumulatedSeconds.isFinite ? max(0, s.accumulatedSeconds) : 0
        self.init(id: s.id, name: s.name, color: PastelColor(name: s.colorName), tags: s.tags,
                  dailyGoalSeconds: s.dailyGoalSeconds, sortOrder: s.sortOrder,
                  createdAt: s.createdAt, accumulatedSeconds: value, accumulatedDay: s.accumulatedDay)
    }

    var snapshot: StopwatchSnapshot {
        StopwatchSnapshot(id: id, name: name, colorName: color.rawValue, tags: tags,
                          dailyGoalSeconds: dailyGoalSeconds, sortOrder: sortOrder,
                          createdAt: createdAt, accumulatedSeconds: accumulatedSeconds,
                          accumulatedDay: accumulatedDay)
    }

    /// Length of the current run (0 when paused).
    func sessionElapsed(at now: TimeInterval) -> TimeInterval {
        guard let start = runStartMono else { return 0 }
        return max(0, now - start)
    }

    /// Displayed stopwatch value: one subtraction + one addition. Never tick-counted.
    func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let from = countStartMono ?? runStartMono else { return accumulatedSeconds }
        return accumulatedSeconds + max(0, now - from)
    }
}

struct PomodoroState: Equatable {
    enum Phase: String { case work, rest }
    var phase: Phase = .work
    /// Remaining time while *not* counting down.
    var remaining: TimeInterval
    /// Monotonic deadline while counting down (only while the stopwatch runs).
    var deadline: TimeInterval?
    /// A phase ended and auto-start is off: waiting for the user.
    var awaitingStart = false

    func remaining(at now: TimeInterval) -> TimeInterval {
        guard let deadline else { return remaining }
        return max(0, deadline - now)
    }
}

enum PetalError: LocalizedError {
    case persistenceUnavailable
    var errorDescription: String? { "Petal's data store isn't available." }
}

// MARK: - 4. Day math & CSV export

enum DayMath {
    /// Splits [start, end) into per-calendar-day chunks. DST-safe (23h/25h days).
    static func split(start: Date, end: Date, calendar: Calendar) -> [(day: Date, seconds: TimeInterval)] {
        guard end > start else { return [] }
        var out: [(day: Date, seconds: TimeInterval)] = []
        var cursor = start
        var iterations = 0
        while cursor < end && iterations < 10_000 {
            iterations += 1
            let dayStart = calendar.startOfDay(for: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart), next > cursor else {
                out.append((dayStart, end.timeIntervalSince(cursor)))
                break
            }
            let segmentEnd = min(next, end)
            out.append((dayStart, segmentEnd.timeIntervalSince(cursor)))
            cursor = segmentEnd
        }
        return out
    }

    static func overlap(start: Date, end: Date, from: Date, to: Date) -> TimeInterval {
        max(0, min(end, to).timeIntervalSince(max(start, from)))
    }

    static func dayInterval(_ date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    /// Current Monday–Sunday week (PRD §6.2.2), regardless of the locale's first weekday.
    static func weekInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        var cal = calendar
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 7 * 86_400)
    }

    static func days(in week: DateInterval, calendar: Calendar) -> [DateInterval] {
        var result: [DateInterval] = []
        var d = week.start
        for _ in 0..<7 {
            let next = calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400)
            result.append(DateInterval(start: d, end: next))
            d = next
        }
        return result
    }
}

enum ExportManager {
    // PRD-DEVIATION: an extra trailing `interrupted` column flags sessions that were
    // closed by crash recovery. The nine PRD columns are unchanged and in order.
    static let columns = ["stopwatch_name", "color", "tag", "date", "start_time", "end_time",
                          "duration_seconds", "note", "laps", "interrupted"]

    /// RFC 4180 quoting plus spreadsheet-formula-injection protection: a text cell that
    /// begins with = + - @ tab or CR is prefixed with an apostrophe so Excel/Numbers
    /// never evaluate a note like "=HYPERLINK(...)".
    static func escape(_ raw: String) -> String {
        var s = raw
        if let first = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            s = "'" + s
        }
        let needsQuotes = s.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        if needsQuotes {
            s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    static func csv(rows: [ExportRow], now: Date, timeZone: TimeZone = .current) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]

        var out = columns.joined(separator: ",") + "\r\n"
        for row in rows {
            let s = row.session
            let duration = max(0, (s.end ?? now).timeIntervalSince(s.start))
            let laps = s.laps.enumerated().map { index, lap in
                "\(lap.label ?? "Lap \(index + 1)") \(TimeFormatter.clock(lap.elapsedAtLap))"
            }.joined(separator: " | ")
            let fields = [
                escape(row.stopwatchName),
                escape(row.colorName),
                escape(row.tags.joined(separator: "; ")),
                dayFormatter.string(from: s.start),
                iso.string(from: s.start),
                s.end.map { iso.string(from: $0) } ?? "",
                String(Int(duration.rounded())),
                escape(s.note ?? ""),
                escape(laps),
                s.wasInterrupted ? "true" : "false",
            ]
            out += fields.joined(separator: ",") + "\r\n"
        }
        return out
    }

    /// Writes to ~/Downloads/petal_export_YYYY-MM-DD.csv, never overwriting an existing file.
    static func write(_ csv: String, date: Date, directory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let dir = try directory ?? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let base = "petal_export_\(f.string(from: date))"
        var url = dir.appendingPathComponent(base + ".csv")
        var n = 2
        while fm.fileExists(atPath: url.path) && n < 1000 {
            url = dir.appendingPathComponent("\(base) (\(n)).csv")
            n += 1
        }
        // UTF-8 BOM so Excel opens non-ASCII names/notes correctly.
        try Data(("\u{FEFF}" + csv).utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}

// MARK: - 5. Persistence (SwiftData)

@Model
final class StopwatchEntity {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorName: String
    var tags: [String]
    var dailyGoalSeconds: Int?
    var sortOrder: Int
    var createdAt: Date
    /// Stopwatch value at the last state transition (so a relaunch shows the same time).
    var accumulatedSeconds: Double = 0
    var accumulatedDay: Date?
    /// Soft delete marker (PRD §5.3). Purged after 30 days.
    var deletedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \SessionEntity.stopwatch)
    var sessions: [SessionEntity] = []

    init(snapshot s: StopwatchSnapshot) {
        id = s.id
        name = s.name
        colorName = s.colorName
        tags = s.tags
        dailyGoalSeconds = s.dailyGoalSeconds
        sortOrder = s.sortOrder
        createdAt = s.createdAt
        accumulatedSeconds = s.accumulatedSeconds
        accumulatedDay = s.accumulatedDay
    }

    func apply(_ s: StopwatchSnapshot) {
        name = s.name
        colorName = s.colorName
        tags = s.tags
        dailyGoalSeconds = s.dailyGoalSeconds
        sortOrder = s.sortOrder
        accumulatedSeconds = s.accumulatedSeconds
        accumulatedDay = s.accumulatedDay
    }

    var snapshot: StopwatchSnapshot {
        StopwatchSnapshot(id: id, name: name, colorName: colorName, tags: tags,
                          dailyGoalSeconds: dailyGoalSeconds, sortOrder: sortOrder,
                          createdAt: createdAt, accumulatedSeconds: accumulatedSeconds,
                          accumulatedDay: accumulatedDay)
    }
}

@Model
final class SessionEntity {
    @Attribute(.unique) var id: UUID
    var stopwatchID: UUID
    var startTime: Date
    var endTime: Date?            // nil = open (crash guard looks for these)
    var note: String?
    var wasInterrupted: Bool = false
    var stopwatch: StopwatchEntity?
    @Relationship(deleteRule: .cascade, inverse: \LapEntity.session)
    var laps: [LapEntity] = []

    init(id: UUID, stopwatchID: UUID, startTime: Date) {
        self.id = id
        self.stopwatchID = stopwatchID
        self.startTime = startTime
    }

    var record: SessionRecord {
        SessionRecord(id: id, stopwatchID: stopwatchID, start: startTime, end: endTime, note: note,
                      wasInterrupted: wasInterrupted,
                      laps: laps.sorted { $0.timestamp < $1.timestamp }.map(\.record))
    }
}

@Model
final class LapEntity {
    @Attribute(.unique) var id: UUID
    var sessionID: UUID
    var timestamp: Date
    var elapsedAtLap: Double
    var label: String?
    var session: SessionEntity?

    init(record r: LapRecord) {
        id = r.id
        sessionID = r.sessionID
        timestamp = r.timestamp
        elapsedAtLap = r.elapsedAtLap
        label = r.label
    }

    var record: LapRecord {
        LapRecord(id: id, sessionID: sessionID, timestamp: timestamp, elapsedAtLap: elapsedAtLap, label: label)
    }
}

enum PetalSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [StopwatchEntity.self, SessionEntity.self, LapEntity.self] }
}

/// Future schema changes: add PetalSchemaV2 + a MigrationStage here (PRD §12).
enum PetalMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PetalSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum PersistenceController {
    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: PetalSchemaV1.self)
        // cloudKitDatabase: .none — local only, never touches the network (PRD §5.3, §14).
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: PetalMigrationPlan.self, configurations: [config])
    }
}

/// Every persistence request. They are applied strictly in the order they were enqueued,
/// so e.g. "start session" can never be overtaken by "end session".
enum PersistOp: Sendable {
    case load(heartbeat: Date?, now: Date, today: DateInterval, reply: @Sendable (LoadResult) -> Void)
    case upsertStopwatch(StopwatchSnapshot)
    case softDelete(id: UUID, at: Date)
    case startSession(id: UUID, stopwatchID: UUID, start: Date)
    case endSession(id: UUID, end: Date)
    case addLap(LapRecord)
    case setNote(sessionID: UUID, note: String?)
    case fetchSessions(reply: @Sendable ([SessionRecord]) -> Void)
    case fetchExport(reply: @Sendable ([ExportRow]) -> Void)
    case deleteAll
    case barrier(@Sendable () -> Void)
}

/// Owns the only ModelContext that writes. Runs on its own serial executor, never the main thread.
@ModelActor
actor PersistenceActor {
    func apply(_ op: PersistOp) {
        modelContext.autosaveEnabled = false   // explicit saves only, on state transitions
        do {
            switch op {
            case let .load(heartbeat, now, today, reply):
                let result = try loadAndRecover(heartbeat: heartbeat, now: now, today: today)
                reply(result)
                return
            case let .upsertStopwatch(snapshot):
                if let existing = try fetchStopwatch(snapshot.id) {
                    existing.apply(snapshot)
                } else {
                    modelContext.insert(StopwatchEntity(snapshot: snapshot))
                }
            case let .softDelete(id, at):
                try fetchStopwatch(id)?.deletedAt = at
            case let .startSession(id, stopwatchID, start):
                let session = SessionEntity(id: id, stopwatchID: stopwatchID, startTime: start)
                modelContext.insert(session)
                session.stopwatch = try fetchStopwatch(stopwatchID)
            case let .endSession(id, end):
                if let session = try fetchSession(id) {
                    session.endTime = max(end, session.startTime)
                }
            case let .addLap(record):
                let lap = LapEntity(record: record)
                modelContext.insert(lap)
                lap.session = try fetchSession(record.sessionID)
            case let .setNote(sessionID, note):
                try fetchSession(sessionID)?.note = note
            case let .fetchSessions(reply):
                let records = try modelContext
                    .fetch(FetchDescriptor<SessionEntity>(sortBy: [SortDescriptor(\.startTime)]))
                    .map(\.record)
                reply(records)
                return
            case let .fetchExport(reply):
                reply(try exportRows())
                return
            case .deleteAll:
                // Object-level deletes (not batch `delete(model:)`, which bypasses the context
                // and can fail relationship constraints). Children first, then owners.
                try modelContext.fetch(FetchDescriptor<LapEntity>()).forEach { modelContext.delete($0) }
                try modelContext.fetch(FetchDescriptor<SessionEntity>()).forEach { modelContext.delete($0) }
                try modelContext.fetch(FetchDescriptor<StopwatchEntity>()).forEach { modelContext.delete($0) }
            case let .barrier(done):
                try saveIfNeeded()
                done()
                return
            }
            try saveIfNeeded()
        } catch {
            petalLog.error("Persistence error: \(error.localizedDescription, privacy: .public)")
            // Replies must always fire exactly once so no caller ever hangs.
            switch op {
            case let .load(_, _, _, reply):
                reply(LoadResult(stopwatches: [], recoveredSessions: 0, error: error.localizedDescription))
            case let .fetchSessions(reply): reply([])
            case let .fetchExport(reply): reply([])
            case let .barrier(done): done()
            default: break
            }
        }
    }

    private func saveIfNeeded() throws {
        if modelContext.hasChanges { try modelContext.save() }
    }

    private func fetchStopwatch(_ id: UUID) throws -> StopwatchEntity? {
        var d = FetchDescriptor<StopwatchEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func fetchSession(_ id: UUID) throws -> SessionEntity? {
        var d = FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    /// `today` comes from the store's calendar, so the actor never needs its own (which could
    /// disagree with the store's about where "today" starts).
    private func loadAndRecover(heartbeat: Date?, now: Date, today: DateInterval) throws -> LoadResult {
        // 1. Purge stopwatches soft-deleted more than 30 days ago (and their sessions).
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let deleted = try modelContext.fetch(FetchDescriptor<StopwatchEntity>(predicate: #Predicate { $0.deletedAt != nil }))
        for entity in deleted where (entity.deletedAt ?? now) < cutoff {
            let stopwatchID = entity.id
            let sessions = try modelContext.fetch(FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.stopwatchID == stopwatchID }))
            sessions.forEach { modelContext.delete($0) }
            modelContext.delete(entity)
        }

        // 2. Crash guard (PRD §5.3).
        // PRD-DEVIATION: the PRD closes orphaned sessions at *launch time*, which would
        // credit every hour the app was dead (possibly days). Instead the app writes a
        // cheap heartbeat to UserDefaults every 30 s while anything runs, and orphaned
        // sessions are closed at the last heartbeat — losing at most ~30 s on a crash.
        let open = try modelContext.fetch(FetchDescriptor<SessionEntity>(predicate: #Predicate { $0.endTime == nil }))
        for session in open {
            let end = max(session.startTime, min(heartbeat ?? session.startTime, now))
            session.endTime = end
            session.wasInterrupted = true
            // Only the part of the orphaned run that fell on *today* belongs to today's value.
            if let owner = try fetchStopwatch(session.stopwatchID) {
                let todayPortion = DayMath.overlap(start: session.startTime, end: end,
                                                   from: today.start, to: .distantFuture)
                if let day = owner.accumulatedDay, today.contains(day) {
                    owner.accumulatedSeconds += todayPortion
                } else {
                    owner.accumulatedSeconds = todayPortion
                    owner.accumulatedDay = today.start
                }
            }
        }

        // Daily rollover for anything last touched on an earlier day (PRD §5.1 / §6.10).
        let live = try modelContext.fetch(FetchDescriptor<StopwatchEntity>(predicate: #Predicate { $0.deletedAt == nil }))
        for entity in live {
            if let day = entity.accumulatedDay, today.contains(day) { continue }
            entity.accumulatedSeconds = 0
            entity.accumulatedDay = today.start
        }
        try saveIfNeeded()

        // 3. Load live stopwatches only — sessions stay on disk until needed.
        let descriptor = FetchDescriptor<StopwatchEntity>(predicate: #Predicate { $0.deletedAt == nil },
                                                          sortBy: [SortDescriptor(\.sortOrder)])
        let items = try modelContext.fetch(descriptor).map(\.snapshot)
        return LoadResult(stopwatches: items, recoveredSessions: open.count, error: nil)
    }

    private func exportRows() throws -> [ExportRow] {
        let stopwatches = try modelContext.fetch(FetchDescriptor<StopwatchEntity>())
        var byID: [UUID: StopwatchEntity] = [:]
        for s in stopwatches { byID[s.id] = s }
        let sessions = try modelContext.fetch(FetchDescriptor<SessionEntity>(sortBy: [SortDescriptor(\.startTime)]))
        return sessions.map { session in
            let owner = byID[session.stopwatchID]
            return ExportRow(stopwatchName: owner?.name ?? "(deleted)",
                             colorName: owner?.colorName ?? "",
                             tags: owner?.tags ?? [],
                             session: session.record)
        }
    }
}

/// FIFO pipe from the main thread to the persistence actor.
///
/// Why not just `Task { await actor.x() }`? Separate Tasks are not guaranteed to run in
/// creation order. A single AsyncStream consumer is, so writes can never be reordered.
final class PersistenceQueue: @unchecked Sendable {
    private let continuation: AsyncStream<PersistOp>.Continuation

    init(container: ModelContainer) {
        let (stream, continuation) = AsyncStream<PersistOp>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task.detached(priority: .utility) {
            // Created inside the detached task on purpose: a @ModelActor constructed on
            // the main thread would execute its work on the main thread.
            let actor = PersistenceActor(modelContainer: container)
            for await op in stream {
                await actor.apply(op)
            }
        }
    }

    func enqueue(_ op: PersistOp) {
        continuation.yield(op)
    }
}

// MARK: - 6. Settings & shortcuts

struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifierFlags: UInt
    var key: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    static func controlOption(_ keyCode: Int, _ key: String) -> KeyCombo {
        KeyCombo(keyCode: UInt32(keyCode),
                 modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue,
                 key: key)
    }

    static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return chars.isEmpty ? "#\(event.keyCode)" : chars
        }
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePopover, startPause, newStopwatch, lap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePopover: return "Toggle popover"
        case .startPause: return "Start/Pause"
        case .newStopwatch: return "New stopwatch"
        case .lap: return "Lap"
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .togglePopover: return 1
        case .startPause: return 2
        case .newStopwatch: return 3
        case .lap: return 4
        }
    }

    // PRD-AMBIGUITY: ⌃⌥Space is also macOS's default "Select next input source"
    // shortcut. If you use multiple keyboard layouts, rebind it in Preferences.
    var defaultCombo: KeyCombo {
        switch self {
        case .togglePopover: return .controlOption(kVK_Space, "Space")
        case .startPause: return .controlOption(kVK_ANSI_S, "S")
        case .newStopwatch: return .controlOption(kVK_ANSI_N, "N")
        case .lap: return .controlOption(kVK_ANSI_L, "L")
        }
    }
}

enum PomodoroSound: String, CaseIterable, Identifiable {
    case none, chime, beep
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum SettingsKeys {
    static let menuBarShowsTime = "menuBarShowsTime"
    static let compactUnderHour = "compactUnderHour"
    static let dailySummaryEnabled = "dailySummaryEnabled"
    static let summaryMinutes = "summaryMinutes"
    static let goalAlertsEnabled = "goalAlertsEnabled"
    static let pomodoroWork = "pomodoroWorkMinutes"
    static let pomodoroBreak = "pomodoroBreakMinutes"
    static let pomodoroAutoStart = "pomodoroAutoStart"
    static let pomodoroSound = "pomodoroSound"
    static let popoverWide = "popoverWide"
    static let reduceAnimations = "reduceAnimations"
    static let shortcuts = "shortcuts"
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Change { case menuBar, shortcuts, summary, recording }

    private let defaults: UserDefaults
    var onChange: ((Change) -> Void)?

    var menuBarShowsTime: Bool {
        didSet { defaults.set(menuBarShowsTime, forKey: SettingsKeys.menuBarShowsTime); onChange?(.menuBar) }
    }
    var compactUnderHour: Bool {
        didSet { defaults.set(compactUnderHour, forKey: SettingsKeys.compactUnderHour); onChange?(.menuBar) }
    }
    // PRD-AMBIGUITY: the PRD mock shows this ticked, but also says permission is only
    // requested when the user *enables* it. Defaulting to off honours the second rule.
    var dailySummaryEnabled: Bool {
        didSet { defaults.set(dailySummaryEnabled, forKey: SettingsKeys.dailySummaryEnabled); onChange?(.summary) }
    }
    /// Minutes after local midnight (default 19:00).
    var summaryMinutes: Int {
        didSet { defaults.set(summaryMinutes, forKey: SettingsKeys.summaryMinutes); onChange?(.summary) }
    }
    var goalAlertsEnabled: Bool {
        didSet { defaults.set(goalAlertsEnabled, forKey: SettingsKeys.goalAlertsEnabled) }
    }
    var pomodoroWorkMinutes: Int {
        didSet { defaults.set(pomodoroWorkMinutes, forKey: SettingsKeys.pomodoroWork) }
    }
    var pomodoroBreakMinutes: Int {
        didSet { defaults.set(pomodoroBreakMinutes, forKey: SettingsKeys.pomodoroBreak) }
    }
    var pomodoroAutoStart: Bool {
        didSet { defaults.set(pomodoroAutoStart, forKey: SettingsKeys.pomodoroAutoStart) }
    }
    var pomodoroSound: PomodoroSound {
        didSet { defaults.set(pomodoroSound.rawValue, forKey: SettingsKeys.pomodoroSound) }
    }
    var popoverWide: Bool {
        didSet { defaults.set(popoverWide, forKey: SettingsKeys.popoverWide) }
    }
    var reduceAnimations: Bool {
        didSet { defaults.set(reduceAnimations, forKey: SettingsKeys.reduceAnimations) }
    }
    private(set) var shortcuts: [ShortcutAction: KeyCombo]
    /// Actions whose hotkey could not be registered (taken by another app or duplicated).
    var shortcutFailures: Set<String> = []
    /// The action whose shortcut is being recorded. Global hotkeys are suspended meanwhile,
    /// otherwise an existing binding would swallow the very keys being recorded.
    var recordingAction: ShortcutAction? {
        didSet { if oldValue != recordingAction { onChange?(.recording) } }
    }

    static let selectionKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                    kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]

    /// Title of whatever already uses `combo` (another action or ⌃⌥1…8), if anything.
    func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> String? {
        func same(_ a: KeyCombo, _ b: KeyCombo) -> Bool {
            a.keyCode == b.keyCode && a.carbonModifiers == b.carbonModifiers
        }
        for other in ShortcutAction.allCases where other != action && same(self.combo(for: other), combo) {
            return other.title
        }
        for (i, code) in Self.selectionKeyCodes.enumerated() where same(.controlOption(code, ""), combo) {
            return "Select timer \(i + 1)"
        }
        return nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            SettingsKeys.menuBarShowsTime: true,
            SettingsKeys.compactUnderHour: true,
            SettingsKeys.dailySummaryEnabled: false,
            SettingsKeys.summaryMinutes: 19 * 60,
            SettingsKeys.goalAlertsEnabled: true,
            SettingsKeys.pomodoroWork: 25,
            SettingsKeys.pomodoroBreak: 5,
            SettingsKeys.pomodoroAutoStart: false,
            SettingsKeys.pomodoroSound: PomodoroSound.chime.rawValue,
            SettingsKeys.popoverWide: false,
            SettingsKeys.reduceAnimations: false,
        ])
        menuBarShowsTime = defaults.bool(forKey: SettingsKeys.menuBarShowsTime)
        compactUnderHour = defaults.bool(forKey: SettingsKeys.compactUnderHour)
        dailySummaryEnabled = defaults.bool(forKey: SettingsKeys.dailySummaryEnabled)
        summaryMinutes = min(max(defaults.integer(forKey: SettingsKeys.summaryMinutes), 0), 24 * 60 - 1)
        goalAlertsEnabled = defaults.bool(forKey: SettingsKeys.goalAlertsEnabled)
        pomodoroWorkMinutes = max(1, defaults.integer(forKey: SettingsKeys.pomodoroWork))
        pomodoroBreakMinutes = max(1, defaults.integer(forKey: SettingsKeys.pomodoroBreak))
        pomodoroAutoStart = defaults.bool(forKey: SettingsKeys.pomodoroAutoStart)
        pomodoroSound = PomodoroSound(rawValue: defaults.string(forKey: SettingsKeys.pomodoroSound) ?? "") ?? .chime
        popoverWide = defaults.bool(forKey: SettingsKeys.popoverWide)
        reduceAnimations = defaults.bool(forKey: SettingsKeys.reduceAnimations)

        var loaded: [ShortcutAction: KeyCombo] = [:]
        if let data = defaults.data(forKey: SettingsKeys.shortcuts),
           let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (key, combo) in stored {
                if let action = ShortcutAction(rawValue: key) { loaded[action] = combo }
            }
        }
        shortcuts = loaded
    }

    func combo(for action: ShortcutAction) -> KeyCombo {
        shortcuts[action] ?? action.defaultCombo
    }

    func setCombo(_ combo: KeyCombo, for action: ShortcutAction) {
        shortcuts[action] = combo
        persistShortcuts()
    }

    func resetShortcuts() {
        shortcuts = [:]
        persistShortcuts()
    }

    private func persistShortcuts() {
        let dict = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { defaults.set(data, forKey: SettingsKeys.shortcuts) }
        onChange?(.shortcuts)
    }
}

// MARK: - 7. Store (the timer state machine)

enum StoreKeys {
    static let selected = "selectedStopwatchID"
    static let heartbeat = "heartbeat"
    static let onboarded = "didOnboard"
    static let goalNotified = "goalNotifiedDays"
}

/// Single source of truth for live stopwatch state.
///
/// Performance design (PRD §2):
/// • ONE repeating 1 Hz Timer, alive only while ≥1 stopwatch runs. Idle = zero timers.
/// • The tick is phase-aligned so it lands just after the displayed stopwatch crosses a
///   whole second — the menu bar never shows a stale second and never skips one.
/// • Elapsed time is computed from a monotonic clock, never accumulated from ticks.
/// • SwiftUI is only invalidated (via `displayTick`) while the popover is visible;
///   with the popover closed, a tick only rewrites the menu bar string if it changed.
@MainActor
@Observable
final class StopwatchStore {
    // MARK: Observable state
    private(set) var stopwatches: [StopwatchModel] = []
    private(set) var selectedID: UUID?
    private(set) var isLoaded = false
    private(set) var statsLoaded = false
    private(set) var displayTick: UInt64 = 0
    private(set) var popoverVisible = false
    var route: UUID? {               // non-nil → Detail view for that stopwatch
        didSet { if oldValue != route { realignTimer() } }
    }
    var renameRequestID: UUID?       // Detail view should start renaming on appear
    var showOnboardingTip = false
    private(set) var persistenceError: String?
    private(set) var pomodoro: [UUID: PomodoroState] = [:]
    private(set) var goalFlash: [UUID: Date] = [:]

    // Aggregates (loaded shortly after launch, then maintained incrementally)
    private(set) var dayTotals: [UUID: [Date: TimeInterval]] = [:]
    private(set) var allTimeCompleted: [UUID: TimeInterval] = [:]
    private(set) var sessionCounts: [UUID: Int] = [:]
    private(set) var completedToday: [SessionRecord] = []
    private(set) var openLaps: [UUID: [LapRecord]] = [:]     // keyed by session id
    private(set) var openNotes: [UUID: String] = [:]         // keyed by session id

    // MARK: Plumbing (not observed)
    let settings: AppSettings
    private let persistence: PersistenceQueue?
    private let defaults: UserDefaults
    private let sideEffects: Bool          // false in unit tests
    @ObservationIgnored var clock: () -> TimeInterval = MonoClock.now
    @ObservationIgnored var wallClock: () -> Date = { Date() }
    @ObservationIgnored var calendar: Calendar = .autoupdatingCurrent
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var napActivity: NSObjectProtocol?
    @ObservationIgnored private var ticksSinceHeartbeat = 0
    @ObservationIgnored private var currentDay: Date = .distantPast
    @ObservationIgnored private var lastMenuTitle: String?
    @ObservationIgnored private var pendingGoalHaptic = false
    @ObservationIgnored private var statsBuffer: [SessionRecord]?
    @ObservationIgnored private var statsGeneration = 0
    @ObservationIgnored private var pomodoroTimers: [UUID: DispatchSourceTimer] = [:]
    @ObservationIgnored private var pomodoroGeneration: [UUID: Int] = [:]
    @ObservationIgnored private var summaryTimer: DispatchSourceTimer?
    /// Consecutive qualifying days ending *yesterday*; today is always computed live.
    @ObservationIgnored private var streakCache: [UUID: Int] = [:]
    /// In-memory mirror of the UserDefaults goal-notified map (read once, not every tick).
    @ObservationIgnored private var goalNotifiedCache: [String: Double]?

    // Wired by AppDelegate / StatusBarController
    @ObservationIgnored var onMenuBarTitle: ((String) -> Void)?
    @ObservationIgnored var onFirstLaunch: (() -> Void)?
    @ObservationIgnored var onOpenHistory: (() -> Void)?
    @ObservationIgnored var onRequestKeyboardFocus: (() -> Void)?

    /// `sideEffects: false` (tests) disables haptics, notifications, App Nap changes and
    /// the deferred stats load, while still allowing a real persistence queue.
    init(persistence: PersistenceQueue?, settings: AppSettings, defaults: UserDefaults = .standard,
         sideEffects: Bool? = nil) {
        self.persistence = persistence
        self.settings = settings
        self.defaults = defaults
        self.sideEffects = sideEffects ?? (persistence != nil)
    }

    /// Resolves once every persistence operation enqueued so far has been applied.
    func flush() async {
        guard let persistence else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            persistence.enqueue(.barrier({ continuation.resume() }))
        }
    }

    // MARK: Lookup

    func model(_ id: UUID) -> StopwatchModel? { stopwatches.first { $0.id == id } }
    private func index(_ id: UUID) -> Int? { stopwatches.firstIndex { $0.id == id } }
    var selected: StopwatchModel? { selectedID.flatMap { model($0) } }
    /// What ⌃⌥S and the right-click menu act on.
    var actionTarget: StopwatchModel? { selected ?? stopwatches.first }
    var anyRunning: Bool { stopwatches.contains { $0.isRunning } }
    /// Test/diagnostic hook: true iff the single shared display timer exists.
    var hasDisplayTimer: Bool { timer != nil }

    /// Current monotonic time. Reading `displayTick` subscribes SwiftUI views to the 1 Hz refresh.
    func now() -> TimeInterval {
        _ = displayTick
        return clock()
    }

    func elapsed(_ sw: StopwatchModel) -> TimeInterval { value(sw, at: now()) }

    /// The displayed stopwatch value (PRD §5.1: today's time since the last reset).
    ///
    /// Computed day-aware at read time, so it is correct even when no tick has run since
    /// midnight (Mac asleep, callback delayed, or nothing running): a value stored for an
    /// earlier day shows only the live run's overlap with today.
    func value(_ sw: StopwatchModel, at now: TimeInterval) -> TimeInterval {
        let wall = wallClock()
        guard calendar.isDate(sw.accumulatedDay, inSameDayAs: wall) else {
            return liveOverlap(sw, from: calendar.startOfDay(for: wall), to: .distantFuture, now: now)
        }
        return sw.elapsed(at: now)
    }

    func reportPersistenceError(_ message: String) { persistenceError = message }

    // MARK: Loading

    func load() {
        guard let persistence else {
            finishLoad(LoadResult(stopwatches: [], recoveredSessions: 0, error: nil))
            return
        }
        let heartbeat = defaults.object(forKey: StoreKeys.heartbeat) as? Date
        let now = wallClock()
        persistence.enqueue(.load(heartbeat: heartbeat, now: now, today: DayMath.dayInterval(now, calendar: calendar), reply: { result in
            Task { @MainActor in self.finishLoad(result) }
        }))
    }

    func finishLoad(_ result: LoadResult) {
        if let error = result.error {
            persistenceError = "Couldn't read saved timers (\(error)). Changes may not be saved."
        }
        stopwatches = result.stopwatches.map(StopwatchModel.init(snapshot:)).sorted { $0.sortOrder < $1.sortOrder }
        if let raw = defaults.string(forKey: StoreKeys.selected), let id = UUID(uuidString: raw), model(id) != nil {
            selectedID = id
        } else {
            selectedID = stopwatches.first?.id
        }
        isLoaded = true
        currentDay = calendar.startOfDay(for: wallClock())

        if !defaults.bool(forKey: StoreKeys.onboarded) {
            defaults.set(true, forKey: StoreKeys.onboarded)
            if stopwatches.isEmpty && result.error == nil {
                create(name: "Research", color: .blush)
                showOnboardingTip = true
                onFirstLaunch?()
            }
        }
        if result.recoveredSessions > 0 {
            petalLog.notice("Closed \(result.recoveredSessions) session(s) left open by an unexpected quit")
        }
        refreshMenuBar()
        // Aggregates are loaded after launch completes so launch stays well under 400 ms.
        if sideEffects {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated { self?.loadStats() }
            }
        } else {
            loadStats()
        }
        rescheduleDailySummary()
    }

    /// (Re)builds per-day totals from every stored session.
    ///
    /// Sessions completed while the fetch is in flight are buffered and merged when it
    /// returns; the fetch saw them as still open (FIFO ordering), so nothing is counted twice.
    func loadStats() {
        guard let persistence else {
            statsBuffer = nil
            statsLoaded = true
            return
        }
        statsGeneration += 1
        let generation = statsGeneration
        statsBuffer = []
        persistence.enqueue(.fetchSessions(reply: { records in
            Task { @MainActor in self.finishStats(records, generation: generation) }
        }))
    }

    private func finishStats(_ records: [SessionRecord], generation: Int) {
        guard generation == statsGeneration else { return }   // a newer reload superseded this one
        dayTotals = [:]
        allTimeCompleted = [:]
        sessionCounts = [:]
        completedToday = []
        streakCache = [:]
        let live = Set(stopwatches.map(\.id))
        for record in records where record.end != nil && live.contains(record.stopwatchID) {
            accumulate(record)
        }
        let buffered = statsBuffer ?? []
        statsBuffer = nil
        buffered.forEach(accumulate)
        statsLoaded = true
        bumpDisplay()
    }

    private func accumulate(_ record: SessionRecord) {
        guard let end = record.end else { return }
        let id = record.stopwatchID
        streakCache[id] = nil
        for part in DayMath.split(start: record.start, end: end, calendar: calendar) {
            dayTotals[id, default: [:]][part.day, default: 0] += part.seconds
        }
        allTimeCompleted[id, default: 0] += max(0, end.timeIntervalSince(record.start))
        sessionCounts[id, default: 0] += 1
        if record.overlaps(todayInterval) { completedToday.append(record) }
    }

    private func recordCompleted(_ record: SessionRecord) {
        if statsBuffer != nil {
            statsBuffer?.append(record)
        } else {
            accumulate(record)
        }
    }

    // MARK: Day math for the UI

    var todayInterval: DateInterval { DayMath.dayInterval(wallClock(), calendar: calendar) }

    /// Portion of the current run that falls inside [from, to).
    func liveOverlap(_ sw: StopwatchModel, from: Date, to: Date, now: TimeInterval) -> TimeInterval {
        guard let wallStart = sw.runStartWall else { return 0 }
        let wallEnd = wallStart.addingTimeInterval(sw.sessionElapsed(at: now))
        return DayMath.overlap(start: wallStart, end: wallEnd, from: from, to: to)
    }

    private func secondsOnDay(_ id: UUID, day: DateInterval, now: TimeInterval) -> TimeInterval {
        let done = dayTotals[id]?[day.start] ?? 0
        guard let sw = model(id) else { return done }
        return done + liveOverlap(sw, from: day.start, to: day.end, now: now)
    }

    func todaySeconds(_ id: UUID) -> TimeInterval { secondsOnDay(id, day: todayInterval, now: now()) }

    func weekSeconds(_ id: UUID) -> TimeInterval {
        let n = now()
        let week = DayMath.weekInterval(containing: wallClock(), calendar: calendar)
        return DayMath.days(in: week, calendar: calendar).reduce(0) { $0 + secondsOnDay(id, day: $1, now: n) }
    }

    func allTimeSeconds(_ id: UUID) -> TimeInterval {
        (allTimeCompleted[id] ?? 0) + (model(id)?.sessionElapsed(at: now()) ?? 0)
    }

    func todayTotal() -> TimeInterval {
        let n = now()
        let day = todayInterval
        return stopwatches.reduce(0) { $0 + secondsOnDay($1.id, day: day, now: n) }
    }

    /// Consecutive days with ≥ 60 s, ending today (if today already qualifies) or yesterday.
    func streak(_ id: UUID) -> Int {
        guard statsLoaded else { return 0 }
        let n = now()
        let today = todayInterval
        let todayCounts = secondsOnDay(id, day: today, now: n) >= 60 ? 1 : 0
        if let past = streakCache[id] { return past + todayCounts }
        // Past days can't change until a run completes or the day rolls over, so the walk is
        // cached; tiles re-render every second while the popover is open.
        var day = today
        var past = 0
        for _ in 0..<3650 {
            guard let prevStart = calendar.date(byAdding: .day, value: -1, to: day.start) else { break }
            day = DayMath.dayInterval(prevStart, calendar: calendar)
            if secondsOnDay(id, day: day, now: n) >= 60 { past += 1 } else { break }
        }
        streakCache[id] = past
        return past + todayCounts
    }

    /// Today's sessions for one stopwatch, newest first, including the open one.
    func todaySessions(_ id: UUID) -> [SessionRecord] {
        var list = completedToday.filter { $0.stopwatchID == id }
        if let sw = model(id), let sid = sw.currentSessionID, let start = sw.runStartWall {
            list.append(SessionRecord(id: sid, stopwatchID: id, start: start, end: nil,
                                      note: openNotes[sid], wasInterrupted: false, laps: openLaps[sid] ?? []))
        }
        return list.sorted { $0.start > $1.start }
    }

    // MARK: Selection

    func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        defaults.set(id?.uuidString, forKey: StoreKeys.selected)
        refreshMenuBar()
        realignTimer()
    }

    func select(position: Int) {
        guard position >= 1, position <= stopwatches.count else { return }
        select(stopwatches[position - 1].id)
    }

    // MARK: State machine  (IDLE → RUNNING ⇄ PAUSED → reset → IDLE)

    func toggle(_ id: UUID, haptic: Bool = true) {
        guard let sw = model(id) else { return }
        if sw.isRunning { pause(id, haptic: haptic) } else { start(id, haptic: haptic) }
    }

    func start(_ id: UUID, haptic: Bool = true) {
        handleDayChange()   // never write state computed against a stale day
        guard let i = index(id), !stopwatches[i].isRunning else { return }   // double-start is a no-op
        let sessionID = UUID()
        let wall = wallClock()
        let mono = clock()
        rollOverIfNeeded(i, now: wall)
        stopwatches[i].runStartMono = mono
        stopwatches[i].countStartMono = mono
        stopwatches[i].runStartWall = wall
        stopwatches[i].currentSessionID = sessionID
        persistence?.enqueue(.startSession(id: sessionID, stopwatchID: id, start: wall))
        // The most recently started stopwatch becomes the selected one.
        selectedID = id
        defaults.set(id.uuidString, forKey: StoreKeys.selected)
        writeHeartbeat()
        pomodoroResume(id)
        updateTimerState()
        realignTimer()
        if haptic { HapticEngine.play(.start) }
    }

    func pause(_ id: UUID, haptic: Bool = true) {
        handleDayChange()   // moves countStartMono to midnight first if a day boundary passed
        guard let i = index(id),
              let startMono = stopwatches[i].runStartMono,
              let startWall = stopwatches[i].runStartWall,
              let sessionID = stopwatches[i].currentSessionID else { return }   // pausing idle is a no-op
        let now = clock()
        let duration = max(0, now - startMono)
        // The displayed value only grows by the part counted since the last midnight rollover.
        let counted = max(0, now - (stopwatches[i].countStartMono ?? startMono))
        stopwatches[i].accumulatedSeconds += counted
        stopwatches[i].accumulatedDay = wallClock()
        stopwatches[i].runStartMono = nil
        stopwatches[i].countStartMono = nil
        stopwatches[i].runStartWall = nil
        stopwatches[i].currentSessionID = nil
        // End = start + monotonic duration, so the record agrees with the stopwatch even
        // if the wall clock was changed mid-session.
        let end = startWall.addingTimeInterval(duration)
        persistence?.enqueue(.endSession(id: sessionID, end: end))
        persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))
        let record = SessionRecord(id: sessionID, stopwatchID: id, start: startWall, end: end,
                                   note: openNotes.removeValue(forKey: sessionID), wasInterrupted: false,
                                   laps: openLaps.removeValue(forKey: sessionID) ?? [])
        recordCompleted(record)
        pomodoroPause(id)
        updateTimerState()
        realignTimer()
        bumpDisplay()
        if haptic { HapticEngine.play(.pause) }
    }

    /// Resets the displayed value. History (sessions) is never touched (PRD §5.3).
    func reset(_ id: UUID, haptic: Bool = true) {
        handleDayChange()
        guard index(id) != nil else { return }
        if model(id)?.isRunning == true { pause(id, haptic: false) }
        guard let i = index(id) else { return }
        stopwatches[i].accumulatedSeconds = 0
        stopwatches[i].accumulatedDay = wallClock()
        persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))
        if pomodoro[id] != nil {
            cancelPomodoroTimer(id)
            pomodoro[id] = PomodoroState(remaining: workInterval)
        }
        refreshMenuBar()
        bumpDisplay()
        if haptic { HapticEngine.play(.reset) }
    }

    func lap(_ id: UUID, haptic: Bool = true) {
        handleDayChange()
        guard let sw = model(id), sw.isRunning, let sessionID = sw.currentSessionID else { return }
        let lap = LapRecord(id: UUID(), sessionID: sessionID, timestamp: wallClock(),
                            elapsedAtLap: value(sw, at: clock()), label: nil)
        openLaps[sessionID, default: []].append(lap)
        persistence?.enqueue(.addLap(lap))
        if haptic { HapticEngine.play(.lap) }
    }

    // MARK: Editing

    @discardableResult
    func create(name: String? = nil, color: PastelColor? = nil, navigate: Bool = false) -> UUID? {
        guard isLoaded else { return nil }
        let used = Set(stopwatches.map(\.color))
        let palette = PastelColor.allCases
        let chosen = color ?? palette.first { !used.contains($0) } ?? palette[stopwatches.count % palette.count]
        let names = Set(stopwatches.map(\.name))
        var n = stopwatches.count + 1
        while names.contains("Timer \(n)") { n += 1 }
        let sw = StopwatchModel(name: name ?? "Timer \(n)", color: chosen,
                                sortOrder: (stopwatches.map(\.sortOrder).max() ?? -1) + 1,
                                createdAt: wallClock(), accumulatedDay: wallClock())
        stopwatches.append(sw)
        persistence?.enqueue(.upsertStopwatch(sw.snapshot))
        if selectedID == nil { select(sw.id) }
        if navigate {
            renameRequestID = sw.id
            route = sw.id
        }
        return sw.id
    }

    func rename(_ id: UUID, to raw: String) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, let i = index(id), stopwatches[i].name != name else { return }
        stopwatches[i].name = name
        persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))
    }

    func setColor(_ id: UUID, _ color: PastelColor) {
        guard let i = index(id), stopwatches[i].color != color else { return }
        stopwatches[i].color = color
        persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))
    }

    /// Tags: trimmed, ≤ 20 chars, ≤ 8 per stopwatch, case-insensitively unique.
    @discardableResult
    func addTag(_ id: UUID, _ raw: String) -> Bool {
        let tag = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        guard !tag.isEmpty, let i = index(id), stopwatches[i].tags.count < 8,
              !stopwatches[i].tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return false }
        stopwatches[i].tags.append(tag)
        persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))
        return true
    }

    func removeTag(_ id: UUID, _ tag: String) {
        guard let i = index(id), stopwatches[i].tags.contains(tag) else { return }
        stopwatches[i].tags.removeAll { $0 == tag }
        persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))
    }

    func setGoal(_ id: UUID, seconds: Int?) {
        guard let i = index(id) else { return }
        let value = seconds.flatMap { $0 > 0 ? min($0, 24 * 3600) : nil }
        guard stopwatches[i].dailyGoalSeconds != value else { return }
        stopwatches[i].dailyGoalSeconds = value
        persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))
        // A new goal gets a fresh notification — unless it's already met, in which case
        // it is marked done silently (it wasn't "just crossed").
        clearGoalNotified(id)
        if let goal = value {
            if statsLoaded && todaySeconds(id) >= Double(goal) { markGoalNotified(id) }
            if settings.goalAlertsEnabled && sideEffects { NotificationService.shared.requestAuthorizationIfNeeded() }
        }
    }

    func delete(_ id: UUID) {
        guard model(id) != nil else { return }
        if model(id)?.isRunning == true { pause(id, haptic: false) }
        cancelPomodoroTimer(id)
        pomodoro[id] = nil
        stopwatches.removeAll { $0.id == id }
        persistence?.enqueue(.softDelete(id: id, at: wallClock()))
        dayTotals[id] = nil
        streakCache[id] = nil
        allTimeCompleted[id] = nil
        sessionCounts[id] = nil
        completedToday.removeAll { $0.stopwatchID == id }
        goalFlash[id] = nil
        clearGoalNotified(id)
        if route == id { route = nil }
        if selectedID == id { select(stopwatches.first?.id) }
        updateTimerState()
        HapticEngine.play(.delete)
    }

    func setNote(sessionID: UUID, stopwatchID: UUID, note raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String? = trimmed.isEmpty ? nil : String(trimmed.prefix(500))
        if model(stopwatchID)?.currentSessionID == sessionID {
            openNotes[sessionID] = note
        } else if let k = completedToday.firstIndex(where: { $0.id == sessionID }) {
            completedToday[k].note = note
        } else if let k = statsBuffer?.firstIndex(where: { $0.id == sessionID }) {
            statsBuffer?[k].note = note
        }
        persistence?.enqueue(.setNote(sessionID: sessionID, note: note))
    }

    func deleteAllData() {
        for sw in stopwatches where sw.isRunning { pause(sw.id, haptic: false) }
        pomodoroTimers.values.forEach { $0.cancel() }
        pomodoroTimers = [:]
        pomodoro = [:]
        stopwatches = []
        route = nil
        select(nil)
        dayTotals = [:]
        allTimeCompleted = [:]
        sessionCounts = [:]
        completedToday = []
        openLaps = [:]
        openNotes = [:]
        goalFlash = [:]
        if statsBuffer != nil { statsBuffer = [] }
        storeGoalNotified([:])
        streakCache = [:]
        persistence?.enqueue(.deleteAll)
        updateTimerState()
        bumpDisplay()
    }

    // MARK: The one shared timer

    private func updateTimerState() {
        if anyRunning {
            if timer == nil { startTimer() }
            beginNapActivity()
        } else {
            timer?.invalidate()
            timer = nil
            endNapActivity()
        }
        refreshMenuBar()
    }

    private func startTimer() {
        let t = Timer(fire: nextAlignedFireDate(), interval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1          // lets macOS coalesce wakeups (energy); still lands after the boundary
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while a menu is being tracked
        timer = t
    }

    /// Re-phases the timer after anything that changes which stopwatch is displayed.
    private func realignTimer() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        startTimer()
    }

    /// Which stopwatch's seconds the tick is phase-locked to: the one open in the Detail view
    /// (its large display is what the user is watching), otherwise the menu bar's.
    private func alignmentTarget() -> StopwatchModel? {
        if popoverVisible, let id = route, let sw = model(id), sw.isRunning { return sw }
        return menuBarStopwatch()
    }

    /// The next moment the aligned stopwatch crosses a whole second, plus 20 ms.
    private func nextAlignedFireDate() -> Date {
        guard let shown = alignmentTarget() else { return Date().addingTimeInterval(1) }
        let e = value(shown, at: clock())
        var delay = (1 - (e - e.rounded(.down))) + 0.02
        if delay > 1 { delay -= 1 }
        return Date().addingTimeInterval(delay)
    }

    func tick() {
        // Day change first: goals/menu bar below must evaluate against the *current* day, and
        // a goal crossed on the first tick after midnight must not have its flash wiped.
        if calendar.startOfDay(for: wallClock()) != currentDay { handleDayChange() }
        let n = clock()
        refreshMenuBar(now: n)
        if popoverVisible { bumpDisplay() }
        checkGoals(now: n)
        checkPomodoroBackstop(now: n)
        ticksSinceHeartbeat += 1
        if ticksSinceHeartbeat >= 30 { writeHeartbeat() }
        // After sleep/wake (or a long stall) the phase can slip; re-align if so.
        if let shown = alignmentTarget(), shown.isRunning {
            let e = value(shown, at: n)
            if e - e.rounded(.down) > 0.3 { realignTimer() }
        }
    }

    private func bumpDisplay() { displayTick &+= 1 }

    private func writeHeartbeat() {
        ticksSinceHeartbeat = 0
        defaults.set(wallClock(), forKey: StoreKeys.heartbeat)
    }

    /// PRD-DEVIATION (energy trade-off, documented): App Nap may throttle a windowless
    /// app's timers to one fire every ~10 s, freezing the menu bar label. While (and only
    /// while) a stopwatch runs, Petal opts out of App Nap. Idle sleep is still allowed.
    private func beginNapActivity() {
        guard napActivity == nil, sideEffects else { return }
        napActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Showing a running stopwatch in the menu bar")
    }

    private func endNapActivity() {
        if let a = napActivity { ProcessInfo.processInfo.endActivity(a) }
        napActivity = nil
    }

    // MARK: Menu bar

    /// Selected if running, otherwise the most recently started running stopwatch.
    func menuBarStopwatch() -> StopwatchModel? {
        if let s = selected, s.isRunning { return s }
        return stopwatches.filter(\.isRunning).max { ($0.runStartMono ?? 0) < ($1.runStartMono ?? 0) }
    }

    func menuBarTitle(now: TimeInterval) -> String {
        guard settings.menuBarShowsTime, let shown = menuBarStopwatch() else { return "" }
        var title = TimeFormatter.menuBar(value(shown, at: now), compactUnderHour: settings.compactUnderHour)
        let running = stopwatches.reduce(0) { $0 + ($1.isRunning ? 1 : 0) }
        if running >= 2 { title += " ·\(running)" }
        return title
    }

    func refreshMenuBar(now: TimeInterval? = nil, force: Bool = false) {
        let title = menuBarTitle(now: now ?? clock())
        guard force || title != lastMenuTitle else { return }
        lastMenuTitle = title
        onMenuBarTitle?(title)
    }

    func settingsChangedMenuBar() {
        refreshMenuBar(force: true)
        realignTimer()
    }

    // MARK: Popover lifecycle

    func popoverWillShow() {
        popoverVisible = true
        handleDayChange()          // nothing may have ticked since midnight if all were idle
        realignTimer()
        bumpDisplay()
        if pendingGoalHaptic {
            pendingGoalHaptic = false
            HapticEngine.play(.goal)
        }
    }

    func popoverDidClose() {
        popoverVisible = false
        route = nil                 // the Summary view is the landing screen every time
        renameRequestID = nil
        showOnboardingTip = false
    }

    // MARK: Goals

    private var todayKey: Double { calendar.startOfDay(for: wallClock()).timeIntervalSince1970 }

    private func goalNotifiedDict() -> [String: Double] {
        if let cached = goalNotifiedCache { return cached }
        let stored = (defaults.dictionary(forKey: StoreKeys.goalNotified) as? [String: Double]) ?? [:]
        goalNotifiedCache = stored
        return stored
    }

    private func storeGoalNotified(_ dict: [String: Double]) {
        goalNotifiedCache = dict
        defaults.set(dict, forKey: StoreKeys.goalNotified)
    }

    func isGoalNotifiedToday(_ id: UUID) -> Bool {
        let dict = goalNotifiedDict()
        return dict[id.uuidString] == todayKey
    }

    private func markGoalNotified(_ id: UUID) {
        var dict = goalNotifiedDict()
        dict[id.uuidString] = todayKey
        storeGoalNotified(dict)
    }

    private func clearGoalNotified(_ id: UUID) {
        var dict = goalNotifiedDict()
        guard dict[id.uuidString] != nil else { return }
        dict[id.uuidString] = nil
        storeGoalNotified(dict)
    }

    private func checkGoals(now: TimeInterval) {
        guard statsLoaded else { return }
        let day = todayInterval
        for sw in stopwatches where sw.isRunning {
            guard let goal = sw.dailyGoalSeconds, goal > 0 else { continue }
            guard secondsOnDay(sw.id, day: day, now: now) >= Double(goal), !isGoalNotifiedToday(sw.id) else { continue }
            markGoalNotified(sw.id)
            goalFlash[sw.id] = wallClock()
            if popoverVisible { HapticEngine.play(.goal) } else { pendingGoalHaptic = true }
            if settings.goalAlertsEnabled && sideEffects {
                NotificationService.shared.post(identifier: "goal-\(sw.id.uuidString)",
                                                title: "Goal reached 🌸",
                                                body: "\(sw.name): \(TimeFormatter.goal(goal)) today.")
            }
        }
    }

    // MARK: Day / clock changes

    func handleDayChange() {
        let day = calendar.startOfDay(for: wallClock())
        guard day != currentDay else { return }
        currentDay = day
        let today = todayInterval
        completedToday.removeAll { !$0.overlaps(today) }
        goalFlash = [:]
        streakCache = [:]
        for i in stopwatches.indices {
            if rollOverIfNeeded(i, now: wallClock()) {
                persistence?.enqueue(.upsertStopwatch(stopwatches[i].snapshot))   // once per day, not per tick
            }
        }
        refreshMenuBar()
        realignTimer()
        bumpDisplay()
    }

    /// PRD §5.1/§6.10: the displayed value is *today's* time since the last reset, so it
    /// returns to zero at midnight. A run that crosses midnight keeps its single session
    /// record (history is split per day separately); only the displayed value restarts,
    /// counting from midnight. Compared by calendar day — not by instant — so changing
    /// time zones never zeroes today's value.
    @discardableResult
    private func rollOverIfNeeded(_ i: Int, now: Date) -> Bool {
        guard !calendar.isDate(stopwatches[i].accumulatedDay, inSameDayAs: now) else { return false }
        let todayStart = calendar.startOfDay(for: now)
        stopwatches[i].accumulatedSeconds = 0
        stopwatches[i].accumulatedDay = now
        if let runMono = stopwatches[i].runStartMono, let runWall = stopwatches[i].runStartWall {
            stopwatches[i].countStartMono = runMono + max(0, todayStart.timeIntervalSince(runWall))
        }
        return true
    }

    func timeZoneChanged() {
        // Day keys depend on the time zone, so rebuild them.
        currentDay = .distantPast
        handleDayChange()
        if isLoaded { loadStats() }
        rescheduleDailySummary()
    }

    func clockChanged() {
        handleDayChange()
        rescheduleDailySummary()
    }

    // MARK: Pomodoro
    //
    // Each active countdown owns a one-shot DispatchSourceTimer on a utility queue that
    // fires once, at the interval's end (PRD §6.7). Its display piggybacks on the shared
    // 1 Hz tick, which is running anyway because the countdown only runs while its
    // stopwatch does. Wall-deadline scheduling keeps counting through sleep, matching the
    // stopwatch. The 1 Hz tick also acts as a backstop in case the source fires late.

    private var workInterval: TimeInterval { TimeInterval(settings.pomodoroWorkMinutes * 60) }
    private var breakInterval: TimeInterval { TimeInterval(settings.pomodoroBreakMinutes * 60) }

    func setPomodoro(_ id: UUID, enabled: Bool) {
        guard model(id) != nil else { return }
        if enabled {
            guard pomodoro[id] == nil else { return }
            pomodoro[id] = PomodoroState(remaining: workInterval)
            if sideEffects { NotificationService.shared.requestAuthorizationIfNeeded() }
            pomodoroResume(id)
        } else {
            cancelPomodoroTimer(id)
            pomodoro[id] = nil
        }
    }

    func startNextPomodoroPhase(_ id: UUID) {
        guard var p = pomodoro[id], p.awaitingStart else { return }
        p.awaitingStart = false
        pomodoro[id] = p
        pomodoroResume(id)
    }

    private func pomodoroResume(_ id: UUID) {
        guard var p = pomodoro[id], p.deadline == nil, !p.awaitingStart, model(id)?.isRunning == true else { return }
        p.deadline = clock() + p.remaining
        pomodoro[id] = p
        schedulePomodoro(id, after: p.remaining)
    }

    private func pomodoroPause(_ id: UUID) {
        guard var p = pomodoro[id], let deadline = p.deadline else { return }
        p.remaining = max(0, deadline - clock())
        p.deadline = nil
        pomodoro[id] = p
        cancelPomodoroTimer(id)
    }

    private func schedulePomodoro(_ id: UUID, after seconds: TimeInterval) {
        cancelPomodoroTimer(id)
        let generation = (pomodoroGeneration[id] ?? 0) + 1
        pomodoroGeneration[id] = generation
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(wallDeadline: .now() + max(0, seconds), leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.pomodoroFired(id, generation: generation) }
        }
        source.resume()
        pomodoroTimers[id] = source
    }

    private func cancelPomodoroTimer(_ id: UUID) {
        pomodoroTimers.removeValue(forKey: id)?.cancel()
        pomodoroGeneration[id] = (pomodoroGeneration[id] ?? 0) + 1   // invalidates any in-flight fire
    }

    private func checkPomodoroBackstop(now: TimeInterval) {
        for (id, p) in pomodoro {
            if let d = p.deadline, now >= d + 1.5 { pomodoroCompleted(id) }
        }
    }

    private func pomodoroFired(_ id: UUID, generation: Int) {
        guard pomodoroGeneration[id] == generation, let p = pomodoro[id], let deadline = p.deadline else { return }
        let n = clock()
        if n < deadline - 1 {                 // fired early (e.g. wall clock moved forward)
            schedulePomodoro(id, after: deadline - n)
            return
        }
        pomodoroCompleted(id)
    }

    private func pomodoroCompleted(_ id: UUID) {
        guard var p = pomodoro[id], p.deadline != nil else { return }
        cancelPomodoroTimer(id)
        let finished = p.phase
        p.phase = finished == .work ? .rest : .work
        p.remaining = p.phase == .work ? workInterval : breakInterval
        p.deadline = nil
        p.awaitingStart = !settings.pomodoroAutoStart
        pomodoro[id] = p
        if settings.pomodoroAutoStart { pomodoroResume(id) }
        bumpDisplay()

        if sideEffects {
            HapticEngine.burst()
            SoundPlayer.play(settings.pomodoroSound)
            let name = model(id)?.name ?? "Petal"
            NotificationService.shared.post(
                identifier: "pomodoro-\(id.uuidString)",
                title: name,
                body: finished == .work ? "Focus interval done — take a break 🎉" : "Break's over — ready to focus?")
        }
    }

    // MARK: Daily summary

    func rescheduleDailySummary() {
        summaryTimer?.cancel()
        summaryTimer = nil
        guard settings.dailySummaryEnabled, sideEffects else { return }
        let now = wallClock()
        let minutes = settings.summaryMinutes
        guard let fire = calendar.nextDate(after: now.addingTimeInterval(1),
                                           matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        // PRD-DEVIATION: macOS can't run code inside a scheduled local notification (a
        // Notification Service Extension only exists for remote pushes). So Petal fires
        // its own wall-clock timer at the chosen time, computes today's totals fresh, and
        // posts the notification immediately.
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(wallDeadline: .now() + max(0, fire.timeIntervalSince(now)), leeway: .seconds(30))
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.fireDailySummary()
                self?.rescheduleDailySummary()
            }
        }
        source.resume()
        summaryTimer = source
    }

    func dailySummaryBody() -> String? {
        let rows = stopwatches.map { ($0.name, todaySeconds($0.id)) }.filter { $0.1 >= 1 }
        guard !rows.isEmpty else { return nil }
        let maxSeconds = rows.map(\.1).max() ?? 1
        let nameWidth = min(14, rows.map { $0.0.count }.max() ?? 0)
        var lines: [String] = rows.map { name, seconds in
            let shown = name.count > nameWidth ? String(name.prefix(nameWidth - 1)) + "…" : name
            let padded = shown.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let filled = max(1, Int((seconds / maxSeconds * 10).rounded()))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
            return "\(padded)  \(TimeFormatter.short(seconds))  \(bar)"
        }
        lines.append(String(repeating: "─", count: 24))
        lines.append("\("Total".padding(toLength: nameWidth, withPad: " ", startingAt: 0))  \(TimeFormatter.short(rows.reduce(0) { $0 + $1.1 }))")
        return lines.joined(separator: "\n")
    }

    private func fireDailySummary() {
        guard statsLoaded, let body = dailySummaryBody() else { return }
        NotificationService.shared.post(identifier: "daily-summary", title: "Petal · Today's summary",
                                        body: body, category: NotificationService.summaryCategory)
    }

    // MARK: History & export

    /// All sessions for the History window, with in-flight sessions resolved against live state.
    func historySessions() async -> [SessionRecord] {
        guard let persistence else { return completedToday + todayOpenSessions() }
        let stored: [SessionRecord] = await withCheckedContinuation { continuation in
            persistence.enqueue(.fetchSessions(reply: { continuation.resume(returning: $0) }))
        }
        let n = clock()
        let completedByID = Dictionary(completedToday.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [SessionRecord] = stored.compactMap { record in
            if record.end != nil { return record }
            if let sw = stopwatches.first(where: { $0.currentSessionID == record.id }), let start = sw.runStartWall {
                var live = record
                live.end = start.addingTimeInterval(sw.sessionElapsed(at: n))
                live.laps = openLaps[record.id] ?? record.laps
                live.note = openNotes[record.id]
                return live
            }
            return completedByID[record.id]   // paused while the fetch was in flight
        }
        let seen = Set(result.map(\.id))
        result += completedToday.filter { !seen.contains($0.id) }
        result += todayOpenSessions().filter { !seen.contains($0.id) }
        return result
    }

    private func todayOpenSessions() -> [SessionRecord] {
        let n = clock()
        return stopwatches.compactMap { sw in
            guard let sid = sw.currentSessionID, let start = sw.runStartWall else { return nil }
            return SessionRecord(id: sid, stopwatchID: sw.id, start: start,
                                 end: start.addingTimeInterval(sw.sessionElapsed(at: n)),
                                 note: openNotes[sid], wasInterrupted: false, laps: openLaps[sid] ?? [])
        }
    }

    func exportCSV() async throws -> URL {
        guard let persistence else { throw PetalError.persistenceUnavailable }
        let rows: [ExportRow] = await withCheckedContinuation { continuation in
            persistence.enqueue(.fetchExport(reply: { continuation.resume(returning: $0) }))
        }
        let now = wallClock()
        return try await Task.detached(priority: .utility) {
            try ExportManager.write(ExportManager.csv(rows: rows, now: now), date: now)
        }.value
    }

    // MARK: Termination

    /// Closes every open session, saves, then calls `done` (with a 3 s safety timeout).
    ///
    /// PRD-AMBIGUITY: running stopwatches are *paused* on quit and are not auto-resumed
    /// on the next launch — otherwise a laptop shut down overnight would appear to
    /// resume "Research" the next morning. The stopwatch value itself is kept.
    func prepareForTermination(_ done: @escaping @MainActor () -> Void) {
        for sw in stopwatches where sw.isRunning { pause(sw.id, haptic: false) }
        writeHeartbeat()
        pomodoroTimers.values.forEach { $0.cancel() }
        pomodoroTimers = [:]
        summaryTimer?.cancel()
        summaryTimer = nil
        guard let persistence else { done(); return }
        var finished = false
        let finish: @MainActor () -> Void = {
            guard !finished else { return }
            finished = true
            done()
        }
        persistence.enqueue(.barrier({ Task { @MainActor in finish() } }))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { finish() } }
    }
}

// MARK: - 8. Services

/// Trackpad haptics. NSHapticFeedbackManager silently does nothing on external mice.
enum HapticEngine {
    enum Event { case start, pause, reset, lap, goal, delete }

    @MainActor
    static func play(_ event: Event) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch event {
        case .start, .pause, .delete: pattern = .generic
        case .reset, .goal: pattern = .alignment
        case .lap: pattern = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    /// Three quick taps for the end of a Pomodoro interval.
    @MainActor
    static func burst() {
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) {
                MainActor.assumeIsolated {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
    }
}

enum SoundPlayer {
    @MainActor
    static func play(_ sound: PomodoroSound) {
        switch sound {
        case .none: break
        case .beep: NSSound.beep()
        case .chime:
            if let chime = NSSound(named: NSSound.Name("Glass")) { chime.play() } else { NSSound.beep() }
        }
    }
}

/// Local notifications. Permission is requested only when the user turns on a feature
/// that needs it — never at launch (PRD §6.8).
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()
    static let summaryCategory = "petal.summary"

    /// Called on the main thread when the daily summary notification is clicked.
    var onOpenHistory: (() -> Void)?

    func configure() {
        UNUserNotificationCenter.current().delegate = self   // does not prompt
    }

    func requestAuthorizationIfNeeded(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    completion(granted)
                }
            case .authorized, .provisional:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    func post(identifier: String, title: String, body: String, category: String = "") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { petalLog.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == Self.summaryCategory {
            DispatchQueue.main.async { self.onOpenHistory?() }
        }
        completionHandler()
    }
}

/// System-wide shortcuts via Carbon `RegisterEventHotKey`.
///
/// PRD-DEVIATION: the PRD specifies `NSEvent.addGlobalMonitorForEvents(.keyDown)`, but
/// global *key* monitors silently receive nothing unless the user grants Accessibility
/// access — which the PRD also forbids — and they cannot swallow the keystroke, so it
/// would still be typed into the frontmost app. Carbon hot keys need no permission,
/// work inside the App Sandbox, consume the keystroke and cost nothing while idle.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    nonisolated fileprivate static let signature: OSType = 0x5045_544C   // 'PETL'

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    @discardableResult
    func register(id: UInt32, combo: KeyCombo, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
        actions = [:]
    }

    fileprivate func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard err == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
    }
}

// MARK: - 9. Status bar item + popover

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: StopwatchStore
    private let settings: AppSettings
    private var outsideClickMonitor: Any?
    private var lastCloseUptime: TimeInterval = 0
    var onOpenPreferences: (() -> Void)?

    var isPopoverShown: Bool { popover.isShown }

    init(store: StopwatchStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = PetalIcon.menuBarImage()
            button.imagePosition = .imageOnly
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityTitle("Petal")
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        store.onMenuBarTitle = { [weak self] title in self?.setTitle(title) }
        store.onRequestKeyboardFocus = { [weak self] in self?.focusPopoverForTyping() }
    }

    private func setTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.setAccessibilityValue(title.isEmpty ? "No timer running" : title)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
            return
        }
        // A transient popover closes itself on mouse-down; don't let the matching
        // mouse-up reopen it.
        if !popover.isShown && ProcessInfo.processInfo.systemUptime - lastCloseUptime < 0.25 { return }
        togglePopover()
    }

    func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    /// Opens without activating Petal: the app you're typing in stays frontmost (PRD §6.1).
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        if popover.contentViewController == nil {   // lazy: built on first open only
            let root = PopoverRootView().environment(store).environment(settings)
            let host = NSHostingController(rootView: root)
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
        }
        store.popoverWillShow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Petal isn't active, so a transient popover can't see clicks in other apps.
        // A mouse-only global monitor (no permission needed) closes it; it exists only
        // while the popover is open.
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        lastCloseUptime = ProcessInfo.processInfo.systemUptime
        store.popoverDidClose()
    }

    /// Text entry needs Petal to be the active app. Only done when the user starts typing.
    private func focusPopoverForTyping() {
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let target = store.actionTarget {
            let title = target.isRunning ? "⏸ Pause \u{201C}\(target.name)\u{201D}" : "▶ Start \u{201C}\(target.name)\u{201D}"
            menu.addItem(makeItem(title, #selector(toggleTarget)))
        } else {
            let item = NSMenuItem(title: "No timers yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("+ New Stopwatch", #selector(newStopwatch)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Petal", #selector(openPetal)))
        menu.addItem(makeItem("Preferences…", #selector(openPreferences), key: ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Petal", #selector(quit), key: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // shows the menu, returns when it closes
        statusItem.menu = nil                  // restore normal left-click behaviour
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleTarget() {
        guard let target = store.actionTarget else { return }
        store.select(target.id)
        store.toggle(target.id)
    }

    @objc private func newStopwatch() {
        guard store.create(navigate: true) != nil else { return }
        Task { @MainActor [weak self] in self?.showPopover() }
    }

    @objc private func openPetal() {
        Task { @MainActor [weak self] in self?.showPopover() }
    }

    @objc private func openPreferences() { onOpenPreferences?() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - 10. Popover views

/// Scale bounce on press (PRD §10). Pure SwiftUI; disabled under Reduce Motion.
struct PressBounceStyle: ButtonStyle {
    var reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Wrapping row layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// PRD-DEVIATION: NavigationStack draws no navigation bar or back button inside an
// NSPopover on macOS, so the two levels are switched manually with a slide transition.
// Behaviour (Summary → Detail → Back) matches the PRD.
@MainActor
struct PopoverRootView: View {
    @Environment(StopwatchStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let width: CGFloat = settings.popoverWide ? 360 : 300
        let reduce = systemReduceMotion || settings.reduceAnimations
        ZStack {
            if let id = store.route, store.model(id) != nil {
                DetailView(id: id)
                    // Explicit identity: without it, switching straight from one stopwatch's
                    // detail to another's would reuse the first one's @State — including an
                    // armed "Confirm reset?" — so the next tap could act on the wrong timer.
                    .id(id)
                    .transition(reduce ? .identity : .move(edge: .trailing))
            } else {
                SummaryView()
                    .transition(reduce ? .identity : .move(edge: .leading))
            }
        }
        .frame(width: width, height: popoverHeight)
        .clipped()
        .animation(reduce ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: store.route)
    }

    /// Adaptive height: 180 pt minimum, 500 pt maximum (scrolls beyond).
    private var popoverHeight: CGFloat {
        if store.route != nil { return 500 }
        let count = store.stopwatches.count
        var height: CGFloat
        if count == 0 {
            height = 220
        } else {
            let rows = CGFloat((count + 2) / 2)          // tiles + the "add" tile, two per row
            height = 44 + 24 + rows * 82 + (rows - 1) * 10 + 40
        }
        if store.showOnboardingTip { height += 52 }
        if store.persistenceError != nil { height += 44 }
        return min(500, max(180, height))
    }
}

@MainActor
struct SummaryView: View {
    @Environment(StopwatchStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.persistenceError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if store.stopwatches.isEmpty && store.isLoaded {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if store.showOnboardingTip { OnboardingTip() }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                  spacing: 10) {
                            ForEach(store.stopwatches) { sw in
                                StopwatchTileView(sw: sw)
                                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                            }
                            AddTileView()
                        }
                        .animation(systemReduceMotion || settings.reduceAnimations ? nil : .spring(duration: 0.22),
                                   value: store.stopwatches.map(\.id))
                    }
                    .padding(12)
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("🌸 Petal").font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Button {
                store.create(navigate: true)
            } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New timer")
            .accessibilityHint("Creates a timer and opens it")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var footer: some View {
        HStack {
            Text("Today: \(store.statsLoaded ? TimeFormatter.short(store.todayTotal()) : "—")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Total today")
            Spacer()
            Button("History ❯") { store.onOpenHistory?() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .accessibilityHint("Opens charts and export")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🌸").font(.system(size: 34))
            Text("No timers yet.").foregroundStyle(.secondary)
            Button("＋ Start tracking") { store.create() }
                .buttonStyle(.borderedProminent)
                .tint(PastelColor.blush.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
struct OnboardingTip: View {
    @Environment(StopwatchStore.self) private var store

    var body: some View {
        Text("Tap to open · Long-press to rename · ＋ adds another")
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .onTapGesture { store.showOnboardingTip = false }
            .task {
                try? await Task.sleep(for: .seconds(6))
                store.showOnboardingTip = false
            }
    }
}

@MainActor
struct StopwatchTileView: View {
    let sw: StopwatchModel
    @Environment(StopwatchStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var reduceMotion: Bool { systemReduceMotion || settings.reduceAnimations }
    private var highContrast: Bool { contrast == .increased }

    var body: some View {
        let elapsed = store.elapsed(sw)
        let status = sw.isRunning ? "LIVE" : (elapsed > 0 ? "paused" : "idle")
        HStack(spacing: 0) {
            strip
            VStack(alignment: .leading, spacing: 3) {
                nameView
                Text(TimeFormatter.clock(elapsed))
                    .font(.system(size: 17, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let goal = sw.dailyGoalSeconds, store.statsLoaded {
                    GoalBar(progress: store.todaySeconds(sw.id) / Double(goal), color: sw.color.color, height: 3)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(sw.isRunning ? sw.color.color : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    let streak = store.streak(sw.id)
                    if streak >= 2 {
                        Text("🔥 \(streak)").font(.system(size: 10)).accessibilityLabel("\(streak) day streak")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 82)
        .background(sw.color.color.opacity(highContrast ? 0.30 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .gesture(
            LongPressGesture(minimumDuration: 0.6)
                .onEnded { _ in beginRename() }
                .exclusively(before: TapGesture().onEnded { open() }),
            including: renaming ? .subviews : .all
        )
        .focusable(!renaming)
        .onKeyPress(.return) { open(); return .handled }
        .onKeyPress(.space) { open(); return .handled }
        .accessibilityElement(children: renaming ? .contain : .ignore)
        .accessibilityLabel(accessibilitySummary(status: status, elapsed: elapsed))
        .accessibilityHint("Opens details. Long-press to rename.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: Text(sw.isRunning ? String("Pause") : String("Start"))) { store.toggle(sw.id) }
    }

    /// Left border strip. The LIVE pulse is a separate view so removing it (pause,
    /// popover closed, Reduce Motion) reliably stops the repeating animation.
    @ViewBuilder private var strip: some View {
        let width: CGFloat = highContrast ? 4 : 3
        if sw.isRunning && store.popoverVisible && !reduceMotion {
            PulsingStrip(color: sw.color.color, width: width)
        } else {
            Rectangle().fill(sw.color.color).frame(width: width)
        }
    }

    @ViewBuilder private var nameView: some View {
        if renaming {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .focused($nameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = false }
                .onChange(of: nameFocused) { _, focused in if !focused && renaming { commitRename() } }
                .onDisappear { if renaming { commitRename() } }
        } else {
            Text(sw.name.count > 14 ? String(sw.name.prefix(14)) + "…" : sw.name)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
    }

    private func accessibilitySummary(status: String, elapsed: TimeInterval) -> String {
        let c = TimeFormatter.components(elapsed)
        var parts = [sw.name, status, "\(c.h) hours \(c.m) minutes \(c.s) seconds"]
        if let goal = sw.dailyGoalSeconds, store.statsLoaded {
            parts.append("\(Int(min(store.todaySeconds(sw.id) / Double(goal), 9.99) * 100)) percent of daily goal")
        }
        let streak = store.streak(sw.id)
        if streak >= 2 { parts.append("\(streak) day streak") }
        return parts.joined(separator: ", ")
    }

    private func open() {
        store.showOnboardingTip = false
        store.select(sw.id)
        store.route = sw.id
    }

    private func beginRename() {
        store.showOnboardingTip = false
        store.onRequestKeyboardFocus?()
        draft = sw.name
        renaming = true
        Task { @MainActor in nameFocused = true }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        store.rename(sw.id, to: draft)
    }
}

@MainActor
struct PulsingStrip: View {
    let color: Color
    let width: CGFloat
    @State private var bright = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width)
            .opacity(bright ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

@MainActor
struct GoalBar: View {
    let progress: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Daily goal")
        .accessibilityValue("\(Int(min(max(progress, 0), 9.99) * 100)) percent")
    }
}

@MainActor
struct AddTileView: View {
    @Environment(StopwatchStore.self) private var store

    var body: some View {
        Button {
            store.create(navigate: true)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                Text("New timer").font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 82)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New timer")
    }
}

@MainActor
struct DetailView: View {
    let id: UUID
    @Environment(StopwatchStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private enum Field: Hashable { case name, note, tag }
    @FocusState private var focus: Field?
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var confirmingReset = false
    @State private var confirmingDelete = false
    @State private var editingNoteID: UUID?
    @State private var noteDraft = ""
    @State private var showAllSessions = false
    @State private var addingTag = false
    @State private var tagDraft = ""
    @State private var pendingTagRemoval: String?
    @State private var customGoal = false
    @State private var showCheck = false
    @State private var confirmTask: Task<Void, Never>?

    private static let goalPresets = [1800, 3600, 5400, 7200, 10800, 14400]
    private var reduceMotion: Bool { systemReduceMotion || settings.reduceAnimations }

    var body: some View {
        if let sw = store.model(id) {
            content(sw)
        } else {
            Color.clear
        }
    }

    private func content(_ sw: StopwatchModel) -> some View {
        let accent = contrast == .increased ? Color.primary : sw.color.color
        let elapsed = store.elapsed(sw)
        return VStack(spacing: 0) {
            navBar(sw)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    timerDisplay(elapsed: elapsed, accent: accent)
                    goalSection(sw)
                    controls(sw, elapsed: elapsed)
                    pomodoroSection(sw)
                    Divider()
                    statsSection(sw)
                    Divider()
                    sessionsSection(sw)
                    Divider()
                    settingsSection(sw)
                    Divider()
                    deleteButton(sw)
                }
                .padding(16)
            }
        }
        .onAppear {
            if store.renameRequestID == id {
                store.renameRequestID = nil
                beginRename(sw)
            }
        }
        .onDisappear {
            // The popover can close mid-edit; never silently drop what was typed.
            confirmTask?.cancel()
            if renaming { commitRename() }
            if let sid = editingNoteID { commitNote(sessionID: sid) }
            if addingTag { commitTag() }
        }
        .onChange(of: focus) { old, new in
            if old == .name && new != .name && renaming { commitRename() }
            if old == .note && new != .note, let sid = editingNoteID { commitNote(sessionID: sid) }
            if old == .tag && new != .tag && addingTag { commitTag() }
        }
        .onChange(of: store.goalFlash[id]) { _, flash in
            guard flash != nil else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3)) { showCheck = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { showCheck = false }
            }
        }
    }

    // MARK: Sections

    private func navBar(_ sw: StopwatchModel) -> some View {
        HStack(spacing: 8) {
            Button { disarm(); store.route = nil } label: {
                Label("Back", systemImage: "chevron.left").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 60, alignment: .leading)
            Spacer(minLength: 0)
            Circle().fill(sw.color.color).frame(width: 8, height: 8)
            if renaming {
                TextField("Name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .focused($focus, equals: .name)
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = false }
                    .frame(maxWidth: 160)
            } else {
                Button { beginRename(sw) } label: {
                    Text(sw.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Renames this timer")
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func timerDisplay(elapsed: TimeInterval, accent: Color) -> some View {
        let c = TimeFormatter.components(elapsed)
        return ZStack {
            HStack(spacing: 2) {
                Text(TimeFormatter.two(c.h))
                Text(":").opacity(0.5)
                Text(TimeFormatter.two(c.m))
                Text(":").opacity(0.5)
                Text(TimeFormatter.two(c.s))
            }
            .font(.system(size: 46, weight: .medium, design: .monospaced))
            .foregroundStyle(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Elapsed \(c.h) hours \(c.m) minutes \(c.s) seconds")

            if showCheck {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale))
                    .accessibilityLabel("Goal reached")
            }
        }
    }

    @ViewBuilder private func goalSection(_ sw: StopwatchModel) -> some View {
        if let goal = sw.dailyGoalSeconds, store.statsLoaded {
            let today = store.todaySeconds(id)
            let progress = today / Double(goal)
            VStack(alignment: .leading, spacing: 4) {
                GoalBar(progress: progress, color: sw.color.color, height: 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: min(progress, 1))
                Text("\(TimeFormatter.short(today)) / \(TimeFormatter.short(Double(goal))) (\(Int(min(progress, 9.99) * 100))%)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func controls(_ sw: StopwatchModel, elapsed: TimeInterval) -> some View {
        VStack(spacing: 8) {
            Button { disarm(); store.toggle(id) } label: {
                Label(sw.isRunning ? "Pause" : "Start", systemImage: sw.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(sw.color.color.opacity(0.9)))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(PressBounceStyle(reduceMotion: reduceMotion))
            .accessibilityHint(sw.isRunning ? "Pauses this timer" : "Starts this timer")

            HStack {
                if sw.isRunning {
                    Button("Lap") { disarm(); store.lap(id) }
                        .accessibilityHint("Records a lap at the current time")
                }
                Spacer()
                if elapsed > 0 {
                    Button(confirmingReset ? "Confirm reset?" : "Reset") {
                        if confirmingReset {
                            disarm()
                            store.reset(id)
                        } else {
                            armConfirm { confirmingReset = $0 }
                        }
                    }
                    .foregroundStyle(confirmingReset ? Color.red : Color.secondary)
                    .accessibilityHint("Sets the timer back to zero. History is kept.")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
        }
    }

    @ViewBuilder private func pomodoroSection(_ sw: StopwatchModel) -> some View {
        HStack(spacing: 8) {
            Toggle("🍅 Pomodoro", isOn: Binding(get: { store.pomodoro[id] != nil },
                                               set: { disarm(); store.setPomodoro(id, enabled: $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
            Spacer()
            if let p = store.pomodoro[id] {
                if p.awaitingStart {
                    Button(p.phase == .work ? "Start focus" : "Start break") { store.startNextPomodoroPhase(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(sw.color.color)
                } else {
                    let label = p.phase == .work ? "Focus" : "Break"
                    Text("\(label): \(TimeFormatter.countdown(p.remaining(at: store.now())))\(sw.isRunning ? " remaining" : " (paused)")")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statsSection(_ sw: StopwatchModel) -> some View {
        VStack(spacing: 4) {
            statRow("Today", store.statsLoaded ? store.todaySeconds(id) : nil)
            statRow("This week", store.statsLoaded ? store.weekSeconds(id) : nil)
            statRow("All time", store.statsLoaded ? store.allTimeSeconds(id) : nil)
        }
    }

    private func statRow(_ title: String, _ value: TimeInterval?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value.map(TimeFormatter.short) ?? "—").monospacedDigit()
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private func sessionsSection(_ sw: StopwatchModel) -> some View {
        let sessions = store.todaySessions(id)
        let visible = showAllSessions ? sessions : Array(sessions.prefix(4))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Sessions — today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if sessions.isEmpty {
                Text("No sessions yet today.").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(visible) { session in
                sessionRow(session, sw: sw)
            }
            if sessions.count > 4 && !showAllSessions {
                Button("Show all (\(sessions.count))") { showAllSessions = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }

    private func sessionRow(_ s: SessionRecord, sw: StopwatchModel) -> some View {
        let duration = s.end.map { $0.timeIntervalSince(s.start) } ?? sw.sessionElapsed(at: store.now())
        return VStack(alignment: .leading, spacing: 3) {
            Button { beginNote(s) } label: {
                HStack(spacing: 4) {
                    Text("\(Formatters.time.string(from: s.start)) → \(s.end.map { Formatters.time.string(from: $0) } ?? "now")")
                    if s.wasInterrupted {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("Petal quit unexpectedly; this session was closed at the last known time.")
                            .accessibilityLabel("Interrupted")
                    }
                    Spacer()
                    Text(TimeFormatter.short(duration)).monospacedDigit()
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Adds or edits a note")

            if editingNoteID == s.id {
                TextField("Add a note", text: $noteDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($focus, equals: .note)
                    .onSubmit { commitNote(sessionID: s.id) }
                    .onExitCommand { editingNoteID = nil }
            } else if let note = s.note {
                Text("└─ \(note)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(Array(s.laps.enumerated()), id: \.element.id) { index, lap in
                Text("Lap \(index + 1): \(TimeFormatter.clock(lap.elapsedAtLap))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
        }
    }

    private func settingsSection(_ sw: StopwatchModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(PastelColor.allCases) { color in
                    Button { disarm(); store.setColor(id, color) } label: {
                        ZStack {
                            Circle().fill(color.color).frame(width: 22, height: 22)
                            if color == sw.color {
                                Circle().stroke(Color.primary.opacity(0.7), lineWidth: 2).frame(width: 28, height: 28)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.displayName)
                    .accessibilityAddTraits(color == sw.color ? .isSelected : [])
                }
            }

            Text("Tags").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(sw.tags, id: \.self) { tag in
                    Button { tapTag(tag) } label: {
                        Text(pendingTagRemoval == tag ? "✕ \(tag)" : tag)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(sw.color.color.opacity(pendingTagRemoval == tag ? 0.65 : 0.35)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tag \(tag)")
                    .accessibilityHint(pendingTagRemoval == tag ? "Activate again to remove" : "Activate twice to remove")
                }
                if addingTag {
                    TextField("tag", text: $tagDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 110)
                        .focused($focus, equals: .tag)
                        .onSubmit { commitTag() }
                        .onExitCommand { addingTag = false; tagDraft = "" }
                        .onChange(of: tagDraft) { _, value in
                            if value.count > 20 { tagDraft = String(value.prefix(20)) }
                        }
                } else if sw.tags.count < 8 {
                    Button("＋ tag") { beginTag() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Daily goal").font(.system(size: 12))
                Spacer()
                Picker("Daily goal", selection: goalBinding(sw)) {
                    Text("None").tag(0)
                    ForEach(Self.goalPresets, id: \.self) { Text(TimeFormatter.goal($0)).tag($0) }
                    if let g = sw.dailyGoalSeconds, !Self.goalPresets.contains(g) {
                        Text(TimeFormatter.goal(g)).tag(g)
                    }
                    Divider()
                    Text("Custom…").tag(-1)
                }
                .labelsHidden()
                .frame(width: 120)
            }
            if customGoal, let goal = sw.dailyGoalSeconds {
                Stepper("Custom: \(TimeFormatter.goal(goal))",
                        value: Binding(get: { goal }, set: { store.setGoal(id, seconds: $0) }),
                        in: 900...57_600, step: 900)
                    .font(.system(size: 12))
            }
        }
    }

    private func deleteButton(_ sw: StopwatchModel) -> some View {
        Button(confirmingDelete ? "Tap again to delete" : "Delete Timer") {
            if confirmingDelete {
                disarm()
                store.delete(id)
            } else {
                armConfirm { confirmingDelete = $0 }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity)
        .accessibilityHint("Deletes this timer. Requires a second tap.")
    }

    // MARK: Actions

    /// Any other action cancels a pending Reset/Delete confirmation, so a confirmation can
    /// never be "used up" later by a stray click.
    private func disarm() {
        confirmTask?.cancel()
        confirmTask = nil
        confirmingReset = false
        confirmingDelete = false
    }

    /// Inline two-step confirmation: armed for 3 seconds, then reverts.
    private func armConfirm(_ set: @escaping (Bool) -> Void) {
        confirmTask?.cancel()
        confirmingReset = false
        confirmingDelete = false
        set(true)
        confirmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { set(false) }
        }
    }

    private func goalBinding(_ sw: StopwatchModel) -> Binding<Int> {
        Binding(
            get: { sw.dailyGoalSeconds ?? 0 },
            set: { value in
                if value == -1 {
                    customGoal = true
                    store.setGoal(id, seconds: sw.dailyGoalSeconds ?? 2700)
                } else {
                    customGoal = false
                    store.setGoal(id, seconds: value == 0 ? nil : value)
                }
            })
    }

    private func beginRename(_ sw: StopwatchModel) {
        store.onRequestKeyboardFocus?()
        nameDraft = sw.name
        renaming = true
        Task { @MainActor in focus = .name }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        store.rename(id, to: nameDraft)
    }

    private func beginNote(_ s: SessionRecord) {
        if let current = editingNoteID, current != s.id { commitNote(sessionID: current) }
        store.onRequestKeyboardFocus?()
        noteDraft = s.note ?? ""
        editingNoteID = s.id
        Task { @MainActor in focus = .note }
    }

    private func commitNote(sessionID: UUID) {
        guard editingNoteID == sessionID else { return }
        editingNoteID = nil
        store.setNote(sessionID: sessionID, stopwatchID: id, note: noteDraft)
    }

    private func beginTag() {
        store.onRequestKeyboardFocus?()
        tagDraft = ""
        addingTag = true
        Task { @MainActor in focus = .tag }
    }

    private func commitTag() {
        guard addingTag else { return }
        addingTag = false
        store.addTag(id, tagDraft)
        tagDraft = ""
    }

    // PRD-AMBIGUITY: "Tap existing tag: removes it (with confirm on long press…)" is
    // self-contradictory. Implemented as the same two-tap inline confirm used for
    // Reset/Delete: first tap arms (chip shows ✕), second tap within 3 s removes.
    private func tapTag(_ tag: String) {
        if pendingTagRemoval == tag {
            pendingTagRemoval = nil
            store.removeTag(id, tag)
        } else {
            pendingTagRemoval = tag
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if pendingTagRemoval == tag { pendingTagRemoval = nil }
            }
        }
    }
}

// MARK: - 11. History & Preferences windows

/// Everything the History window shows, computed once from the fetched sessions.
struct HistoryData {
    struct Row: Identifiable {
        let id: UUID
        let label: String
        let color: Color
        let today: TimeInterval
        let week: TimeInterval
        let allTime: TimeInterval
        let count: Int
    }
    struct WeekEntry: Identifiable {
        let id: String
        let day: String
        let label: String
        let seconds: TimeInterval
    }
    struct TimelineItem: Identifiable {
        let id: UUID
        let label: String
        let color: Color
        let start: Date
        let end: Date
        let note: String?
        let lapCount: Int
    }

    let rows: [Row]
    let week: [WeekEntry]
    let dayLabels: [String]
    let dayItems: [String: [TimelineItem]]
    let todayItems: [TimelineItem]
    let legendLabels: [String]
    let legendColors: [Color]

    /// Chart categories must be unique, but duplicate stopwatch names are allowed (PRD §12).
    static func uniqueLabels(_ stopwatches: [StopwatchModel]) -> [UUID: String] {
        var seen: [String: Int] = [:]
        var result: [UUID: String] = [:]
        for sw in stopwatches {
            let n = (seen[sw.name] ?? 0) + 1
            seen[sw.name] = n
            result[sw.id] = n == 1 ? sw.name : "\(sw.name) (\(n))"
        }
        return result
    }

    init(sessions: [SessionRecord], stopwatches: [StopwatchModel], now: Date, calendar: Calendar) {
        let labels = Self.uniqueLabels(stopwatches)
        var colors: [UUID: Color] = [:]
        for sw in stopwatches { colors[sw.id] = sw.color.color }
        let today = DayMath.dayInterval(now, calendar: calendar)
        let weekInterval = DayMath.weekInterval(containing: now, calendar: calendar)
        let days = DayMath.days(in: weekInterval, calendar: calendar)
        let names = days.map { Formatters.weekday.string(from: $0.start) }

        var todayBy: [UUID: TimeInterval] = [:], weekBy: [UUID: TimeInterval] = [:]
        var allBy: [UUID: TimeInterval] = [:], countBy: [UUID: Int] = [:]
        var perDay = Array(repeating: [UUID: TimeInterval](), count: days.count)
        var items = Array(repeating: [TimelineItem](), count: days.count)
        var todayItems: [TimelineItem] = []

        for s in sessions {
            guard let end = s.end, let label = labels[s.stopwatchID], let color = colors[s.stopwatchID] else { continue }
            let id = s.stopwatchID
            let item = TimelineItem(id: s.id, label: label, color: color, start: s.start, end: end, note: s.note,
                                    lapCount: s.laps.count)
            allBy[id, default: 0] += max(0, end.timeIntervalSince(s.start))
            countBy[id, default: 0] += 1
            todayBy[id, default: 0] += DayMath.overlap(start: s.start, end: end, from: today.start, to: today.end)
            weekBy[id, default: 0] += DayMath.overlap(start: s.start, end: end, from: weekInterval.start, to: weekInterval.end)
            for (i, day) in days.enumerated() where s.overlaps(day) {
                perDay[i][id, default: 0] += DayMath.overlap(start: s.start, end: end, from: day.start, to: day.end)
                items[i].append(item)
            }
            if s.overlaps(today) { todayItems.append(item) }
        }

        rows = stopwatches.map { sw in
            Row(id: sw.id, label: labels[sw.id] ?? sw.name, color: sw.color.color,
                today: todayBy[sw.id] ?? 0, week: weekBy[sw.id] ?? 0,
                allTime: allBy[sw.id] ?? 0, count: countBy[sw.id] ?? 0)
        }
        var entries: [WeekEntry] = []
        for (i, name) in names.enumerated() {
            for sw in stopwatches {
                let label = labels[sw.id] ?? sw.name
                entries.append(WeekEntry(id: "\(i)-\(sw.id.uuidString)", day: name, label: label,
                                         seconds: perDay[i][sw.id] ?? 0))
            }
        }
        week = entries
        dayLabels = names
        var byDay: [String: [TimelineItem]] = [:]
        for (i, name) in names.enumerated() { byDay[name] = items[i].sorted { $0.start < $1.start } }
        dayItems = byDay
        self.todayItems = todayItems.sorted { $0.start < $1.start }
        legendLabels = stopwatches.map { labels[$0.id] ?? $0.name }
        legendColors = stopwatches.map { $0.color.color }
    }
}

// PRD-DEVIATION: History opens in its own window rather than a `.sheet` on the popover.
// A sheet attached to a transient NSPopover is dismissed along with it the moment the
// user clicks anything, and a 300 pt popover is too narrow for the charts. Content,
// tabs, lazy loading and export behave as specified.
@MainActor
struct HistoryView: View {
    @Environment(StopwatchStore.self) private var store
    @State private var data: HistoryData?
    @State private var tab: Tab = .daily
    @State private var selectedDay: String?
    @State private var sortOrder = [KeyPathComparator(\HistoryData.Row.allTime, order: .reverse)]
    @State private var exportMessage: String?
    @State private var exportFailed = false
    @State private var exporting = false

    enum Tab: String, CaseIterable, Identifiable {
        case daily = "Daily", weekly = "Weekly", totals = "Totals"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let data {
                switch tab {
                case .daily: daily(data)
                case .weekly: weekly(data)
                case .totals: totals(data)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                if let exportMessage {
                    Text(exportMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(exportFailed ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(exporting ? "Exporting…" : "Export CSV") { Task { await export() } }
                    .disabled(exporting)
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 540)
        .task { await reload() }   // fetched only when the window opens
    }

    private func reload() async {
        let sessions = await store.historySessions()
        let stopwatches = store.stopwatches
        let calendar = store.calendar
        let now = store.wallClock()
        data = HistoryData(sessions: sessions, stopwatches: stopwatches, now: now, calendar: calendar)
    }

    @ViewBuilder private func daily(_ data: HistoryData) -> some View {
        Text("Today").font(.headline)
        Chart(data.rows) { row in
            BarMark(x: .value("Hours", row.today / 3600), y: .value("Timer", row.label))
                .foregroundStyle(row.color)
        }
        .chartXAxisLabel("hours")
        .frame(height: max(80, CGFloat(data.rows.count) * 28))
        timeline(data.todayItems, empty: "Nothing tracked today yet.")
    }

    @ViewBuilder private func weekly(_ data: HistoryData) -> some View {
        Text("This week").font(.headline)
        Chart(data.week) { entry in
            BarMark(x: .value("Day", entry.day), y: .value("Hours", entry.seconds / 3600))
                .foregroundStyle(by: .value("Timer", entry.label))
                .opacity(selectedDay == nil || selectedDay == entry.day ? 1 : 0.4)
        }
        .chartForegroundStyleScale(domain: data.legendLabels, range: data.legendColors)
        .chartYAxisLabel("hours")
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plot = proxy.plotFrame else { return }
                        let x = location.x - geo[plot].origin.x
                        if let day: String = proxy.value(atX: x) {
                            selectedDay = selectedDay == day ? nil : day
                        }
                    }
            }
        }
        .frame(height: 220)
        if let day = selectedDay {
            Text(day).font(.subheadline.weight(.semibold))
            timeline(data.dayItems[day] ?? [], empty: "Nothing tracked on this day.")
        } else {
            Text("Click a day to see its sessions.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func totals(_ data: HistoryData) -> some View {
        Table(data.rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Name", value: \.label) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(row.label)
                }
            }
            TableColumn("Today", value: \.today) { Text(TimeFormatter.short($0.today)).monospacedDigit() }
            TableColumn("This week", value: \.week) { Text(TimeFormatter.short($0.week)).monospacedDigit() }
            TableColumn("All time", value: \.allTime) { Text(TimeFormatter.short($0.allTime)).monospacedDigit() }
            TableColumn("Sessions", value: \.count) { Text("\($0.count)").monospacedDigit() }
        }
    }

    private func timeline(_ items: [HistoryData.TimelineItem], empty: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if items.isEmpty {
                    Text(empty).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 10, height: 10)
                        Text(item.label).fontWeight(.medium)
                        Text("\(Formatters.time.string(from: item.start))–\(Formatters.time.string(from: item.end)) (\(TimeFormatter.short(item.end.timeIntervalSince(item.start))))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let note = item.note {
                            Text("— \(note)").foregroundStyle(.secondary).lineLimit(1)
                        }
                        if item.lapCount > 0 {
                            Text("· \(item.lapCount) lap\(item.lapCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            let url = try await store.exportCSV()
            exportFailed = false
            exportMessage = "Saved \(url.lastPathComponent) to Downloads."
        } catch {
            exportFailed = true
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
struct ShortcutRecorderRow: View {
    let action: ShortcutAction
    @Environment(AppSettings.self) private var settings
    @State private var monitor: Any?
    @State private var message: String?

    private var recording: Bool { settings.recordingAction == action }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(action.title)
                Spacer()
                if settings.shortcutFailures.contains(action.rawValue) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("This shortcut is already in use by another app.")
                        .accessibilityLabel("Shortcut unavailable, in use by another app")
                }
                Text(recording ? "Press keys…" : settings.combo(for: action).displayString)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                    .accessibilityLabel(recording ? "Recording" : "Current shortcut \(settings.combo(for: action).displayString)")
                Button(recording ? "Cancel" : "Edit") { recording ? stop() : start() }
                    .accessibilityHint(recording ? "Stops recording" : "Records a new shortcut; press Escape to cancel")
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        // Another row started recording: drop this row's key monitor.
        .onChange(of: settings.recordingAction) { _, now in
            if now != action { removeMonitor() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        removeMonitor()
        message = nil
        settings.recordingAction = action          // suspends global hotkeys
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard settings.recordingAction == action else { return event }
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require ⌃, ⌥ or ⌘ so a global shortcut can never steal plain typing.
            guard !mods.intersection([.command, .option, .control]).isEmpty else {
                message = "Include ⌃, ⌥ or ⌘."
                NSSound.beep()
                return nil
            }
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), modifierFlags: mods.rawValue,
                                 key: KeyCombo.keyName(for: event))
            if let owner = settings.conflict(for: combo, excluding: action) {
                message = "\(combo.displayString) is already used by “\(owner)”."
                NSSound.beep()
                return nil
            }
            stop()
            settings.setCombo(combo, for: action)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func stop() {
        removeMonitor()
        if settings.recordingAction == action { settings.recordingAction = nil }   // resumes hotkeys
    }
}

@MainActor
struct PreferencesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(StopwatchStore.self) private var store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?
    @State private var notificationMessage: String?
    @State private var showingDelete = false
    @State private var deleteText = ""
    @State private var dataMessage: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("General") {
                Toggle("Launch Petal at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
                Picker("Menu bar", selection: $settings.menuBarShowsTime) {
                    Text("Icon + time").tag(true)
                    Text("Icon only").tag(false)
                }
                .pickerStyle(.radioGroup)
                Picker("Time format", selection: $settings.compactUnderHour) {
                    Text("HH:MM:SS").tag(false)
                    Text("MM:SS when under 1 hour").tag(true)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Shortcuts") {
                ForEach(ShortcutAction.allCases) { ShortcutRecorderRow(action: $0) }
                Text("⌃⌥1 … ⌃⌥8 select a timer by position. Shortcuts work even when the popover is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restore defaults") { settings.resetShortcuts() }
            }

            Section("Notifications") {
                Toggle("Daily summary notification", isOn: Binding(
                    get: { settings.dailySummaryEnabled },
                    set: { on in
                        if on { withPermission { settings.dailySummaryEnabled = true } } else { settings.dailySummaryEnabled = false }
                    }))
                DatePicker("Time", selection: summaryTime, displayedComponents: .hourAndMinute)
                    .disabled(!settings.dailySummaryEnabled)
                Toggle("Goal completion alerts", isOn: Binding(
                    get: { settings.goalAlertsEnabled },
                    set: { on in
                        if on { withPermission { settings.goalAlertsEnabled = true } } else { settings.goalAlertsEnabled = false }
                    }))
                if let notificationMessage {
                    Text(notificationMessage).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Pomodoro") {
                Picker("Work interval", selection: $settings.pomodoroWorkMinutes) {
                    ForEach(Self.options([15, 20, 25, 30, 45, 50, 60, 90], current: settings.pomodoroWorkMinutes), id: \.self) {
                        Text("\($0) min").tag($0)
                    }
                }
                Picker("Break interval", selection: $settings.pomodoroBreakMinutes) {
                    ForEach(Self.options([3, 5, 10, 15, 20, 30], current: settings.pomodoroBreakMinutes), id: \.self) {
                        Text("\($0) min").tag($0)
                    }
                }
                Toggle("Auto-start next interval", isOn: $settings.pomodoroAutoStart)
                Picker("Sound on end", selection: $settings.pomodoroSound) {
                    ForEach(PomodoroSound.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Appearance") {
                Picker("Popover size", selection: $settings.popoverWide) {
                    Text("Compact (300pt)").tag(false)
                    Text("Regular (360pt)").tag(true)
                }
                .pickerStyle(.radioGroup)
                Toggle("Reduce animations", isOn: $settings.reduceAnimations)
                Text("The system Reduce Motion setting is always respected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                HStack {
                    Button("Open Data Folder") { _ = NSWorkspace.shared.open(URL.applicationSupportDirectory) }
                    Button("Export All Data") {
                        Task {
                            do {
                                let url = try await store.exportCSV()
                                dataMessage = "Saved \(url.lastPathComponent) to Downloads."
                            } catch {
                                dataMessage = "Export failed: \(error.localizedDescription)"
                            }
                        }
                    }
                }
                if showingDelete {
                    HStack {
                        TextField("Type “delete” to confirm", text: $deleteText)
                        Button("Delete", role: .destructive) {
                            store.deleteAllData()
                            showingDelete = false
                            deleteText = ""
                            dataMessage = "All data deleted."
                        }
                        .disabled(deleteText != "delete")
                        Button("Cancel") {
                            showingDelete = false
                            deleteText = ""
                        }
                    }
                } else {
                    Button("Delete All Data…", role: .destructive) { showingDelete = true }
                }
                if let dataMessage { Text(dataMessage).font(.caption).foregroundStyle(.secondary) }
            }

            Section("About") {
                LabeledContent("Petal", value: version)
                Text("Built with Swift 5.9 · macOS 14+").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 660)
    }

    /// Keeps a hand-edited or legacy value visible in the picker instead of a blank.
    private static func options(_ base: [Int], current: Int) -> [Int] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    private var summaryTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: settings.summaryMinutes / 60,
                                      minute: settings.summaryMinutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.summaryMinutes = (c.hour ?? 19) * 60 + (c.minute ?? 0)
            })
    }

    private func withPermission(_ then: @escaping @MainActor () -> Void) {
        NotificationService.shared.requestAuthorizationIfNeeded { granted in
            Task { @MainActor in
                if granted {
                    notificationMessage = nil
                    then()
                } else {
                    notificationMessage = "Notifications are turned off for Petal. Enable them in System Settings › Notifications."
                }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Petal in System Settings › General › Login Items." : nil
        } catch {
            loginMessage = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 12. App entry point

/// Only one Petal may run at a time. Every copy (the installed app, a `build.sh` build, an
/// Xcode run) shares one sandbox container and therefore one SwiftData store, so a second
/// copy would treat the first one's running sessions as crash orphans and close them, then
/// overwrite its edits — and only one copy can own the global shortcuts anyway.
///
/// The lock is an `flock` on a file in the container, not a scan of running apps: the
/// kernel releases it the moment its holder exits — even on a crash — and two copies
/// launched together can never both win (or both lose) the race.
final class InstanceLock {
    /// Posted by a copy that lost the race, asking the running one to show itself.
    /// Sandboxed apps may post distributed notifications only without a payload.
    static let showRequest = Notification.Name("com.local.petal.showPopover")

    private let fd: Int32

    /// `nil` only when another copy already holds the lock. If the lock file can't be
    /// opened at all, launch proceeds unguarded rather than refusing to start.
    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            petalLog.error("Instance lock unavailable (errno \(errno)); not guarding against a second copy")
            return
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
    }

    deinit { if fd >= 0 { close(fd) } }

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Petal.instance-lock")
    }
}

@main
struct PetalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar only (LSUIElement). Windows are managed by AppDelegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var store: StopwatchStore?
    private var statusBar: StatusBarController?
    private var preferencesPanel: NSPanel?
    private var historyWindow: NSWindow?
    private var settings: AppSettings { AppSettings.shared }
    private var observers: [NSObjectProtocol] = []
    private var isTerminating = false
    private var instanceLock: InstanceLock?

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        NSApp.setActivationPolicy(.accessory)   // belt-and-braces with LSUIElement

        // Must happen before the store is opened: the crash guard in `load()` assumes no
        // other copy is running.
        guard let lock = InstanceLock(url: InstanceLock.defaultURL) else {
            petalLog.notice("Another copy of Petal is already running; showing it instead")
            DistributedNotificationCenter.default().postNotificationName(InstanceLock.showRequest, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock
        ProcessInfo.processInfo.disableAutomaticTermination("Petal keeps time in the menu bar")

        var storeError: String?
        let container: ModelContainer
        do {
            container = try PersistenceController.makeContainer(inMemory: false)
        } catch {
            storeError = error.localizedDescription
            do {
                container = try PersistenceController.makeContainer(inMemory: true)
            } catch {
                fatalError("Petal could not create even an in-memory store: \(error)")
            }
        }

        let store = StopwatchStore(persistence: PersistenceQueue(container: container), settings: settings)
        if let storeError {
            store.reportPersistenceError("Couldn't open Petal's data (\(storeError)). Timers work, but nothing is saved this session.")
        }
        self.store = store

        let bar = StatusBarController(store: store, settings: settings)
        bar.onOpenPreferences = { [weak self] in self?.openPreferences() }
        statusBar = bar

        store.onOpenHistory = { [weak self] in self?.openHistory() }
        store.onFirstLaunch = { [weak bar] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                bar?.showPopover()
            }
        }
        NotificationService.shared.onOpenHistory = { [weak self] in self?.openHistory() }
        NotificationService.shared.configure()

        settings.onChange = { [weak self] change in self?.settingsChanged(change) }
        registerHotKeys()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.handleDayChange() }
        })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.timeZoneChanged() }
        })
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store?.clockChanged() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: InstanceLock.showRequest, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusBar?.showPopover() }
        })

        store.load()
    }

    /// Launching Petal while it already runs (Finder, Spotlight, Launchpad) sends a reopen
    /// event to this copy. With no Dock icon or window, the popover is the only thing to show.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.showPopover()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.isLoaded, !isTerminating else { return .terminateNow }
        isTerminating = true
        store.prepareForTermination { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }

    private func settingsChanged(_ change: AppSettings.Change) {
        switch change {
        case .menuBar: store?.settingsChangedMenuBar()
        case .shortcuts: registerHotKeys()
        case .summary: store?.rescheduleDailySummary()
        case .recording:
            if settings.recordingAction != nil { HotKeyCenter.shared.unregisterAll() } else { registerHotKeys() }
        }
    }

    private func registerHotKeys() {
        guard settings.recordingAction == nil else { return }   // suspended while recording
        let hotKeys = HotKeyCenter.shared
        hotKeys.unregisterAll()
        var failures = Set<String>()
        for action in ShortcutAction.allCases {
            let ok = hotKeys.register(id: action.hotKeyID, combo: settings.combo(for: action)) { [weak self] in
                self?.perform(action)
            }
            if !ok { failures.insert(action.rawValue) }
        }
        for (i, code) in AppSettings.selectionKeyCodes.enumerated() {
            hotKeys.register(id: 100 + UInt32(i), combo: .controlOption(code, "\(i + 1)")) { [weak self] in
                self?.store?.select(position: i + 1)
            }
        }
        settings.shortcutFailures = failures
    }

    private var lastShortcutFire: [ShortcutAction: TimeInterval] = [:]

    private func perform(_ action: ShortcutAction) {
        guard let store, store.isLoaded else { return }
        // Guard against auto-repeat / double delivery toggling a timer twice.
        let now = ProcessInfo.processInfo.systemUptime
        let minimumGap = action == .lap ? 0.15 : 0.3
        if let last = lastShortcutFire[action], now - last < minimumGap { return }
        lastShortcutFire[action] = now
        switch action {
        case .togglePopover:
            statusBar?.togglePopover()
        case .startPause:
            guard let target = store.actionTarget else { return }
            store.select(target.id)
            store.toggle(target.id, haptic: false)
        case .newStopwatch:
            if store.create(navigate: true) != nil { statusBar?.showPopover() }
        case .lap:
            if let target = store.actionTarget, target.isRunning { store.lap(target.id, haptic: false) }
        }
    }

    func openHistory() {
        guard let store else { return }
        statusBar?.closePopover()
        if historyWindow == nil {
            let host = NSHostingController(rootView: HistoryView().environment(store).environment(settings))
            let window = NSWindow(contentViewController: host)
            window.title = "Petal History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 600, height: 620))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            historyWindow = window
        }
        NSApp.activate()
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    func openPreferences() {
        guard let store else { return }
        statusBar?.closePopover()
        if preferencesPanel == nil {
            let host = NSHostingController(rootView: PreferencesView().environment(store).environment(settings))
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
                                styleMask: [.titled, .closable], backing: .buffered, defer: true)
            panel.contentViewController = host
            panel.title = "Petal Preferences"
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            preferencesPanel = panel
        }
        NSApp.activate()
        preferencesPanel?.makeKeyAndOrderFront(nil)
    }

    /// Windows are released after closing so their view trees don't sit in memory.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Deferred so the window isn't deallocated in the middle of its own close.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if window === self.historyWindow { self.historyWindow = nil }
            if window === self.preferencesPanel { self.preferencesPanel = nil }
        }
    }
}
