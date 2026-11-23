// Reads macOS's own power logs (/var/db/powerlog) and totals energy, running
// time, processor time, screen time and Wi-Fi data per app. Read-only.
import AppKit
import Foundation
import SQLite3

struct AppRow: Identifiable, Hashable, Codable {
    let id: String          // bundle id or process name
    var name: String
    var kind: String        // App / System / Background
    var appPath: String?
    var share: Double
    var energyWh: Double
    var avgW: Double        // -1 when running time is too short to say
    var runningH: Double
    var cpuH: Double
    var screenH: Double
}

struct Totals {
    var energyWh = 0.0, screenOnH = 0.0, hours = 0.0
}

struct Report {
    var start: Date, end: Date
    var rows: [AppRow]
    var totals: Totals
    var hardware = Breakdown()     // Wh for the period
    var estimatedFrom: Date?       // details after this time are not logged by macOS yet (split like the time before)
    var dataDays: Set<String> = [] // local days ("yyyy-MM-dd") for which macOS's logs have whole-Mac data
    var missingDays: [Date] = []   // days in the period with no data at all (start of each day)
    var coveredHours = 0.0         // period length minus the missing days — used for average power
    var macOSLogsStart: Date?      // oldest data in macOS's own power logs on this Mac
}

/// Local calendar day as "yyyy-MM-dd" (also the daily summary file name).
/// One formatter for all calls (making one is slow, and this runs for every log entry); a new one only
/// when the Mac's time zone changed. DateFormatter is thread-safe for formatting.
func dayKey(_ d: Date) -> String {
    DayKey.lock.lock(); defer { DayKey.lock.unlock() }
    if DayKey.formatter == nil || DayKey.formatter!.timeZone != TimeZone.current {
        let f = DateFormatter()
        // Always Gregorian: with another calendar in System Settings the names would be e.g. "1448-05-22".
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        DayKey.formatter = f
    }
    return DayKey.formatter!.string(from: d)
}

private enum DayKey {
    static let lock = NSLock()
    nonisolated(unsafe) static var formatter: DateFormatter?
}

enum PowerLogError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let m): return m }
    }
}

/// Only used from one serial background queue (see Model), hence @unchecked.
final class PowerLog: @unchecked Sendable {
    static let logDir = "/var/db/powerlog/Library/BatteryLife"
    /// The log does not state its unit; nanojoules gives realistic totals on Apple silicon.
    static let njPerWh = 3.6e12
    /// Longer gaps between records are sleep and are not counted as running time.
    static let maxInterval = 600.0
    /// Test builds: `MEM_PRETEND_LAG=<seconds>` ignores log entries newer than that, as if macOS hadn't written them yet.
    static let logCutoff: Double = {
#if DIAGNOSTICS
        if let s = ProcessInfo.processInfo.environment["MEM_PRETEND_LAG"], let lag = Double(s) {
            return Date().timeIntervalSince1970 - lag
        }
#endif
        return .infinity
    }()

    private let cache: URL
    let archive = DailyArchive()
    private let fm = FileManager.default
    private var lastCopy = Date.distantPast
    private var lastStamp = ""             // size/time of the current log at the last copy

    init() {
        // In Application Support (not Caches), so cleaning apps don't delete it while the app runs.
        cache = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacEnergyMonitor/PowerLogs")
        // Versions up to 1.1.1 kept these files in Caches: move them over once (or drop them if already moved).
        let old = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEnergyMonitor")
        if fm.fileExists(atPath: old.path) {
            try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: cache.path) { try? fm.moveItem(at: old, to: cache) }
            try? fm.removeItem(at: old)
        }
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    // MARK: log files

    /// Decompressed archives (kept in Application Support/MacEnergyMonitor/PowerLogs) plus a fresh copy of the current log.
    func databases() throws -> [String] {
        let archives = Self.logDir + "/Archives"
        var out: [String] = []
        // If the folder was deleted anyway while the app runs, recreate it; the archives are simply unpacked again.
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(atPath: archives)) ?? []
        // macOS usually compresses a day's archive (.PLSQL.gz), but sometimes leaves it uncompressed (.PLSQL, seen
        // for 17 and 19 Nov 2026 on one Mac): both count, or those days would be missing.
        for f in files.sorted() where f.hasSuffix(".PLSQL.gz") || f.hasSuffix(".PLSQL") {
            let name = f.hasSuffix(".gz") ? String(f.dropLast(3)) : f
            let dest = cache.appendingPathComponent(name).path
            if out.contains(dest) { continue }                 // the same day both compressed and not: once
            if !fm.fileExists(atPath: dest) {
                // One archive that can't be unpacked or copied is left out; the others still count.
                if f.hasSuffix(".gz") {
                    guard (try? unpack(archives + "/" + f, to: dest)) == true else { continue }
                } else {
                    guard (try? fm.copyItem(atPath: archives + "/" + f, toPath: dest)) != nil else { continue }   // an APFS clone
                }
            }
            out.append(dest)
        }
        // forget archives macOS has rotated away
        for f in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where f.hasSuffix(".PLSQL") {
            let p = cache.appendingPathComponent(f).path
            if !out.contains(p) { try? fm.removeItem(atPath: p) }
        }

        let curDir = cache.appendingPathComponent("current")
        try? fm.createDirectory(at: curDir, withIntermediateDirectories: true)
        let cur = curDir.appendingPathComponent("CurrentPowerlog.PLSQL").path
        if Date().timeIntervalSince(lastCopy) > 60 || !fm.fileExists(atPath: cur) {
            let src = Self.logDir + "/CurrentPowerlog.PLSQL"
            guard fm.isReadableFile(atPath: src) else {
                throw PowerLogError.unreadable("Cannot read the macOS power log at \(src).")
            }
            // Copy only when macOS has written to the log since the last copy (size or time changed). The copy is an
            // APFS clone (copy-on-write): no 34 MB read into memory and written back.
            let stamp = ["", "-wal", "-shm"].map { s -> String in
                let at = try? fm.attributesOfItem(atPath: src + s)
                return "\((at?[.size] as? NSNumber)?.int64Value ?? -1)/\((at?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }.joined(separator: ",")
            if stamp != lastStamp || !fm.fileExists(atPath: cur) {
                for s in ["", "-wal", "-shm"] {
                    try? fm.removeItem(atPath: cur + s)
                    if fm.fileExists(atPath: src + s) {
                        try fm.copyItem(atPath: src + s, toPath: cur + s)
                    }
                }
                lastStamp = stamp
            }
            lastCopy = Date()
        }
        out.append(cur)
        return out
    }

