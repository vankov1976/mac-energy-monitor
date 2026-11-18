import Foundation

/// One finished local day, summarised and kept on disk after macOS deletes its own power logs (~10 days).
struct DaySummary: Codable {
    var day: String              // "2026-11-13" (local time)
    var start: Double            // Unix seconds, start of the day
    var end: Double              // start of the next day
    var rows: [AppRow]           // per app: energy, running, processor and screen time
    var screenOnH: Double
    var hardware: Breakdown      // Wh for the day
    var savedAt: Double
    /// How the summary was computed: 2 = per-day display estimate (Nov 2026), 3–9 = awake/sleep time and
    /// sleep energy, running time counted once (1.1.5). Older files have none (= 1).
    var version: Int? = DaySummary.currentVersion
    static let currentVersion = 14   // 14: memory / chip parts not logged = unknown, not 0; 11: brief full wakes inside a sleep, pmset restarts = off; 12: logged-awake gaps; 13: re-save days saved in another time zone by tests
}

/// Keeps a small JSON file per day in ~/Library/Application Support/MacEnergyMonitor/Daily
/// (a few kilobytes each), so history reaches back further than macOS keeps its logs.
/// Only used on the log queue (see `PowerLog.fullReport`), hence @unchecked.
final class DailyArchive: @unchecked Sendable {
    let dir: URL
    private let fm = FileManager.default
    private var cache: [String: DaySummary]?
    var lastCheck = Date.distantPast          // throttles saveMissingDays (tests set it)
    private let cal = Calendar.current

    init() {
        // MEM_ARCHIVE_DIR: a different folder, used only for testing with made-up history.
        if let test = ProcessInfo.processInfo.environment["MEM_ARCHIVE_DIR"] {
            dir = URL(fileURLWithPath: test)
        } else {
            dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacEnergyMonitor/Daily")
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A summary's name is its Gregorian date, within a day of its start (whatever time zone it was saved in).
    /// Copies named in another calendar ("1448-05-22", from an older version) would otherwise count twice.
    static func isGregorianName(_ s: DaySummary) -> Bool {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s.day) else { return false }
        return abs(d.timeIntervalSince1970 - s.start) < 36 * 3600
    }

    var days: [DaySummary] {
        if cache == nil {
            var c: [String: DaySummary] = [:]
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
                if let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
                   var s = try? JSONDecoder().decode(DaySummary.self, from: d),
                   // Only files named like dayKey (Gregorian): a copy of the same day saved under another
                   // calendar's name (e.g. "1448-05-22") would otherwise be counted twice.
                   Self.isGregorianName(s) {
                    // Saved before version 14 on a Mac that logs no memory / chip-part values: stored as 0, not unknown.
                    if (s.version ?? 1) < 14, s.hardware.memory == 0 {
                        s.hardware.memory = nil
                        if let ch = s.hardware.chip, ch <= (s.hardware.cpu ?? 0) + (s.hardware.gpu ?? 0) + 1e-6 { s.hardware.chip = nil }
                    }
                    c[s.day] = s
                }
            }
            cache = c
        }
        return cache!.values.sorted { $0.start < $1.start }
    }

    /// Saves every finished day the macOS logs still cover and that isn't saved yet (at most once an hour).
    /// A day is saved once it ended more than 2 hours ago, so macOS has logged its details by then.
    func saveMissingDays(using log: PowerLog, logRange: ClosedRange<Date>) {
        guard Date().timeIntervalSince(lastCheck) > 3600 else { return }
        lastCheck = Date()
        // Days saved by an older version are computed again while macOS still has their logs.
        var saved: [String: Int] = [:]
        for d in days { saved[d.day] = d.version ?? 1 }
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian); df.timeZone = cal.timeZone; df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        var dayStart = cal.startOfDay(for: logRange.lowerBound)
        while true {
            guard let next = cal.date(byAdding: .day, value: 1, to: dayStart) else { break }
            if next > Date().addingTimeInterval(-2 * 3600) { break }
            let name = df.string(from: dayStart)
            // Only days the logs really cover: from the start of the day, with whole-Mac and CPU data.
            // (Days macOS has no logs for are left out instead of being saved as zero.)
            if (saved[name] ?? 0) < DaySummary.currentVersion, logRange.lowerBound <= dayStart.addingTimeInterval(3600),
               let r = try? log.report(from: dayStart, to: next),
               let total = r.hardware.total, total > 0, r.hardware.cpu != nil, !r.rows.isEmpty {
                let s = DaySummary(day: name, start: dayStart.timeIntervalSince1970, end: next.timeIntervalSince1970,
                                   rows: r.rows, screenOnH: r.totals.screenOnH, hardware: r.hardware,
                                   savedAt: Date().timeIntervalSince1970)
                if let data = try? JSONEncoder().encode(s) {
                    try? data.write(to: dir.appendingPathComponent(name + ".json"), options: .atomic)
                    cache?[name] = s
                }
            }
            dayStart = next
        }
    }
}

