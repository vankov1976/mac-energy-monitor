import AppKit
import Foundation

/// Command-line checks, compiled only into the test build (`./build.sh --tests`, in build/tests).
/// They print their results and quit without starting the app.
extension EnergyMonitorApp {
    static func runDiagnosticsIfAsked() {
        // Test runs: read macOS's sleep log first, so history reports use it every time (reproducible).
        // MEM_NO_PMSET=1: without it (as before the sleep log is read).
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0 != "--background" }),
           ProcessInfo.processInfo.environment["MEM_NO_PMSET"] == nil { _ = PMSetLog.shared.events() }
        // `MacEnergyMonitor --selftest`: print the last 7 days and quit (used to check the build).
        if CommandLine.arguments.contains("--selftest") {
            do {
                let i = CommandLine.arguments.firstIndex(of: "--selftest")!
                let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "168"
                let log = PowerLog()
                // "all": from the oldest data, as the "All" view does
                let from = arg == "all" ? (try log.fullRange())?.lowerBound ?? Date()
                                        : Date().addingTimeInterval(-(Double(arg) ?? 168) * 3600)
                let r = try log.fullReport(from: from, to: Date())
                print("period from \(from.formatted(date: .abbreviated, time: .shortened)), macOS logs start \(r.macOSLogsStart?.formatted(date: .abbreviated, time: .shortened) ?? "-")")
                print(String(format: "apps %.1f Wh, screen %.1f h, %d rows",
                             r.totals.energyWh, r.totals.screenOnH, r.rows.count))
                print("missing days: \(r.missingDays.isEmpty ? "none" : ContentView.dayRanges(r.missingDays)), covered \(ContentView.duration(r.coveredHours)) of \(ContentView.duration(r.totals.hours))"
                      + String(format: ", avg %.2f W", r.hardware.whole / max(r.coveredHours, 0.001)))
                print("hardware: " + r.hardware.parts.map { String(format: "%@ %.2f", $0.name, $0.value) }.joined(separator: " + ")
                      + String(format: " = whole Mac %.2f Wh", r.hardware.whole))
                for row in r.rows.prefix(6) {
                    print(String(format: "%5.1f%% %7.1f Wh %5.2f W run %5.1f h screen %5.1f h  %@ [%@]",
                                 row.share, row.energyWh, row.avgW, row.runningH, row.screenH, row.name, row.kind))
                }
            } catch { print("error: \(error.localizedDescription)") }
            exit(0)
        }
        GapTests.runIfAsked()
        VerifyTests.runIfAsked()
        liveTestIfAsked()
        diagnosticsIfAsked()
    }

    // Diagnostics for checking the numbers:
    // `--liveavg <seconds>`: average the live breakdown over that time, print it with the time range, quit.
    // `--range <from> <to>`: print the history breakdown for that exact range (Unix seconds), quit.
    static func diagnosticsIfAsked() {
        let a = CommandLine.arguments
        // `--loginagent on|off <app path>`: same as the panel switch (for testing).
        // `--loginagent on|off|status`: same as the "Start at login" switch (run from the installed app, for testing).
        if let i = a.firstIndex(of: "--loginagent"), i + 1 < a.count {
            do {
                if a[i + 1] == "on" { try LoginAgent.enable() } else if a[i + 1] == "off" { LoginAgent.disable() }
            } catch { print("error: \(error.localizedDescription)") }
            print("login agent: \(LoginAgent.service.status.rawValue) (0 not registered, 1 enabled, 2 requires approval, 3 not found)")
            exit(0)
        }
        // `--archivecheck <from> <pretendLogStart>`: compare a report built from saved days + logs with one from logs only.
        if let i = a.firstIndex(of: "--archivecheck"), i + 2 < a.count, let f = Double(a[i + 1]), let p = Double(a[i + 2]) {
            let log = PowerLog(), from = Date(timeIntervalSince1970: f), now = Date()
            let both = try! log.fullReport(from: from, to: now, pretendLogStart: Date(timeIntervalSince1970: p))
            let logs = try! log.report(from: from, to: now)
            for (x, y) in zip(both.hardware.parts, logs.hardware.parts) {
                print(String(format: "%-34@ saved days + logs %8.2f   logs only %8.2f", x.name as NSString, x.value, y.value))
            }
            print(String(format: "whole Mac: %.2f vs %.2f Wh | screen %.2f vs %.2f h | apps table %.2f vs %.2f Wh, %d vs %d rows",
                         both.hardware.whole, logs.hardware.whole, both.totals.screenOnH, logs.totals.screenOnH,
                         both.totals.energyWh, logs.totals.energyWh, both.rows.count, logs.rows.count))
            for r in both.rows.prefix(3) {
                let o = logs.rows.first { $0.id == r.id }
                print(String(format: "  %@: %.2f vs %.2f Wh, running %.1f vs %.1f h", r.name, r.energyWh, o?.energyWh ?? -1, r.runningH, o?.runningH ?? -1))
            }
            exit(0)
        }
        // `--filtercheck`: for every row of the last 7 days, compare what the table shows with the filters' decisions.
        if a.contains("--filtercheck") {
            let r = try! PowerLog().report(from: Date().addingTimeInterval(-7 * 86400), to: Date())
            var bad = 0, checked = 0
            for row in r.rows where row.kind != "System" {
                let text = fmt(row.energyWh, row.energyWh < 10 ? 2 : 1)
                // Read the text back in this Mac's own number format (comma or dot as decimal separator).
                let nf = NumberFormatter(); nf.numberStyle = .decimal; nf.locale = .current
                let shown = nf.number(from: text)?.doubleValue ?? -1
                for t in [0.1, 1.0, 10.0] {
                    checked += 1
                    if (ContentView.shownEnergy(row.energyWh) >= t) != (shown >= t) {
                        bad += 1; print("energy mismatch: \(row.name) shows \(text), threshold \(t)")
                    }
                }
                let screenText = row.screenH < ContentView.minScreenH ? "—" : ContentView.duration(row.screenH)
                let passes = row.screenH >= ContentView.minScreenH
                checked += 1
                if passes != !(screenText == "—" || screenText == "< 1 min") {
                    bad += 1; print("screen mismatch: \(row.name) shows \(screenText), filter keeps it: \(passes)")
                }
            }
            print("filter check: \(checked) checks on \(r.rows.filter { $0.kind != "System" }.count) rows, \(bad) mismatches")
            exit(0)
        }
        if let i = a.firstIndex(of: "--range"), i + 2 < a.count, let f = Double(a[i + 1]), let t = Double(a[i + 2]) {
            do {
                let r = try PowerLog().fullReport(from: Date(timeIntervalSince1970: f), to: Date(timeIntervalSince1970: t))
                let h = max((t - f) / 3600, 1e-9)
                print("screen time: " + r.rows.filter { $0.screenH > 0 }.sorted { $0.screenH > $1.screenH }.prefix(6)
                    .map { "\($0.name) \(Int(($0.screenH * 3600).rounded())) s" }.joined(separator: ", ")
                    + " | screen on \(Int((r.totals.screenOnH * 3600).rounded())) s")
                print("history avg W: " + r.hardware.parts.map { String(format: "%@ %.2f", $0.name, $0.value / h) }
                    .joined(separator: " | ") + String(format: " | whole %.2f", r.hardware.whole / h))
            } catch { print("error: \(error.localizedDescription)") }
            exit(0)
        }
        guard let i = a.firstIndex(of: "--liveavg"), i + 1 < a.count, let secs = Double(a[i + 1]) else { return }
        let start = Date().timeIntervalSince1970
        var sums: [String: Double] = [:], n = 0.0, measured = 0.0
        DispatchQueue.main.async { MainActor.assumeIsolated { LiveBreakdown.shared.start() } }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            MainActor.assumeIsolated {
                let b = LiveBreakdown.shared.breakdown
                guard b.total != nil else { return }
                for p in b.parts { sums[p.name, default: 0] += p.value }
                measured += b.total ?? 0; n += 1
                if Date().timeIntervalSince1970 - start >= secs {
                    t.invalidate()
                    let names = b.parts.map(\.name)
                    print(String(format: "range %.0f %.0f", start, Date().timeIntervalSince1970))
                    print("live avg W:    " + names.map { String(format: "%@ %.2f", $0, (sums[$0] ?? 0) / n) }
                        .joined(separator: " | ") + String(format: " | whole %.2f", measured / n))
                    exit(0)
                }
            }
        }
        Self.runWithoutApp()
    }

    /// Long diagnostic runs keep going on a plain run loop and never start the app itself. Otherwise they would
    /// be a second running "Mac Energy Monitor" (same bundle ID), and AppleScript's `quit app` could reach the
    /// diagnostic copy instead of the real one (found Nov 2026: the real app seemed to ignore quit).
    static func runWithoutApp() -> Never {
        while true { RunLoop.main.run() }
    }

    // `--livetest`: measure the live breakdown for ~5 s, print it and quit (used to check the build).
    static func liveTestIfAsked() {
        guard CommandLine.arguments.contains("--livetest") else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { LiveBreakdown.shared.start() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            MainActor.assumeIsolated {
                let l = LiveBreakdown.shared
                print(l.breakdown.parts.map { String(format: "%@ %.2f", $0.name, $0.value) }.joined(separator: " + ")
                      + String(format: " = whole Mac %.2f W (measured %.2f)", l.breakdown.whole, l.breakdown.total ?? -1)
                      + "   (readable \(l.readable), unreadable \(l.unreadable))")
                let kinds = Dictionary(grouping: l.rows, by: \.kind).mapValues(\.count)
                print("table rows: \(l.rows.count) \(kinds)")
                for r in l.rows.sorted(by: { $0.watts > $1.watts }).prefix(10) {
                    print(String(format: "%7.3f W %5.1f%%  %@ [%@]", r.watts, r.share, r.name, r.kind))
                }
                exit(0)
            }
        }
        runWithoutApp()
    }
}