    /// gunzip `src` into `dest` (via a .tmp file, so an interrupted run leaves no half file). False if gunzip failed.
    private func unpack(_ src: String, to dest: String) throws -> Bool {
        let tmp = dest + ".tmp"
        try? fm.removeItem(atPath: tmp)
        guard fm.createFile(atPath: tmp, contents: nil) else { return false }
        defer { try? fm.removeItem(atPath: tmp) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", src]
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        try handle.close()
        guard p.terminationStatus == 0 else { return false }
        try? fm.removeItem(atPath: dest)
        try fm.moveItem(atPath: tmp, toPath: dest)
        return true
    }

    /// Runs `sql` on every log and calls `body` for each row not seen before
    /// (archives overlap with each other and with the current log).
    private func each(_ dbs: [String], _ sql: String, _ args: [Double],
                      key: (OpaquePointer) -> String, _ body: (OpaquePointer) -> Void) {
        var seen = Set<String>()
        for path in dbs {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                sqlite3_close(db); continue
            }
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, PowerLogClock.fix(sql), -1, &st, nil) == SQLITE_OK, let st {
                for (i, a) in args.enumerated() { sqlite3_bind_double(st, Int32(i + 1), a) }
                while sqlite3_step(st) == SQLITE_ROW {
                    if seen.insert(key(st)).inserted { body(st) }
                }
            }
            sqlite3_finalize(st)
            sqlite3_close(db)
        }
    }

    private func dbl(_ st: OpaquePointer, _ i: Int32) -> Double { sqlite3_column_double(st, i) }
    private func isNull(_ st: OpaquePointer, _ i: Int32) -> Bool { sqlite3_column_type(st, i) == SQLITE_NULL }
    private func str(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }

    // MARK: analysis

    func availableRange() throws -> ClosedRange<Date>? {
        var lo = Double.infinity, hi = -Double.infinity
        for path in try databases() {
            guard let r = ranges(path).coalition else { continue }
            lo = min(lo, r.lo); hi = max(hi, r.hi)
        }
        guard lo.isFinite else { return nil }
        return Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: hi)
    }

    /// Time ranges of a log file: its app data (coalitions) and all the tables the reports read. Archives never
    /// change, so theirs are read once; the current log's every time (it grows).
    private struct Ranges { var coalition: (lo: Double, hi: Double)?; var all: (lo: Double, hi: Double)? }
    private var rangeCache: [String: Ranges] = [:]
    private let rangeLock = NSLock()
    private func ranges(_ path: String) -> Ranges {
        let isArchive = !path.hasSuffix("CurrentPowerlog.PLSQL")
        if isArchive { rangeLock.lock(); defer { rangeLock.unlock() }; if let r = rangeCache[path] { return r } }
        var r = Ranges()
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            for table in ["PLCoalitionAgent_EventInterval_CoalitionInterval", "PLBatteryAgent_EventBackward_Adapter",
                          "PLBatteryAgent_EventBackward_Battery", "PLIOReportAgent_EventBackward_EnergyModel"] {
                var st: OpaquePointer?
                if sqlite3_prepare_v2(db, PowerLogClock.fix("select min(timestamp), max(timestamp) from \(table)"), -1, &st, nil) == SQLITE_OK,
                   let st, sqlite3_step(st) == SQLITE_ROW, !isNull(st, 0) {
                    let x = (lo: dbl(st, 0), hi: dbl(st, 1))
                    if table.hasPrefix("PLCoalition") { r.coalition = x }
                    r.all = r.all.map { (min($0.lo, x.lo), max($0.hi, x.hi)) } ?? x
                }
                sqlite3_finalize(st)
            }
        }
        sqlite3_close(db)
        if isArchive { rangeLock.lock(); rangeCache[path] = r; rangeLock.unlock() }
        return r
    }

    /// The log files with data in [lo, hi] (and any whose range is unknown): the others can't add rows.
    func databases(overlapping lo: Double, _ hi: Double) throws -> [String] {
        try databases().filter { p in
            p.hasSuffix("CurrentPowerlog.PLSQL") || (ranges(p).all.map { $0.hi >= lo && $0.lo <= hi } ?? true)
        }
    }

    private struct Acc { var energy = 0.0, running = 0.0, cpu = 0.0, screen = 0.0 }

    func report(from startDate: Date, to endDate: Date) throws -> Report {
        let start = startDate.timeIntervalSince1970, end = endDate.timeIntervalSince1970
        // Queries reach up to a day before and after the period (sleeps, the last record before it): 2 days margin.
        let dbs = try databases(overlapping: start - 2 * 86400, end + 2 * 86400)
        var apps: [String: Acc] = [:]
        var spans: [String: [(Double, Double)]] = [:]     // running intervals per app, inside the period

        // 1. energy, running time, processor time
        each(dbs, """
            select timestamp, timestampEnd, LaunchdCoalitionId, BundleId, LaunchdName,
                   energy, gpu_energy_nj, cpu_time
            from PLCoalitionAgent_EventInterval_CoalitionInterval
            where timestamp >= ? and timestamp < ?
            """, [start - Self.maxInterval, end],
            key: { "\(Int((self.dbl($0, 0) * 10).rounded()))|\(sqlite3_column_int64($0, 2))|\(self.str($0, 3) ?? "")" }
        ) { st in
            let id = Self.owner(str(st, 3) ?? str(st, 4) ?? "unknown")
            let ts = dbl(st, 0)
            let te = isNull(st, 1) ? ts : dbl(st, 1)
            guard te <= Self.logCutoff else { return }
            // Each entry is spread evenly over its interval; only the part inside the period counts.
            let f = Self.fraction(ts, te, start, end)
            guard f > 0 else { return }
            var a = apps[id, default: Acc()]
            a.energy += (dbl(st, 5) + dbl(st, 6)) / Self.njPerWh * f
            let ra = max(ts, start), rb = min(te, ts + Self.maxInterval, end)
            if rb > ra { spans[id, default: []].append((ra, rb)) }
            a.cpu += dbl(st, 7) * f
            apps[id] = a
        }
        // Running time = the time covered by at least one of the app's entries. An app can have several
        // at once (helpers, extensions); overlapping time counts only once.
        for (id, list) in spans {
            var total = 0.0, curA = 0.0, curB = 0.0
            for (x, y) in list.sorted(by: { $0.0 < $1.0 }) {
                if x > curB { total += max(0, curB - curA); curA = x; curB = y } else { curB = max(curB, y) }
            }
            total += max(0, curB - curA)
            apps[id]?.running = total
        }

        // Days with energy data (whole-Mac load is logged about every minute while awake). Screen time only
        // counts on those days, so all figures cover the same days (macOS may keep screen-on totals longer).
        var energyDays = Set<String>()
        var loadTimes: [Double] = []
        each(dbs, "select timestamp from PLBatteryAgent_EventBackward_Adapter where timestamp >= ? and timestamp < ?",
             [start - 86400, end + 3600], key: { "\(Int((self.dbl($0, 0) * 10).rounded()))" }) { st in
            let t = dbl(st, 0)
            loadTimes.append(t)
            if t < end { energyDays.insert(dayKey(Date(timeIntervalSince1970: t))) }
        }
        // When the Mac was awake (whole-Mac values at most 10 minutes apart; awake until now if the last is recent).
        // An hour's screen-on time is spread only over its awake minutes: the screen can't be on while the Mac
        // is asleep or off (e.g. the minutes after a shutdown in the same hour).
        loadTimes.sort()
        var awakeSpans: [(Double, Double)] = []
        for (p, q) in zip(loadTimes, loadTimes.dropFirst()) where q - p <= Self.maxInterval {
            if let l = awakeSpans.last, l.1 >= p { awakeSpans[awakeSpans.count - 1].1 = q } else { awakeSpans.append((p, q)) }
        }
        let nowT = Date().timeIntervalSince1970
        if let last = loadTimes.last, nowT - last <= Self.maxInterval { awakeSpans.append((last, nowT)) }
        func awakeIn(_ x: Double, _ y: Double) -> Double {
            awakeSpans.reduce(0) { $0 + max(0, min($1.1, y) - max($1.0, x)) }
        }
        /// Part of [a, b]'s screen-on time that falls inside the period: by awake time, else evenly.
        func screenShare(_ a: Double, _ b: Double) -> Double {
            let aw = awakeIn(a, b)
            return aw > 0 ? awakeIn(max(a, start), min(b, end)) / aw : overlap(a, b, start, end) / (b - a)
        }

        // 2. screen time: front app, scaled to the logged screen-on seconds per hour
        var screenOn: [Int: Double] = [:]
        // Each hourly entry is stamped a few seconds before the hour it covers (e.g. 21:59:55 = 22:00–23:00),
        // and the current hour's entry holds the seconds so far.
        each(dbs, "select timestamp, ScreenOn from PLDisplayAgent_Aggregate_ScreenOn where timestamp >= ? and timestamp < ?",
             [start - 7200, end], key: { "\(Int(self.dbl($0, 0)))" }) { st in
            let h = Int((dbl(st, 0) + 300) / 3600)
            screenOn[h] = max(screenOn[h] ?? 0, dbl(st, 1))
        }
        let now = Date().timeIntervalSince1970
        /// Screen-on seconds of hour `h` that fall inside [start, end].
        // The current hour's value is only updated every 5 minutes; the minutes since then are counted
        // as screen-on if the display is on right now.
        let displayOnNow = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        func screenOnSeconds(_ h: Int) -> Double {
            let hs = Double(h) * 3600
            guard energyDays.contains(dayKey(Date(timeIntervalSince1970: hs + 1800))) else { return 0 }
            guard now - hs < 3600 else {                       // a finished hour
                guard let on = screenOn[h] else { return 0 }
                return min(on, 3600) * screenShare(hs, hs + 3600)
            }
            let on = screenOn[h] ?? 0
            let loggedUntil = min(now, max(hs + (((now - hs) / 300).rounded(.down)) * 300, hs + on))
            let logged = loggedUntil > hs ? min(on, loggedUntil - hs) * screenShare(hs, loggedUntil) : 0
            let tail = displayOnNow ? overlap(loggedUntil, now, start, end) : 0
            return logged + tail
        }
        var events: [(Double, String)] = []
        each(dbs, "select timestamp, BundleID from PLApplicationAgent_EventForward_FrontmostApp where timestamp >= ? and timestamp < ?",
             [start - 86400, end], key: { "\(Int((self.dbl($0, 0) * 100).rounded()))|\(self.str($0, 1) ?? "")" }) { st in
            events.append((dbl(st, 0), str(st, 1).map(Self.owner) ?? "unknown"))
        }
        // Prefer the app's own front-app record wherever it was running (macOS's log can miss hours).
        let own = FrontAppLog.shared.read(from: start - 86400, to: end)
        func ownCovers(_ t: Double) -> Bool { own.covered.contains { t >= $0.0 && t <= $0.1 } }
        events = events.filter { !ownCovers($0.0) } + own.events.filter { ownCovers($0.0) }
        events.sort { $0.0 < $1.0 }
        var perHour: [Int: [String: Double]] = [:]
        for (i, (ts, id)) in events.enumerated() {
            guard !id.isEmpty else { continue }                  // no app in use (locked, asleep, app quit)
            var t = max(ts, start)
            let segEnd = min(i + 1 < events.count ? events[i + 1].0 : end, end)
            while t < segEnd {
                let h = Int(t / 3600)
                let step = min(segEnd, Double(h + 1) * 3600) - t
                perHour[h, default: [:]][id, default: 0] += step
                t += step
            }
        }
        var hoursInRange = Set(screenOn.keys)
        hoursInRange.insert(Int(now / 3600))                    // the current hour may not be logged yet
        // Screen-on seconds per local day (start of day, Unix seconds), for the per-day display estimate.
        var screenByDay: [Double: Double] = [:]
        let cal = Calendar.current
        for h in hoursInRange {
            let secs = screenOnSeconds(h)
            guard secs > 0 else { continue }
            let mid = Date(timeIntervalSince1970: min(max(Double(h) * 3600 + 1800, start), end))
            screenByDay[cal.startOfDay(for: mid).timeIntervalSince1970, default: 0] += secs
        }
        let screenTotal = screenByDay.values.reduce(0, +)
        for (h, counts) in perHour {
            let total = counts.values.reduce(0, +)
            let on = screenOnSeconds(h)
            guard total > 0, on > 0 else { continue }
            for (id, secs) in counts { apps[id, default: Acc()].screen += secs * on / total }
        }

        let (hw, estimatedFrom, dataDays) = hardware(dbs, start: start, end: end, screenByDay: screenByDay)
        // Share = part of the whole Mac's energy (as in Live); without whole-Mac data, part of all apps' energy.
        let totalWh = hw.whole > 0 ? hw.whole : max(apps.values.reduce(0) { $0 + $1.energy }, 1e-9)
        var rows: [AppRow] = []
        for (id, a) in apps where a.energy > 0.0005 || a.screen > 30 {
            let (name, kind, path) = Self.describe(id)
            let runH = a.running / 3600
            rows.append(AppRow(id: id, name: name, kind: kind, appPath: path,
                               share: 100 * a.energy / totalWh, energyWh: a.energy,
                               avgW: runH > 0.01 ? a.energy / runH : -1,
                               runningH: runH, cpuH: a.cpu / 3600,
                               screenH: a.screen / 3600))
        }
        rows.sort { $0.energyWh > $1.energyWh }
        let totals = Totals(energyWh: rows.reduce(0) { $0 + $1.energyWh },
                            screenOnH: screenTotal / 3600,
                            hours: (end - start) / 3600)
        return Report(start: startDate, end: endDate, rows: rows, totals: totals, hardware: hw,
                      estimatedFrom: estimatedFrom.map { Date(timeIntervalSince1970: $0) }, dataDays: dataDays)
    }

    // MARK: hardware breakdown for a period (Wh)

    /// Runs `sql` on one log file (no de-duplication).
    private func query(_ path: String, _ sql: String, _ args: [Double], _ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return }
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, PowerLogClock.fix(sql), -1, &st, nil) == SQLITE_OK, let st {
            for (i, a) in args.enumerated() { sqlite3_bind_double(st, Int32(i + 1), a) }
            while sqlite3_step(st) == SQLITE_ROW { body(st) }
        }
        sqlite3_finalize(st)
        sqlite3_close(db)
    }

    /// Part of a logged interval [ts, te] that falls inside [x, y), with the energy spread evenly over it.
    /// Intervals longer than `maxInterval` (they span sleep) count as only their first `maxInterval` seconds.
    static func fraction(_ ts: Double, _ te: Double, _ x: Double, _ y: Double) -> Double {
        let b = min(te, ts + maxInterval)
        guard b > ts else { return ts >= x && ts < y ? 1 : 0 }
        return max(0, min(b, y) - max(ts, x)) / (b - ts)
    }

    private func overlap(_ a: Double, _ b: Double, _ start: Double, _ end: Double) -> Double {
        max(0, min(b, end) - max(a, start))
    }

    /// CPU / GPU / memory / chip from the energy-model counters macOS logs every ~30 minutes (mJ per interval),
    /// whole Mac from the logged running total of system load (about every minute), display from
    /// screen-on time × backlight power, your apps from per-app energy (logged in batches).
    /// macOS logs the details later than the whole-Mac total: the minutes it hasn't broken down yet are split
    /// in the same proportions as the time just before (`estimatedFrom` says from when).
    private func hardware(_ dbs: [String], start: Double, end: Double, screenByDay: [Double: Double])
        -> (Breakdown, estimatedFrom: Double?, dataDays: Set<String>) {
        var b = Breakdown()
        let mJperWh = 3.6e6

        // Whole Mac: running total of system load (mW samples) and its sample count.
        var load: [Double: (acc: Double, n: Double)] = [:]
        for path in dbs {
            query(path, """
                select timestamp, AccumulatedSystemLoad, SystemLoadAccumulatorCount
                from PLBatteryAgent_EventBackward_Adapter where timestamp > ? and timestamp < ?
                """, [start - 86400, end + 86400]) { st in
                guard dbl(st, 0) <= Self.logCutoff else { return }
                load[(dbl(st, 0) * 10).rounded() / 10] = (dbl(st, 1), dbl(st, 2))
            }
        }
        var segments: [(a: Double, b: Double, w: Double)] = []
        let pts = load.sorted { $0.key < $1.key }
        // Gaps (sleep): macOS's counter keeps running while the Mac sleeps (about one sample per second), so
        // the running total across a gap is the Mac's real power while asleep. Not after a restart (the counter
        // starts again) or when it stopped counting (fewer samples than seconds): then SleepEnergy falls back.
        var sleepCounter: [(a: Double, b: Double, w: Double)] = []
        // A gap in the whole-Mac values where pmset's log shows no sleep and no restart: the Mac was awake (on some
        // Macs, e.g. a MacBook Air, macOS sometimes logs no values for 10–30 minutes while in use). Awake time,
        // with the counter's energy if it kept counting; not sleep.
        let pmSpans = PMSetLog.shared.spansIfRead() ?? [], pmFrom = PMSetLog.shared.fromIfRead()
        let pmBoots = PMSetLog.shared.bootsIfRead()
        func awakeGap(_ a: Double, _ b: Double) -> Bool {
            guard let f = pmFrom, a >= f, b - a > Self.maxInterval else { return false }
            if pmBoots.contains(where: { $0 > a - 60 && $0 < b + 600 }) { return false }
            return !pmSpans.contains { $0.b > a + 60 && $0.a < b - 60 }
        }
        for (p, q) in zip(pts, pts.dropFirst()) {
            let dt = q.key - p.key, dn = q.value.n - p.value.n, da = q.value.acc - p.value.acc
            guard dt > 0, dn > 0, da >= 0 else { continue }                         // a reset
            if dt <= Self.maxInterval || (awakeGap(p.key, q.key) && abs(dn - dt) <= 0.2 * dt) {
                segments.append((p.key, q.key, da / dn / 1000))
            } else if abs(dn - dt) <= 0.2 * dt {
                sleepCounter.append((p.key, q.key, da / dn / 1000))
            }
        }
        // The last minutes macOS hasn't logged yet (normally 1–3, written about every minute): while the Mac is
        // awake now and the gap is short, they count as awake at the average power of the last logged 15 minutes,
        // so "awake" isn't shorter than "screen on". A longer gap (e.g. right after a long sleep) stays out.
        let nowT = Date().timeIntervalSince1970
        if let lastSeg = segments.last, nowT > lastSeg.b, nowT - lastSeg.b <= Self.maxInterval, nowT <= Self.logCutoff {
            let from = lastSeg.b - 900
            let wh = segments.reduce(0) { $0 + $1.w * overlap($1.a, $1.b, from, lastSeg.b) / 3600 }
            let secs = segments.reduce(0) { $0 + overlap($1.a, $1.b, from, lastSeg.b) }
            if secs > 0 { segments.append((lastSeg.b, nowT, wh * 3600 / secs)) }
        }
        // Whole-Mac energy up to a time, from running totals (segments are in time order, not overlapping),
        // so any interval costs a binary search instead of a pass over all segments.
        var cumEnd = [Double](); cumEnd.reserveCapacity(segments.count)
        var running = 0.0
        for seg in segments { running += seg.w * (seg.b - seg.a) / 3600; cumEnd.append(running) }
        func cumWh(_ t: Double) -> Double {
            var lo = 0, hi = segments.count                      // first segment ending after t
            while lo < hi { let m = (lo + hi) / 2; if segments[m].b <= t { lo = m + 1 } else { hi = m } }
            if lo == segments.count { return running }
            let seg = segments[lo], before = lo > 0 ? cumEnd[lo - 1] : 0
            return before + seg.w * max(0, t - seg.a) / 3600
        }
        func wholeWh(_ x: Double, _ y: Double) -> Double { y > x ? cumWh(y) - cumWh(x) : 0 }
        let total = wholeWh(start, end)
        // Days with whole-Mac data (logged about every minute while the Mac is awake).
        // A day of the period counts if macOS logged whole-Mac values anywhere on it, not only inside the period:
        // a period that starts while the Mac slept (no values in that part) still has data for that day.
        var dataDays = Set<String>()
        let dayCal = Calendar.current
        for s in segments {
            for t in [s.a, max(s.a, s.b - 1)] {
                let d0 = dayCal.startOfDay(for: Date(timeIntervalSince1970: t))
                guard let d1 = dayCal.date(byAdding: .day, value: 1, to: d0),
                      d0.timeIntervalSince1970 < end, d1.timeIntervalSince1970 > start else { continue }
                dataDays.insert(dayKey(d0))
            }
        }
        // Sleeps from macOS's sleep log (pmset), if it has been read: the short background wake-ups inside a sleep
        // (Power Nap, network) count as sleep, not as awake, like in the sleep analysis ("Sleep only"). Without it
        // (not read yet, or older than the log's week) only the time without whole-Mac records counts as sleep.
        let sessions = PMSetLog.shared.spansIfRead().map { $0.filter { $0.b > start - 86400 && $0.a < end + 86400 } } ?? []
        func inSessions(_ x: Double, _ y: Double) -> [(a: Double, b: Double)] {
            sessions.compactMap { s in let a = max(s.a, x), z = min(s.b, y); return z > a ? (a: a, b: z) : nil }
        }
        /// Whole-Mac energy of the background wake-ups inside sleeps in [x, y] (it belongs to the Sleep row).
        func sessionAwakeWh(_ x: Double, _ y: Double) -> Double { inSessions(x, y).reduce(0) { $0 + wholeWh($1.a, $1.b) } }
        let darkWh = sessionAwakeWh(start, end)
        if !segments.isEmpty { b.total = max(0, total - darkWh) }

        // Awake = covered by load records; the gaps between them are asleep or off (see SleepEnergy).
        // No load records at all: nothing known to be awake or asleep (the day counts as "no data").
        b.awakeH = 0; b.sleepH = 0
        if !segments.isEmpty {
            // Only days with whole-Mac data count: a day without any (macOS's log for it is missing, or the
            // Mac was off all day) is neither awake nor asleep, like the "no data" days elsewhere.
            let cal = Calendar.current
            var days = Set<Double>()
            for s in segments { days.insert(cal.startOfDay(for: Date(timeIntervalSince1970: s.a)).timeIntervalSince1970) }
            let lo = max(start, pts.first?.key ?? start), hi = min(end, Date().timeIntervalSince1970)
            // Awake only up to the last logged whole-Mac value: minutes macOS hasn't logged yet have no energy,
            // so counting them as awake would pull the average down.
            // A sleep from pmset's log after the last logged value is known time too (asleep, counted below in
            // sleepH): covered must reach its end, or the sleep is subtracted from time that was never counted
            // (awake too short, its average too high — e.g. right after waking, while macOS's log lags).
            let sleptTo = sessions.filter { $0.a < hi }.map { min($0.b, hi) }.max() ?? -Double.infinity
            let hiAwake = min(hi, max(pts.last?.key ?? hi, segments.last?.b ?? hi, sleptTo))
            var dayRanges: [(a: Double, b: Double)] = []        // whole days with data
            var covered: [(a: Double, b: Double)] = []          // their parts inside [lo, hi]
            for d in days.sorted() {
                let next = cal.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: d))!.timeIntervalSince1970
                dayRanges.append((d, next))
                let a = max(d, lo), z = min(next, hiAwake)
                if z > a { covered.append((a, z)) }
            }
            // Whole sleeps (not cut at the period's edges: the battery is measured over the whole sleep,
            // and SleepEnergy counts only the part inside the period), limited to days with data.
            var gaps: [(a: Double, b: Double)] = []
            for (p, q) in zip(pts, pts.dropFirst()) where q.key - p.key > Self.maxInterval && !awakeGap(p.key, q.key) {
                for c in dayRanges where min(q.key, c.b) > max(p.key, c.a) {
                    gaps.append((max(p.key, c.a), min(q.key, c.b)))
                }
            }
            // Pieces of one gap split at midnight stay one sleep for the battery measurement.
            var merged: [(a: Double, b: Double)] = []
            for g in gaps {
                if let l = merged.last, abs(l.b - g.a) < 1 { merged[merged.count - 1].b = g.b } else { merged.append(g) }
            }
            // A real sleep has a sleep or wake event at its start or end. A gap without one is a hole in
            // macOS's log (e.g. a day's log file is missing): no data, neither asleep nor awake.
            // (Logs without any such events: every gap counts as sleep, as before.)
            var events: [Double] = []
            for path in dbs {
                query(path, "select timestamp from PLSleepWakeAgent_EventForward_PowerState where timestamp > ? and timestamp < ?",
                      [start - 90000, end + 90000]) { events.append(dbl($0, 0)) }
            }
            events.sort()
            func eventNear(_ t: Double) -> Bool {
                var lo = 0, hi = events.count                     // first event ≥ t − 300
                while lo < hi { let m = (lo + hi) / 2; if events[m] < t - 300 { lo = m + 1 } else { hi = m } }
                return lo < events.count && events[lo] <= t + 300
            }
            // A gap with a restart in it (cold boot, logged when the Mac starts) is switched off: from the last value
            // until the restart it counts as "asleep or off" (SleepEnergy gives it 0 on the charger); the minutes
            // between the restart and macOS's first new value have no data.
            var boots: [Double] = []
            for path in dbs {
                query(path, "select timestamp from PLSMCAgent_EventNone_ColdBoot where timestamp > ? and timestamp < ?",
                      [start - 90000, end + 90000]) { boots.append(dbl($0, 0)) }
            }
            boots += PMSetLog.shared.bootsIfRead().filter { $0 > start - 90000 && $0 < end + 90000 }
            var sleeps: [(a: Double, b: Double)] = [], holes: [(a: Double, b: Double)] = [], offs: [(a: Double, b: Double)] = []
            for g in merged {
                // A restart first: the boot itself logs sleep/wake-like events near the gap's end.
                if let boot = boots.filter({ $0 > g.a && $0 <= g.b + 600 }).min() {
                    let off = min(boot, g.b)
                    if off > g.a { sleeps.append((g.a, off)); offs.append((g.a, off)) }
                    if g.b > off { holes.append((off, g.b)) }
                } else if events.isEmpty || eventNear(g.a) || eventNear(g.b) {
                    sleeps.append(g)
                } else {
                    holes.append(g)
                }
            }
            // After macOS's last logged value, the time between the sleeps the sleep log already has: no data, not
            // awake (macOS writes its power log late; those minutes have no energy yet).
            if let last = pts.last?.key, sleptTo > last {
                var cur = last
                for sp in sessions.filter({ $0.b > last && $0.a < sleptTo }).sorted(by: { $0.a < $1.a }) {
                    if sp.a > cur { holes.append((cur, sp.a)) }       // awake between sleeps, but nothing logged yet
                    cur = max(cur, sp.b)
                }
            }
            let holeH = holes.reduce(0) { $0 + overlap($1.a, $1.b, lo, hi) } / 3600
            #if DIAGNOSTICS
            if ProcessInfo.processInfo.environment["MEM_DEBUG_AWAKE"] != nil {
                func t(_ x: Double) -> String { Clock.time(Date(timeIntervalSince1970: x)) + String(format: ":%02d", Int(x) % 60) }
                print("AWAKE lo \(t(lo)) hi \(t(hi)) hiAwake \(t(hiAwake)) lastPt \(pts.last.map { t($0.key) } ?? "-") sleptTo \(sleptTo > 0 ? t(sleptTo) : "-")")
                print("  segments " + segments.filter { $0.b > lo }.map { "\(t($0.a))–\(t($0.b))" }.joined(separator: " "))
                print("  sessions " + sessions.filter { $0.b > lo && $0.a < hi }.map { "\(t($0.a))–\(t($0.b))" }.joined(separator: " "))
                print("  holes " + holes.filter { $0.b > lo }.map { "\(t($0.a))–\(t($0.b))" }.joined(separator: " "))
                // History's sleeps that aren't one of the sleep log's sleeps (gaps in the power log counted as asleep).
                let extra = sleeps.filter { g in !sessions.contains { $0.a < g.b && g.a < $0.b } && g.b > lo && g.a < hi }
                func d(_ x: Double) -> String { Clock.dayTime(Date(timeIntervalSince1970: x)) }
                print("  gap-sleeps outside the sleep log: " + extra.map { "\(d($0.a))–\(t($0.b)) (\(Int(($0.b - $0.a) / 60)) min)" }.joined(separator: ", "))
                let partial = sleeps.filter { g in sessions.contains { $0.a < g.b && g.a < $0.b } && !sessions.contains { $0.a <= g.a + 60 && g.b <= $0.b + 60 } && g.b > lo && g.a < hi }
                print("  gap-sleeps partly outside: " + partial.map { "\(d($0.a))–\(t($0.b))" }.joined(separator: ", "))
            }
            #endif
            // Sleeps from pmset's log, each with the same energy rule as "Sleep only" (SleepEnergy.sessionWh),
            // so the Sleep row and "Sleep only" agree. Gaps outside them (before the log, switched off) as before.
            // The battery log around the WHOLE sleeps, also where a sleep runs past the period's end: the energy of a
            // sleep on battery is its whole charge drop, shared out by time (else a period ending mid-sleep loses it).
            let bat = SleepEnergy.battery(dbs, min(start, sessions.map(\.a).min() ?? start) - 3600,
                                          max(end, sessions.map(\.b).max() ?? end) + 3600)
            // Readings up to a day past the end: the one that closes a counter span reaching into the period can be
            // hours later (e.g. a long sleep that ends after the period). Without it that sleep part has no energy.
            let ctr = SleepAnalysis.Counter(self, from: Date(timeIntervalSince1970: start - 86400),
                                            to: Date(timeIntervalSince1970: end + 86400))
            var sessWh = 0.0, sessKnown = false, sessSecs = 0.0
            // Only the parts of sleeps on days with data (like awake time), so awake + asleep never exceed them.
            for sp in sessions {
                var pieces: [(x: Double, y: Double)] = []
                for c in dayRanges {
                    let x = max(sp.a, start, c.a), y = min(sp.b, hi, c.b)
                    if y > x { pieces.append((x, y)) }
                }
                let secs = pieces.reduce(0) { $0 + $1.y - $1.x }
                sessSecs += secs
                // In one piece when the sleep's part in the period lies on days with data only: split at midnight,
                // a day's piece can miss the counter's 95 % coverage (e.g. MacBook Air) and lose its energy.
                let whole = (x: max(sp.a, start), y: min(sp.b, hi))
                if abs(secs - (whole.y - whole.x)) < 1 { pieces = [whole] }
                for p in pieces {
                    let w = SleepEnergy.sessionWh(full: sp.a, sp.b, part: p.x, p.y, onBattery: sp.onBattery, battery: bat,
                                                  counter: { ctr.wh(Date(timeIntervalSince1970: $0), Date(timeIntervalSince1970: $1)) },
                                                  counted: ctr.counted)
                    #if DIAGNOSTICS
                    if ProcessInfo.processInfo.environment["MEM_DEBUG_SLEEPWH"] != nil {
                        print(String(format: "SLEEPWH %@ – %@ part %@ – %@ battery %@ → %@", "\(Date(timeIntervalSince1970: sp.a))", "\(Date(timeIntervalSince1970: sp.b))",
                                     "\(Date(timeIntervalSince1970: p.x))", "\(Date(timeIntervalSince1970: p.y))", "\(sp.onBattery as Any)", w.map { String(format: "%.3f", $0) } ?? "nil"))
                    }
                    #endif
                    if let w { sessWh += w; sessKnown = true }
                }
            }
            var outside: [(a: Double, b: Double)] = []          // the gaps minus the parts inside sleeps
            for g in sleeps {
                var pieces = [(a: g.a, b: g.b)]
                for sp in sessions where sp.b > g.a && sp.a < g.b {
                    pieces = pieces.flatMap { p -> [(a: Double, b: Double)] in
                        guard sp.b > p.a && sp.a < p.b else { return [p] }
                        return [(a: p.a, b: max(p.a, sp.a)), (a: min(p.b, sp.b), b: p.b)].filter { $0.b > $0.a + 1 }
                    }
                }
                outside += pieces
            }
            // Where pmset's log reaches, only its sleeps are sleep: the rest of a gap (no whole-Mac values, but no sleep
            // or restart either) was awake, with the counter's energy. So the Sleep row equals "Sleep only".
            if let f = pmFrom {
                outside = outside.filter { p in
                    guard p.a >= f, !offs.contains(where: { $0.a < p.b && $0.b > p.a }) else { return true }
                    let x = max(p.a, start), y = min(p.b, hi)
                    if y > x, let wh = ctr.wh(Date(timeIntervalSince1970: x), Date(timeIntervalSince1970: y)) {
                        b.total = (b.total ?? 0) + wh
                    }
                    return false
                }
            }
            let s = SleepEnergy.compute(dbs, gaps: outside, counter: sleepCounter, start: start, end: hi)
            #if DIAGNOSTICS
            if ProcessInfo.processInfo.environment["MEM_SHOW_OUTSIDE"] != nil {
                for p in outside where min(p.b, hi) > max(p.a, start) {
                    print("outside gap", Date(timeIntervalSince1970: p.a), "→", Date(timeIntervalSince1970: p.b),
                          String(format: "%.2f h", (p.b - p.a) / 3600), offs.contains { $0.a < p.b && $0.b > p.a } ? "OFF" : "")
                }
            }
            #endif
            // Switched off (a restart in the gap) is its own time, not sleep: the parts of the gaps outside sleeps
            // that lie in an "off" gap.
            let offSecs = outside.reduce(0.0) { acc, p in acc + offs.reduce(0.0) { $0 + overlap(max(p.a, $1.a), min(p.b, $1.b), start, hi) } }
            b.offH = offSecs / 3600
            b.sleepH = max(0, s.sleepH - offSecs / 3600) + sessSecs / 3600
            // Awake = the rest of the time on days with data, without the log holes. Short stretches without
            // usable load records (e.g. around a restart) are not sleep, so they count as awake.
            b.awakeH = max(0, covered.reduce(0) { $0 + ($1.b - $1.a) } / 3600 - b.sleepH! - b.offH! - holeH)
            b.sleep = s.wh != nil || sessKnown ? (s.wh ?? 0) + sessWh : nil
            #if DIAGNOSTICS
            if ProcessInfo.processInfo.environment["MEM_SHOW_OUTSIDE"] != nil {
                print(String(format: "SLEEP PARTS sessions %.2f h %.3f Wh | outside gaps %.2f h %@ Wh | off %.2f h | pmFrom %@",
                             sessSecs / 3600, sessWh, s.sleepH, s.wh.map { String(format: "%.3f", $0) } ?? "nil", offSecs / 3600,
                             pmFrom.map { "\(Date(timeIntervalSince1970: $0))" } ?? "nil"))
            }
            #endif
            b.sleepEstimated = s.estimated ? true : nil
        }

        // Energy model rows: each covers [timestamp − SampleTime, timestamp].
        var em: [(a: Double, b: Double, c: Double, g: Double, d: Double, chip: Double)] = []
        var seen = Set<Int>()
        // Some Macs (e.g. MacBook Air M1) log only CPU and GPU here: memory and the rest of the chip are then
        // not known (nil, row hidden) instead of 0, and their energy stays in "Other hardware".
        var memLogged = false, chipLogged = false
        for path in dbs {
            query(path, """
                select timestamp, SampleTime, "CPU Energy", "GPU Energy", DRAM0,
                       coalesce(DCS0,0) + coalesce(AMCC0,0) + coalesce(ANE0,0) + coalesce(AVE0,0) + coalesce(ISP0,0) + coalesce(MSR0,0),
                       DRAM0 is not null, coalesce(DCS0, AMCC0, ANE0, AVE0, ISP0, MSR0) is not null
                from PLIOReportAgent_EventBackward_EnergyModel where timestamp > ? and timestamp < ?
                """, [start - 90000, end + 7200]) { st in
                let ts = dbl(st, 0), len = dbl(st, 1)
                guard len > 0, ts <= Self.logCutoff, seen.insert(Int((ts * 10).rounded())).inserted else { return }
                let c = dbl(st, 2), g = dbl(st, 3), d = dbl(st, 4)
                if dbl(st, 6) > 0 { memLogged = true }
                if dbl(st, 7) > 0 { chipLogged = true }
                em.append((ts - len, ts, c / mJperWh, g / mJperWh, d / mJperWh, (c + g + d + dbl(st, 5)) / mJperWh))
            }
        }
        // A chip entry covers 5–260 minutes. Its energy is spread like the whole Mac's energy in that time
        // (it is used while the Mac is awake and busy, not evenly), and evenly only if there is none logged.
        // The Mac's energy while asleep (counter), for spreading chip blocks that cover sleep: the part of a
        // block that falls on sleep is already in the Sleep row, so it isn't counted again in the chip parts.
        func sleepWh(_ x: Double, _ y: Double) -> Double {
            sleepCounter.reduce(0) { $0 + $1.w * overlap($1.a, $1.b, x, y) / 3600 }
        }
        func emParts(_ x: Double, _ y: Double) -> (c: Double, g: Double, d: Double, chip: Double) {
            em.reduce((0, 0, 0, 0)) { acc, r in
                let inside = overlap(r.a, r.b, x, y)
                guard inside > 0 else { return acc }
                let all = wholeWh(r.a, r.b) + sleepWh(r.a, r.b)
                // Only the awake part outside sleeps: the chip's energy in background wake-ups is in the Sleep row.
                let a0 = max(r.a, x), z0 = min(r.b, y)
                let f = all > 0 ? max(0, wholeWh(a0, z0) - sessionAwakeWh(a0, z0)) / all : inside / (r.b - r.a)
                return (acc.0 + r.c * f, acc.1 + r.g * f, acc.2 + r.d * f, acc.3 + r.chip * f)
            }
        }
        var estimatedFrom: Double?
        // The time macOS hasn't broken down yet is split like a fixed reference: the last logged hour with
        // whole-Mac energy before it (6 or 24 hours if the Mac slept through that hour). The same reference
        // for every period, so a period's estimate is the sum of its parts' estimates.
        // The reference is the last hour the Mac was awake (logged whole-Mac time), going back as far as needed:
        // a clock hour the Mac slept through has almost no energy, and dividing by it would blow the estimate up.
        // Time the chip log covers (its entries' spans, merged). macOS can stop writing it for hours while the Mac
        // stays awake (seen on a MacBook Air awake with the lid closed) while the per-app log goes on: time it
        // doesn't cover is unknown, not 0, and gets the same estimate as the minutes after its last entry.
        var emCov: [(a: Double, b: Double)] = []
        for r in em.sorted(by: { $0.a < $1.a }) {
            if let l = emCov.last, r.a <= l.b + 1 { emCov[emCov.count - 1].b = max(l.b, r.b) } else { emCov.append((r.a, r.b)) }
        }
        func uncovered(_ x: Double, _ y: Double) -> [(a: Double, b: Double)] {
            var out: [(a: Double, b: Double)] = [], cur = x
            for c in emCov where c.b > x && c.a < y {
                if c.a > cur { out.append((cur, c.a)) }
                cur = max(cur, c.b)
            }
            if cur < y { out.append((cur, y)) }
            return out
        }
        /// Awake whole-Mac energy outside the sleeps' background wake-ups (that is in the Sleep row).
        func awakeWh(_ x: Double, _ y: Double) -> Double { max(0, wholeWh(x, y) - sessionAwakeWh(x, y)) }
        // The time macOS hasn't broken down is split like a fixed reference: the last hour the Mac was awake
        // (logged whole-Mac time) AND the chip log covers, going back as far as needed. The same reference for
        // every period, so a period's estimate is the sum of its parts' estimates.
        func refStart(before t: Double) -> Double {
            var awake = 0.0
            for seg in segments.reversed() where seg.a < t {
                for c in emCov.reversed() where c.a < min(seg.b, t) && c.b > seg.a {
                    let a = max(seg.a, c.a), b = min(seg.b, t, c.b)
                    guard b > a else { continue }
                    awake += b - a
                    if awake >= 3600 { return a + (awake - 3600) }
                }
            }
            return segments.first?.a ?? t - 86400
        }
        let lastEM = em.map(\.b).max()
        let emRef = lastEM.map { l -> (c: Double, g: Double, d: Double, chip: Double, total: Double) in
            let rs = refStart(before: l), r = emParts(rs, l)
            return (r.c, r.g, r.d, r.chip, emCov.reduce(0) { $0 + awakeWh(max($1.a, rs), min($1.b, l)) })
        }
        /// CPU / GPU / memory / chip for [x, y]: logged, plus the estimate for the awake time the chip log doesn't
        /// cover (gaps in it, and the time after its last entry).
        func emEst(_ x: Double, _ y: Double) -> (c: Double, g: Double, d: Double, chip: Double) {
            guard lastEM != nil else { return (0, 0, 0, 0) }
            var p = emParts(x, y)
            if let r = emRef, r.total > 0 {
                // The chip can't use more than the whole Mac: never split more than the whole-Mac energy itself.
                let k = uncovered(x, y).reduce(0) { $0 + awakeWh($1.a, $1.b) } / max(r.total, r.chip)
                p = (p.c + r.c * k, p.g + r.g * k, p.d + r.d * k, p.chip + r.chip * k)
            }
            return p
        }
        if let lastEM {
            let parts = emEst(start, end)
            if lastEM < end { estimatedFrom = max(start, lastEM) }
            b.cpu = parts.c; b.gpu = parts.g
            b.memory = memLogged ? parts.d : nil
            b.chip = chipLogged || memLogged ? parts.chip : nil
        }

        // Your apps' processor energy (per-app log, written in batches); the rest of the CPU is macOS's own.
        var appsByEnd: [(t: Double, te: Double, wh: Double)] = []
        var seenApps = Set<String>()
        var kinds: [String: Bool] = [:]
        for path in dbs {
            query(path, """
                select timestamp, LaunchdCoalitionId, BundleId, LaunchdName, energy, timestampEnd
                from PLCoalitionAgent_EventInterval_CoalitionInterval where timestamp > ? and timestamp < ?
                """, [start - 90000, end]) { st in
                let key = "\(Int((dbl(st, 0) * 10).rounded()))|\(sqlite3_column_int64(st, 1))|\(str(st, 2) ?? "")"
                guard seenApps.insert(key).inserted else { return }
                let id = Self.owner(str(st, 2) ?? str(st, 3) ?? "unknown")
                let mine = kinds[id] ?? (Self.describe(id).1 != "System")
                kinds[id] = mine
                let ts = dbl(st, 0)
                if mine, (isNull(st, 5) ? ts : dbl(st, 5)) <= Self.logCutoff { appsByEnd.append((ts, isNull(st, 5) ? ts : dbl(st, 5), dbl(st, 4) / Self.njPerWh)) }
            }
        }
        // Your apps' processor energy while awake; what they used in background wake-ups inside sleeps is in Sleep.
        func appsWh(_ x: Double, _ y: Double) -> Double {
            let sl = inSessions(x, y)
            return appsByEnd.reduce(0) { acc, r in
                let f = Self.fraction(r.t, r.te, x, y) - sl.reduce(0) { $0 + Self.fraction(r.t, r.te, $1.a, $1.b) }
                return acc + r.wh * max(0, f)
            }
        }
        b.apps = appsWh(start, end)
        if let lastApps = appsByEnd.map({ min($0.te, $0.t + Self.maxInterval) }).max(), lastApps < end, b.cpu != nil {
            // Per-app energy not logged yet: your apps' share of the CPU in the same fixed reference
            // (the last logged hour with energy before it), applied to the CPU of the time after it.
            let rs = refStart(before: lastApps)
            let refCPU = emEst(rs, lastApps).c
            if refCPU > 0 {
                let share = min(1, appsWh(rs, lastApps) / refCPU)
                b.apps += share * emEst(max(start, lastApps), end).c
                estimatedFrom = min(estimatedFrom ?? .infinity, max(start, lastApps))
            }
        }

        // Display, per local day: that day's average backlight power (SMC PDBR, logged as averages over
        // CycleCountDiff cycles) × that day's screen-on time. Samples from all log files, de-duplicated.
        var pdbr: [Double: (n: Double, v: Double)] = [:]
        let firstDay = screenByDay.keys.min() ?? start
        for path in dbs {
            var key: String?
            query(path, "select KeyIndex from SMC_AccumulatedLookUpTable_2_2 where KeyName = 'PDBR' order by timestamp desc limit 1", []) { st in
                key = self.str(st, 0)
            }
            guard let key, key.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            query(path, "select timestamp, CycleCountDiff, \(key) from SMC_AccumulatedKeyValues_1_2 where \(key) is not null and timestamp >= ? and timestamp < ?",
                  [min(firstDay, start), end + 3600]) { st in
                let n = self.dbl(st, 1), v = self.dbl(st, 2)
                guard n > 0, v >= 0, v < 100 else { return }
                pdbr[(self.dbl(st, 0) * 10).rounded() / 10] = (n, v)
            }
            if pdbr.isEmpty {   // nothing logged in the period yet: the latest values before its end
                query(path, "select timestamp, CycleCountDiff, \(key) from SMC_AccumulatedKeyValues_1_2 where \(key) is not null and timestamp < ? order by timestamp desc limit 6", [end]) { st in
                    let n = self.dbl(st, 1), v = self.dbl(st, 2)
                    guard n > 0, v >= 0, v < 100 else { return }
                    pdbr[(self.dbl(st, 0) * 10).rounded() / 10] = (n, v)
                }
            }
        }
        func avgW(_ x: Double, _ y: Double) -> Double? {
            var sum = 0.0, w = 0.0
            for (t, s) in pdbr where t >= x && t < y { sum += s.v * s.n; w += s.n }
            return w > 0 ? sum / w : nil
        }
        if !pdbr.isEmpty, !screenByDay.isEmpty {
            let overall = avgW(-.infinity, .infinity)!
            let cal = Calendar.current
            var dayAvg: [Double: Double] = [:]
            for d in screenByDay.keys {
                let next = cal.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: d))!.timeIntervalSince1970
                // The part of the day inside the period, else the whole day.
                if let a = avgW(max(d, start), min(next, end + 3600)) ?? avgW(d, next) { dayAvg[d] = a }
            }
            var display = 0.0
            for (d, secs) in screenByDay {
                // Day without backlight values: the nearest day that has them, else the period's average.
                let avg = dayAvg[d] ?? dayAvg.min { abs($0.key - d) < abs($1.key - d) }?.value ?? overall
                display += avg * secs / 3600
            }
            b.display = display
        }
        return (b, estimatedFrom, dataDays)
    }

    // MARK: names

    static let friendly: [String: String] = [
        "com.apple.WindowServer": "WindowServer (screen drawing)",
        "com.apple.kernel_task": "kernel_task (macOS core)",
        "com.apple.loginwindow": "Lock screen / login window",
        "com.apple.notificationcenterui.agent": "Notification Center / widgets",
        "com.apple.MenuBarAgent": "Menu bar (macOS)",
        "com.apple.mediaanalysisd": "Photos media analysis",
        "com.parallels.desktop.launchdaemon": "Parallels Desktop (VMs)",
    ]

    /// The app an entry belongs to, so the history lists the same apps as the Live view (which groups by the
    /// app that started a process): an app extension, widget, agent or helper app is logged under its own ID
    /// ("eu.exelban.Stats.Widgets") but counts for its app ("eu.exelban.Stats"). Found by the app the ID's
    /// bundle sits inside, or else by the ID's shorter forms that belong to an installed app.
    /// macOS's own IDs and the named services in `friendly` stay as they are.
    static func owner(_ id: String) -> String {
        ownerLock.lock(); defer { ownerLock.unlock() }
        if Date().timeIntervalSince(owners.at) > 600 { owners = (Date(), [:]) }
        if let o = owners.map[id] { return o }
        let o = findOwner(id)
        owners.map[id] = o
        return o
    }

    private static let ownerLock = NSLock()
    nonisolated(unsafe) private static var owners: (at: Date, map: [String: String]) = (Date(), [:])

    private static func findOwner(_ id: String) -> String {
        if friendly[id] != nil || id.hasPrefix("com.apple.") || !id.contains(".") { return id }
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: id) {
            // A helper app inside another app (…/Outer.app/Contents/…/Helper.app): the outer app.
            let p = url.path
            if let r = p.range(of: ".app/Contents/") {
                let outer = URL(fileURLWithPath: String(p[..<r.lowerBound]) + ".app")
                if let oid = Bundle(url: outer)?.bundleIdentifier, oid != id { return oid }
            }
            return id
        }
        var parts = id.split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            let candidate = parts.joined(separator: ".")
            if let url = ws.urlForApplication(withBundleIdentifier: candidate), !url.path.contains(".app/Contents/") {
                return candidate
            }
        }
        return id
    }

    /// Looking an app up in macOS's app database is slow, so each ID is looked up once per 10 minutes
    /// (apps can be installed, moved or deleted meanwhile).
    private static let describeLock = NSLock()
    nonisolated(unsafe) private static var described: (at: Date, map: [String: (String, String, String?)]) = (Date(), [:])

    static func describe(_ id: String) -> (String, String, String?) {
        describeLock.lock(); defer { describeLock.unlock() }
        if Date().timeIntervalSince(described.at) > 600 { described = (Date(), [:]) }
        if let d = described.map[id] { return d }
        let d = lookUp(id)
        described.map[id] = d
        return d
    }

    private static func lookUp(_ id: String) -> (String, String, String?) {
        if let f = friendly[id] { return (f, id.hasPrefix("com.apple.") ? "System" : "Background", nil) }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            let nested = url.path.contains(".app/Contents/")
            return (name, nested ? "System" : "App", url.path)
        }
        let short = id.split(separator: ".").last.map(String.init) ?? id
        return (short, id.hasPrefix("com.apple.") ? "System" : "Background", nil)
    }
}

