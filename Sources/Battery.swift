import Foundation
import IOKit
import IOKit.ps
import CoreGraphics

nonisolated(unsafe) private var batteryData: [String: Any] = [:]
nonisolated(unsafe) private var batteryDataAt = 0.0

/// Live battery values from the battery's own record (IOKit AppleSmartBattery). Read-only, no permissions.
struct BatteryNow {
    var level: Double            // %
    var onCharger: Bool          // charger connected
    var charging: Bool
    var fullyCharged: Bool
    var voltage: Double          // V
    var amperage: Double         // A (negative = discharging)
    var cycles: Int
    var capacityNow: Double      // mAh (full charge capacity today)
    var capacityDesign: Double   // mAh
    var rawRemaining: Double?    // mAh the battery holds now (AppleRawCurrentCapacity)
    var rawFull: Double?         // mAh it holds when full today (AppleRawMaxCapacity)
    var macOSToEmpty: Double?    // s, macOS's estimate
    var macOSToFull: Double?     // s
    var systemLoad: Double?      // W, what the Mac uses
    var powerIn: Double?         // W, from the charger
    var adapterName: String?
    var adapterMaxW: Double?

    /// Power out of (on battery) or into (charging) the battery. From the power controller, updated every second:
    /// on battery all of the Mac's power comes from it; charging, it gets what the charger delivers beyond the Mac's use.
    /// The battery's own record updates only about once a minute (fallback).
    var batteryW: Double {
        if onCharger {
            if let i = powerIn, let s = systemLoad, smcLive { return max(0, i - s) }
            return amperage > 0 ? voltage * amperage : 0
        }
        return systemLoad ?? abs(voltage * amperage)
    }
    /// Battery current derived from the power above (mA).
    var batteryMilliamps: Double { voltage > 0 ? batteryW / voltage * 1000 : abs(amperage * 1000) }
    var smcLive = false

