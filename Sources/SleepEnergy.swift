import Foundation
import SQLite3

/// Energy while the Mac sleeps. A sleep shows up as a gap in macOS's whole-Mac log, but its running counter keeps
/// counting while the Mac sleeps, so the counter across the gap is the measured energy (on battery and charger).
/// Where the counter can't be used (a restart in between, or it stopped counting): on battery, the battery's
/// charge before and after the gap (mAh × V); on the charger, an estimate from this Mac's measured sleeps.
/// A gap with a restart in it counts as switched off: 0 on the charger.
struct SleepEnergy {
    struct Result {
        var wh: Double?          // nil: no battery (desktop Mac) or nothing to go on yet
        var sleepH = 0.0         // time asleep or off inside the period
        var estimated = false    // part of `wh` is an estimate (charger connected)
    }

    struct Battery { let t: Double, mAh: Double, mV: Double, onBattery: Bool }

    /// Average sleep power measured on battery, cached for an hour (it needs all log files).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedRate: (at: Date, w: Double?)?

    /// `gaps`: periods without whole-Mac load records (asleep or off), from the caller's load samples.
    static func compute(_ dbs: [String], gaps: [(a: Double, b: Double)], counter: [(a: Double, b: Double, w: Double)] = [],
                        start: Double, end: Double) -> Result {
        var r = Result()
        let inside = gaps.filter { min($0.b, end) > max($0.a, start) }
        r.sleepH = inside.reduce(0) { $0 + (min($1.b, end) - max($1.a, start)) } / 3600
        guard !inside.isEmpty else {
            r.wh = hasBattery(dbs) || !counter.isEmpty ? 0 : nil
            return r
        }
        // The counter's average power for a sleep, if it covers the whole sleep.
        func counted(_ g: (a: Double, b: Double)) -> Double? {
            var wh = 0.0, secs = 0.0
            for c in counter where min(c.b, g.b) > max(c.a, g.a) {
                let o = min(c.b, g.b) - max(c.a, g.a)
                wh += c.w * o / 3600; secs += o
            }
            return secs >= 0.95 * (g.b - g.a) ? wh : nil
        }
        let lo = inside.map(\.a).min()! - 900, hi = inside.map(\.b).max()! + 900
        let bat = battery(dbs, lo, hi)
        let boots = coldBoots(dbs, lo, hi)
        var total = 0.0, any = false
        for g in inside {
            let f = (min(g.b, end) - max(g.a, start)) / (g.b - g.a)        // part of this sleep inside the period
            if let c = counted(g) {
                total += c * f; any = true
            } else if bat.isEmpty {
                continue                                      // desktop Mac without the counter: unknown
            } else if let m = measured(g, bat) {
                total += m * f; any = true
            } else if boots.contains(where: { $0 >= g.a - 60 && $0 <= g.b + 600 }) {
                any = true                                    // restarted: off for (almost) all of it
            } else if let w = rate(dbs) {
                total += w * (g.b - g.a) / 3600 * f; any = true; r.estimated = true
            }
        }
        if any { r.wh = total }
        return r
    }

    /// Energy of one sleep (from closing the lid until you wake the Mac), the part [x, y] of it. The same rule in
    /// the history views and in "Sleep only": on battery, the battery's own charge drop over the whole sleep,
    /// because on some Macs (MacBook Air M1) macOS's counter counts far too little while asleep; otherwise the
    /// whole-Mac counter over the whole sleep; failing that, the battery after all.
    /// Always worked out for the WHOLE sleep and then shared out to the part (by the counter's energy in that part,
    /// by time where it has none): so the parts of a sleep always add up to it, wherever a period cuts it. (A part
    /// measured on its own could miss the counter's 90 % coverage while the whole sleep doesn't, and lose its energy.)
    /// `counted`: the counter's energy between two times without the coverage rule (holes count as 0).
    static func sessionWh(full a: Double, _ b: Double, part x: Double, _ y: Double, onBattery: Bool?, battery bat: [Battery],
                          counter: (Double, Double) -> Double?, counted: ((Double, Double) -> Double)? = nil) -> Double? {
        guard b > a, y > x else { return 0 }
        var total: Double?
        if onBattery == true, b - a >= 1800 { total = measured((a, b), bat) }
        if total == nil { total = counter(a, b) }
        if total == nil { total = measured((a, b), bat) }
        guard let t = total else { return nil }
        if x <= a && y >= b { return t }
        var share = (min(y, b) - max(x, a)) / (b - a)
        if let counted {
            let all = counted(a, b)
            if all > 0 { share = counted(max(x, a), min(y, b)) / all }
        }
        return t * share
    }

