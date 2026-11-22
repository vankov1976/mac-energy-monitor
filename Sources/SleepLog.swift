import Foundation
import SQLite3

/// Sleep analysis for a period: every sleep (lid closed or idle → you wake the Mac) with its energy, every
/// wake-up during sleep with its reason, and times the Mac didn't sleep although it should have.
///
/// Sources, all readable without admin rights:
/// - `pmset -g log` (macOS's sleep/wake log, about a week): sleeps with their cause, wake-ups with their reason,
///   which process asked for a scheduled wake-up, display on/off, and every sleep blocker ("assertion").
/// - macOS's power log (copied by PowerLog): the whole-Mac counter, which keeps running in sleep (energy),
///   and when the lid was closed or opened.
/// - `pmset -g custom`: this Mac's sleep settings, for the hints (read only, nothing is changed).

/// One sleep from pmset's log: from a real sleep until you wake the Mac (Unix seconds), and its power source.
struct SleepSpan { let a: Double, b: Double, onBattery: Bool? }

/// Why the Mac woke up, grouped for people.
enum WakeGroup: String, CaseIterable, Identifiable {
    case user = "You (lid, keyboard, trackpad)"
    case network = "Wi-Fi or Bluetooth (network, nearby devices)"
    case scheduled = "Timer set by macOS (Power Nap, maintenance)"
    case power = "Power adapter"
    case other = "Other"
    var id: String { rawValue }

    /// The group for macOS's wake reason text (e.g. "smc.sysState.Wake(0x70070000) wifibt SMC.OutboxNotEmpty").
    /// Reason codes differ between Mac models; anything unknown goes to Other with its original text.
    static func of(_ reason: String) -> WakeGroup {
        let r = reason.lowercased()
        if ["lid", "hid activity", "trackpadkeyboard", "useractivity", "pwrbtn", "power button", "keyboard"]
            .contains(where: r.contains) { return .user }
        if ["wifibt", "wlan", "network", "bluetooth", "bt."].contains(where: r.contains) { return .network }
        if ["rtc", "maintenance"].contains(where: r.contains) { return .scheduled }
        if ["usb-c_plug", "usb-c", "ac attach", "charger", "adapter"].contains(where: r.contains) { return .power }
        return .other
    }

    /// The reason without macOS's internal codes ("wifibt" instead of "smc.sysState.Wake(0x70070000) wifibt …").
    static func label(_ reason: String) -> String {
        let drop = ["smc.sysstate.wake", "smc.outboxnotempty", "nub.", "nub-spmi"]
        let words = reason.replacingOccurrences(of: "/", with: " ").split(separator: " ").map(String.init)
            .filter { w in !drop.contains(where: { w.lowercased().hasPrefix($0) }) }
        return words.isEmpty ? reason : words.joined(separator: " ")
    }
}

struct SleepReport {
    struct Session: Identifiable {
        let id = UUID()
        let start: Date, end: Date
        let cause: String            // "Lid closed", "Idle", …
        let onBattery: Bool?
        let wh: Double?              // whole-Mac energy, including short wake-ups
        let wakes: Int
        var unusual = false          // more than twice this Mac's usual sleep power (same power source)
        var causeTip: String? = nil  // what started it, in more detail (e.g. which app asked to sleep)
        var levels: (from: Double, to: Double)? = nil   // battery charge (%) at the start and end (on battery)
        var hours: Double { end.timeIntervalSince(start) / 3600 }
        var avgW: Double? { wh.flatMap { hours > 0.01 ? $0 / hours : nil } }
        // Sort keys for the tables (no optionals)
        var whSort: Double { wh ?? -1 }
        var avgSort: Double { avgW ?? -1 }
        var power: String { onBattery.map { $0 ? "Battery" : "Charger" } ?? "—" }
    }
    struct Wake: Identifiable {
        let id = UUID()
        let time: Date
        let dark: Bool               // a background wake-up (display stays off) vs. woken by the user
        let group: WakeGroup
        let reason: String
        let requester: String?       // the process that asked for a scheduled wake-up
        let secs: Double             // until the Mac slept again
        let wh: Double?
    }
    struct Group: Identifiable {
        let group: WakeGroup
        var count = 0, secs = 0.0, wh = 0.0
        var reasons: [String: Int] = [:]
        var requesters: [String: Int] = [:]
        var id: String { group.rawValue }
        var name: String { group.rawValue }
    }
    struct NoSleep: Identifiable {
        let id = UUID()
        let start: Date, end: Date
        let cause: String            // "Lid closed" or "Display off"
        let blockers: [(name: String, secs: Double, tech: String)]   // tech: macOS's own names, for the tooltip
        let wh: Double?
        var onBattery: Bool? = nil   // from the battery log: charger connected or not (most of the time)
        var power: String { onBattery.map { $0 ? "Battery" : "Charger" } ?? "—" }
        var hours: Double { end.timeIntervalSince(start) / 3600 }
        var whSort: Double { wh ?? -1 }
    }

    /// Wake-ups grouped by reason, most frequent first (the whole period, or one sleep's wake-ups).
    static func groups(_ wakes: [Wake]) -> [Group] {
        var groups: [WakeGroup: Group] = [:]
        for w in wakes {
            var g = groups[w.group] ?? .init(group: w.group)
            g.count += 1; g.secs += w.secs; g.wh += w.wh ?? 0
            g.reasons[w.reason, default: 0] += 1
            if let q = w.requester { g.requesters[q, default: 0] += 1 }
            groups[w.group] = g
        }
        return groups.values.sorted { $0.count > $1.count }
    }

    var sessions: [Session] = []
    var wakes: [Wake] = []
    var groups: [Group] = []
    var noSleep: [NoSleep] = []
    var hints: [String] = []
    var sleepWh: Double?             // energy of all sleeps in the period
    var sleepH = 0.0
    var avgBatteryW: Double?, avgChargerW: Double?
    var detailsFrom: Date?           // pmset's log starts here; earlier sleeps can't be analysed
    var usualBattery: Double?, usualCharger: Double?   // this Mac's usual sleep power (for the hints)
    var allSessions = 0              // sleeps in the period before the Power / Minimum energy filters