extension Breakdown {
    /// Sum of two breakdowns (a part is missing only if it is missing in both).
    static func + (a: Breakdown, b: Breakdown) -> Breakdown {
        func add(_ x: Double?, _ y: Double?) -> Double? { x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0) }
        // Awake/asleep hours are only known if known for both (else averages fall back to the whole period).
        func both(_ x: Double?, _ y: Double?) -> Double? { x.flatMap { x in y.map { x + $0 } } }
        var r = Breakdown(display: add(a.display, b.display), cpu: add(a.cpu, b.cpu), apps: a.apps + b.apps,
                          gpu: add(a.gpu, b.gpu), memory: add(a.memory, b.memory), chip: add(a.chip, b.chip),
                          total: add(a.total, b.total))
        r.sleep = add(a.sleep, b.sleep)
        r.sleepEstimated = (a.sleepEstimated ?? false) || (b.sleepEstimated ?? false) ? true : nil
        r.awakeH = both(a.awakeH, b.awakeH)
        r.sleepH = both(a.sleepH, b.sleepH)
        r.offH = add(a.offH, b.offH)
        r.unknownH = add(a.unknownH, b.unknownH)
        r.unknownWh = add(a.unknownWh, b.unknownWh)
        return r
    }

    func scaled(_ k: Double) -> Breakdown {
        var r = Breakdown(display: display.map { $0 * k }, cpu: cpu.map { $0 * k }, apps: apps * k, gpu: gpu.map { $0 * k },
                          memory: memory.map { $0 * k }, chip: chip.map { $0 * k }, total: total.map { $0 * k })
        r.sleep = sleep.map { $0 * k }; r.sleepEstimated = sleepEstimated
        r.awakeH = awakeH.map { $0 * k }; r.sleepH = sleepH.map { $0 * k }; r.offH = offH.map { $0 * k }
        r.unknownH = unknownH.map { $0 * k }; r.unknownWh = unknownWh.map { $0 * k }
        return r
    }
}

extension PowerLog {
    /// Report for any period: macOS's logs where they still exist, the app's saved daily summaries before that.
    /// `pretendLogStart` (diagnostics only) treats macOS's logs as starting later than they do.
    func fullReport(from: Date, to: Date, pretendLogStart: Date? = nil) throws -> Report {
        let logRange = try availableRange()
        if let logRange { archive.saveMissingDays(using: self, logRange: logRange) }
        let logStart = pretendLogStart ?? logRange?.lowerBound ?? to

        // macOS's logs for the part of the period they reach. macOS doesn't always delete its archives
        // oldest-first, so a day inside that range can be missing from them too.
        var rows: [String: AppRow] = [:]
        var hw: Breakdown?, screenH = 0.0
        var estimatedFrom: Date?
        var dataDays = Set<String>()
        if to > logStart || from >= logStart {
            let recent = try report(from: max(from, logStart), to: to)
            hw = recent.hardware
            screenH = recent.totals.screenOnH
            for r in recent.rows { rows[r.id] = Self.merge(rows[r.id], r, 1) }
            estimatedFrom = recent.estimatedFrom
            dataDays = recent.dataDays
        }

        // Saved days fill everything macOS's logs don't have: days before them, and days macOS has deleted
        // in between. A day only partly inside the period counts proportionally; on the day the logs start,
        // only the part before their start comes from the saved summary.
        let a = from.timeIntervalSince1970, z = to.timeIntervalSince1970, ls = logStart.timeIntervalSince1970
        for d in archive.days {
            // Days the logs have count from the logs. A summary saved in another time zone (e.g. while travelling)
            // spans two local days: if the logs have either of them, only its part before the logs' start counts.
            let inLogs = dataDays.contains(d.day) || dataDays.contains(dayKey(Date(timeIntervalSince1970: d.start)))
                || dataDays.contains(dayKey(Date(timeIntervalSince1970: d.end - 1)))
            let upTo = inLogs ? min(d.end, ls) : d.end
            let k = max(0, min(upTo, z) - max(d.start, a)) / (d.end - d.start)
            guard k > 0 else { continue }
            #if DIAGNOSTICS
            if ProcessInfo.processInfo.environment["MEM_SHOW_DAYS"] != nil {
                print("summary used:", d.day, String(format: "k %.3f", k), "inLogs", dataDays.contains(d.day), "logStart", logStart,
                      "dataDays", dataDays.sorted().joined(separator: ","))
            }
            #endif
            var dh = d.hardware.scaled(k)
            if dh.awakeH == nil {          // saved before 1.1.5: not known when the Mac slept
                dh.awakeH = 0; dh.sleepH = 0
                dh.unknownH = (d.end - d.start) * k / 3600; dh.unknownWh = dh.whole
            }
            hw = hw.map { $0 + dh } ?? dh
            screenH += d.screenOnH * k
            for r in d.rows { rows[r.id] = Self.merge(rows[r.id], r, k) }
            dataDays.insert(d.day)
        }
        var list = Array(rows.values)
        // Share = part of the whole Mac's energy (as in Live); without whole-Mac data, part of all apps' energy.
        let hwAll = hw ?? Breakdown()
        let total = hwAll.whole > 0 ? hwAll.whole : max(list.reduce(0) { $0 + $1.energyWh }, 1e-9)
        for i in list.indices {
            list[i].share = 100 * list[i].energyWh / total
            list[i].avgW = list[i].runningH > 0.01 ? list[i].energyWh / list[i].runningH : -1
        }
        list.sort { $0.energyWh > $1.energyWh }
        let totals = Totals(energyWh: list.reduce(0) { $0 + $1.energyWh }, screenOnH: screenH,
                            hours: to.timeIntervalSince(from) / 3600)
        var r = withCoverage(Report(start: from, end: to, rows: list, totals: totals, hardware: hwAll,
                                    estimatedFrom: estimatedFrom, dataDays: dataDays), logStart: logStart)
        // Time with data = awake + asleep where both are known (this leaves out holes in macOS's log too).
        if let a = hwAll.awakeH, let s = hwAll.sleepH {          // also 0 when nothing is logged yet
            r.coveredHours = min(r.coveredHours, a + s + (hwAll.offH ?? 0) + (hwAll.unknownH ?? 0))
        }
        return r
    }

