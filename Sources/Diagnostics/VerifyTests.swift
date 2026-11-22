import AppKit
import SwiftUI
import Foundation
import SQLite3

/// `MacEnergyMonitor --verify`: times the history reports and checks that the numbers are consistent.
/// Test build only. Use MEM_ARCHIVE_DIR to keep the real daily summaries untouched.
enum VerifyTests {
    static var failures = 0

    static func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if !ok { failures += 1; print("  FAIL: " + what()) }
    }

    static func time<T>(_ f: () throws -> T) rethrows -> (T, Double) {
        let t0 = Date(); let r = try f(); return (r, Date().timeIntervalSince(t0))
    }

    static func runIfAsked() {
        BatteryChecks.runIfAsked()
        // `--pmsetmem`: memory of the parsed sleep log (process memory before/after reading it).
        if CommandLine.arguments.contains("--pmsetmem") {
            func rss() -> Double {
                var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
                _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
                return Double(info.resident_size) / 1_048_576
            }
            let r0 = rss()
            let e = PMSetLog.parse(String(decoding: { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "log"]
                let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return d }(), as: UTF8.self))
            let r1 = rss()
            var kinds: [String: Int] = [:]
            for x in e { kinds[String(describing: x.kind).components(separatedBy: "(").first ?? "?", default: 0] += 1 }
            let spans = SleepAnalysis.sleepSpans(e).spans
            print(String(format: "memory before %.0f MB, after parsing %.0f MB (+%.0f MB); %d entries kept; %d sleep spans", r0, r1, r1 - r0, e.count, spans.count))
            print(kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            exit(0)
        }
        // `--batterycheck`: every stretch on battery of at least 30 minutes: the battery's own loss (mAh × V) vs. the
        // whole-Mac counter vs. the history report's "Whole Mac" — an independent check of the energy measurement.
        if CommandLine.arguments.contains("--batterycheck") {
            let log = PowerLog(), dbs = (try? log.databases()) ?? []
            guard let range = try? log.availableRange() else { print("no logs"); exit(1) }
            let bat = SleepEnergy.battery(dbs, range.lowerBound.timeIntervalSince1970, Date().timeIntervalSince1970)
            var stretches: [[SleepEnergy.Battery]] = [], cur: [SleepEnergy.Battery] = []
            for b in bat {
                // a new stretch at the charger, a jump in the charge (charging, gauge reset) or a gap of over 6 hours
                if !b.onBattery || (cur.last.map { b.mAh > $0.mAh + 2 || b.t - $0.t > 6 * 3600 } ?? false) {
                    if cur.count > 1 { stretches.append(cur) }
                    cur = b.onBattery ? [b] : []
                } else { cur.append(b) }
            }
            if cur.count > 1 { stretches.append(cur) }
            let counter = SleepAnalysis.Counter(log, from: range.lowerBound, to: Date())
            var tb = 0.0, tc = 0.0, th = 0.0, n = 0
            for st in stretches {
                guard let a = st.first, let z = st.last, z.t - a.t >= 1800 else { continue }
                // battery energy: the charge lost, at the average voltage (sum over samples)
                var batWh = 0.0
                for (p, q) in zip(st, st.dropFirst()) { batWh += max(0, p.mAh - q.mAh) * (p.mV + q.mV) / 2 / 1e6 }
                let from = Date(timeIntervalSince1970: a.t), to = Date(timeIntervalSince1970: z.t)
                guard batWh >= 0.5, let c = counter.wh(from, to) else { continue }
                let h = (try? log.report(from: from, to: to))?.hardware.whole ?? -1
                print(String(format: "  %@  %5.2f h  battery %7.2f Wh  counter %7.2f Wh (%+5.1f%%)  history %7.2f Wh (%+5.1f%%)",
                             from.description, (z.t - a.t) / 3600, batWh, c, (c / batWh - 1) * 100, h, (h / batWh - 1) * 100))
                tb += batWh; tc += c; th += h; n += 1
            }
            print(String(format: "TOTAL %d stretches: battery %.2f Wh, counter %.2f Wh (%+.1f%%), history %.2f Wh (%+.1f%%)",
                         n, tb, tc, (tc / tb - 1) * 100, th, (th / tb - 1) * 100))
            exit(0)
        }
        // `--sleepcompare`: the history's Sleep row vs. "Sleep only" for the same periods (should match where pmset's log reaches).
        if CommandLine.arguments.contains("--sleepcompare") {
            let log = PowerLog(), now = Date()
            for h in [1.0, 24, 72, 168, 400] {
                let from = now.addingTimeInterval(-h * 3600)
                let hist = try? log.fullReport(from: from, to: now)
                let s = SleepAnalysis.report(log, from: from, to: now)
                if h == 72, ProcessInfo.processInfo.environment["MEM_SHOW_SESSIONS"] != nil {
                    // Each sleep with the history's inputs (counter and battery from 1 day before the period).
                    let st = from.timeIntervalSince1970, en = now.timeIntervalSince1970
                    let dbs = (try? log.databases()) ?? []
                    let bat = SleepEnergy.battery(dbs, st - 86400, en + 3600)
                    let ctr = SleepAnalysis.Counter(log, from: Date(timeIntervalSince1970: st - 86400), to: Date(timeIntervalSince1970: en + 3600))
                    for x in s.sessions {
                        let full = PMSetLog.shared.spansIfRead()?.first { abs($0.b - x.end.timeIntervalSince1970) < 2 }
                        let hw = full.flatMap { f in SleepEnergy.sessionWh(full: f.a, f.b, part: x.start.timeIntervalSince1970, x.end.timeIntervalSince1970,
                                    onBattery: f.onBattery, battery: bat, counter: { ctr.wh(Date(timeIntervalSince1970: $0), Date(timeIntervalSince1970: $1)) }) }
                        if abs((hw ?? -1) - (x.wh ?? -1)) > 0.05 {
                            print(String(format: "  session %@ – %@ %@ sleep only %.2f Wh, history-style %.2f Wh, full from %@", x.start.description, x.end.description,
                                         x.power, x.wh ?? -1, hw ?? -1, full.map { Date(timeIntervalSince1970: $0.a).description } ?? "-"))
                        }
                    }
                }
                print(String(format: "%4.0f h: history sleep %7.2f Wh %6.2f h | sleep only %7.2f Wh %6.2f h | details from %@",
                             h, hist?.hardware.sleep ?? -1, hist?.hardware.sleepH ?? -1, s.sleepWh ?? -1, s.sleepH,
                             s.detailsFrom?.description ?? "-"))
            }
            exit(0)
        }
        // `--sleepcheck [days]`: correctness checks for the sleep analysis (consistency, split, battery cross-check).
        if let i = CommandLine.arguments.firstIndex(of: "--sleepcheck") {
            let days = i + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 1]) ?? 7 : 7
            let log = PowerLog(), now = Date(), from = now.addingTimeInterval(-days * 86400)
            let r = SleepAnalysis.report(log, from: from, to: now)
            print(String(format: "period %.0f days: %d sleeps, %.2f h, %.3f Wh, %d wake-ups, %d didn't-sleep",
                         days, r.sessions.count, r.sleepH, r.sleepWh ?? -1, r.wakeCount, r.noSleep.count))
            if ProcessInfo.processInfo.environment["MEM_SHOW_TIPS"] != nil {   // the texts and tooltips as the view shows them
                for h in r.hints { print("HINT:", h, "\n") }
                for s in r.sessions where s.causeTip != nil { print("CAUSE:", s.cause, "\n" + s.causeTip!, "\n") }
                for g in r.groups { for k in g.reasons.keys { let e = Explain.reason(k); print("REASON:", FriendlyNames.reason(k), "\n" + TipFormat.make(e.0, bullets: e.1, tech: ["macOS wake reason: \(k)"]), "\n") }
                                    for k in g.requesters.keys { let e = Explain.requester(k); print("REQUEST:", FriendlyNames.requester(k), "\n" + TipFormat.make(e.0, bullets: e.1, tech: ["macOS wake request: \(k)"]), "\n") } }
                for n in r.noSleep { for b in n.blockers { print("BLOCKER:", b.name, "\n" + SleepAnalysis.blockerTip(b.name, b.tech), "\n") } }
            }
            // 1. Consistency
            let ss = r.sessions.sorted { $0.start < $1.start }
            check(zip(ss, ss.dropFirst()).allSatisfy { $0.end <= $1.start }, "sleeps overlap")
            check(ss.allSatisfy { $0.start >= from && $0.end <= now && $0.end > $0.start }, "a sleep outside the period or empty")
            for w in r.wakes where !ss.contains(where: { w.time >= $0.start && w.time < $0.end }) {
                check(false, "a wake-up outside every sleep: \(w.time) \(w.reason) (nearest sleep ends \(ss.map(\.end).min { abs($0.timeIntervalSince(w.time)) < abs($1.timeIntervalSince(w.time)) }.map { "\($0)" } ?? "-"))")
            }
            check(r.groups.reduce(0) { $0 + $1.count } == r.wakes.count, "groups don't add up to the wake-ups")
            check(abs(r.groups.reduce(0) { $0 + $1.secs } - r.wakes.reduce(0) { $0 + $1.secs }) < 1, "group awake time doesn't add up")
            check(ss.reduce(0) { $0 + $1.wakes } == r.wakeCount, "per-sleep wake-ups don't add up: \(ss.reduce(0) { $0 + $1.wakes }) vs \(r.wakeCount)")
            for s in ss {
                let awake = r.wakes.filter { $0.time >= s.start && $0.time < s.end }.reduce(0) { $0 + $1.secs }
                check(awake <= s.end.timeIntervalSince(s.start) + 60, "wake-ups longer than their sleep at \(s.start)")
                if let w = s.avgW { check(w >= 0 && w < 60, "implausible sleep power \(w) W at \(s.start)") }
            }
            for n in r.noSleep { for o in ss where o.start < n.end && n.start < o.end {
                check(false, "a didn't-sleep time overlaps a sleep: \(n.start)–\(n.end) (\(n.cause)) vs sleep \(o.start)–\(o.end)")
            } }
            check(abs(r.sleepH - ss.reduce(0) { $0 + $1.hours }) < 0.001, "sleep hours don't add up")
            // 1b. Power / Minimum energy filters: every part of the view counts only the matching sleeps.
            check(r.filtered(power: "All", minEnergy: 0).sessions.count == r.sessions.count, "no filter changes the report")
            var filterChecks = 0
            for p in ["All", "Battery", "Charger"] {
                for m in [0, 0.1, 1, 10] {
                    let f = r.filtered(power: p, minEnergy: m), tag = "filter \(p) ≥ \(m) Wh"
                    filterChecks += 1
                    check(f.allSessions == r.sessions.count, "\(tag): total sleeps changed")
                    check(f.sessions.allSatisfy { (p == "All" || $0.power == p) && ($0.wh ?? 0) >= m }, "\(tag): a sleep that doesn't match")
                    check(f.sessions.count == r.sessions.filter { (p == "All" || $0.power == p) && ($0.wh ?? 0) >= m }.count, "\(tag): a matching sleep is missing")
                    check(f.sessions.reduce(0) { $0 + $1.wakes } == f.wakeCount, "\(tag): per-sleep wake-ups \(f.sessions.reduce(0) { $0 + $1.wakes }) vs card \(f.wakeCount)")
                    check(f.groups.reduce(0) { $0 + $1.count } == f.wakes.count, "\(tag): wake-ups by reason \(f.groups.reduce(0) { $0 + $1.count }) vs \(f.wakes.count)")
                    check(abs((f.sleepWh ?? 0) - f.sessions.compactMap(\.wh).reduce(0, +)) < 0.001, "\(tag): energy card doesn't add up")
                    check(abs(f.sleepH - f.sessions.reduce(0) { $0 + $1.hours }) < 0.001, "\(tag): sleep hours don't add up")
                    check(f.noSleep.allSatisfy { (p == "All" || $0.power == p) && ($0.wh ?? 0) >= m }, "\(tag): a didn't-sleep time that doesn't match")
                }
                let b = r.filtered(power: "Battery", minEnergy: 0), c = r.filtered(power: "Charger", minEnergy: 0)
                check(b.sessions.count + c.sessions.count + r.sessions.filter { $0.onBattery == nil }.count == r.sessions.count, "Battery + Charger + unknown ≠ All")
                check(b.wakeCount + c.wakeCount <= r.wakeCount, "Battery + Charger wake-ups > All")
            }
            print("  filters: \(filterChecks) combinations checked; battery \(r.filtered(power: "Battery", minEnergy: 0).sessions.count), charger \(r.filtered(power: "Charger", minEnergy: 0).sessions.count), unknown \(r.sessions.filter { $0.onBattery == nil }.count) of \(r.sessions.count) sleeps; didn't sleep: battery \(r.noSleep.filter { $0.onBattery == true }.count), charger \(r.noSleep.filter { $0.onBattery == false }.count), unknown \(r.noSleep.filter { $0.onBattery == nil }.count)")
            // 2. Split: the whole period = its two halves
            let mid = from.addingTimeInterval(now.timeIntervalSince(from) / 2)
            let a = SleepAnalysis.report(log, from: from, to: mid), b = SleepAnalysis.report(log, from: mid, to: now)
            func cmp(_ label: String, _ w: Double, _ x: Double, tol: Double) {
                print(String(format: "  split %-14@ %10.3f vs %10.3f (diff %+.3f)", label as NSString, w, x, w - x))
                check(abs(w - x) <= tol, "split \(label): \(w) vs \(x)")
            }
            cmp("sleep h", r.sleepH, a.sleepH + b.sleepH, tol: 0.01)
            cmp("sleep Wh", r.sleepWh ?? 0, (a.sleepWh ?? 0) + (b.sleepWh ?? 0), tol: 0.02 + 0.01 * (r.sleepWh ?? 0))
            cmp("wake-ups", Double(r.wakeCount), Double(a.wakeCount + b.wakeCount), tol: 0)
            // 3. Battery cross-check: sleeps on battery of at least 1 hour, counter vs. battery's own charge drop
            let dbs = (try? log.databases()) ?? []
            let bat = SleepEnergy.battery(dbs, from.timeIntervalSince1970 - 3600, now.timeIntervalSince1970)
            var cw = 0.0, bw = 0.0, n = 0
            for s in ss where s.onBattery == true && s.hours >= 1 {
                guard let c = s.wh, let m = SleepEnergy.measured((s.start.timeIntervalSince1970, s.end.timeIntervalSince1970), bat) else { continue }
                print(String(format: "  battery sleep %@  %5.2f h  counter %.3f Wh  battery %.3f Wh", s.start.description, s.hours, c, m))
                cw += c; bw += m; n += 1
            }
            if n > 0 {
                print(String(format: "  battery sleeps total: counter %.3f Wh vs battery %.3f Wh (ratio %.2f) over %d sleeps", cw, bw, cw / max(bw, 1e-9), n))
                check(cw / max(bw, 1e-9) > 0.6 && cw / max(bw, 1e-9) < 1.6, "counter and battery disagree for battery sleeps")
            }
            print("\n\(failures == 0 ? "ALL SLEEP CHECKS PASSED" : "\(failures) SLEEP CHECK(S) FAILED")")
            exit(failures == 0 ? 0 : 1)
        }
        // `--sleep <from> <to>`: the sleep analysis for that range, as text.
        if let i = CommandLine.arguments.firstIndex(of: "--sleep"), i + 2 < CommandLine.arguments.count,
           let f = Double(CommandLine.arguments[i + 1]), let t = Double(CommandLine.arguments[i + 2]) {
            let t0 = Date()
            let r = SleepAnalysis.report(PowerLog(), from: Date(timeIntervalSince1970: f), to: Date(timeIntervalSince1970: t))
            let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
            print(String(format: "%.1f s | details from %@ | sleep %.3f Wh in %.2f h | battery %@ W, charger %@ W | wake-ups %d",
                         Date().timeIntervalSince(t0), r.detailsFrom.map { df.string(from: $0) } ?? "-", r.sleepWh ?? -1, r.sleepH,
                         r.avgBatteryW.map { String(format: "%.3f", $0) } ?? "-", r.avgChargerW.map { String(format: "%.3f", $0) } ?? "-", r.wakeCount))
            print("SLEEPS")
            for s in r.sessions {
                print(String(format: "  %@ – %@  %5.2f h  %@  %@ Wh  %@ W  %d wake-ups %@  %@", df.string(from: s.start), df.string(from: s.end), s.hours,
                             s.onBattery.map { $0 ? "battery" : "charger" } ?? "?", s.wh.map { String(format: "%.3f", $0) } ?? "-",
                             s.avgW.map { String(format: "%.3f", $0) } ?? "-", s.wakes, s.cause, s.unusual ? "UNUSUAL" : ""))
            }
            print("WAKE REASONS")
            for g in r.groups {
                print(String(format: "  %-36@ %4d  %6.0f s  %.3f Wh  reasons %@  requested by %@", g.group.rawValue as NSString, g.count, g.secs, g.wh,
                             g.reasons.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)×\($0.value)" }.joined(separator: ", "),
                             g.requesters.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")))
            }
            print("DIDN'T SLEEP")
            for n in r.noSleep {
                print(String(format: "  %@ – %@  %@  %@ Wh  blockers: %@", df.string(from: n.start), df.string(from: n.end), n.cause,
                             n.wh.map { String(format: "%.2f", $0) } ?? "-", n.blockers.map { "\($0.name) \(Int($0.secs / 60)) min" }.joined(separator: "; ")))
            }
            print("HINTS"); for h in r.hints { print("  " + h) }
            exit(0)
        }
        // `--period <from> <to>`: the cards and breakdown for that range, as the window shows them (Custom).
        if let i = CommandLine.arguments.firstIndex(of: "--period"), i + 2 < CommandLine.arguments.count,
           let f = Double(CommandLine.arguments[i + 1]), let t = Double(CommandLine.arguments[i + 2]) {
            let r = try! PowerLog().fullReport(from: Date(timeIntervalSince1970: f), to: Date(timeIntervalSince1970: t))
            let h = r.hardware
            print(String(format: "whole %.3f Wh | awake %.2f h, asleep %.2f h | sleep %.3f Wh (estimated: %@) | avg awake %.2f W | sleep avg %.3f W",
                         h.whole, h.awakeH ?? -1, h.sleepH ?? -1, h.sleep ?? -1, (h.sleepEstimated ?? false) ? "partly" : "no",
                         h.averageAwakeW(fallbackHours: r.coveredHours) ?? -1, (h.sleep ?? 0) / max(h.sleepH ?? 0, 0.001)))
            for p in h.parts { print(String(format: "  %-30@ %.3f Wh", p.name as NSString, p.value)) }
            exit(0)
        }
        // `--background --windowshot <png>`: the main window's content (in the view last chosen), off-screen, as PNG.
        if let i = CommandLine.arguments.firstIndex(of: "--windowshot"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    // MEM_SHOT_W / MEM_SHOT_H: size; MEM_SHOT_SLEEP=1: switch "Sleep only" on after the window appeared;
                    // MEM_SHOT_TAB=wakes|nosleep: the tab in "Sleep only"; MEM_SHOT_DARK=1: dark appearance.
                    let env = ProcessInfo.processInfo.environment
                    let sw = Double(env["MEM_SHOT_W"] ?? "") ?? 1213, sh = Double(env["MEM_SHOT_H"] ?? "") ?? 766
                    // MEM_SHOT_PRESET: the time frame ("Live", "24 hours", …), put back afterwards.
                    let oldPreset = UserDefaults.standard.string(forKey: "preset")
                    if let p = env["MEM_SHOT_PRESET"] { UserDefaults.standard.set(p, forKey: "preset") }
                    let v = NSHostingView(rootView: ContentView().frame(width: sw, height: sh))
                    if env["MEM_SHOT_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
                    if env["MEM_SHOT_SLEEP"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { UserDefaults.standard.set(true, forKey: "sleepOnly") }
                    }
                    let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: sw, height: sh),
                                     styleMask: .borderless, backing: .buffered, defer: false)
                    w.backgroundColor = .windowBackgroundColor
                    w.contentView = v
                    w.orderBack(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["MEM_SHOT_WAIT"] ?? "") ?? 12)) {
                        MainActor.assumeIsolated {
                            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                                v.cacheDisplay(in: v.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                            }
                            if env["MEM_SHOT_PRESET"] != nil { UserDefaults.standard.set(oldPreset, forKey: "preset") }
                            if env["MEM_SHOT_SLEEP"] != nil { UserDefaults.standard.set(false, forKey: "sleepOnly") }
                            // MEM_SHOT_CHECK=<name>: every probed view (top controls, footer, the whole content) must
                            // lie inside the window: nothing cut off at this size.
                            if let name = env["MEM_SHOT_CHECK"] {
                                // Inside the window's 12-pt margin (ContentView's padding), so both sides look the same.
                                let win = CGRect(x: 0, y: 0, width: sw, height: sh).insetBy(dx: 11.5, dy: 11.5)
                                // The content may be taller than its area (it scrolls), but never wider than the window.
                                let f = LayoutProbe.frames
                                var bad = f.filter { k, r in k == "content" ? r.minX < win.minX || r.maxX > win.maxX : !win.contains(r) }
                                    .map { k, r in String(format: "%@ at x %.0f…%.0f, y %.0f…%.0f", k, r.minX, r.maxX, r.minY, r.maxY) }
                                for k in ["top controls", "content area", "content"] where f[k] == nil { bad.append(k + " not drawn") }
                                if name != "Live" && f["footer"] == nil { bad.append("footer not drawn") }
                                let scroll = (f["content"]?.height ?? 0) - (f["content area"]?.height ?? 0)
                                if bad.isEmpty { print(String(format: "layout %@ %.0f×%.0f: all inside%@", name, sw, sh,
                                                              scroll > 1.5 ? String(format: " (content scrolls by %.0f pt)", scroll) : "")) }
                                for b in bad.sorted() { print(String(format: "FAIL: layout %@ %.0f×%.0f: %@ (outside the window)", name, sw, sh, b)) }
                            }
                            exit(0)
                        }
                    }
                }
            }
            return
        }
        // `--background --menubarshot <png>`: the menu bar item (watts + battery) as the menu bar draws it, dark.
        if let i = CommandLine.arguments.firstIndex(of: "--menubarshot"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    let bat = BatteryModel.shared
                    guard let b = bat.now else { exit(1) }
                    let level = b.level.rounded(), charging = b.onCharger && !b.fullyCharged || b.charging
                    let full = b.onCharger && !b.charging && (b.fullyCharged || b.level >= 100)
                    let time = b.onCharger && !b.charging ? (full ? BT.menuFull : BT.menuPaused) : StatusBarController.batteryTime(nil)
                    let att = NSTextAttachment()
                    let s = NSMutableAttributedString(string: " " + StatusBarController.label(14.2) + "  ", attributes: [.font: font, .foregroundColor: NSColor.white])
                    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                        att.image = StatusBarController.batteryImage(level: level, charging: charging, full: full)
                    }
                    att.bounds = CGRect(x: 0, y: -4, width: StatusBarController.batteryIconSize.width, height: StatusBarController.batteryIconSize.height)
                    s.append(NSAttributedString(attachment: att))
                    s.append(NSAttributedString(string: " " + time, attributes: [.font: font, .foregroundColor: NSColor.white]))
                    let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)!
                    let size = NSSize(width: 24 + s.size().width + 16, height: 24), scale: CGFloat = 3
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                        NSColor(white: 0.12, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
                        bolt.withSymbolConfiguration(.init(paletteColors: [.white]))?.draw(in: NSRect(x: 8, y: 5, width: 11, height: 14))
                        s.draw(at: NSPoint(x: 20, y: (size.height - s.size().height) / 2))
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    exit(0)
                }
            }
            return
        }
        // `--background --panelshot <png>`: draws the menu bar panel in an off-screen window into a PNG, then quits.
        if let i = CommandLine.arguments.firstIndex(of: "--panelshot"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    LiveBreakdown.shared.start()
                    let v = NSHostingView(rootView: MenuBarView(model: MenuModel()))
                    let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 360, height: 700),
                                     styleMask: .borderless, backing: .buffered, defer: false)
                    w.backgroundColor = .windowBackgroundColor
                    w.contentView = v
                    w.orderBack(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        MainActor.assumeIsolated {
                            w.setContentSize(v.fittingSize)
                            v.layoutSubtreeIfNeeded()
                            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                                v.cacheDisplay(in: v.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                            }
                            exit(0)
                        }
                    }
                }
            }
            return
        }
        // `--unknowncheck <from> <pretendLogStart>`: with summaries that have no sleep data before pretendLogStart,
        // the awake average must equal the one from macOS's logs for pretendLogStart…now alone.
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--unknowncheck"), i + 2 < a.count, let f = Double(a[i + 1]), let p = Double(a[i + 2]) {
            let log = PowerLog(), now = Date()
            let both = try! log.fullReport(from: Date(timeIntervalSince1970: f), to: now, pretendLogStart: Date(timeIntervalSince1970: p))
            let logs = try! log.report(from: Date(timeIntervalSince1970: p), to: now)
            let h = both.hardware, l = logs.hardware
            print(String(format: "with old summaries: whole %.2f Wh, awake %.2f h, asleep %.2f h, no sleep data %.2f h (%.2f Wh), covered %.2f h, avg awake %.3f W",
                         h.whole, h.awakeH ?? -1, h.sleepH ?? -1, h.unknownH ?? -1, h.unknownWh ?? -1, both.coveredHours,
                         h.averageAwakeW(fallbackHours: both.coveredHours) ?? -1))
            print(String(format: "logs only from p:   whole %.2f Wh, awake %.2f h, asleep %.2f h, avg awake %.3f W",
                         l.whole, l.awakeH ?? -1, l.sleepH ?? -1, l.averageAwakeW(fallbackHours: 1) ?? -1))
            let d = abs((h.averageAwakeW(fallbackHours: 1) ?? 0) - (l.averageAwakeW(fallbackHours: 1) ?? 0))
            print(d < 0.05 ? "UNKNOWN CHECK PASSED" : "UNKNOWN CHECK FAILED (diff \(d) W)")
            exit(0)
        }
        if CommandLine.arguments.contains("--owners") {          // every logged ID that counts for another app
            var ids = Set<String>()
            for db in (try? PowerLog().databases()) ?? [] {
                var h: OpaquePointer?
                guard sqlite3_open_v2(db, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { continue }
                var st: OpaquePointer?
                if sqlite3_prepare_v2(h, "select distinct ifnull(nullif(BundleId,''), LaunchdName) from PLCoalitionAgent_EventInterval_CoalitionInterval", -1, &st, nil) == SQLITE_OK {
                    while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 0) { ids.insert(String(cString: c)) } }
                }
                sqlite3_finalize(st); sqlite3_close(h)
            }
            var n = 0
            for id in ids.sorted() where PowerLog.owner(id) != id { n += 1; print("\(id)  →  \(PowerLog.owner(id))") }
            print("\(n) of \(ids.count) IDs count for another app")
            exit(0)
        }
        // `--liverows [seconds]`: the Live view's app groups, energy over that time (default 10 s), for comparing
        // with macOS's per-app log. Prints the time range (Unix seconds) and, per group, Wh and its id.
        if let i = CommandLine.arguments.firstIndex(of: "--liverows") {
            let secs = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) ?? 10 : 10
            let sampler = ProcessSampler()
            _ = sampler.sample()
            let t0 = Date()
            var wh: [String: (String, String, Double)] = [:]
            var last = t0
            for _ in 0..<secs {
                Thread.sleep(forTimeInterval: 1)
                let now = Date(), dt = now.timeIntervalSince(last); last = now
                for g in sampler.sample().groups { wh[g.id, default: (g.name, g.kind, 0)].2 += g.watts * dt / 3600 }
            }
            print(String(format: "range %.0f %.0f", t0.timeIntervalSince1970, last.timeIntervalSince1970))
            for (id, v) in wh.sorted(by: { $0.value.2 > $1.value.2 }).prefix(40) {
                print(String(format: "%8.4f Wh\t%@\t%@\t%@", v.2, v.1 as NSString, v.0 as NSString, id as NSString))
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--verifydays") {      // one line per local day of "All"
            let log = PowerLog(), cal = Calendar.current, now = Date()
            var d = cal.startOfDay(for: (try? log.fullRange())??.lowerBound ?? now)
            while d < now {
                let n = min(cal.date(byAdding: .day, value: 1, to: d)!, now)
                if let r = try? log.fullReport(from: d, to: n) {
                    let hw = r.hardware
                    let parts = (hw.awakeH ?? 0) + (hw.sleepH ?? 0) + (hw.unknownH ?? 0) + (hw.offH ?? 0)
                    print(String(format: "%@  whole %7.2f Wh  awake %5.2f h  asleep %5.2f h  unknown %5.2f h  off %5.2f h  covered %5.2f h  missing %@  inLogs %@%@",
                                 dayKey(d), hw.whole, hw.awakeH ?? -1, hw.sleepH ?? -1, hw.unknownH ?? -1, hw.offH ?? -1, r.coveredHours,
                                 r.missingDays.isEmpty ? "-" : "yes", r.dataDays.contains(dayKey(d)) ? "yes" : "no",
                                 parts > r.coveredHours + 0.05 ? String(format: "  <-- parts %.2f h > covered", parts) : ""))
                    if let l = try? log.report(from: d, to: n) {
                        print(String(format: "            logs only: whole %7.2f Wh  awake %5.2f h  asleep %5.2f h  total %@  segments-days %@",
                                     l.hardware.whole, l.hardware.awakeH ?? -1, l.hardware.sleepH ?? -1,
                                     l.hardware.total.map { String(format: "%.1f", $0) } ?? "nil", l.dataDays.sorted().joined(separator: ",")))
                    }
                }
                d = n
            }
            exit(0)
        }
        guard CommandLine.arguments.contains("--verify") else { return }
        let log = PowerLog()
        let now = Date()
        do {
            let (_, tdb) = try time { try log.databases() }
            print(String(format: "databases(): %.2f s", tdb))
            let all = try log.fullRange()?.lowerBound ?? now.addingTimeInterval(-86400 * 10)
            let periods: [(String, Date)] = [("1 hour", now.addingTimeInterval(-3600)), ("24 hours", now.addingTimeInterval(-86400)),
                                             ("3 days", now.addingTimeInterval(-3 * 86400)), ("7 days", now.addingTimeInterval(-7 * 86400)),
                                             ("All", all)]
            for (name, from) in periods {
                let (r, t1) = try time { try log.fullReport(from: from, to: now) }
                let (_, t2) = try time { try log.fullReport(from: from, to: now) }
                let hw = r.hardware
                let periodH = now.timeIntervalSince(from) / 3600
                print(String(format: "\n%@: %.2f s (again %.2f s) | whole %.2f Wh, awake %.2f h + asleep %.2f h (+ no sleep data) = %.2f h of %.2f h covered (period %.2f h), sleep %@ Wh, avg awake %.2f W",
                             name, t1, t2, hw.whole, hw.awakeH ?? -1, hw.sleepH ?? -1, (hw.awakeH ?? 0) + (hw.sleepH ?? 0) + (hw.unknownH ?? 0) + (hw.offH ?? 0),
                             r.coveredHours, periodH, hw.sleep.map { String(format: "%.3f", $0) } ?? "nil",
                             hw.averageAwakeW(fallbackHours: r.coveredHours) ?? -1))
                // parts
                let sum = hw.parts.reduce(0) { $0 + $1.value }
                check(abs(sum - hw.whole) < 1e-6, "parts \(sum) ≠ whole \(hw.whole)")
                check(hw.parts.allSatisfy { $0.value >= 0 }, "negative part")
                // (the per-app log and the chip log are separate measurements: tiny differences are allowed)
                if let cpu = hw.cpu { check(hw.apps <= cpu + 0.01 + 0.02 * cpu, "apps \(hw.apps) > cpu \(cpu)") }
                if let s = hw.sleep { check(s >= 0, "sleep < 0") }
                // time
                if let a0 = hw.awakeH, let s = hw.sleepH {
                    let a = a0 + (hw.unknownH ?? 0) + (hw.offH ?? 0)        // days without sleep data count as known time here
                    check(a + s <= r.coveredHours + 0.05, String(format: "awake+asleep %.2f h > covered %.2f h", a + s, r.coveredHours))
                    check(a + s >= r.coveredHours - 0.25 || !r.missingDays.isEmpty,
                          String(format: "awake+asleep %.2f h < covered %.2f h", a + s, r.coveredHours))
                    if let w = hw.averageAwakeW(fallbackHours: r.coveredHours) { check(w > 0.5 && w < 200, "avg awake \(w) W implausible") }
                    if let sl = hw.sleep, s > 0.5 { check(sl / s < 5, "sleep power \(sl / s) W implausible") }
                }
                // table
                let shares = r.rows.reduce(0) { $0 + $1.share }
                check(shares <= 100.01, "shares add up to \(shares)%")
                for row in r.rows {
                    check(abs(row.share - 100 * row.energyWh / max(hw.whole, 1e-9)) < 0.01, "\(row.name) share \(row.share)")
                    check(row.runningH <= periodH + 0.02, String(format: "%@ running %.2f h > period %.2f h", row.name, row.runningH, periodH))
                    check(row.energyWh >= 0, "\(row.name) energy < 0")
                }
                print(String(format: "  table: %d rows, shares %.1f%%, longest running %.2f h", r.rows.count, shares,
                             r.rows.map(\.runningH).max() ?? 0))
            }

            // Additivity: one period = its two halves (macOS logs only, so the saved summaries don't mix in).
            print("\nSplit checks (logs only): whole period vs. first half + second half")
            for hours in [2.0, 24, 72] {
                let a = now.addingTimeInterval(-hours * 3600), m = now.addingTimeInterval(-hours * 1800)
                let w = try log.report(from: a, to: now), x = try log.report(from: a, to: m), y = try log.report(from: m, to: now)
                func cmp(_ label: String, _ v: Double, _ p: Double, _ q: Double, tol: Double) {
                    let d = v - (p + q)
                    print(String(format: "  %4.0f h %-22@ %9.3f vs %9.3f (diff %+.3f)", hours, label as NSString, v, p + q, d))
                    check(abs(d) <= tol, "\(Int(hours)) h \(label): \(v) vs \(p + q)")
                }
                cmp("whole Mac awake Wh", w.hardware.total ?? 0, x.hardware.total ?? 0, y.hardware.total ?? 0, tol: 0.01 * max(1, w.hardware.total ?? 0))
                cmp("CPU Wh", w.hardware.cpu ?? 0, x.hardware.cpu ?? 0, y.hardware.cpu ?? 0, tol: 0.03 * max(1, w.hardware.cpu ?? 0))
                cmp("your apps Wh", w.hardware.apps, x.hardware.apps, y.hardware.apps, tol: 0.05 * max(0.5, w.hardware.apps))
                cmp("awake h", w.hardware.awakeH ?? 0, x.hardware.awakeH ?? 0, y.hardware.awakeH ?? 0, tol: 0.05)
                cmp("asleep h", w.hardware.sleepH ?? 0, x.hardware.sleepH ?? 0, y.hardware.sleepH ?? 0, tol: 0.05)
                cmp("sleep Wh", w.hardware.sleep ?? 0, x.hardware.sleep ?? 0, y.hardware.sleep ?? 0, tol: 0.05 + 0.2 * (w.hardware.sleep ?? 0))
                cmp("table Wh", w.totals.energyWh, x.totals.energyWh, y.totals.energyWh, tol: 0.02 * max(1, w.totals.energyWh))
            }
        } catch { print("error: \(error.localizedDescription)") }
        print("\n\(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")")
        exit(failures == 0 ? 0 : 1)
    }
}
