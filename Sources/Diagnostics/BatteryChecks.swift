import Foundation

/// `--chargecheck`: automated checks of the battery view (test builds only).
///  1. Charges from macOS's logs: consistent times, no overlaps.
///  2. Our time estimate: known inputs give the hand-calculated results.
///  3. The learned charging curve: plausible values, slower at the top than in the middle.
enum BatteryChecks {
    static func runIfAsked() {
        guard CommandLine.arguments.contains("--chargecheck") else { return }
        let check = VerifyTests.check
        guard BatteryNow.read() != nil else { print("no battery: battery view hidden (OK on Macs without one)"); exit(0) }

        // 1. Charges
        let log = PowerLog()
        let events = PMSetLog.shared.events()
        let spans = SleepAnalysis.sleepSpans(events).spans
        let h = BatteryHistory.read(log, sleep: spans, sleepFrom: events.first?.t.timeIntervalSince1970)
        print("charges: \(h.charges.count)")
        check(!h.charges.isEmpty, "no charges found in the battery log")
        for (a, b) in zip(h.charges, h.charges.dropFirst()) {
            check(a.end <= b.start.addingTimeInterval(1), "charges overlap: \(a.start) – \(a.end) and \(b.start)")
        }
        for c in h.charges {
            let len = c.end.timeIntervalSince(c.start)
            check(len >= 0, "charge ends before it starts: \(c.start)")
            check(c.used >= 0 && c.used <= 100, "charge used out of range: \(c.used) % at \(c.start)")
            if let aw = c.awake, let sl = c.asleep {
                check(abs(aw + sl + c.off - len) <= 120,
                      String(format: "awake + asleep + off ≠ length at %@: %.0f + %.0f + %.0f vs %.0f s", "\(c.start)", aw, sl, c.off, len))
                check((c.displayOn ?? 0) <= aw + 60, "display on longer than awake at \(c.start)")
            }
            if let w = c.avgAwakeW { check(w > 0.5 && w < 200, "implausible average while awake: \(w) W at \(c.start)") }
        }

        // 1b. Battery charge at the start and end of sleeps on battery (tooltip in the Sleeps table)
        let rep = SleepAnalysis.report(log, from: Date().addingTimeInterval(-7 * 86400), to: Date())
        let batSleeps = rep.sessions.filter { $0.onBattery == true }
        let lv = BatteryHistory.levels(log, batSleeps.map { ($0.start, $0.end) })
        print("sleeps on battery: \(batSleeps.count), with charge levels: \(lv.count)")
        check(batSleeps.isEmpty || lv.count >= batSleeps.count * 8 / 10, "charge levels missing for many sleeps on battery")
        for s in batSleeps { if let l = lv[s.start.timeIntervalSince1970] {
            var t = s; t.levels = l
            if l.to > l.from + 1 {      // plugged in while asleep: the tooltip must say so
                check(BT.sleepTip(t).contains(String(localized: "Charged while asleep: \(BT.pct(l.from)) → \(BT.pct(l.to))")),
                      "sleep charged on the charger not marked as such at \(s.start)")
            }
            if s.id == batSleeps.last?.id { print("example tooltip:\n" + BT.sleepTip(t)) }
        } }

        // 2. Time estimate with known inputs (60 Wh in the battery, full 120 Wh at 12 V).
        func battery(onCharger: Bool, load: Double, level: Double) -> BatteryNow {
            var b = BatteryNow(level: level, onCharger: onCharger, charging: onCharger, fullyCharged: false, voltage: 12,
                               amperage: 0, cycles: 1, capacityNow: 10000, capacityDesign: 10000,
                               rawRemaining: 5000, rawFull: 10000, macOSToEmpty: nil, macOSToFull: nil,
                               systemLoad: load, powerIn: onCharger ? load + 20 : nil, adapterName: nil, adapterMaxW: nil)
            b.smcLive = true
            return b
        }
        let now = Date().timeIntervalSince1970
        let e1 = OwnTimeEstimate()
        let onBat = battery(onCharger: false, load: 10, level: 50)
        e1.seed(stride(from: now - 300, to: now, by: 60).map { ($0, 10) })
        e1.update(onBat)
        let left = e1.secondsLeft(onBat) ?? -1
        check(abs(left - 6 * 3600) < 120, String(format: "time left: %.0f s, expected 21600 (60 Wh / 10 W)", left))

        // Charging at 20 W into the battery: linear 60 Wh / 20 W = 3 h; with a curve that halves above 80 %:
        // 30 % at 20 W (36 Wh → 1.8 h) + 20 % at 10 W (24 Wh → 2.4 h) = 4.2 h.
        let charging = battery(onCharger: true, load: 5, level: 50)
        let e2 = OwnTimeEstimate()
        e2.seed(stride(from: now - 300, to: now, by: 60).map { ($0, 20) })
        e2.update(charging)
        let linear = e2.secondsToFull(charging) ?? -1
        check(abs(linear - 3 * 3600) < 120, String(format: "time to full without a curve: %.0f s, expected 10800", linear))
        let e3 = OwnTimeEstimate()
        e3.setChargeCurve(Dictionary(uniqueKeysWithValues: (1...99).map { ($0, $0 < 80 ? 20.0 : 10.0) }))
        e3.seed(stride(from: now - 300, to: now, by: 60).map { ($0, 20) })
        e3.update(charging)
        let curved = e3.secondsToFull(charging) ?? -1
        check(abs(curved - 4.2 * 3600) < 180, String(format: "time to full with a curve: %.0f s, expected 15120", curved))
        // A weaker charger than in the log: never faster than now (10 W now, curve 20 W): 60 Wh … ≥ 6 h - margin.
        let e4 = OwnTimeEstimate()
        e4.setChargeCurve(Dictionary(uniqueKeysWithValues: (1...99).map { ($0, 20.0) }))
        e4.seed(stride(from: now - 300, to: now, by: 60).map { ($0, 10) })
        let weak = battery(onCharger: true, load: 5, level: 50)
        e4.update(weak)
        let slow = e4.secondsToFull(weak) ?? -1
        check(abs(slow - 6 * 3600) < 180, String(format: "weaker charger: %.0f s, expected 21600 (60 Wh / 10 W)", slow))
        print(String(format: "estimate: left %.2f h, to full linear %.2f h, with curve %.2f h, weak charger %.2f h",
                     left / 3600, linear / 3600, curved / 3600, slow / 3600))

        // 3. The learned charging curve of this Mac
        let curve = BatteryHistory.chargeCurve(log)
        print("charge curve: \(curve.count) levels" + (curve.isEmpty ? "" : ", " + [20, 50, 80, 95].compactMap { l in
            curve[l].map { String(format: "%d %%: %.0f W", l, $0) } }.joined(separator: ", ")))
        if curve.count >= 5 {
            check(curve.values.allSatisfy { $0 > 0.5 && $0 < 200 }, "implausible charging power in the curve")
            let mid = curve.filter { (30...60).contains($0.key) }.map(\.value), top = curve.filter { $0.key >= 90 }.map(\.value)
            if !mid.isEmpty && !top.isEmpty {
                check(top.reduce(0, +) / Double(top.count) < mid.reduce(0, +) / Double(mid.count),
                      "the curve doesn't slow down above 90 % (it should, as batteries do)")
            }
        }
        print(VerifyTests.failures == 0 ? "ALL CHARGE CHECKS PASSED" : "\(VerifyTests.failures) CHARGE CHECK(S) FAILED")
        exit(VerifyTests.failures == 0 ? 0 : 1)
    }
}