    /// nil on Macs without a battery.
    static func read() -> BatteryNow? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        // Only the values needed, one by one: the whole record (with its detailed cell data) is large, and this
        // runs every second for the menu bar.
        let keys = ["BatteryInstalled", "CurrentCapacity", "ExternalConnected", "IsCharging", "FullyCharged", "Voltage",
                    "Amperage", "CycleCount", "NominalChargeCapacity", "AppleRawMaxCapacity", "AppleRawCurrentCapacity",
                    "DesignCapacity", "AvgTimeToEmpty", "AvgTimeToFull", "TimeRemaining", "PowerTelemetryData", "AdapterDetails"]
        var d: [String: Any] = [:]
        for k in keys {
            if let v = IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() { d[k] = v }
        }
        if d["CurrentCapacity"] == nil { return nil }
        // The capacities (mAh) are only in the large nested BatteryData: read every 30 s, kept in between.
        let nowT = Date().timeIntervalSince1970
        if nowT - batteryDataAt > 30 || batteryData.isEmpty {
            batteryData = IORegistryEntryCreateCFProperty(svc, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] ?? [:]
            batteryDataAt = nowT
        }
        d["BatteryData"] = batteryData
        if let installed = d["BatteryInstalled"] as? Bool, !installed { return nil }
        func n(_ k: String, in x: [String: Any] = d) -> NSNumber? { x[k] as? NSNumber }
        func secs(_ k: String) -> Double? {   // minutes; 65535 = macOS still calculating
            guard let m = n(k)?.intValue, m > 0, m < 65535 else { return nil }
            return Double(m) * 60
        }
        let t = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        let a = d["AdapterDetails"] as? [String: Any] ?? [:]
        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        let mW = { (k: String) -> Double? in n(k, in: t).map { $0.doubleValue / 1000 }.flatMap { $0 > 0 ? $0 : nil } }
        return BatteryNow(
            level: n("CurrentCapacity")?.doubleValue ?? 0,
            onCharger: (d["ExternalConnected"] as? Bool) ?? false,
            charging: (d["IsCharging"] as? Bool) ?? false,
            fullyCharged: (d["FullyCharged"] as? Bool) ?? false,
            voltage: (n("Voltage")?.doubleValue ?? 0) / 1000,
            amperage: Double(n("Amperage")?.int64Value ?? 0) / 1000,     // stored as a signed value
            cycles: n("CycleCount")?.intValue ?? 0,
            capacityNow: [n("NominalChargeCapacity"), n("NominalChargeCapacity", in: bd), n("AppleRawMaxCapacity"),
                          n("AppleRawMaxCapacity", in: bd)].compactMap { $0?.doubleValue }.first { $0 > 0 } ?? 0,
            capacityDesign: n("DesignCapacity")?.doubleValue ?? n("DesignCapacity", in: bd)?.doubleValue ?? 0,
            rawRemaining: (n("AppleRawCurrentCapacity") ?? n("AppleRawCurrentCapacity", in: bd))?.doubleValue,
            rawFull: (n("AppleRawMaxCapacity") ?? n("AppleRawMaxCapacity", in: bd))?.doubleValue,
            // TimeRemaining is what macOS's battery menu shows; right after unplugging it may still hold the time
            // to full (the view shows "Calculating…" for 90 s then).
            macOSToEmpty: (d["ExternalConnected"] as? Bool) == true ? nil : secs("TimeRemaining") ?? secs("AvgTimeToEmpty"),
            macOSToFull: secs("AvgTimeToFull") ?? ((d["IsCharging"] as? Bool) == true ? secs("TimeRemaining") : nil),
            systemLoad: mW("SystemLoad"),
            powerIn: mW("SystemPowerIn"),
            adapterName: a["Name"] as? String ?? a["Description"] as? String,
            adapterMaxW: n("Watts", in: a)?.doubleValue)
            .withPowerController().faked()
    }

    /// Test build: MEM_FAKE_BATTERY=full|paused shows that state (for screenshots); otherwise unchanged.
    private func faked() -> BatteryNow {
        #if DIAGNOSTICS
        var b = self
        switch ProcessInfo.processInfo.environment["MEM_FAKE_BATTERY"] {
        case "full": b.level = 100; b.onCharger = true; b.charging = false; b.fullyCharged = true
        case "paused": b.level = 80; b.onCharger = true; b.charging = false; b.fullyCharged = false
        default: break
        }
        return b
        #else
        return self
        #endif
    }

    /// Whole-Mac power (PSTR) and charger input (PDTR) from the power controller: every second, unlike the battery record.
    private func withPowerController() -> BatteryNow {
        var b = self
        if let s = SMC.shared.float("PSTR"), s > 0 {
            b.systemLoad = s; b.smcLive = true
            if let i = SMC.shared.float("PDTR") { b.powerIn = i }
        }
        return b
    }
}

/// How the remaining time is estimated. macOS's own estimate for now; the user's own calculation can
/// replace it later by adding another implementation (nothing else changes).
protocol BatteryTimeEstimator {
    func secondsLeft(_ b: BatteryNow) -> Double?
    func secondsToFull(_ b: BatteryNow) -> Double?
    /// Called with every live reading (once a second while the window is open).
    func update(_ b: BatteryNow)
    /// The state changed (plugged in or out): start over.
    func reset()
    /// Earlier power readings (from macOS's battery log), so the average is complete as soon as the window opens.
    func seed(_ samples: [(t: Double, w: Double)])
    /// This Mac's charging curve: typical power into the battery at each charge level (%), from its own log.
    func setChargeCurve(_ curve: [Int: Double])
}
extension BatteryTimeEstimator {
    func update(_ b: BatteryNow) {}
    func reset() {}
    func seed(_ samples: [(t: Double, w: Double)]) {}
    func setChargeCurve(_ curve: [Int: Double]) {}
}

/// Our own estimate: the energy left (or missing) in the battery divided by the average power of the last
/// 5 minutes, recomputed every 10 seconds so the shown time doesn't jump.
///   time left       = remaining mAh × voltage ÷ average power drawn
///   time until full = (full mAh − remaining mAh) × voltage ÷ average power into the battery
/// Above about 80 % the battery charges more slowly; the measured charging power follows that by itself.
final class OwnTimeEstimate: BatteryTimeEstimator {
    static let window = 300.0, every = 10.0, minSamples = 30.0
    private var samples: [(t: Double, w: Double)] = []
    private var shown: (t: Double, left: Double?, full: Double?) = (0, nil, nil)

