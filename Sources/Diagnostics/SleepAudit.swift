import Foundation

/// `--sleepaudit [days]`: every row of the three "Sleep only" tables (texts and tooltips exactly as shown, from
/// SleepTexts), the cards and the hints, for the whole available history (or the last `days`), with the filters
/// All / Battery / Charger. Lines starting with "ISSUE [code]" are values or texts that are inconsistent or make
/// no sense; a summary by code at the end.
enum SleepAudit {
    static var issues: [String: Int] = [:]
    static func issue(_ code: String, _ what: String) { issues[code, default: 0] += 1; print("ISSUE [\(code)] \(what)") }
    static func one(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "\n", with: " ⏎ ") }

    static func runIfAsked() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--sleepaudit") else { return }
        let log = PowerLog(), now = Date()
        let from = i + 1 < a.count && Double(a[i + 1]) != nil ? now.addingTimeInterval(-Double(a[i + 1])! * 86400)
            : ((try? log.fullRange())??.lowerBound ?? now.addingTimeInterval(-30 * 86400))
        let full = SleepAnalysis.report(log, from: from, to: now)
        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm:ss"
        for power in ["All", "Battery", "Charger"] {
            let r = full.filtered(power: power, minEnergy: 0)
            print("\n######## Power: \(power) — \(r.sessions.count) sleeps, \(r.wakeCount) wake-ups, \(r.noSleep.count) didn't sleep")
            cards(r, power)
            if power == "All" { print("HINTS"); for h in r.hints { print("  " + h) } }
            sleeps(r, df, power)
            wakeTable(r.groups, "period", r.wakeCount)
            if power == "All" { noSleep(r, df) }
        }
        // History counts the sleep log's sleeps from PMSetLog's spans, "Sleep only" from its own sessions: the same sleeps.
        _ = PMSetLog.shared.spansIfRead(); Thread.sleep(forTimeInterval: 3)
        let spans = (PMSetLog.shared.spansIfRead() ?? []).filter { $0.b > from.timeIntervalSince1970 && $0.a < now.timeIntervalSince1970 }
        let ses = full.sessions
        let lo = from.timeIntervalSince1970, hi = now.timeIntervalSince1970
        let spanH = spans.reduce(0) { $0 + max(0, min($1.b, hi) - max($1.a, lo)) } / 3600, sesH = ses.reduce(0) { $0 + $1.hours }
        print(String(format: "\n######## HISTORY'S SLEEPS vs SLEEP ONLY: %d spans (%.2f h), %d sleeps (%.2f h)", spans.count, spanH, ses.count, sesH))
        let hist = (try? log.report(from: from, to: now))?.hardware
        print(String(format: "History: asleep %.2f h, sleep %.3f Wh, off %.2f h · Sleep only: %.2f h, %.3f Wh", hist?.sleepH ?? -1, hist?.sleep ?? -1, hist?.offH ?? -1, sesH, full.sleepWh ?? -1))
        for sp in spans where sp.b - sp.a >= 60 {
            let a = Date(timeIntervalSince1970: sp.a), b = Date(timeIntervalSince1970: sp.b)
            let match = ses.first { abs($0.start.timeIntervalSince(a)) <= 60 && abs($0.end.timeIntervalSince(b)) <= 60 }
            if match == nil {
                let over = ses.filter { $0.start < b && a < $0.end }.map { "\(df.string(from: $0.start))–\(df.string(from: $0.end))" }
                issue("H-sleep-differs", "History sleep \(df.string(from: a))–\(df.string(from: b)) (\(Int((sp.b - sp.a) / 60)) min) vs Sleep only: \(over.isEmpty ? "none" : over.joined(separator: ", "))")
            }
        }
        for s in ses where !spans.contains(where: { abs($0.a - s.start.timeIntervalSince1970) <= 60 && abs($0.b - s.end.timeIntervalSince1970) <= 60 }) {
            if s.start.timeIntervalSince(from) > 60 && now.timeIntervalSince(s.end) > 60 {
                issue("H-sleep-missing", "Sleep only \(df.string(from: s.start))–\(df.string(from: s.end)) isn't one of History's sleeps")
            }
        }

        print("\n######## SUMMARY")
        for (k, v) in issues.sorted(by: { $0.key < $1.key }) { print(String(format: "  %-28@ %5d", k as NSString, v)) }
        exit(0)
    }

    static func cards(_ r: SleepReport, _ p: String) {
        let avg = r.sleepWh.flatMap { r.knownH > 0.01 ? $0 / r.knownH : nil }     // as the card
        print(String(format: "CARDS energy %@ Wh · asleep %@ · avg %@ W (battery %@, charger %@) · wake-ups %d",
                     r.sleepWh.map { fmt($0, 1) } ?? "N/A", ContentView.duration(r.sleepH), avg.map { fmt($0, 2) } ?? "N/A",
                     r.avgBatteryW.map { fmt($0, 2) } ?? "-", r.avgChargerW.map { fmt($0, 2) } ?? "-", r.wakeCount))
        let unknown = r.sessions.filter { $0.wh == nil }
        if !unknown.isEmpty, let a = avg, abs(a - (r.sleepWh ?? 0) / max(r.knownH, 0.001)) > 0.005 {
            let knownH = r.knownH
            issue("C-avg-includes-unknown", "[\(p)] avg \(fmt(a, 2)) W divides the known energy by ALL \(ContentView.duration(r.sleepH)) asleep, "
                  + "incl. \(unknown.count) sleeps (\(ContentView.duration(r.sleepH - knownH))) with unknown energy; known only: \(fmt((r.sleepWh ?? 0) / max(knownH, 0.001), 2)) W")
        }
        let sumWakes = r.sessions.reduce(0) { $0 + $1.wakes }
        if sumWakes != r.wakeCount { issue("C-wakes", "[\(p)] card \(r.wakeCount) vs sleeps' wake-ups \(sumWakes)") }
    }

    static func sleeps(_ r: SleepReport, _ df: DateFormatter, _ p: String) {
        print("SLEEPS (power | started by | wake-ups | energy | avg | duration | from – to) with tooltips")
        for s in r.sessions.sorted(by: { $0.start < $1.start }) {
            let pw = SleepTexts.power(s), c = SleepTexts.cause(s), e = SleepTexts.energy(s, r.wakes), a = SleepTexts.avg(s, r.wakes)
            let id = "\(df.string(from: s.start))–\(df.string(from: s.end))"
            print("  \(id) | \(pw.text) | \(c.text) | \(s.wakes) | \(e.text) | \(a.unusual != nil ? "⚠ " : "")\(a.cell.text) | \(SleepTexts.duration(s))")
            if p == "All" {
                if let t = pw.tip { print("      power tip: " + one(t)) }
                if let t = c.tip { print("      cause tip: " + one(t)) }
                print("      energy tip: " + one(e.tip))
                if let t = a.cell.tip, t != e.tip { print("      avg tip: " + one(t)) }
            }
            guard p == "All" else { continue }
            let w = SleepTexts.wakesIn(s, r.wakes), secs = s.end.timeIntervalSince(s.start)
            if w.count != s.wakes { issue("S-wakecount", "\(id): shows \(s.wakes) wake-ups, table has \(w.count)") }
            let wWh = w.compactMap(\.wh).reduce(0, +)
            if false, let t = s.wh, wWh > t + 0.005 { issue("S-wakes-more-than-sleep", "\(id): wake-ups \(fmt(wWh, 3)) Wh > whole sleep \(fmt(t, 3)) Wh") }
            if false, s.wh == nil, wWh > 0 { issue("i-unknown-but-wakes-known", "\(id): sleep energy unknown, its wake-ups \(fmt(wWh, 3)) Wh") }
            if false, w.contains(where: { $0.wh == nil }) { issue("S-wake-energy-shown-as-0", "\(id): \(w.filter { $0.wh == nil }.count) wake-ups without energy, tooltip doesn't say unknown") }
            let ws = w.reduce(0) { $0 + $1.secs }
            if ws > secs + 5 { issue("S-wakes-longer-than-sleep", "\(id): wake-ups \(Int(ws)) s > sleep \(Int(secs)) s") }
            if secs < 60 && s.wakes == 0 { issue("S-under-1-min", "\(id): \(Int(secs)) s (\(s.cause), \(s.wakes) wake-ups, energy \(e.text))") }
            if let t = s.wh, t == 0, secs > 600 { issue("S-zero-energy", "\(id): 0 Wh over \(SleepTexts.duration(s))") }
            if let x = s.avgW, x > 8 { issue("S-avg-high", "\(id): \(fmt(x, 2)) W while asleep (\(s.power))") }
            // Very low is only wrong when the battery contradicts it (its charge clearly dropped).
            if let x = s.avgW, x < 0.03, secs > 600, let l = s.levels, l.from - l.to >= 2 { issue("S-avg-low", "\(id): \(fmt(x, 3)) W while asleep (\(s.power))") }
            if s.onBattery == true {
                if let l = s.levels {
                    if l.to > l.from + 1 { issue("S-battery-but-charged", "\(id): Power says Battery, but it charged \(BT.pct(l.from)) → \(BT.pct(l.to)) while asleep") }
                } else if !(pw.tip ?? "").contains("not in macOS's battery log") { issue("S-battery-no-levels", "\(id): on battery, no charge levels and no reason in the Power tooltip") }
            }
            if s.onBattery == nil { issue("S-power-unknown", "\(id): power source unknown (\(s.power))") }
            let usual = s.onBattery == true ? r.usualBattery : s.onBattery == false ? r.usualCharger : nil
            if s.unusual, let u = usual, let x = s.avgW, x <= 2 * u { issue("S-unusual-wrong", "\(id): ⚠ but \(fmt(x, 2)) W ≤ 2× usual \(fmt(u, 2)) W") }
            if s.fromSummary { issue("i-from-summary", "\(id): energy from the day's saved summary (\(e.text))") }
            if s.estimated { issue("i-estimated", "\(id): energy estimated (\(e.text), \(a.cell.text))") }
            if let x = s.avgW, secs >= 600, !s.estimated {
                let same = r.sessions.filter { $0.start != s.start && $0.end.timeIntervalSince($0.start) >= 600 && $0.avgW.map { abs($0 - x) < 0.005 } == true }
                if same.count >= 2 { issue("S-same-avg-as-others", "\(id): \(fmt(x, 2)) W, exactly like \(same.count) other sleep(s) (one counter reading shared out by time?)") }
            }
            // The wake-up table when clicking this sleep's number.
            if !w.isEmpty { wakeTable(SleepReport.groups(w), "sleep \(id)", w.count, quiet: true) }
        }
    }

    static func wakeTable(_ groups: [SleepReport.Group], _ scope: String, _ total: Int, quiet: Bool = false) {
        if !quiet { print("WAKE-UPS BY REASON (\(scope))") }
        let sum = groups.reduce(0) { $0 + $1.count }
        if sum != total { issue("W-sum", "\(scope): groups \(sum) vs \(total) wake-ups") }
        for g in groups {
            let cells = SleepTexts.groupCells(g), bullets = SleepTexts.groupBullets(g)
            if !quiet {
                print("  " + cells.map(\.text).joined(separator: " | "))
                for b in bullets { print("      • \(b.before)\(b.text)\(b.after)   tip: \(one(b.tip))") }
            }
            if false { issue("W-reasons-hidden", "\(scope) \(g.name): \(g.reasons.count) reasons, details show 3 (\(g.reasons.sorted { $0.value > $1.value }.dropFirst(3).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")) hidden)") }
            if bullets.count != g.reasons.count + g.requesters.count { issue("W-details-hidden", "\(scope) \(g.name): \(bullets.count) details for \(g.reasons.count + g.requesters.count)") }
            let names = bullets.map { $0.before + $0.text }
            if Set(names).count != names.count { issue("W-duplicate-label", "\(scope) \(g.name): \(names.joined(separator: " / "))") }
            for k in g.reasons.keys where WakeGroup.of(k) != g.group && g.group != .aborted {
                issue("W-reason-in-wrong-group", "\(scope): reason \"\(k)\" (\(FriendlyNames.reason(k))) in \(g.name)")
            }
            if !g.requesters.isEmpty && g.group != .scheduled { issue("W-planned-outside-timer", "\(scope) \(g.name): \(g.requesters)") }
            if false, g.secs > 60 {
                let w = g.wh / (g.secs / 3600)
                if w > 25 || w < 0.2 { issue("W-power-odd", "\(scope) \(g.name): \(fmt(g.wh, 3)) Wh in \(Int(g.secs)) s = \(fmt(w, 2)) W") }
            }
            if g.reasons.keys.contains(where: { FriendlyNames.reason($0) == $0 }) {
                issue("W-raw-label", "\(scope) \(g.name): untranslated reason \(g.reasons.keys.filter { FriendlyNames.reason($0) == $0 })")
            }
        }
    }

    static func noSleep(_ r: SleepReport, _ df: DateFormatter) {
        print("DIDN'T SLEEP (power | while | energy | duration | from | to) and kept awake by")
        let ns = r.noSleep.sorted { $0.start < $1.start }
        for (a, b) in zip(ns, ns.dropFirst()) where b.start.timeIntervalSince(a.end) < 60 {
            issue("D-back-to-back", "\(df.string(from: a.start))–\(df.string(from: a.end)) and \(df.string(from: b.start))–\(df.string(from: b.end)) follow each other (\(a.cause) / \(b.cause))")
        }
        for n in r.noSleep {
            let c = SleepTexts.noSleepCells(n), b = SleepTexts.blockerBullets(n)
            let id = "\(df.string(from: n.start))–\(df.string(from: n.end))"
            print("  " + c.map(\.text).joined(separator: " | "))
            for x in b { print("      • \(x.text)\(x.after)   tip: \(one(x.tip))") }
            if n.wh == nil { issue("D-energy-unknown", "\(id): energy shown as —") }
            if n.onBattery == nil { issue("D-power-unknown", "\(id): power shown as —") }
            if let w = n.wh, w / max(n.hours, 0.001) < 0.5 || w / max(n.hours, 0.001) > 40 {
                issue("D-power-odd", "\(id): \(fmt(w / n.hours, 2)) W")
            }
            for x in n.blockers where x.secs > n.end.timeIntervalSince(n.start) + 1 { issue("D-blocker-longer", "\(id): \(x.name) \(Int(x.secs)) s") }
            if n.blockers.isEmpty { issue("D-not-logged", "\(id): no blocker logged") }
            // History must count this stretch as awake, with the same energy (never in the Sleep row).
            if let h = try? PowerLog().report(from: n.start, to: n.end) {
                let hw = h.hardware
                if (hw.sleepH ?? 0) > 0.02 || (hw.sleep ?? 0) > 0.01 {
                    issue("D-in-history-sleep", "\(id): History counts \(ContentView.duration(hw.sleepH ?? 0)) / \(fmt(hw.sleep ?? 0, 2)) Wh of it as asleep")
                }
                if let w = n.wh, abs(hw.whole - w) > 0.02 + 0.03 * w {
                    issue("D-energy-vs-history", "\(id): \(fmt(w, 2)) Wh here, History \(fmt(hw.whole, 2)) Wh")
                }
            }
        }
    }
}