    /// Only the sleeps that match the filters, and everything else for just those: their wake-ups, the sums,
    /// "Didn't sleep" (same filters) and the hints. "All" and 0 Wh = no filter.
    func filtered(power: String, minEnergy: Double) -> SleepReport {
        guard power != "All" || minEnergy > 0 else { return self }
        func keep(_ p: String, _ wh: Double?) -> Bool { (power == "All" || p == power) && (wh ?? 0) >= minEnergy }
        var r = self
        r.sessions = sessions.filter { keep($0.power, $0.wh) }
        r.wakes = wakes.filter { w in r.sessions.contains { w.time >= $0.start && w.time < $0.end } }
        r.noSleep = noSleep.filter { keep($0.power, $0.wh) }
        r.finish()
        r.hints = SleepAnalysis.hints(r, usualBattery: usualBattery, usualCharger: usualCharger)
        return r
    }

    /// Sums and groups from the sessions and wake-ups.
    mutating func finish() {
        sleepH = sessions.reduce(0) { $0 + $1.hours }
        let known = sessions.compactMap(\.wh)
        sleepWh = known.isEmpty ? nil : known.reduce(0, +)
        func avg(_ battery: Bool) -> Double? {
            let s = sessions.filter { $0.onBattery == battery && $0.wh != nil }
            let h = s.reduce(0) { $0 + $1.hours }
            return h > 0.1 ? s.reduce(0) { $0 + ($1.wh ?? 0) } / h : nil
        }
        avgBatteryW = avg(true); avgChargerW = avg(false)
        groups = Self.groups(wakes)
    }
    var wakeCount: Int { wakes.filter(\.dark).count }
}

// MARK: - pmset's sleep/wake log

/// The parsed `pmset -g log`, kept for 5 minutes (reading it takes a few seconds).
final class PMSetLog: @unchecked Sendable {
    static let shared = PMSetLog()

    enum Kind {
        case sleep(cause: String, onBattery: Bool?)
        case darkWake(String), wake(String)
        case displayOff, displayOn
        case wakeRequests([(process: String, request: String, at: Date)])
        case assertion(on: Bool, process: String, type: String, name: String, id: String)
        case boot
    }
    struct Event { let t: Date; let kind: Kind }

    private let lock = NSLock()
    private var cached: (at: Date, events: [Event])?

    /// The full log, for the sleep analysis ("Sleep only"). Kept for 5 minutes after the last use, then released:
    /// it holds ~75,000 entries (mostly sleep blockers), tens of MB.
    func events() -> [Event] {
        lock.lock()
        lastFullUse = Date()
        // New sleeps can only appear after a wake (then it is marked stale) or a manual refresh: no fixed expiry.
        // A stale log is still returned at once and read again in the background (~5 s); `updated` then reloads
        // the views. Only the very first read waits.
        if let c = cached {
            let old = stale
            lock.unlock()
            if old { _ = spansIfRead() }
            return c.events
        }
        defer { lock.unlock() }
        let e = Self.parse(Self.read())
        cached = (Date(), e)
        spans = SleepAnalysis.sleepSpans(e).spans
        boots = Self.bootTimes(e); logFrom = e.first?.t.timeIntervalSince1970
        stale = false
        scheduleRelease()
        return e
    }