    func reset() { samples.removeAll(); shown = (0, nil, nil) }
    func seed(_ s: [(t: Double, w: Double)]) {
        let first = samples.first?.t ?? .infinity
        samples = s.filter { $0.t < first } + samples        // only what's older than our own readings
        shown.t = 0                                           // recompute at the next reading
    }

    func update(_ b: BatteryNow) {
        let now = Date().timeIntervalSince1970
        // On battery: power drawn; charging: power going into the battery.
        if b.onCharger ? b.charging : true { samples.append((now, b.batteryW)) }
        samples.removeAll { now - $0.t > Self.window }
        guard now - shown.t >= Self.every || shown.t == 0 else { return }
        shown.t = now
        guard let first = samples.first, now - first.t >= Self.minSamples, b.voltage > 0 else {
            shown.left = nil; shown.full = nil; return                    // "Calculating…" for the first 30 s
        }
        // Time-weighted: the log's readings (one a minute) count for their minute, ours (one a second) for their second.
        var sum = 0.0, span = 0.0
        for (i, x) in samples.enumerated() {
            let dt = min(120, (i + 1 < samples.count ? samples[i + 1].t : now) - x.t)
            sum += x.w * max(1, dt); span += max(1, dt)
        }
        let avgW = sum / span
        guard avgW > 0.1 else { shown.left = nil; shown.full = nil; return }
        let remainingWh = (b.rawRemaining ?? b.level / 100 * b.capacityNow) * b.voltage / 1000
        let fullWh = (b.rawFull ?? b.capacityNow) * b.voltage / 1000
        shown.left = b.onCharger ? nil : remainingWh / avgW * 3600
        shown.full = b.onCharger && b.charging ? toFull(b, fullWh: fullWh, avgW: avgW) : nil
    }

    private var curve: [Int: Double] = [:]
    func setChargeCurve(_ c: [Int: Double]) { curve = c; shown.t = 0 }

    /// Time until full, step by step through the charge levels: each 1 % needs 1 % of the full energy, at the power
    /// this Mac's battery typically charges with at that level (its own charging curve), but never faster than it
    /// charges right now (the charger in use may be weaker than the one in the log). Without a curve: linear.
    private func toFull(_ b: BatteryNow, fullWh: Double, avgW: Double) -> Double {
        let level = Int(b.level.rounded(.down))
        guard curve.count >= 5, level < 100 else {
            let remainingWh = (b.rawRemaining ?? b.level / 100 * b.capacityNow) * b.voltage / 1000
            return max(0, fullWh - remainingWh) / avgW * 3600
        }
        let known = curve.keys.sorted()
        func curveW(_ l: Int) -> Double {                       // nearest learned level
            curve[l] ?? curve[known.min { abs($0 - l) < abs($1 - l) }!]!
        }
        // Right now the battery takes avgW at this level; the curve says what's typical here. Above this level the
        // battery limits the power (the curve's drop); below the curve's value the charger does (avgW).
        let pctWh = fullWh / 100
        var secs = 0.0
        for l in level..<100 {
            let w = max(0.3, min(avgW, curveW(l)))
            let part = l == level ? max(0, 1 - (b.level - Double(level))) : 1
            secs += pctWh * part / w * 3600
        }
        return secs
    }
    func secondsLeft(_ b: BatteryNow) -> Double? { b.onCharger ? nil : shown.left }
    func secondsToFull(_ b: BatteryNow) -> Double? { b.charging ? shown.full : nil }
}

/// macOS's own estimate, as its battery menu shows it (IOPowerSources).
struct MacOSTimeEstimate: BatteryTimeEstimator {
    func secondsLeft(_ b: BatteryNow) -> Double? {
        guard !b.onCharger else { return nil }
        let t = IOPSGetTimeRemainingEstimate()                      // seconds; -1 = still calculating
        return t > 0 ? t : nil
    }
    func secondsToFull(_ b: BatteryNow) -> Double? {
        guard b.charging else { return nil }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return b.macOSToFull }
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               let m = d[kIOPSTimeToFullChargeKey] as? Int, m > 0 { return Double(m) * 60 }
        }
        return nil
    }
}