    /// Battery energy used during a gap, if the Mac was on battery before and after it.
    static func measured(_ g: (a: Double, b: Double), _ bat: [Battery]) -> Double? {
        guard let before = bat.last(where: { $0.t <= g.a + 60 }), before.t >= g.a - 600,
              let after = bat.first(where: { $0.t >= g.b - 60 }), after.t <= g.b + 600,
              before.onBattery, after.onBattery else { return nil }
        let drop = before.mAh - after.mAh
        guard drop >= 0 else { return nil }
        return drop * (before.mV + after.mV) / 2 / 1e6      // mAh × mV = µWh
    }

    /// This Mac's average sleep power on battery (W): all sleeps measured on battery in the logs together
    /// (single short sleeps are only a few mAh, so they are added up rather than averaged one by one).
    private static func rate(_ dbs: [String]) -> Double? {
        lock.lock(); defer { lock.unlock() }
        if let c = cachedRate, Date().timeIntervalSince(c.at) < 3600 { return c.w }
        var loads = Set<Double>()
        for p in dbs {
            query(p, "select timestamp from PLBatteryAgent_EventBackward_Adapter", []) { loads.insert(sqlite3_column_double($0, 0)) }
        }
        let pts = loads.sorted()
        let bat = battery(dbs, -Double.infinity, Double.infinity)
        var wh = 0.0, h = 0.0
        for (p, q) in zip(pts, pts.dropFirst()) where q - p > PowerLog.maxInterval {
            if let m = measured((p, q), bat) { wh += m; h += (q - p) / 3600 }
        }
        let w = h >= 1 ? wh / h : nil                         // at least an hour of measured sleep
        cachedRate = (Date(), w)
        return w
    }

    private static func hasBattery(_ dbs: [String]) -> Bool {
        var found = false
        for p in dbs where !found {
            query(p, "select 1 from PLBatteryAgent_EventBackward_Battery where AppleRawCurrentCapacity > 0 limit 1", []) { _ in found = true }
        }
        return found
    }

    static func battery(_ dbs: [String], _ lo: Double, _ hi: Double) -> [Battery] {
        var byTime: [Double: Battery] = [:]
        for p in dbs {
            query(p, """
                select timestamp, AppleRawCurrentCapacity, Voltage, ExternalConnected
                from PLBatteryAgent_EventBackward_Battery where timestamp >= ? and timestamp <= ?
                """, [lo, hi]) { st in
                let t = sqlite3_column_double(st, 0), mAh = sqlite3_column_double(st, 1), mV = sqlite3_column_double(st, 2)
                guard mAh > 0, mV > 0 else { return }
                byTime[(t * 10).rounded() / 10] = Battery(t: t, mAh: mAh, mV: mV, onBattery: sqlite3_column_int(st, 3) == 0)
            }
        }
        return byTime.values.sorted { $0.t < $1.t }
    }

    private static func coldBoots(_ dbs: [String], _ lo: Double, _ hi: Double) -> [Double] {
        var t = Set<Double>()
        for p in dbs {
            query(p, "select timestamp from PLSMCAgent_EventNone_ColdBoot where timestamp >= ? and timestamp <= ?", [lo, hi]) {
                t.insert(sqlite3_column_double($0, 0))
            }
        }
        return Array(t)
    }

    private static func query(_ path: String, _ sql: String, _ args: [Double], _ body: (OpaquePointer) -> Void) {
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
}