    private var lastFullUse = Date.distantPast
    /// While the window is open the full log is kept, so "Sleep only" never waits for a new read.
    private var windowOpen = false
    func setWindowOpen(_ open: Bool) { lock.lock(); windowOpen = open; lock.unlock() }
    private func scheduleRelease() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 330) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if !self.windowOpen, Date().timeIntervalSince(self.lastFullUse) >= 300 { self.cached = nil } else { self.scheduleRelease() }
        }
    }

    /// The sleep periods only (a few dozen), all the history views need. Kept while the app runs.
    private var spans: [SleepSpan]?
    private var boots: [Double] = []     // restarts in pmset's log ("powerd process is started"), Unix seconds

    /// Restarts from pmset's log, once it has been read (warm restarts don't always log a cold boot elsewhere).
    func bootsIfRead() -> [Double] { lock.lock(); defer { lock.unlock() }; return boots }
    private var logFrom: Double?
    /// Where pmset's log starts (Unix seconds), once it has been read: from here on its sleeps are known.
    func fromIfRead() -> Double? { lock.lock(); defer { lock.unlock() }; return logFrom }
    private static func bootTimes(_ e: [Event]) -> [Double] {
        e.compactMap { if case .boot = $0.kind { return $0.t.timeIntervalSince1970 }; return nil }
    }

    /// For the history views, which are calculated often: the log read last, without waiting. If there is none yet,
    /// or the Mac has slept since (new sleeps can only appear then), it is read again in the background and
    /// `updated` is posted when done (the views then reload). Reading costs ~5 s of CPU, so not more often.
    static let updated = Notification.Name("PMSetLogUpdated")
    private var stale = false, reading = false

    func spansIfRead() -> [SleepSpan]? {
        lock.lock()
        let c = spans, need = (spans == nil || stale) && !reading
        if need { reading = true }
        lock.unlock()
        if need {
            DispatchQueue.global(qos: .utility).async {
                // Read and keep only the sleep periods; the full log is dropped right away (unless "Sleep only"
                // is using it).
                let e = Self.parse(Self.read())
                let sp = SleepAnalysis.sleepSpans(e).spans
                self.lock.lock()
                self.spans = sp; self.boots = Self.bootTimes(e); self.logFrom = e.first?.t.timeIntervalSince1970; self.stale = false; self.reading = false
                if self.cached != nil { self.cached = (Date(), e) }      // "Sleep only" in use: keep it fresh
                self.lock.unlock()
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updated, object: nil) }
            }
        }
        return c
    }

    /// The Mac woke up: the next history report reads the log again (in the background).
    func markStale() { lock.lock(); stale = true; lock.unlock() }

    private static func read() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "log"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> [Event] {
        let tp = Date(); defer { if ProcessInfo.processInfo.environment["MEM_LAP"] != nil { print("parse:", Date().timeIntervalSince(tp)) } }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let local = DateFormatter()        // wakeAt= has no time zone: local time
        local.locale = Locale(identifier: "en_US_POSIX"); local.calendar = Calendar(identifier: .gregorian)
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out: [Event] = []
        // Most lines are sleep blockers of types that don't matter here: they are skipped by a cheap byte check
        // on the raw line before any other work.
        let needles = SleepAnalysis.blockingTypes.map { Array(" \($0) ".utf8) }
        let assertions = Array("Assertions".utf8)
        func has(_ hay: [UInt8], _ n: [UInt8], from: Int) -> Bool {
            guard hay.count >= n.count + from else { return false }
            var i = from
            while i <= hay.count - n.count {
                if hay[i] == n[0] {
                    var k = 1
                    while k < n.count && hay[i + k] == n[k] { k += 1 }
                    if k == n.count { return true }
                }
                i += 1
            }
            return false
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let bytes = Array(raw.utf8)
            guard bytes.count > 40, bytes[0] >= 48, bytes[0] <= 57 else { continue }
            if Array(bytes[25..<35]) == assertions, !needles.contains(where: { has(bytes, $0, from: 36) }) { continue }
            let line = String(raw)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let kind = line[line.index(line.startIndex, offsetBy: 25)..<tab].trimmingCharacters(in: .whitespaces)
            guard let t = fastDate(line.utf8.prefix(25)) ?? stamp.date(from: String(line.prefix(25))) else { continue }
            let detail = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
            switch kind {
            case "Sleep":
                // "Entering DarkWake state due to 'Clamshell Sleep'": macOS wanted to sleep (e.g. lid closed) but a
                // sleep blocker only let it go dark, awake with the display off. That is not sleep.
                if detail.hasPrefix("Entering DarkWake state") { out.append(Event(t: t, kind: .displayOff)); continue }
                let cause = detail.range(of: "due to '").flatMap { r in
                    detail[r.upperBound...].split(separator: "'", maxSplits: 1).first.map(String.init) } ?? "Sleep"
                out.append(Event(t: t, kind: .sleep(cause: cause, onBattery: onBattery(detail))))
            case "DarkWake", "Wake":
                let reason = detail.range(of: "due to ").map { r in
                    String(detail[r.upperBound...].components(separatedBy: " Using ").first ?? "")
                        .trimmingCharacters(in: .whitespaces) } ?? ""
                out.append(Event(t: t, kind: kind == "Wake" ? .wake(reason) : .darkWake(reason)))
            case "Notification":
                if detail.hasPrefix("Display is turned off") { out.append(Event(t: t, kind: .displayOff)) }
                if detail.hasPrefix("Display is turned on") { out.append(Event(t: t, kind: .displayOn)) }
            case "Wake Requests":
                var reqs: [(String, String, Date)] = []
                // The request that will actually wake the Mac is marked with "*" ("[*process=…").
                for part in detail.components(separatedBy: "process=").dropFirst() {
                    let proc = String(part.prefix { $0 != " " })
                    let req = part.range(of: "request=").map { String(part[$0.upperBound...].prefix { $0 != " " }) } ?? ""
                    if let w = part.range(of: "wakeAt=") {
                        let s = String(part[w.upperBound...].prefix(19))
                        if let at = local.date(from: s) { reqs.append((proc, req, at)) }
                    }
                }
                out.append(Event(t: t, kind: .wakeRequests(reqs)))
            case "Assertions":
                // PID 680(cloudd) Created SystemIsActive "NSURLSessionTask …" 00:00:00  id:0x0xc0000a781 [System: …]
                guard detail.hasPrefix("PID "), let open = detail.firstIndex(of: "("),
                      let close = detail.firstIndex(of: ")") , open < close else { continue }
                let process = String(detail[detail.index(after: open)..<close])
                let rest = detail[detail.index(after: close)...].split(separator: " ", maxSplits: 2).map(String.init)
                guard rest.count >= 2 else { continue }
                let action = rest[0], type = rest[1]
                let on: Bool
                switch action {
                case "Created", "TurnedOn": on = true
                case "Released", "TurnedOff", "ClientDied": on = false
                default: continue
                }
                let name = detail.range(of: "\"").flatMap { q in
                    detail[q.upperBound...].split(separator: "\"", maxSplits: 1).first.map(String.init) } ?? ""
                let id = detail.range(of: "id:").map { String(detail[$0.upperBound...].prefix { $0 != " " }) } ?? ""
                out.append(Event(t: t, kind: .assertion(on: on, process: process, type: type, name: name, id: id)))
            case "Start":
                out.append(Event(t: t, kind: .boot))
            default:
                continue
            }
        }
        // "Software Sleep pid=…": name the process when the log names that process number anywhere (e.g. in a
        // sleep blocker line "PID 415(loginwindow)"). Only a few such sleeps, so a plain text search is quick.
        // Process numbers are reused, so only a line within a day of the sleep counts (the nearest one).
        for (k, e) in out.enumerated() {
            guard case .sleep(let cause, let battery) = e.kind, cause.hasPrefix("Software Sleep pid="),
                  let pid = Int(cause.dropFirst("Software Sleep pid=".count).prefix { $0.isNumber }) else { continue }
            var best: (gap: Double, name: Substring)?
            var from = text.startIndex
            while let r = text.range(of: "PID \(pid)(", range: from..<text.endIndex) {
                from = r.upperBound
                let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
                guard let t = fastDate(text[lineStart...].utf8.prefix(25)) else { continue }
                let gap = abs(t.timeIntervalSince(e.t))
                if gap <= 86400, gap < (best?.gap ?? .infinity) {
                    best = (gap, text[r.upperBound...].prefix { $0 != ")" && $0 != "\n" })
                }
            }
            if let b = best { out[k] = Event(t: e.t, kind: .sleep(cause: cause + " by " + b.name, onBattery: battery)) }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// "2026-11-17 00:29:08 +0100" → Date, without a DateFormatter (much faster for ~80,000 lines).
    static func fastDate(_ u: Substring.UTF8View.SubSequence) -> Date? {
        let b = Array(u)
        guard b.count == 25, b[4] == 45, b[7] == 45, b[10] == 32, b[13] == 58, b[16] == 58, b[19] == 32 else { return nil }
        func n(_ i: Int, _ len: Int) -> Int? {
            var v = 0
            for k in i..<(i + len) { let c = Int(b[k]) - 48; guard c >= 0, c <= 9 else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = n(0, 4), let mo = n(5, 2), let d = n(8, 2), let h = n(11, 2), let mi = n(14, 2), let s = n(17, 2),
              let oh = n(21, 2), let om = n(23, 2), b[20] == 43 || b[20] == 45 else { return nil }
        // Days since 1970-01-01 (Howard Hinnant's days_from_civil).
        let yy = mo <= 2 ? y - 1 : y, era = (yy >= 0 ? yy : yy - 399) / 400, yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1, doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let offset = (oh * 3600 + om * 60) * (b[20] == 45 ? -1 : 1)
        return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + s - offset))
    }

    private static func onBattery(_ s: String) -> Bool? {
        let l = s.lowercased()
        if l.contains("using batt") { return true }
        if l.contains("using ac") { return false }
        return nil
    }
}

/// This Mac's sleep settings (`pmset -g custom`), per power source. Read only.
enum SleepSettings {
    static func read() -> (battery: [String: String], charger: [String: String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return ([:], [:]) }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var battery: [String: String] = [:], charger: [String: String] = [:], current = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Battery Power") { current = 1; continue }
            if line.hasPrefix("AC Power") { current = 2; continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let key = parts.dropLast().joined(separator: " "), value = String(parts.last!)
            if current == 1 { battery[key] = value } else if current == 2 { charger[key] = value }
        }
        return (battery, charger)
    }
}

// MARK: - analysis

enum SleepAnalysis {
    /// The sleeps in pmset's log as time spans (Unix seconds), by the same rules as the sleep analysis: from a real
    /// sleep (lid closed, idle, Apple menu) until you wake the Mac fully, or until a restart (then up to the last
    /// entry before it). Short background wake-ups in between are part of the sleep. Also the log's first entry.
    static func sleepSpans(_ events: [PMSetLog.Event]) -> (spans: [SleepSpan], from: Double?) {
        var out: [SleepSpan] = []
        var open: Double?, battery: Bool?
        var last = events.first?.t.timeIntervalSince1970 ?? 0
        let brief = briefWakes(events)
        for (i, e) in events.enumerated() {
            let t = e.t.timeIntervalSince1970
            switch e.kind {
            case .sleep(let cause, let bat):
                if open == nil, !continuing.contains(where: cause.contains) { open = t; battery = bat }
            case .wake:
                if let o = open, !brief.contains(i) { out.append(.init(a: o, b: t, onBattery: battery)); open = nil }
            case .boot:
                if let o = open, last > o { out.append(.init(a: o, b: last, onBattery: battery)) }
                open = nil
            default: break
            }
            if case .assertion = e.kind {} else { last = t }
        }
        if let o = open, last > o { out.append(.init(a: o, b: last, onBattery: battery)) }
        return (out, events.first?.t.timeIntervalSince1970)
    }

    /// Brief full wakes inside a sleep: macOS wakes fully for a moment (e.g. "due to Notification" when the
    /// charger is plugged in with the lid closed) and goes back to sleep by itself within minutes ("… Back to
    /// Sleep"). That isn't you waking the Mac, so the sleep goes on (otherwise the rest of the night was lost).
    static func briefWakes(_ events: [PMSetLog.Event]) -> Set<Int> {
        var out = Set<Int>()
        for (i, e) in events.enumerated() {
            guard case .wake = e.kind else { continue }
            let n = events[(i + 1)...].first { switch $0.kind { case .sleep, .wake, .boot: return true; default: return false } }
            if let n, case .sleep(let cause, _) = n.kind, cause.contains("Back to Sleep"), n.t.timeIntervalSince(e.t) <= 900 {
                out.insert(i)
            }
        }
        return out
    }

    /// Sleep blockers: assertion types that keep the system awake (display-only ones don't count).
    static let blockingTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "InternalPreventSleep",
        "SystemIsActive", "BackgroundTask", "NetworkClientActive", "UserIsActive", "ApplePushServiceTask",
        "InteractivePushServiceTask", "MaintenanceWake",
    ]
    /// Causes of a sleep that only continue an existing one (after a short wake-up in the background).
    static let continuing: [String] = ["Maintenance Sleep", "Back to Sleep"]

    static func report(_ log: PowerLog, from: Date, to: Date) -> SleepReport {
        var r = SleepReport()
        let t0 = Date()
        let events = PMSetLog.shared.events()
        if ProcessInfo.processInfo.environment["MEM_LAP"] != nil { print("pmset:", Date().timeIntervalSince(t0)) }
        r.detailsFrom = events.first?.t
        guard !events.isEmpty else { return r }
        let t1 = Date()
        let counter = Counter(log, from: from.addingTimeInterval(-3 * 86400), to: to.addingTimeInterval(3600))
        if ProcessInfo.processInfo.environment["MEM_LAP"] != nil { print("counter:", Date().timeIntervalSince(t1)) }

        // 1. Sleeps: from a real sleep (lid closed, idle, Apple menu) until you wake the Mac. Short wake-ups
        //    in the background in between belong to the sleep. A restart ends it (the Mac was switched off).
        var all: [SleepReport.Session] = []
        var wakes: [SleepReport.Wake] = []
        var open: (start: Date, cause: String, battery: Bool?, wakes: Int)?
        var causeTips: [Date: String] = [:]     // by sleep start
        var lastEvent = events[0].t
        var requests: [(process: String, request: String, at: Date)] = []
        // Brief full wakes that are part of a sleep (see briefWakes).
        let briefWakes = briefWakes(events)
        for (i, e) in events.enumerated() {
            switch e.kind {
            case .sleep(let cause, let battery):
                if open == nil, !continuing.contains(where: cause.contains) {
                    // A fixed set of labels, so the column has a known width (the longest: "An app or a command").
                    // "Software Sleep": software asked to sleep. From loginwindow = the Apple menu's Sleep; other
                    // processes are named in the tooltip when macOS's log names them (see PMSetLog.parse).
                    let soft = cause.hasPrefix("Software Sleep")
                    let by = soft ? cause.range(of: " by ").map { String(cause[$0.upperBound...]) } : nil
                    let label = cause == "Clamshell Sleep" ? "Lid closed" : cause == "Idle Sleep" ? "Idle"
                        : soft ? (by == "loginwindow" ? "Apple menu" : "An app or a command")
                        : cause.hasPrefix("Low Power") ? "Low battery"
                        : cause.hasPrefix("Power Button") ? "Power button"
                        : cause.hasPrefix("Thermal") ? "Too hot" : "Other"
                    open = (e.t, label, battery, 0)
                    if soft {
                        let tech = cause.components(separatedBy: " by ").first ?? cause
                        causeTips[e.t] = by == "loginwindow"
                            ? TipFormat.make("Sleep was chosen in the Apple menu.", tech: ["macOS's log: \(tech) (loginwindow)"])
                            : TipFormat.make(by.map { "\(FriendlyNames.process($0)) asked the Mac to sleep." }
                                             ?? "An app or a command (e.g. pmset sleepnow) asked the Mac to sleep. macOS's log only has its process number, and the process no longer runs, so it can't be named.",
                                             tech: ["macOS's log: \(tech)" + (by.map { " (\($0))" } ?? "")])
                    }
                }
            case .wakeRequests(let reqs):
                requests = reqs
            case .darkWake(let reason), .wake(let reason):
                if briefWakes.contains(i) { continue }        // part of the sleep (see above)
                let dark: Bool
                if case .darkWake = e.kind { dark = true } else { dark = false }
                // A background wake-up ends when the Mac sleeps again or you wake it fully (e.g. opening the lid
                // first logs a short background wake-up, then the full wake): your use afterwards isn't part of it.
                let next = events.indices.dropFirst(i + 1).first { j in
                    switch events[j].kind { case .sleep, .boot: return true; case .wake: return !briefWakes.contains(j); default: return false }
                }.map { events[$0].t }
                let secs = min(next.map { $0.timeIntervalSince(e.t) } ?? 0, dark ? 3600 : 0)
                let req = requests.first { abs($0.at.timeIntervalSince(e.t)) <= 90 }
                // A background wake-up in the same moment as the full wake is the start of you waking the Mac.
                let partOfFullWake = dark && events.indices.dropFirst(i + 1).prefix(8).contains { j in
                    if case .wake = events[j].kind, !briefWakes.contains(j) { return events[j].t.timeIntervalSince(e.t) <= 2 }; return false
                }
                if partOfFullWake { continue }
                if open != nil {          // only wake-ups during a recognized sleep (they add up per sleep)
                    wakes.append(.init(time: e.t, dark: dark, group: WakeGroup.of(reason), reason: WakeGroup.label(reason),
                                       requester: req.map { "\($0.process) (\($0.request))" }, secs: secs,
                                       wh: dark ? counter.wh(e.t, e.t.addingTimeInterval(secs)) : nil))
                }
                if dark { open?.wakes += 1 }
                if !dark, let o = open {
                    all.append(.init(start: o.start, end: e.t, cause: o.cause, onBattery: o.battery,
                                     wh: counter.wh(o.start, e.t), wakes: o.wakes))
                    open = nil
                }
            case .boot:
                if let o = open, lastEvent > o.start {
                    all.append(.init(start: o.start, end: lastEvent, cause: o.cause, onBattery: o.battery,
                                     wh: counter.wh(o.start, lastEvent), wakes: o.wakes))
                }
                open = nil
            default:
                break
            }
            if case .assertion = e.kind {} else { lastEvent = e.t }
        }
        if var o = open {   // still asleep at the end of the log (or the log ends): up to its last entry
            // The log ends in a background wake-up that is still going on (e.g. right now): the sleep ends where it
            // started, so it isn't one of this sleep's wake-ups yet. It is once macOS logs the next sleep.
            if let w = wakes.last, w.dark, w.time == lastEvent, o.wakes > 0 { wakes.removeLast(); o.wakes -= 1 }
            all.append(.init(start: o.start, end: lastEvent, cause: o.cause, onBattery: o.battery,
                             wh: counter.wh(o.start, lastEvent), wakes: o.wakes))
        }

        let batAll = SleepEnergy.battery((try? log.databases()) ?? [], (all.first?.start.timeIntervalSince1970 ?? 0) - 900,
                                         (all.last?.end.timeIntervalSince1970 ?? 0) + 900)
        func energy(_ s: SleepReport.Session, _ x: Date, _ y: Date, _ bat: [SleepEnergy.Battery]) -> Double? {
            SleepEnergy.sessionWh(full: s.start.timeIntervalSince1970, s.end.timeIntervalSince1970,
                                  part: x.timeIntervalSince1970, y.timeIntervalSince1970, onBattery: s.onBattery, battery: bat,
                                  counter: { counter.wh(Date(timeIntervalSince1970: $0), Date(timeIntervalSince1970: $1)) })
        }
        for i in all.indices {
            let s = all[i]
            all[i] = .init(start: s.start, end: s.end, cause: s.cause, onBattery: s.onBattery,
                           wh: energy(s, s.start, s.end, batAll), wakes: s.wakes)
        }
        // Usual sleep power per power source (median of sleeps of at least 30 minutes in the whole log).
        func median(_ v: [Double]) -> Double? {
            guard v.count >= 3 else { return nil }
            let s = v.sorted(); return s[s.count / 2]
        }
        let usualBattery = median(all.filter { $0.onBattery == true && $0.hours >= 0.5 }.compactMap(\.avgW))
        let usualCharger = median(all.filter { $0.onBattery == false && $0.hours >= 0.5 }.compactMap(\.avgW))
        for i in all.indices {
            guard let w = all[i].avgW, all[i].hours >= 0.25 else { continue }
            if let u = all[i].onBattery == true ? usualBattery : all[i].onBattery == false ? usualCharger : nil,
               w > 2 * u, w > 0.05 { all[i].unusual = true }
        }

        // Only the part inside the period (energy for that part). Where the counter didn't keep counting
        // (deep standby on some days), a sleep on battery is measured from the battery's charge before and after.
        let dbs = (try? log.databases()) ?? []
        let bat = SleepEnergy.battery(dbs, from.timeIntervalSince1970 - 86400, to.timeIntervalSince1970 + 3600)
        for s in all where s.end > from && s.start < to {
            let a = max(s.start, from), b = min(s.end, to)
            let inside = wakes.filter { $0.dark && $0.time >= a && $0.time < b }.count
            let wh = energy(s, a, b, bat)
            r.sessions.append(.init(start: a, end: b, cause: s.cause, onBattery: s.onBattery,
                                    wh: wh, wakes: inside, unusual: s.unusual, causeTip: causeTips[s.start]))
        }
        r.wakes = wakes.filter { $0.time >= from && $0.time < to && $0.dark }
        // Sums, and 2. wake-ups by reason.
        r.finish()
        r.allSessions = r.sessions.count
        r.usualBattery = usualBattery; r.usualCharger = usualCharger

        // 3. Didn't sleep: the lid closed, or the display off for a long time, while the Mac stayed awake.
        //    Its power source (for the Power filter): what the battery log says for most of that time.
        r.noSleep = noSleep(log, events: events, counter: counter, from: from, to: to).map { n in
            var n = n
            let a = n.start.timeIntervalSince1970, b = n.end.timeIntervalSince1970
            let inside = bat.filter { $0.t >= a && $0.t <= b }
            if inside.isEmpty { n.onBattery = bat.last { $0.t < a }?.onBattery }
            else { n.onBattery = inside.filter(\.onBattery).count * 2 > inside.count }
            return n
        }

        r.hints = hints(r, usualBattery: usualBattery, usualCharger: usualCharger)
        return r
    }

    private static func noSleep(_ log: PowerLog, events: [PMSetLog.Event], counter: Counter,
                                from: Date, to: Date) -> [SleepReport.NoSleep] {
        let sleeps = events.compactMap { e -> Date? in if case .sleep = e.kind { return e.t }; return nil }
        let boots = events.compactMap { e -> Date? in if case .boot = e.kind { return e.t }; return nil }
        func next(_ list: [Date], after t: Date) -> Date? { list.first { $0 > t } }
        let lid = lidEvents(log, from: from.addingTimeInterval(-86400), to: to)

        // Sleep blockers as time spans (switched on → off, by their id).
        var started: [String: (Date, String, Int)] = [:]
        var spans: [(a: Date, b: Date, name: String, strength: Int)] = []
        /// How firmly a blocker keeps the Mac awake: 0 = prevents sleep outright (e.g. caffeinate -s),
        /// 1 = prevents idle sleep, 2 = only signals activity for a while (network, background task).
        func strength(_ type: String) -> Int {
            type == "PreventSystemSleep" ? 0
                : ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "InternalPreventSleep"].contains(type) ? 1 : 2
        }
        for e in events {
            guard case .assertion(let on, let process, let type, let name, let id) = e.kind,
                  blockingTypes.contains(type) else { continue }
            let label = name.isEmpty || name.count > 50 ? "\(process) (\(type))" : "\(process): \(name)"
            if on { started[id + type] = (e.t, label, strength(type)) } else if let s = started.removeValue(forKey: id + type) {
                spans.append((s.0, e.t, s.1, s.2))
            }
        }
        for (_, s) in started { spans.append((s.0, to, s.1, s.2)) }
        /// Apps and services that held a sleep blocker during [a, b], with how long (the time counted once even
        /// if they held several at once). macOS's own power management (powerd) is summarised as one line.
        func blockers(_ a: Date, _ b: Date) -> [(name: String, secs: Double, tech: String)] {
            var byName: [String: [(Date, Date)]] = [:]
            var firmest: [String: Int] = [:]
            var tech: [String: Set<String>] = [:]     // macOS's own names under each plain name
            for s in spans where s.b > a && s.a < b {
                // macOS's own power management and display server: part of how macOS works, not a cause by itself.
                let own = s.name.hasPrefix("powerd") || s.name.contains("com.apple.powermanagement")
                    || s.name.hasPrefix("WindowServer")
                let key = own ? "macOS power management" : FriendlyNames.blocker(s.name)
                tech[key, default: []].insert(s.name)
                byName[key, default: []].append((max(s.a, a), min(s.b, b)))
                firmest[key] = min(firmest[key] ?? 9, s.strength)
            }
            var out: [(String, Double)] = []
            for (name, list) in byName {
                var total = 0.0, cur: (Date, Date)?
                for (x, y) in list.sorted(by: { $0.0 < $1.0 }) {
                    if let c = cur, x <= c.1 { cur = (c.0, max(c.1, y)) } else {
                        if let c = cur { total += c.1.timeIntervalSince(c.0) }
                        cur = (x, y)
                    }
                }
                if let c = cur { total += c.1.timeIntervalSince(c.0) }
                if total >= 30 { out.append((name, total)) }
            }
            // Apps and services first, macOS's own power management last; then the longest, and with (almost)
            // equal time the firmest blocker first (caffeinate before a short-lived network task).
            func rank(_ x: (String, Double)) -> (Int, Int, Int) {
                (x.0 == "macOS power management" ? 1 : 0, -Int((x.1 / 60).rounded()), firmest[x.0] ?? 9)
            }
            return out.sorted { rank($0) < rank($1) }.prefix(5).map { ($0.0, $0.1, (tech[$0.0] ?? []).sorted().joined(separator: "\n")) }
        }

        var out: [SleepReport.NoSleep] = []
        let logStart = events.first?.t ?? from
        /// Only real cases: inside pmset's log (its sleeps are known), and above sleep-level power
        /// (at under 0.5 W the Mac was asleep; only the log's sleep entry is missing).
        func real(_ a: Date, _ b: Date, _ wh: Double?) -> Bool {
            a >= logStart && (wh.map { $0 / (b.timeIntervalSince(a) / 3600) >= 0.5 } ?? true)
        }
        // Lid closed but no sleep within 10 minutes.
        for (i, l) in lid.enumerated() where l.closed {
            let opened = lid[(i + 1)...].first { !$0.closed }?.t ?? to
            let stop = [next(sleeps, after: l.t), next(boots, after: l.t), opened, to].compactMap { $0 }.min()!
            // On the charger macOS stays awake a few minutes after the lid is closed (by design): 10 minutes.
            if stop.timeIntervalSince(l.t) > 600, stop > from, l.t < to, min(stop, to).timeIntervalSince(max(l.t, from)) > 60 {
                let a = max(l.t, from), b = min(stop, to), wh = counter.wh(a, b)
                if real(l.t, b, wh) { out.append(.init(start: a, end: b, cause: "Lid closed", blockers: blockers(a, b), wh: wh)) }
            }
        }
        // Display off (lid open) and the Mac awake for more than 30 minutes.
        let displays = events.filter { if case .displayOff = $0.kind { return true }; if case .displayOn = $0.kind { return true }; return false }
        for (i, e) in displays.enumerated() {
            guard case .displayOff = e.kind else { continue }
            let on = displays[(i + 1)...].first { if case .displayOn = $0.kind { return true }; return false }?.t
            let stop = [next(sleeps, after: e.t), on, next(boots, after: e.t), to].compactMap { $0 }.min()!
            let lidClosed = lid.last { $0.t <= e.t.addingTimeInterval(60) }?.closed ?? false
            guard !lidClosed, stop.timeIntervalSince(e.t) > 1800, stop > from, e.t < to else { continue }
            let a = max(e.t, from), b = min(stop, to)
            guard !out.contains(where: { $0.end > a && $0.start < b }) else { continue }
            let wh = counter.wh(a, b)
            if real(e.t, b, wh) { out.append(.init(start: a, end: b, cause: "Display off", blockers: blockers(a, b), wh: wh)) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Hints in plain words. A name with a technical background is written «plain name|technical detail»: the view
    /// shows the plain name in blue with the detail as its tooltip.
    /// Tooltip for a sleep blocker: what it is (if known), then macOS's own names (a few at most).
    static func blockerTip(_ name: String, _ tech: String) -> String {
        let names = tech.split(separator: "\n").map(String.init)
        let process = names.first.map { n in String(n.prefix { $0 != ":" && $0 != "(" }).trimmingCharacters(in: .whitespaces) } ?? name
        let about = Explain.process(name) ?? Explain.process(process)
        let shown = names.prefix(4) + (names.count > 4 ? ["… and \(names.count - 4) more"] : [])
        let techPart = names.isEmpty ? "" : TipFormat.make("Sleep blocker in macOS's log:", bullets: Array(shown))
        return [about, techPart].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func hints(_ r: SleepReport, usualBattery: Double?, usualCharger: Double?) -> [String] {
        var h: [String] = []
        let settings = SleepSettings.read()
        let total = max(r.wakes.count, 1)
        func share(_ g: WakeGroup) -> Double { Double(r.groups.first { $0.group == g }?.count ?? 0) / Double(total) }
        // Only settings for the power source(s) the Mac actually slept on in this period.
        let sleptOnBattery = r.sessions.contains { $0.onBattery == true }, sleptOnCharger = r.sessions.contains { $0.onBattery == false }
        func on(_ key: String) -> String? {
            let b = sleptOnBattery && settings.battery[key] == "1", c = sleptOnCharger && settings.charger[key] == "1"
            return b && c ? "both on battery and with the charger" : b ? "on battery" : c ? "with the charger" : nil
        }
        func dur(_ secs: Double) -> String { secs >= 3600 ? String(format: "%.1f h", locale: .current, secs / 3600) : "\(Int(secs / 60)) min" }
        // On the charger, sleep can cost far more than on battery: say so with this Mac's numbers and settings.
        if let b = r.avgBatteryW, let c = r.avgChargerW, c > 3 * b {
            let diff = ["powernap": "Power Nap", "womp": "Wake for network access", "SleepServices": "Sleep services"]
                .filter { settings.charger[$0.key] == "1" && settings.battery[$0.key] != "1" }.sorted { $0.value < $1.value }
                .map { "«\($0.value)|\(Explain.setting($0.key, "with the charger, 0 on battery"))»" }
            let why = diff.isEmpty ? "" : " These are on only with the charger: \(diff.joined(separator: ", "))."
            h.append(String(format: "On the charger, sleep uses %.0f× more than on battery (%.2f W vs. %.2f W): the Mac does much more in the background.", locale: .current, c / b, c, b) + why)
        }
        /// Worth a hint: at least 0.5 Wh or a tenth of all sleep energy.
        func matters(_ g: SleepReport.Group) -> Bool { g.wh >= 0.5 || g.wh >= 0.1 * (r.sleepWh ?? .infinity) }
        if r.wakes.count >= 10, share(.network) >= 0.3, let g = r.groups.first(where: { $0.group == .network }), matters(g) {
            // The settings of the power source these wake-ups happened on.
            let wakesOnBattery = r.wakes.filter { w in w.group == .network && r.sessions.contains { $0.onBattery == true && w.time >= $0.start && w.time < $0.end } }.count
            let src = wakesOnBattery * 2 >= g.count ? settings.battery : settings.charger
            let srcName = wakesOnBattery * 2 >= g.count ? "on battery" : "with the charger"
            var why: [String] = []
            if src["womp"] == "1" { why.append("«Wake for network access|\(Explain.setting("womp", srcName))» is on \(srcName)") }
            if src["tcpkeepalive"] == "1" { why.append("the Mac «keeps its network connections alive|\(Explain.setting("tcpkeepalive", srcName))» while asleep \(srcName)") }
            let w = why.isEmpty ? "" : " " + why.joined(separator: "; ").prefix(1).uppercased() + why.joined(separator: "; ").dropFirst() + "."
            let wifi = Explain.reason("wifibt")
            let tip = TipFormat.make(wifi.0, bullets: wifi.1, tech: ["macOS wake reason: wifibt"])
            let text = "Most wake-ups (\(Int(share(.network) * 100))%) come from «Wi-Fi or Bluetooth|\(tip)». \(g.count) wake-ups, awake \(dur(g.secs)) in total, \(String(format: "%.1f", locale: .current, g.wh)) Wh.\(w)"
            h.append(text)
        }
        if r.wakes.count >= 10, share(.scheduled) >= 0.1, let g = r.groups.first(where: { $0.group == .scheduled }), matters(g) {
            let p = on("powernap").map { " «Power Nap|\(Explain.setting("powernap", $0))» is on \($0): the Mac wakes regularly for mail, iCloud, Time Machine backups and other background tasks." } ?? ""
            let timerTip = TipFormat.make("macOS set the Mac's built-in clock to wake it for planned background work:",
                                          bullets: ["Power Nap checks", "backups (e.g. Time Machine), updates and sync", "Sleep Services: iCloud, Find My, mail"],
                                          tech: ["macOS wake reasons: rtc Maintenance, rtc SleepService (rtc = the built-in clock)"])
            let text = "\(g.count) wake-ups were on a «timer set by macOS|\(timerTip)», awake \(dur(g.secs)) in total, \(String(format: "%.1f", locale: .current, g.wh)) Wh.\(p)"
            h.append(text)
        }
        let unusual = r.sessions.filter(\.unusual)
        if !unusual.isEmpty {
            h.append("\(unusual.count) sleep\(unusual.count == 1 ? "" : "s") used more than twice this Mac's usual sleep power (marked with a blue «⚠|» below). Look at the wake-ups and \"Didn't sleep\" for that time.")
        }
        for n in r.noSleep.sorted(by: { ($0.wh ?? 0) > ($1.wh ?? 0) }).prefix(3) {
            let span = Clock.dayTime(n.start) + "–" + Clock.time(n.end)
            let when = span + ", with the " + (n.cause == "Lid closed" ? "lid closed" : "display off")
            let dur = n.hours >= 1 ? String(format: "%.1f h", locale: .current, n.hours) : "\(Int(n.hours * 60)) min"
            let who = n.blockers.first.map { b in
                let t = SleepAnalysis.blockerTip(b.name, b.tech)
                let tip = t.isEmpty ? "" : "|" + t
                return b.name == "macOS power management" ? " «macOS itself\(tip)» kept it awake (e.g. Power Nap or wake-ups on the charger)."
                    : " Kept awake mostly by: «\(b.name)\(tip)»." } ?? ""
            h.append("\(when), the Mac stayed awake for \(dur)\(n.wh.map { String(format: " (%.1f Wh)", locale: .current, $0) } ?? "").\(who)")
        }
        return h
    }

    /// Lid closed / opened, from macOS's power log.
    private static func lidEvents(_ log: PowerLog, from: Date, to: Date) -> [(t: Date, closed: Bool)] {
        var out: [(Date, Bool)] = []
        for path in (try? log.databases(overlapping: from.timeIntervalSince1970 - 86400, to.timeIntervalSince1970 + 86400)) ?? [] {
            Counter.query(path, "select timestamp, closed from PLPeripheralAgent_EventForward_ClamshellState where timestamp > ? and timestamp < ?",
                          [from.timeIntervalSince1970, to.timeIntervalSince1970]) { st in
                out.append((Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), sqlite3_column_int(st, 1) != 0))
            }
        }
        // macOS repeats the current state (e.g. in every log file): keep only the changes.
        var changes: [(t: Date, closed: Bool)] = []
        for e in out.sorted(by: { $0.0 < $1.0 }) where changes.last?.closed != e.1 { changes.append((e.0, e.1)) }
        return changes
    }

    /// macOS's whole-Mac counter: a running total of the Mac's power that keeps counting while it sleeps
    /// (about one sample per second). Energy for any interval, awake or asleep. Not across a restart.
    struct Counter {
        private var spans: [(a: Double, b: Double, w: Double)] = []
        private var cumWh: [Double] = [], cumSecs: [Double] = []   // running totals up to the end of each span

        init(_ log: PowerLog, from: Date, to: Date) {
            var pts: [Double: (acc: Double, n: Double)] = [:]
            for path in (try? log.databases(overlapping: from.timeIntervalSince1970 - 86400, to.timeIntervalSince1970 + 86400)) ?? [] {
                Self.query(path, "select timestamp, AccumulatedSystemLoad, SystemLoadAccumulatorCount from PLBatteryAgent_EventBackward_Adapter where timestamp > ? and timestamp < ?",
                           [from.timeIntervalSince1970, to.timeIntervalSince1970]) { st in
                    pts[(sqlite3_column_double(st, 0) * 10).rounded() / 10] = (sqlite3_column_double(st, 1), sqlite3_column_double(st, 2))
                }
            }
            let sorted = pts.sorted { $0.key < $1.key }
            for (p, q) in zip(sorted, sorted.dropFirst()) {
                let dt = q.key - p.key, dn = q.value.n - p.value.n, da = q.value.acc - p.value.acc
                guard dt > 0, dn > 0, da >= 0, dt <= PowerLog.maxInterval || abs(dn - dt) <= 0.2 * dt else { continue }
                spans.append((p.key, q.key, da / dn / 1000))
            }
            var wh = 0.0, secs = 0.0
            for sp in spans { wh += sp.w * (sp.b - sp.a) / 3600; secs += sp.b - sp.a; cumWh.append(wh); cumSecs.append(secs) }
        }

        /// Energy and counted seconds from the first span up to time t (binary search, spans are in order).
        private func upTo(_ t: Double) -> (wh: Double, secs: Double) {
            var lo = 0, hi = spans.count
            while lo < hi { let m = (lo + hi) / 2; if spans[m].b <= t { lo = m + 1 } else { hi = m } }
            let wh0 = lo > 0 ? cumWh[lo - 1] : 0, s0 = lo > 0 ? cumSecs[lo - 1] : 0
            guard lo < spans.count, t > spans[lo].a else { return (wh0, s0) }
            let o = t - spans[lo].a
            return (wh0 + spans[lo].w * o / 3600, s0 + o)
        }

        /// Wh between two times; nil if the counter doesn't cover at least 90% of it.
        func wh(_ x: Date, _ y: Date) -> Double? {
            let a = x.timeIntervalSince1970, b = y.timeIntervalSince1970
            guard b > a else { return 0 }
            let x0 = upTo(a), y0 = upTo(b)
            return y0.secs - x0.secs >= 0.9 * (b - a) ? y0.wh - x0.wh : nil
        }

        static func query(_ path: String, _ sql: String, _ args: [Double], _ body: (OpaquePointer) -> Void) {
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
    }
}