/// macOS's own health rating (as in System Settings › Battery). Slow (system_profiler), read once per opening.
struct BatteryHealth { var condition: String; var maxCapacity: Double? }

extension BatteryHealth {
    static func read() -> BatteryHealth? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType", "-json"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = j["SPPowerDataType"] as? [[String: Any]],
              let h = items.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first else { return nil }
        let cap = (h["sppower_battery_health_maximum_capacity"] as? String)
            .map { $0.filter { $0.isNumber } }.flatMap { Double($0) }
        return BatteryHealth(condition: h["sppower_battery_health"] as? String ?? "", maxCapacity: cap)
    }
}

/// One charge: from unplugging to plugging in again (or until now, if still on battery).
struct BatteryCharge: Identifiable {
    var id: Double { start.timeIntervalSince1970 }
    var start: Date, end: Date
    let startLevel: Double, endLevel: Double
    let awake: Double?, asleep: Double?    // s; nil before macOS's sleep log starts (unknown)
    let displayOn: Double?                 // s, part of awake
    var off: Double = 0                    // s, switched off (shut down) during the charge
    let wh: Double?, avgAwakeW: Double?
    var running: Bool
    var used: Double { max(0, startLevel - endLevel) }
}

extension BatteryHistory {
    /// Battery charge (%) at the start and end of the given periods (keyed by start time).
    static func levels(_ log: PowerLog, _ periods: [(Date, Date)]) -> [Double: (from: Double, to: Double)] {
        guard let lo = periods.map({ $0.0.timeIntervalSince1970 }).min(),
              let hi = periods.map({ $0.1.timeIntervalSince1970 }).max(),
              let dbs = try? log.databases(overlapping: lo - 5400, hi + 900) else { return [:] }
        var rows: [Double: Double] = [:]
        for p in dbs {
            BatteryLogQuery.run(p, "select timestamp, Level from PLBatteryAgent_EventBackward_Battery where timestamp >= ? and timestamp <= ?",
                                [lo - 5400, hi + 900]) { v in if v[1] > 0 { rows[v[0]] = v[1] } }
        }
        let ts = rows.keys.sorted()
        // The last entry up to 90 minutes before (asleep, some Macs log only every 30–60 minutes), otherwise the
        // first one up to 15 minutes after.
        func at(_ t: Double) -> Double? {
            var lo = 0, hi = ts.count
            while lo < hi { let m = (lo + hi) / 2; if ts[m] <= t { lo = m + 1 } else { hi = m } }
            if lo > 0, t - ts[lo - 1] <= 5400 { return rows[ts[lo - 1]] }
            if lo < ts.count, ts[lo] - t <= 900 { return rows[ts[lo]] }
            return nil
        }
        var out: [Double: (from: Double, to: Double)] = [:]
        for (a, b) in periods {
            if let f = at(a.timeIntervalSince1970), let t = at(b.timeIntervalSince1970) { out[a.timeIntervalSince1970] = (f, t) }
        }
        return out
    }

    /// This Mac's charging curve from its battery log (about 12 days): the median power going into the battery at
    /// each charge level while it was charging. Levels with fewer than 3 readings are left out.
    static func chargeCurve(_ log: PowerLog) -> [Int: Double] {
        let hi = Date().timeIntervalSince1970, lo = hi - 12 * 86400
        guard let dbs = try? log.databases(overlapping: lo, hi) else { return [:] }
        var byLevel: [Int: [Double]] = [:]
        var seen = Set<Double>()
        for p in dbs {
            BatteryLogQuery.run(p, """
                select timestamp, Level, Voltage, InstantAmperage from PLBatteryAgent_EventBackward_Battery
                where timestamp >= ? and timestamp <= ? and ExternalConnected = 1 and IsCharging = 1
                """, [lo, hi]) { v in
                guard seen.insert(v[0]).inserted else { return }
                let w = v[2] / 1000 * v[3] / 1000
                guard w > 0.5, v[1] >= 1, v[1] < 100 else { return }    // charging paused: not part of the curve
                byLevel[Int(v[1]), default: []].append(w)
            }
        }
        return byLevel.filter { $0.value.count >= 3 }.mapValues { $0.sorted()[$0.count / 2] }
    }

