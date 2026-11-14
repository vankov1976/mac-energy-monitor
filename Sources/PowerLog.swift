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
func dayKey(_ d: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar.current; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
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

    private let cache: URL
    let archive = DailyArchive()
    private let fm = FileManager.default
    private var lastCopy = Date.distantPast

    init() {
        cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacEnergyMonitor")
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    // MARK: log files

    /// Decompressed archives (kept in Caches) plus a fresh copy of the current log.
    func databases() throws -> [String] {
        let archives = Self.logDir + "/Archives"
        var out: [String] = []
        let files = (try? fm.contentsOfDirectory(atPath: archives)) ?? []
        for f in files.sorted() where f.hasSuffix(".PLSQL.gz") {
            let dest = cache.appendingPathComponent(String(f.dropLast(3))).path
            if !fm.fileExists(atPath: dest) {
                let tmp = dest + ".tmp"
                fm.createFile(atPath: tmp, contents: nil)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                p.arguments = ["-c", archives + "/" + f]
                p.standardOutput = handle
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                try handle.close()
                guard p.terminationStatus == 0 else { try? fm.removeItem(atPath: tmp); continue }
                try? fm.removeItem(atPath: dest)
                try fm.moveItem(atPath: tmp, toPath: dest)
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
            for s in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: cur + s)
                if fm.fileExists(atPath: src + s) {
                    let data = try Data(contentsOf: URL(fileURLWithPath: src + s))
                    try data.write(to: URL(fileURLWithPath: cur + s))
                }
            }
            lastCopy = Date()
        }
        out.append(cur)
        return out
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
            if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st {
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
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); continue }
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "select min(timestamp), max(timestamp) from PLCoalitionAgent_EventInterval_CoalitionInterval", -1, &st, nil) == SQLITE_OK,
               let st, sqlite3_step(st) == SQLITE_ROW, !isNull(st, 0) {
                lo = min(lo, dbl(st, 0)); hi = max(hi, dbl(st, 1))
            }
            sqlite3_finalize(st); sqlite3_close(db)
        }
        guard lo.isFinite else { return nil }
        return Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: hi)
    }

    private struct Acc { var energy = 0.0, running = 0.0, cpu = 0.0, screen = 0.0 }

    func report(from startDate: Date, to endDate: Date) throws -> Report {
        let start = startDate.timeIntervalSince1970, end = endDate.timeIntervalSince1970
        let dbs = try databases()
        var apps: [String: Acc] = [:]

        // 1. energy, running time, processor time
        each(dbs, """
            select timestamp, timestampEnd, LaunchdCoalitionId, BundleId, LaunchdName,
                   energy, gpu_energy_nj, cpu_time
            from PLCoalitionAgent_EventInterval_CoalitionInterval
            where timestamp >= ? and timestamp < ?
            """, [start, end],
            key: { "\(Int((self.dbl($0, 0) * 10).rounded()))|\(sqlite3_column_int64($0, 2))|\(self.str($0, 3) ?? "")" }
        ) { st in
            let id = str(st, 3) ?? str(st, 4) ?? "unknown"
            let ts = dbl(st, 0)
            let te = isNull(st, 1) ? ts : dbl(st, 1)
            var a = apps[id, default: Acc()]
            a.energy += (dbl(st, 5) + dbl(st, 6)) / Self.njPerWh
            a.running += min(max(0, min(te, end) - ts), Self.maxInterval)
            a.cpu += dbl(st, 7)
            apps[id] = a
        }

        // Days with energy data (whole-Mac load is logged about every minute while awake). Screen time only
        // counts on those days, so all figures cover the same days (macOS may keep screen-on totals longer).
        var energyDays = Set<String>()
        each(dbs, "select timestamp from PLBatteryAgent_EventBackward_Adapter where timestamp >= ? and timestamp < ?",
             [start - 86400, end], key: { "\(Int((self.dbl($0, 0) * 10).rounded()))" }) { st in
            energyDays.insert(dayKey(Date(timeIntervalSince1970: dbl(st, 0))))
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
                return min(on, 3600) * overlap(hs, hs + 3600, start, end) / 3600
            }
            let on = screenOn[h] ?? 0
            let loggedUntil = min(now, max(hs + (((now - hs) / 300).rounded(.down)) * 300, hs + on))
            let logged = loggedUntil > hs ? min(1, on / (loggedUntil - hs)) * overlap(hs, loggedUntil, start, end) : 0
            let tail = displayOnNow ? overlap(loggedUntil, now, start, end) : 0
            return logged + tail
        }
        var events: [(Double, String)] = []
        each(dbs, "select timestamp, BundleID from PLApplicationAgent_EventForward_FrontmostApp where timestamp >= ? and timestamp < ?",
             [start - 86400, end], key: { "\(Int((self.dbl($0, 0) * 100).rounded()))|\(self.str($0, 1) ?? "")" }) { st in
            events.append((dbl(st, 0), str(st, 1) ?? "unknown"))
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

        let totalWh = max(apps.values.reduce(0) { $0 + $1.energy }, 1e-9)
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
        let (hw, estimatedFrom, dataDays) = hardware(dbs, start: start, end: end, screenByDay: screenByDay)
        return Report(start: startDate, end: endDate, rows: rows, totals: totals, hardware: hw,
                      estimatedFrom: estimatedFrom.map { Date(timeIntervalSince1970: $0) }, dataDays: dataDays)
    }

    // MARK: hardware breakdown for a period (Wh)

    /// Runs `sql` on one log file (no de-duplication).
    private func query(_ path: String, _ sql: String, _ args: [Double], _ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return }
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st {
            for (i, a) in args.enumerated() { sqlite3_bind_double(st, Int32(i + 1), a) }
            while sqlite3_step(st) == SQLITE_ROW { body(st) }
        }
        sqlite3_finalize(st)
        sqlite3_close(db)
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
                """, [start - 7200, end + Self.maxInterval]) { st in
                load[(dbl(st, 0) * 10).rounded() / 10] = (dbl(st, 1), dbl(st, 2))
            }
        }
        var segments: [(a: Double, b: Double, w: Double)] = []
        let pts = load.sorted { $0.key < $1.key }
        for (p, q) in zip(pts, pts.dropFirst()) {
            let dt = q.key - p.key, dn = q.value.n - p.value.n, da = q.value.acc - p.value.acc
            guard dt > 0, dt <= Self.maxInterval, dn > 0, da >= 0 else { continue }   // gaps = sleep or a reset
            segments.append((p.key, q.key, da / dn / 1000))
        }
        func wholeWh(_ x: Double, _ y: Double) -> Double {
            segments.reduce(0) { $0 + $1.w * overlap($1.a, $1.b, x, y) / 3600 }
        }
        let total = wholeWh(start, end)
        // Days with whole-Mac data (logged about every minute while the Mac is awake).
        var dataDays = Set<String>()
        for s in segments where overlap(s.a, s.b, start, end) > 0 {
            dataDays.insert(dayKey(Date(timeIntervalSince1970: max(s.a, start))))
        }
        if !segments.isEmpty { b.total = total }

        // Energy model rows: each covers [timestamp − SampleTime, timestamp].
        var em: [(a: Double, b: Double, c: Double, g: Double, d: Double, chip: Double)] = []
        var seen = Set<Int>()
        for path in dbs {
            query(path, """
                select timestamp, SampleTime, "CPU Energy", "GPU Energy", DRAM0,
                       coalesce(DCS0,0) + coalesce(AMCC0,0) + coalesce(ANE0,0) + coalesce(AVE0,0) + coalesce(ISP0,0) + coalesce(MSR0,0)
                from PLIOReportAgent_EventBackward_EnergyModel where timestamp > ? and timestamp < ?
                """, [start - 7200, end + 7200]) { st in
                let ts = dbl(st, 0), len = dbl(st, 1)
                guard len > 0, seen.insert(Int((ts * 10).rounded())).inserted else { return }
                let c = dbl(st, 2), g = dbl(st, 3), d = dbl(st, 4)
                em.append((ts - len, ts, c / mJperWh, g / mJperWh, d / mJperWh, (c + g + d + dbl(st, 5)) / mJperWh))
            }
        }
        func emParts(_ x: Double, _ y: Double) -> (c: Double, g: Double, d: Double, chip: Double) {
            em.reduce((0, 0, 0, 0)) { acc, r in
                let f = overlap(r.a, r.b, x, y) / (r.b - r.a)
                return (acc.0 + r.c * f, acc.1 + r.g * f, acc.2 + r.d * f, acc.3 + r.chip * f)
            }
        }
        var estimatedFrom: Double?
        if let lastEM = em.map(\.b).max() {
            let covered = min(end, lastEM)
            var parts = emParts(start, covered)
            if covered < end {
                // Not broken down yet: split that time's whole-Mac energy like the logged time just before.
                let refStart = covered - start >= 600 ? start : (em.max { $0.b < $1.b }?.a ?? covered - 1800)
                let ref = emParts(refStart, covered), refTotal = wholeWh(refStart, covered)
                let missing = wholeWh(max(start, covered), end)
                if refTotal > 0 {
                    let k = missing / refTotal
                    parts = (parts.c + ref.c * k, parts.g + ref.g * k, parts.d + ref.d * k, parts.chip + ref.chip * k)
                }
                estimatedFrom = max(start, covered)
            }
            b.cpu = parts.c; b.gpu = parts.g; b.memory = parts.d; b.chip = parts.chip
        }

        // Your apps' processor energy (per-app log, written in batches); the rest of the CPU is macOS's own.
        var appsByEnd: [(t: Double, wh: Double)] = []
        var seenApps = Set<String>()
        var kinds: [String: Bool] = [:]
        for path in dbs {
            query(path, """
                select timestamp, LaunchdCoalitionId, BundleId, LaunchdName, energy
                from PLCoalitionAgent_EventInterval_CoalitionInterval where timestamp > ? and timestamp < ?
                """, [start - 7200, end]) { st in
                let key = "\(Int((dbl(st, 0) * 10).rounded()))|\(sqlite3_column_int64(st, 1))|\(str(st, 2) ?? "")"
                guard seenApps.insert(key).inserted else { return }
                let id = str(st, 2) ?? str(st, 3) ?? "unknown"
                let mine = kinds[id] ?? (Self.describe(id).1 != "System")
                kinds[id] = mine
                if mine { appsByEnd.append((dbl(st, 0), dbl(st, 4) / Self.njPerWh)) }
            }
        }
        func appsWh(_ x: Double, _ y: Double) -> Double {
            appsByEnd.reduce(0) { $0 + ($1.t >= x && $1.t < y ? $1.wh : 0) }
        }
        b.apps = appsWh(start, end)
        if let lastApps = appsByEnd.map(\.t).max(), lastApps < end - 120, let cpu = b.cpu, total > 0 {
            // Per-app energy not logged yet for the last minutes: use your apps' share of the CPU just before.
            let refStart = lastApps - start >= 600 ? start : lastApps - 1800
            let refCPU = emParts(refStart, lastApps).c
            if refCPU > 0 {
                let share = min(1, appsWh(refStart, lastApps) / refCPU)
                b.apps += share * cpu * wholeWh(max(start, lastApps), end) / total
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

    static func describe(_ id: String) -> (String, String, String?) {
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