    /// Fills in the days of the period missing from the app's own history: days *before* macOS's logs
    /// (which reach back ~10 days and are trusted as they are) that have no saved daily summary —
    /// the app didn't run before macOS deleted their logs. Also the covered time, for averages.
    private func withCoverage(_ r: Report, logStart: Date) -> Report {
        var r = r
        // Time the saved summaries cover, as absolute intervals (they still fit after a time-zone change).
        let a = r.start.timeIntervalSince1970, z = r.end.timeIntervalSince1970
        var spans: [(Double, Double)] = []
        for d in archive.days where d.end > a && d.start < z {
            if let last = spans.last, d.start <= last.1 { spans[spans.count - 1].1 = max(last.1, d.end) }
            else { spans.append((d.start, d.end)) }
        }
        func coveredSecs(_ x: Double, _ y: Double) -> Double {
            spans.reduce(0) { $0 + max(0, min($1.1, y) - max($1.0, x)) }
        }
        let cal = Calendar.current
        var day = cal.startOfDay(for: r.start)
        var missingSecs = 0.0
        while day < r.end, let next = cal.date(byAdding: .day, value: 1, to: day) {
            // Days macOS's own logs cover (even partly) are trusted as they are — if they have whole-Mac data.
            // A day inside the logs' range without any (macOS's log for it is missing) has no data either.
            // Today is never "no data": what's missing there is only what macOS hasn't logged yet.
            if next > logStart, !r.dataDays.contains(dayKey(day)), next <= Date() {
                let x = max(day, r.start).timeIntervalSince1970, y = min(next, r.end).timeIntervalSince1970
                if y > x {
                    missingSecs += y - x
                    if y - x >= 3600 { r.missingDays.append(day) }
                }
            } else if next <= logStart {
                let x = max(day, r.start).timeIntervalSince1970, y = min(next, r.end).timeIntervalSince1970
                let gap = max(0, (y - x) - coveredSecs(x, y))
                missingSecs += gap
                // Listed as missing when most of its part of the period has no saved data.
                if gap > 0, gap * 2 >= y - x { r.missingDays.append(day) }
            }
            day = next
        }
        r.coveredHours = max(0, r.end.timeIntervalSince(r.start) - missingSecs) / 3600
        r.macOSLogsStart = logStart
        return r
    }

    /// Oldest point with data: saved days or macOS's logs, whichever reaches further back.
    func fullRange() throws -> ClosedRange<Date>? {
        let logRange = try availableRange()
        guard let first = archive.days.first else { return logRange }
        let lo = Date(timeIntervalSince1970: first.start)
        guard let logRange else { return lo...Date(timeIntervalSince1970: archive.days.last!.end) }
        return min(lo, logRange.lowerBound)...logRange.upperBound
    }

    private static func merge(_ a: AppRow?, _ r: AppRow, _ k: Double) -> AppRow {
        var m = a ?? AppRow(id: r.id, name: r.name, kind: r.kind, appPath: r.appPath, share: 0, energyWh: 0,
                            avgW: -1, runningH: 0, cpuH: 0, screenH: 0)
        m.name = r.name; m.kind = r.kind; m.appPath = r.appPath ?? m.appPath
        m.energyWh += r.energyWh * k; m.runningH += r.runningH * k; m.cpuH += r.cpuH * k; m.screenH += r.screenH * k
        return m
    }
}