    /// The battery's power over the last `seconds` in the given state, from macOS's battery log (about one entry a
    /// minute): on battery the power drawn, charging the power going in (voltage × current).
    static func recentPower(_ log: PowerLog, onCharger: Bool, seconds: Double = OwnTimeEstimate.window) -> [(t: Double, w: Double)] {
        let hi = Date().timeIntervalSince1970, lo = hi - seconds
        guard let dbs = try? log.databases(overlapping: lo, hi) else { return [] }
        var out: [Double: Double] = [:]
        for p in dbs {
            BatteryLogQuery.run(p, """
                select timestamp, Voltage, InstantAmperage, ExternalConnected from PLBatteryAgent_EventBackward_Battery
                where timestamp >= ? and timestamp <= ?
                """, [lo, hi]) { v in
                guard (v[3] != 0) == onCharger else { return }
                let w = v[1] / 1000 * v[2] / 1000                       // mV × mA → W (negative = discharging)
                if onCharger ? w > 0 : w < 0 { out[v[0]] = abs(w) }
            }
        }
        return out.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// Charges and the current state, from macOS's battery log plus the sleep periods of macOS's sleep log.
struct BatteryHistory {
    var charges: [BatteryCharge] = []
    var since: Date?             // start of the current state (on battery, or on the charger)
    var sinceLevel: Double?
    var current: BatteryCharge?  // the running charge, when on battery
    var temperature: Double?     // °C, last logged
    var lastOnCharger: Bool?     // state in the last log row (the log lags up to a minute or more)

    private struct Row { let t: Double, level: Double, mAh: Double, mV: Double, onCharger: Bool, temp: Double }

    static let minSeconds = 600.0, minUsed = 3.0

    static func read(_ log: PowerLog, sleep: [SleepSpan], sleepFrom: Double?, now: Date = Date()) -> BatteryHistory {
        let hi = now.timeIntervalSince1970, lo = hi - 12 * 86400
        guard let dbs = try? log.databases(overlapping: lo, hi) else { return BatteryHistory() }
        var byTime: [Double: Row] = [:]
        for p in dbs {
            BatteryLogQuery.run(p, """
                select timestamp, Level, AppleRawCurrentCapacity, Voltage, ExternalConnected, Temperature
                from PLBatteryAgent_EventBackward_Battery where timestamp >= ? and timestamp <= ?
                """, [lo, hi]) { v in
                guard v[1] > 0 else { return }
                byTime[(v[0] * 10).rounded() / 10] = Row(t: v[0], level: v[1], mAh: v[2], mV: v[3], onCharger: v[4] != 0, temp: v[5])
            }
        }
        let rows = byTime.values.sorted { $0.t < $1.t }
        // Start-ups after a shutdown (cold boots): a log gap that contains one was time switched off.
        var boots: [Double] = []
        for p in dbs {
            BatteryLogQuery.run(p, "select timestamp from PLSMCAgent_EventNone_ColdBoot where timestamp >= ? and timestamp <= ?", [lo, hi]) { boots.append($0[0]) }
        }
        // Screen-on seconds per hour (each entry is stamped a few seconds before the hour it covers).
        var screen: [Int: Double] = [:]
        for p in dbs {
            BatteryLogQuery.run(p, "select timestamp, ScreenOn from PLDisplayAgent_Aggregate_ScreenOn where timestamp >= ? and timestamp <= ?",
                                [lo - 7200, hi]) { v in
                let h = Int((v[0] + 300) / 3600); screen[h] = max(screen[h] ?? 0, v[1])
            }
        }
        var h = BatteryHistory()
        guard let last = rows.last else { return h }
        h.temperature = last.temp > 0 ? last.temp : nil
        h.lastOnCharger = last.onCharger

        // Battery segments (runs of rows on battery).
        var segs: [(a: Int, b: Int)] = []
        var i = 0
        while i < rows.count {
            guard !rows[i].onCharger else { i += 1; continue }
            var j = i
            while j + 1 < rows.count && !rows[j + 1].onCharger { j += 1 }
            segs.append((i, j)); i = j + 1
        }
        // Every unplugging starts a new charge (no merging: the chart must match what the user did).
        let merged = segs
        let onBatteryNow = !last.onCharger
        for (k, s) in merged.enumerated() {
            let isRunning = onBatteryNow && k == merged.count - 1
            let a = rows[s.a], b = isRunning ? last : (s.b + 1 < rows.count ? rows[s.b + 1] : rows[s.b])
            let endT = isRunning ? hi : b.t
            let c = charge(rows, a.t, endT, a.level, b.level, sleep, screen, boots, known: sleepFrom.map { a.t >= $0 } ?? false, running: isRunning)
            if isRunning { h.current = c }
            if isRunning || endT - a.t >= minSeconds || c.used >= minUsed { h.charges.append(c) }   // drop only tiny ones
        }
        // Since when in the current state.
        var k = rows.count - 1
        while k > 0 && rows[k - 1].onCharger == last.onCharger { k -= 1 }
        if k > 0 || rows.count > 1 { h.since = Date(timeIntervalSince1970: rows[k].t); h.sinceLevel = rows[k].level }
        if onBatteryNow, let c = h.current { h.since = c.start; h.sinceLevel = c.startLevel }
        return h
    }

    private static func charge(_ rows: [Row], _ a: Double, _ b: Double, _ la: Double, _ lb: Double,
                               _ sleep: [SleepSpan], _ screen: [Int: Double], _ boots: [Double], known: Bool, running: Bool) -> BatteryCharge {
        // Awake or asleep: macOS's sleep log, checked against the battery log. Awake, macOS writes a battery entry
        // about every minute; asleep only every 20–30 minutes (short background wake-ups in between belong to the sleep).
        //  · a sleep in the sleep log counts, except stretches where the battery shows real awake use (seen on a MacBook
        //    Air with a macOS beta, whose sleep log marked awake stretches as sleep);
        //  · gaps of more than 5 minutes between battery entries outside those sleeps count as asleep too (sleeps the
        //    sleep log missed), or as switched off when a start-up after a shutdown (cold boot) falls into them.
        // The last stretch of the running charge (the battery log lags behind) uses only the sleep log.
        let inside = rows.filter { $0.t >= a && $0.t <= b }
        func wh(_ x: Double, _ y: Double) -> Double? {
            let r = inside.filter { $0.t >= x && $0.t <= y }
            guard let f = r.first, let l = r.last, l.t > f.t else { return nil }
            return max(0, (f.mAh - l.mAh) * (f.mV + l.mV) / 2 / 1e6)
        }
        // Inside a sleep: stretches of at least 10 minutes with a battery entry every 3 minutes or less and more than
        // 1.5 W were awake after all; they're cut out of the sleep.
        var spans: [(a: Double, b: Double)] = []
        for sp in sleep {
            let x = max(sp.a, a), y = min(sp.b, b)
            guard y > x else { continue }
            let r = inside.filter { $0.t >= x && $0.t <= y }
            var cuts: [(a: Double, b: Double)] = []
            var i = 0
            while i < r.count {
                var j = i
                while j + 1 < r.count && r[j + 1].t - r[j].t <= 180 { j += 1 }
                let d = r[j].t - r[i].t
                if d >= 600 {
                    let e = max(0, (r[i].mAh - r[j].mAh) * (r[i].mV + r[j].mV) / 2 / 1e6)
                    if e / (d / 3600) > 1.5 { cuts.append((r[i].t, r[j].t)) }
                }
                i = j + 1
            }
            var start = x
            for c in cuts { if c.a > start { spans.append((start, c.a)) }; start = max(start, c.b) }
            if y > start { spans.append((start, y)) }
        }
        func inSpans(_ x: Double, _ y: Double) -> Double { spans.reduce(0.0) { $0 + max(0, min($1.b, y) - max($1.a, x)) } }
        var asleep = spans.reduce(0.0) { $0 + ($1.b - $1.a) }, off = 0.0
        var sleepWh = spans.compactMap { wh($0.a, $0.b) }.reduce(0, +)
        let points = [a] + inside.map(\.t) + [b]
        let tail = running ? (inside.last?.t ?? a) : b
        for (x, y) in zip(points, points.dropFirst()) where y - x > 300 && x < tail {
            let free = (y - x) - inSpans(x, y)                         // not already counted as sleep
            guard free > 60 else { continue }
            if boots.contains(where: { $0 > x && $0 <= y + 120 }) { off += free }
            else { asleep += free; if let e = wh(x, y) { sleepWh += e * free / (y - x) } }
        }
        let awake = max(0, (b - a) - asleep - off)
        var on = 0.0
        for h in Int(a / 3600)...Int(b / 3600) {
            // The running hour's entry holds only the seconds so far: spread it over the minutes elapsed.
            let hs = Double(h) * 3600, part = max(0, min(b, hs + 3600) - max(a, hs))
            let now = Date().timeIntervalSince1970
            if now - hs < 3600 {
                // macOS updates the running hour about every 5 minutes: logged until the last update; if the display
                // is on now, the minutes since then count as display on (as in the history view).
                // The app's copy of the log can lag further: with the display on now, the hour is taken as logged only
                // up to its logged seconds (all display on), and the rest as display on until now.
                let displayOnNow = CGDisplayIsAsleep(CGMainDisplayID()) == 0
                let loggedUntil = displayOnNow ? min(now, hs + (screen[h] ?? 0))
                    : min(now, max(hs + ((now - hs) / 300).rounded(.down) * 300, hs + (screen[h] ?? 0)))
                let covered = max(1, loggedUntil - hs)
                on += (screen[h] ?? 0) * min(1, max(0, min(b, loggedUntil) - max(a, hs)) / covered)
                if displayOnNow { on += max(0, min(b, now) - max(a, loggedUntil)) }
            } else {
                on += (screen[h] ?? 0) * part / 3600
            }
        }
        on = min(on, awake)
        // Energy: drop of the battery's charge (mAh) times its voltage.
        var wh: Double? = nil
        if let f = inside.first, let l = inside.last, f.mAh > 0, l.mAh > 0 {
            wh = max(0, (f.mAh - l.mAh) * (f.mV + l.mV) / 2 / 1e6)
        }
        // 30 min+ awake; below 1.5 W it can't be right (an awake Mac uses more): then the logs don't allow the split
        // between awake and asleep energy (seen on a MacBook Air with gaps in its logs) and it's left out.
        let avg = known ? (wh.map { $0 - sleepWh }).flatMap { awake >= 1800 && $0 > 0 ? $0 / (awake / 3600) : nil }
            .flatMap { $0 >= 1.5 ? $0 : nil } : nil
        #if DIAGNOSTICS
        if ProcessInfo.processInfo.environment["MEM_DEBUG_CHARGE"] != nil {
            let f = inside.first, l = inside.last
            print(String(format: "DEBUG %@ – %@: rows %d, mAh %.0f→%.0f, V %.2f→%.2f, wh %.2f, sleepWh %.2f, awake %.0f min, asleep %.0f min, off %.0f min",
                         "\(Date(timeIntervalSince1970: a))", "\(Date(timeIntervalSince1970: b))", inside.count, f?.mAh ?? -1, l?.mAh ?? -1,
                         (f?.mV ?? 0) / 1000, (l?.mV ?? 0) / 1000, wh ?? -1, sleepWh, awake / 60, asleep / 60, off / 60))
        }
        #endif
        var c = BatteryCharge(start: Date(timeIntervalSince1970: a), end: Date(timeIntervalSince1970: b),
                             startLevel: la, endLevel: lb, awake: known ? awake : nil, asleep: known ? asleep : nil,
                             displayOn: known ? on : nil, wh: wh, avgAwakeW: avg, running: running)
        c.off = off
        return c
    }
}

import SQLite3
enum BatteryLogQuery {
    /// Read-only query; each row's columns as Doubles.
    static func run(_ path: String, _ sql: String, _ args: [Double], _ body: ([Double]) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st {
            for (i, a) in args.enumerated() { sqlite3_bind_double(st, Int32(i + 1), a) }
            let n = sqlite3_column_count(st)
            while sqlite3_step(st) == SQLITE_ROW { body((0..<n).map { sqlite3_column_double(st, $0) }) }
        }
        sqlite3_finalize(st)
        sqlite3_close(db)
    }
}
