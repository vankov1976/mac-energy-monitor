import Foundation

/// Every text and tooltip of the three "Sleep only" tables, in one place: the view shows exactly these, and the test
/// build's `--sleepaudit` checks exactly these (so what is checked is what you see).
enum SleepTexts {
    struct Cell: Hashable { var text: String; var tip: String? = nil; var before = ""; var after = "" }

    static func wh(_ v: Double) -> String { v > 0 && v < 0.005 ? "< " + fmt(0.01, 2) : fmt(v, 2) }
    static func wakesIn(_ s: SleepReport.Session, _ wakes: [SleepReport.Wake]) -> [SleepReport.Wake] {
        wakes.filter { $0.time >= s.start && $0.time < s.end }
    }

    // MARK: Sleeps

    static func power(_ s: SleepReport.Session) -> Cell {
        if s.onBattery == false, let l = s.levels {     // started on battery, plugged in while asleep
            return Cell(text: s.power, tip: "Plugged in during this sleep: the battery charged from \(BT.pct(l.from)) to \(BT.pct(l.to)). "
                + "It counts as a sleep on the charger.")
        }
        if s.onBattery == nil { return Cell(text: s.power, tip: "macOS's sleep log doesn't say whether the Mac was on battery or on the charger.") }
        return Cell(text: s.power, tip: s.onBattery == true ? BT.sleepTip(s) : nil)
    }
    static let summaryNote = "Estimated from this Mac's saved summary of that day: macOS has deleted that day's detailed power log, "
        + "so only the day's total sleep energy is known. It is shared out by the time asleep (History does the same)."
    static func note(_ s: SleepReport.Session) -> String? { s.fromSummary ? summaryNote : s.estimated ? estimatedNote : nil }
    static let estimatedNote = "Estimated: macOS's energy counter has only one reading for a longer stretch around this sleep "
        + "(including time awake), so its energy is shared out by time."
    static func cause(_ s: SleepReport.Session) -> Cell { Cell(text: s.cause, tip: s.causeTip) }
    static func wakeCount(_ s: SleepReport.Session) -> Cell { Cell(text: "\(s.wakes)", tip: s.wakes > 0 ? "Show details" : nil) }

    /// The sleep's energy: the whole sleep, its wake-ups included (they are part of it; no energy of their own).
    static func energy(_ s: SleepReport.Session, _ wakes: [SleepReport.Wake]) -> Cell {
        let w = wakesIn(s, wakes), awake = ContentView.duration(w.reduce(0) { $0 + $1.secs } / 3600)
        let incl = w.isEmpty ? "asleep all the time (no wake-ups)"
            : "including its \(w.count == 1 ? "1 wake-up" : "\(w.count) wake-ups") (\(awake) awake)"
        guard let total = s.wh else {
            return Cell(text: "unknown", tip: "Energy of this sleep unknown: macOS's logs don't cover enough of it (its energy counter missed "
                + "too much of the time, and the battery's charge drop can't be measured).")
        }
        return Cell(text: (note(s) != nil ? "≈ " : "") + wh(total) + " Wh",
                    tip: "\(wh(total)) Wh for the whole sleep, \(incl)" + (note(s).map { "\n\n" + $0 } ?? ""))
    }

    /// Average power; `unusual`: the tooltip of the ⚠ in front of it (nil = no ⚠).
    static func avg(_ s: SleepReport.Session, _ wakes: [SleepReport.Wake]) -> (cell: Cell, unusual: String?) {
        let u = s.unusual ? "More than twice this Mac's usual sleep power on \(s.onBattery == true ? "battery" : "the charger")" : nil
        if s.wh == nil { return (Cell(text: "unknown", tip: energy(s, wakes).tip), u) }
        guard let a = s.avgW else {
            return (Cell(text: "too short", tip: "This sleep lasted only \(Int(s.end.timeIntervalSince(s.start).rounded())) seconds: too short for a meaningful average power."), u)
        }
        return (Cell(text: (note(s) != nil ? "≈ " : "") + fmt(a, 2) + " W", tip: note(s)), u)
    }
    static func duration(_ s: SleepReport.Session) -> String { ContentView.duration(s.hours) }

    // MARK: Wake-ups by reason

    static func reasonTip(_ key: String) -> String {
        let e = Explain.reason(key)
        return TipFormat.make(e.0, bullets: e.1, tech: ["macOS wake reason: \(key)"])
    }
    static func requestTip(_ key: String) -> String {
        let e = Explain.requester(key)
        return TipFormat.make(e.0, bullets: e.1, tech: ["macOS wake request: \(key)"])
    }
    static func groupCells(_ g: SleepReport.Group) -> [Cell] {
        [Cell(text: g.name), Cell(text: "\(g.count)"), Cell(text: ContentView.duration(g.secs / 3600))]
    }
    /// The Details column: every reason (most frequent first), then every planned request.
    static func groupBullets(_ g: SleepReport.Group) -> [Cell] {
        g.reasons.sorted { $0.value > $1.value }.map {
            Cell(text: FriendlyNames.reason($0.key), tip: reasonTip($0.key), after: " (\($0.value)×)") }
        + g.requesters.sorted { $0.value > $1.value }.map {
            Cell(text: FriendlyNames.requester($0.key), tip: requestTip($0.key), before: "Planned: ", after: " (\($0.value)×)") }
    }

    // MARK: Didn't sleep

    static func noSleepCells(_ n: SleepReport.NoSleep) -> [Cell] {
        [Cell(text: n.power, tip: n.onBattery == nil ? "macOS's battery log has no entry for this time: battery or charger unknown." : nil),
         Cell(text: n.cause),
         n.wh.map { Cell(text: fmt($0, 2) + " Wh") }
            ?? Cell(text: "unknown", tip: "Energy unknown: macOS's energy counter doesn't cover enough of this time."),
         Cell(text: ContentView.duration(n.hours)), Cell(text: Clock.dateTime(n.start)), Cell(text: Clock.dateTime(n.end))]
    }
    static func blockerBullets(_ n: SleepReport.NoSleep) -> [Cell] {
        n.blockers.isEmpty ? [Cell(text: "Not logged")] : n.blockers.map {
            let t = SleepAnalysis.blockerTip($0.name, $0.tech)
            return Cell(text: $0.name, tip: t.isEmpty ? nil : t, after: " · \(ContentView.duration($0.secs / 3600))")
        }
    }
}