/// macOS's power log can run on a shifted clock: its own table PLStorageOperator_EventForward_TimeOffset says how far
/// (column `system`: seconds to add to its timestamps for real time). Usually a few seconds; on a MacBook Air with a
/// macOS beta it was about −1 h 56 min, which put every power value two hours away from the sleep log's events.
/// Every query on the power log goes through `fix`: with an offset over a minute, `timestamp` / `timestampEnd`
/// become real time, both in what the query selects and in its conditions. One offset for all log files (the
/// current log's), so rows found in several files still match exactly when they are de-duplicated.
enum PowerLogClock {
    nonisolated(unsafe) private static var cached: (off: Double, at: Double)?
    private static let lock = NSLock()

    /// Seconds to add to the power log's timestamps (0 when under a minute).
    static var offset: Double {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if let c = cached, now - c.at < 600 { return c.off }
        var off = 0.0
        #if DIAGNOSTICS
        if let s = ProcessInfo.processInfo.environment["MEM_LOG_OFFSET"], let v = Double(s) { cached = (v, now); return v }
        #endif
        var db: OpaquePointer?
        if sqlite3_open_v2(PowerLog.logDir + "/CurrentPowerlog.PLSQL", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var st: OpaquePointer?
            // The median of the recent rows (a single row can be a brief outlier).
            if sqlite3_prepare_v2(db, "select system from PLStorageOperator_EventForward_TimeOffset where system is not null order by timestamp desc limit 15", -1, &st, nil) == SQLITE_OK, let st {
                var v: [Double] = []
                while sqlite3_step(st) == SQLITE_ROW { v.append(sqlite3_column_double(st, 0)) }
                if !v.isEmpty { off = v.sorted()[v.count / 2] }
            }
            sqlite3_finalize(st)
        }
        sqlite3_close(db)
        if abs(off) < 60 { off = 0 }
        cached = (off, now)
        return off
    }

    /// The query with real times. Conditions keep the log's own column, with the bound shifted
    /// (`timestamp > ?` → `timestamp > (? - offset)`), so the log's index is still used; `order by` stays (a constant
    /// shift keeps the order); every other `timestamp` / `timestampEnd` becomes `(timestamp + offset)`.
    static func fix(_ sql: String) -> String {
        let off = offset
        guard off != 0 else { return sql }
        let o = String(format: "%.3f", off)
        var q = sql.replacingOccurrences(of: #"\btimestamp(End)?\s*(<=|>=|<|>|=)\s*\?"#, with: "§ts$1§ $2 (? - \(o))",
                                         options: .regularExpression)
        q = q.replacingOccurrences(of: #"order by timestamp(End)?\b"#, with: "order by §ts$1§", options: .regularExpression)
        q = q.replacingOccurrences(of: #"\btimestamp(End)?\b"#, with: "(timestamp$1 + \(o))", options: .regularExpression)
        return q.replacingOccurrences(of: #"§ts(End)?§"#, with: "timestamp$1", options: .regularExpression)
    }
}
