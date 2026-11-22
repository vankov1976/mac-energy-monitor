import Foundation

/// `--gaptest [all|tzwrite|tzread]`: automated tests of the saved daily history with made-up days.
/// Only runs with MEM_ARCHIVE_DIR set to a test folder (never the real history folder).
/// Meant to run with TZ=Europe/Berlin (`all`, `tzwrite`) and TZ=America/New_York (`tzread`); see tools/gaptest.sh.
enum GapTests {
    static var pass = 0, fail = 0
    static let cal = Calendar.current

    static func runIfAsked() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--gaptest") else { return }
        let phase = i + 1 < a.count ? a[i + 1] : "all"
        guard let dir = ProcessInfo.processInfo.environment["MEM_ARCHIVE_DIR"], !dir.isEmpty,
              !dir.contains("Application Support/MacEnergyMonitor") else {
            print("gaptest: set MEM_ARCHIVE_DIR to a test folder"); exit(2)
        }
        let url = URL(fileURLWithPath: dir)
        print("gaptest \(phase), time zone \(TimeZone.current.identifier), folder \(url.lastPathComponent)")
        switch phase {
        case "tzwrite": tzWrite(url)
        case "tzread": tzRead(url)
        default:
            edgesAndMidDay(url); damagedFiles(url); daylightSaving(url); partlyCovered(url); appOff15Days(url); overlappingDays(url)
        }
        print("gaptest \(phase): \(pass) passed, \(fail) failed")
        exit(fail == 0 ? 0 : 1)
    }

    // MARK: helpers

    static func check(_ ok: Bool, _ what: String) {
        if ok { pass += 1 } else { fail += 1; print("  FAIL: \(what)") }
    }
    static func near(_ a: Double?, _ b: Double, _ what: String, tol: Double = 0.01) {
        check(a.map { abs($0 - b) <= tol } ?? false, "\(what): got \(a.map { String(format: "%.3f", $0) } ?? "nil"), expected \(String(format: "%.3f", b))")
    }
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in c: Calendar = cal) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    static func clear(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    /// A made-up saved day: whole Mac `wh`, other parts in fixed proportions.
    static func day(_ start: Date, _ wh: Double, in c: Calendar = cal) -> DaySummary {
        let next = c.date(byAdding: .day, value: 1, to: start)!
        let f = DateFormatter()
        f.calendar = c; f.timeZone = c.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let row = AppRow(id: "test.app", name: "Test App", kind: "App", appPath: nil, share: 100, energyWh: wh * 0.1,
                         avgW: -1, runningH: 10, cpuH: 1, screenH: 4)
        return DaySummary(day: f.string(from: start), start: start.timeIntervalSince1970, end: next.timeIntervalSince1970,
                          rows: [row], screenOnH: 5,
                          hardware: Breakdown(display: wh * 0.1, cpu: wh * 0.3, apps: wh * 0.1, gpu: wh * 0.05,
                                              memory: wh * 0.05, chip: wh * 0.5, total: wh),
                          savedAt: Date().timeIntervalSince1970)
    }
    static func write(_ days: [DaySummary], _ dir: URL) {
        for d in days { try! JSONEncoder().encode(d).write(to: dir.appendingPathComponent(d.day + ".json")) }
    }
    /// A fresh log reader (re-reads the folder). Without `autosave` it doesn't save days from the real macOS logs.
    static func fresh(autosave: Bool = false) -> PowerLog {
        let log = PowerLog()
        if !autosave { log.archive.lastCheck = Date() }
        return log
    }
    static func keys(_ ds: [Date]) -> [String] { ds.map(dayKey) }

    // MARK: scenarios

    /// Gaps at the start, in the middle and at the end of a period; periods starting/ending mid-day.
    static func edgesAndMidDay(_ dir: URL) {
        print("- gaps at period edges and mid-day")
        clear(dir)
        write([10, 11, 13, 14, 15].map { day(date(2026, 3, $0), Double(100 + 10 * ($0 - 10))) }, dir)
        // wh: 10 Mar 100, 11 Mar 110, 13 Mar 130, 14 Mar 140, 15 Mar 150
        var r = try! fresh().fullReport(from: date(2026, 3, 10, 12), to: date(2026, 3, 15, 6))
        check(keys(r.missingDays) == ["2026-03-12"], "mid gap flags only 12 Mar: \(keys(r.missingDays))")
        near(r.coveredHours, 114 - 24, "covered hours, mid gap")
        near(r.hardware.total, 0.5 * 100 + 110 + 130 + 140 + 0.25 * 150, "whole Mac, half/quarter edge days")
        near(r.totals.screenOnH, 5 * (0.5 + 3 + 0.25), "screen-on hours scaled")

        r = try! fresh().fullReport(from: date(2026, 3, 9, 18), to: date(2026, 3, 16, 6))
        check(keys(r.missingDays) == ["2026-03-09", "2026-03-12", "2026-03-16"], "edge gaps flagged: \(keys(r.missingDays))")
        near(r.coveredHours, 156 - 36, "covered hours, edge gaps count only their part in the period")
        near(r.hardware.total, 630, "whole Mac, edge gaps")
        near(r.rows.first?.energyWh, 63, "app row summed")

        r = try! fresh().fullReport(from: date(2026, 3, 12, 3), to: date(2026, 3, 12, 20))
        check(keys(r.missingDays) == ["2026-03-12"], "period inside one missing day")
        near(r.coveredHours, 0, "nothing covered inside a missing day")
        check(r.hardware.total == nil && r.rows.isEmpty, "no made-up numbers for a missing day")
    }

    /// A day saved in another time zone (here New York, by an older version) overlaps the next saved day:
    /// the overlapping hours count once (from the newer summary), the hours no summary covers count as missing.
    static func overlappingDays(_ dir: URL) {
        print("- overlapping saved days (one saved in New York time)")
        clear(dir)
        var ny = Calendar(identifier: .gregorian); ny.timeZone = TimeZone(identifier: "America/New_York")!
        var odd = day(date(2026, 3, 11, in: ny), 110, in: ny); odd.version = 11
        let days = [day(date(2026, 3, 10), 100), odd, day(date(2026, 3, 12), 120), day(date(2026, 3, 13), 130)]
        write(days, dir)
        let from = date(2026, 3, 10), to = date(2026, 3, 14)
        let overlap = max(0, odd.end - days[2].start), gap = max(0, odd.start - days[0].end)    // seconds
        let r = try! fresh().fullReport(from: from, to: to)
        near(r.hardware.total, 100 + 110 * (86400 - overlap) / 86400 + 120 + 130, "whole Mac: the overlap counts once")
        near(r.hardware.unknownH, (4 * 86400 - gap) / 3600, "hours: every covered hour once")
        near(r.coveredHours, (4 * 86400 - gap) / 3600, "covered hours: the uncovered gap is left out")
        check((r.hardware.unknownH ?? 0) <= r.coveredHours + 0.05, "counted hours ≤ covered hours")
    }

    /// Damaged, truncated, empty and unrelated files are skipped (the day counts as missing), no crash.
    static func damagedFiles(_ dir: URL) {
        print("- damaged JSON files")
        clear(dir)
        write([day(date(2026, 3, 10), 100), day(date(2026, 3, 11), 110)], dir)
        let good = try! JSONEncoder().encode(day(date(2026, 3, 13), 130))
        try! Data("{ not json".utf8).write(to: dir.appendingPathComponent("2026-03-12.json"))
        try! good.prefix(good.count / 2).write(to: dir.appendingPathComponent("2026-03-13.json"))
        try! Data().write(to: dir.appendingPathComponent("2026-03-14.json"))
        try! Data("hello".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let r = try! fresh().fullReport(from: date(2026, 3, 10), to: date(2026, 3, 15))
        check(keys(r.missingDays) == ["2026-03-12", "2026-03-13", "2026-03-14"], "damaged days flagged: \(keys(r.missingDays))")
        near(r.hardware.total, 210, "whole Mac from the good days only")
        near(r.coveredHours, 48, "covered hours (up to 3 min less: time with data starts at the first logged value)", tol: 0.05)
        check(r.hardware.whole.isFinite, "no NaN")
    }

    /// 29 Mar 2026 (23 h) and 25 Oct 2026 (25 h) in Europe/Berlin.
    static func daylightSaving(_ dir: URL) {
        print("- daylight-saving days")
        guard TimeZone.current.identifier == "Europe/Berlin" else { check(false, "run with TZ=Europe/Berlin"); return }
        for (m, d, len) in [(3, 29, 23.0), (10, 25, 25.0)] {
            clear(dir)
            let days = [d - 1, d, d + 1].map { day(date(2026, m, $0), 100) }
            near((days[1].end - days[1].start) / 3600, len, "length of \(days[1].day)")
            write(days, dir)
            var r = try! fresh().fullReport(from: date(2026, m, d - 1), to: date(2026, m, d + 2))
            check(r.missingDays.isEmpty, "\(days[1].day): nothing missing")
            near(r.coveredHours, 48 + len, "\(days[1].day): period length")
            near(r.hardware.total, 300, "\(days[1].day): whole Mac")
            // Half a local day (00:00–12:00) on the DST day: 11 or 13 real hours.
            r = try! fresh().fullReport(from: date(2026, m, d), to: date(2026, m, d, 12))
            let realH = len == 23 ? 11.0 : 13.0
            near(r.coveredHours, realH, "\(days[1].day) 00–12: real hours")
            near(r.hardware.total, 100 * realH / len, "\(days[1].day) 00–12: share of the day")
            // DST day missing
            try! FileManager.default.removeItem(at: dir.appendingPathComponent(days[1].day + ".json"))
            r = try! fresh().fullReport(from: date(2026, m, d - 1), to: date(2026, m, d + 2))
            check(keys(r.missingDays) == [days[1].day], "\(days[1].day) missing is flagged")
            near(r.coveredHours, 48, "\(days[1].day) missing: covered hours")
        }
    }

    /// A saved day on the day macOS's logs (pretend) start: only the part before their start comes from the summary.
    static func partlyCovered(_ dir: URL) {
        print("- partly covered saved days (with real macOS logs)")
        clear(dir)
        // Days relative to macOS's current logs (it deletes old ones): D = the first day after the logs' first day
        // that has whole-Mac data, P = the day before it. The logs are pretended to start at noon on D.
        let log = fresh()
        guard let range = try? log.availableRange() else { check(false, "no macOS logs"); return }
        var dDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: range.lowerBound))!
        while ((try? log.report(from: dDay, to: cal.date(byAdding: .day, value: 1, to: dDay)!))?.hardware.total ?? 0) <= 0 {
            dDay = cal.date(byAdding: .day, value: 1, to: dDay)!
            if dDay > Date() { check(false, "no day with whole-Mac data in macOS's logs"); return }
        }
        let pDay = cal.date(byAdding: .day, value: -1, to: dDay)!, nDay = cal.date(byAdding: .day, value: 1, to: dDay)!
        let ls = dDay.addingTimeInterval(12 * 3600)
        let real = try! log.report(from: ls, to: nDay)
        let logsHaveD = real.dataDays.contains(dayKey(dDay))
        write([day(pDay, 400), day(dDay, 1000)], dir)
        var r = try! fresh().fullReport(from: pDay, to: nDay, pretendLogStart: ls)
        check(r.missingDays.isEmpty, "nothing missing: \(keys(r.missingDays))")
        near(r.hardware.total, 400 + (logsHaveD ? 500 : 1000) + (real.hardware.total ?? 0),
             "whole Mac = day before + morning of D (saved) + afternoon (logs)")
        near(r.coveredHours, 48, "covered hours (up to 3 min less: time with data starts at the first logged value)", tol: 0.05)
        try! FileManager.default.removeItem(at: dir.appendingPathComponent(dayKey(pDay) + ".json"))
        r = try! fresh().fullReport(from: pDay, to: nDay, pretendLogStart: ls)
        check(keys(r.missingDays) == [dayKey(pDay)], "the day before the logs, not saved, flagged: \(keys(r.missingDays))")
        check(!keys(r.missingDays).contains(dayKey(dDay)), "the logs' first day is never flagged")
    }

    /// The app didn't run for 15 days (last saved day 29 Oct), then starts: it saves only days macOS still has.
    static func appOff15Days(_ dir: URL) {
        print("- app not run for 15 days, then starts")
        let log0 = fresh()
        guard let range = try! log0.availableRange() else { check(false, "no macOS logs"); return }
        let from = date(2026, 10, 15), now = Date()
        let lastSaved = cal.date(byAdding: .day, value: -16, to: cal.startOfDay(for: now))!
        func oldDays() -> [DaySummary] {
            var out: [DaySummary] = [], d = from
            while d <= lastSaved { out.append(day(d, 100)); d = cal.date(byAdding: .day, value: 1, to: d)! }
            return out
        }
        func files() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { String($0.prefix(10)) })
        }
        func expectedMissing(_ logStart: Date, saved: Set<String>) -> [String] {
            var out: [String] = [], d = cal.date(byAdding: .day, value: 1, to: lastSaved)!
            while let next = cal.date(byAdding: .day, value: 1, to: d), next <= logStart {
                if !saved.contains(dayKey(d)) { out.append(dayKey(d)) }
                d = next
            }
            // Since 1.1.5 also finished days inside macOS's log range that have no whole-Mac data in the logs
            // (a day's log file is missing) and no saved summary.
            while let next = cal.date(byAdding: .day, value: 1, to: d), next <= now {
                if !saved.contains(dayKey(d)), !logHasData(d, next) { out.append(dayKey(d)) }
                d = next
            }
            return out.sorted()
        }
        func logHasData(_ a: Date, _ b: Date) -> Bool {
            ((try? PowerLog().report(from: a, to: b))?.hardware.total ?? 0) > 0
        }

        // a) real macOS log range; two summaries from an older app version: one inside macOS's logs, one before
        clear(dir); write(oldDays(), dir)
        let before = files()
        let inLogs = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: range.lowerBound))!
        var o1 = day(inLogs, 1), o2 = day(lastSaved, 7)
        o1.version = nil; o2.version = nil
        write([o1, o2], dir)
        let log = fresh(autosave: true)
        var r = try! log.fullReport(from: from, to: now)
        let added = files().subtracting(before).subtracting([o1.day])
        let re1 = log.archive.days.first { $0.day == o1.day }, re2 = log.archive.days.first { $0.day == o2.day }
        let o1Reportable = ((try? log.report(from: inLogs, to: cal.date(byAdding: .day, value: 1, to: inLogs)!))?
            .hardware.total ?? 0) > 0
        check(!o1Reportable || (re1?.version == DaySummary.currentVersion && re1?.hardware.total != 1),
              "old-version day inside macOS's logs is computed again")
        check(re2?.version == nil && re2?.hardware.total == 7, "old-version day before macOS's logs is kept as it is")
        let logStartDay = cal.startOfDay(for: range.lowerBound)
        let today = dayKey(now)
        check(!added.contains(today), "today isn't saved (not finished)")
        check(added.allSatisfy { $0 >= dayKey(logStartDay) }, "only days macOS still has are saved: \(added.sorted())")
        let savedOK = log.archive.days.filter { added.contains($0.day) }
            .allSatisfy { ($0.hardware.total ?? 0) > 0 && $0.hardware.cpu != nil && !$0.rows.isEmpty }
        check(savedOK, "saved days have real data (no zero days)")
        print("    saved \(added.count) days from macOS's logs (\(added.sorted().first ?? "-") … \(added.sorted().last ?? "-"))")
        let exp = expectedMissing(range.lowerBound, saved: Set(log.archive.days.map(\.day)))
        check(keys(r.missingDays) == exp, "flagged \(keys(r.missingDays)), expected \(exp)")
        check(r.missingDays.allSatisfy { cal.date(byAdding: .day, value: 1, to: $0)! <= range.lowerBound
                                         || !logHasData($0, cal.date(byAdding: .day, value: 1, to: $0)!) },
              "a day inside macOS's log range is flagged only if the logs have no whole-Mac data for it")

        // b) pretend macOS only has logs from 8 Nov 10:00 (8 Nov starts too late to be saved whole)
        clear(dir); write(oldDays(), dir)
        let pls = date(2026, 11, 8, 10)
        let log2 = fresh()
        log2.archive.lastCheck = .distantPast
        log2.archive.saveMissingDays(using: log2, logRange: pls...now)
        let added2 = files().subtracting(before).sorted()
        check(added2.first.map { $0 >= "2026-11-09" } ?? true, "pretend range: nothing before 9 Nov saved: \(added2)")
        check(!added2.contains("2026-11-08"), "8 Nov (logs start 10:00) not saved")
        r = try! log2.fullReport(from: from, to: now, pretendLogStart: pls)
        let exp2 = expectedMissing(pls, saved: Set(log2.archive.days.map(\.day)))
        check(keys(r.missingDays) == exp2, "pretend: flagged \(keys(r.missingDays)), expected \(exp2)")
        check(!keys(r.missingDays).contains("2026-11-08") || !logHasData(date(2026, 11, 8, 0), date(2026, 11, 9, 0)),
              "pretend: first log day trusted (when the logs have data for it)")
    }

    // MARK: time-zone change (two runs)

    static let berlin: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; return c }()

    /// Run with TZ=Europe/Berlin: saves 1–10 Oct (Berlin days), whole Mac 101…110 Wh.
    static func tzWrite(_ dir: URL) {
        clear(dir)
        write((1...10).map { day(date(2026, 10, $0, in: berlin), 100 + Double($0), in: berlin) }, dir)
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-10-10.json").path), "written")
    }

    /// Run with TZ=America/New_York on the Berlin-saved days.
    static func tzRead(_ dir: URL) {
        print("- time-zone change (saved in Berlin, read in New York)")
        guard TimeZone.current.identifier == "America/New_York" else { check(false, "run with TZ=America/New_York"); return }
        var r = try! fresh().fullReport(from: date(2026, 10, 2, in: berlin), to: date(2026, 10, 9, in: berlin))
        check(r.missingDays.isEmpty, "Berlin 2–9 Oct: nothing missing: \(keys(r.missingDays))")
        near(r.hardware.total, (102...108).reduce(0) { $0 + Double($1) }, "Berlin 2–9 Oct whole Mac")
        near(r.coveredHours, 168, "covered hours")
        // New York 10 Oct = Berlin 10 Oct 06:00 – 11 Oct 06:00; Berlin 11 Oct isn't saved: 6 h without data.
        r = try! fresh().fullReport(from: date(2026, 10, 10), to: date(2026, 10, 11))
        near(r.hardware.total, 110 * 18 / 24, "NY 10 Oct whole Mac (18 h of Berlin 10 Oct)")
        near(r.coveredHours, 18, "NY 10 Oct: the 6 h without saved data are not counted as covered")
        // New York 11 Oct: no saved data at all.
        r = try! fresh().fullReport(from: date(2026, 10, 11), to: date(2026, 10, 12))
        check(keys(r.missingDays) == ["2026-10-11"], "NY 11 Oct flagged: \(keys(r.missingDays))")
        // New York 30 Sep 18:00 – 1 Oct 00:00 = Berlin 1 Oct 00:00–06:00 (saved): not flagged although "30 Sep" isn't saved.
        r = try! fresh().fullReport(from: date(2026, 9, 30, 18), to: date(2026, 10, 1))
        check(r.missingDays.isEmpty, "NY evening of 30 Sep covered by Berlin 1 Oct: \(keys(r.missingDays))")
        near(r.hardware.total, 101 * 6 / 24, "NY evening of 30 Sep whole Mac")
    }
}
