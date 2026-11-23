import Foundation

/// Text layer for the battery view: every user-visible text of the battery feature lives here, as whole
/// sentences with placeholders (String(localized:)), so a translation only adds a string catalog.
/// (The rest of the app moves into this layer later; new features start here.)
enum BT {
    static func pct(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) + " %" }
    static func watts(_ w: Double) -> String { w.formatted(.number.precision(.fractionLength(w < 10 ? 2 : 1))) + " W" }
    static func dur(_ s: Double) -> String {
        let m = Int((s / 60).rounded()); return String(format: "%d:%02d", m / 60, m % 60)
    }
    static func time(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? Clock.time(d) : Clock.dayTime(d)
    }

    // Button
    static func left(_ s: Double) -> String { String(localized: "\(dur(s)) left") }
    static func untilFull(_ s: Double) -> String { String(localized: "\(dur(s)) until full") }
    static let fullyCharged = String(localized: "Fully charged")
    static func pausedAt(_ level: Double) -> String { String(localized: "Charging paused at \(pct(level))") }
    static let calculating = String(localized: "Calculating…")
    static let menuFull = String(localized: "Full", comment: "menu bar, after the battery icon: fully charged")
    static let menuPaused = String(localized: "Paused", comment: "menu bar, after the battery icon: charging paused")
    static let showTip = String(localized: "Show battery details")
    static let inMenuBar = String(localized: "In menu bar")
    static let inMenuBarTip = String(localized: "Show the battery (charge and time left) in the menu bar, after the watts")
    static let hideTip = String(localized: "Hide battery details")

    // State card
    static func onBatteryFor(_ s: Double, since: Date, at: Double) -> String {
        String(localized: "On battery for \(dur(s)) · since \(time(since)) at \(pct(at))")
    }
    static func chargingFor(_ s: Double, since: Date, at: Double) -> String {
        String(localized: "Charging for \(dur(s)) · since \(time(since)) at \(pct(at))")
    }
    static func onChargerSince(_ since: Date) -> String { String(localized: "On charger since \(time(since))") }
    static let onBattery = String(localized: "On battery")
    static let onCharger = String(localized: "On charger")
    static let awakeAsleep = String(localized: "Awake / asleep")
    static let drawingNow = String(localized: "Drawing now")
    static let avgAwake = String(localized: "Average while awake")
    static let chargingWith = String(localized: "Charging with")
    static let charger = String(localized: "Charger")
    static let macUses = String(localized: "Mac uses now")

    // Health card
    static let health = String(localized: "Battery health")
    static let capacity = String(localized: "Capacity now / when new")
    static let cycles = String(localized: "Cycles")
    static let temperature = String(localized: "Temperature")
    static let voltage = String(localized: "Voltage")
    static func condition(_ macOS: String) -> String {
        switch macOS {
        case "Good": return String(localized: "Normal")
        case "Fair", "Check Battery": return String(localized: "Service recommended")
        case "Poor", "Service Battery", "Replace Soon", "Replace Now": return String(localized: "Service recommended")
        default: return macOS
        }
    }

    // Chart
    static let perCharge = String(localized: "Per charge")
    static let chargeUsed = String(localized: "Charge used")
    static let awake = String(localized: "Awake")
    static let asleep = String(localized: "Asleep")
    static let running = String(localized: "running")
    static let noCharges = String(localized: "No charges on battery in macOS's battery log yet.")
    static func usedLabel(_ c: BatteryCharge) -> String { String(localized: "\(pct(c.used)) used") }
    /// Non-breaking spaces inside a part, so a narrow column wraps only between the parts.
    private static func keep(_ t: String) -> String { t.replacingOccurrences(of: " ", with: "\u{00A0}") }
    static func awakeLabel(_ s: Double, displayOn on: Double) -> String {
        String(localized: "\(dur(s)) awake (\(dur(on)) display on)")
    }
    /// "14 Nov 03:05–13:10", or with both dates when the charge spans midnight.
    static func range(_ c: BatteryCharge) -> String {
        let start = Clock.dayTime(c.start)
        if c.running { return start + " – " + running }
        let end = Calendar.current.isDate(c.start, inSameDayAs: c.end) ? Clock.time(c.end)
            : Clock.dayTime(c.end)
        return start + "–" + end
    }
    static func displayLabel(_ s: Double) -> String { String(localized: "\(dur(s)) display on") }
    static func asleepLabel(_ s: Double) -> String { String(localized: "\(dur(s)) asleep") }
    static func offLabel(_ s: Double) -> String { String(localized: "\(dur(s)) switched off") }
    static func onBatteryLabel(_ s: Double) -> String { String(localized: "\(dur(s)) on battery") }
    static let displayOn = String(localized: "Display on")
    static let awakeDisplayOff = String(localized: "Awake, display off")
    static let awakeRow = String(localized: "Awake")
    static let asleepRow = String(localized: "Asleep")
    static let offRow = String(localized: "Switched off")
    static func chargeTip(_ c: BatteryCharge) -> String {
        let sameDay = Calendar.current.isDate(c.start, inSameDayAs: c.end)
        let start = Clock.dayTime(c.start)
        let end = c.running ? running : sameDay ? Clock.time(c.end)
            : Clock.dayTime(c.end)
        var s = String(localized: "\(start) – \(end)")
        s += "\n" + String(localized: "\(pct(c.used)) used (\(pct(c.startLevel)) → \(pct(c.endLevel))) in \(dur(c.end.timeIntervalSince(c.start)))")
        if let a = c.awake, let z = c.asleep {
            s += "\n" + String(localized: "Awake \(dur(a)), display on \(dur(c.displayOn ?? 0))")
            s += "\n" + String(localized: "Asleep \(dur(z))")
            if c.off >= 60 { s += "\n" + String(localized: "Switched off \(dur(c.off))") }
        } else { s += "\n" + String(localized: "Awake and asleep unknown: macOS's sleep log doesn't reach back this far.") }
        if let wh = c.wh { s += "\n" + String(localized: "\(wh.formatted(.number.precision(.fractionLength(1)))) Wh used") }
        if let w = c.avgAwakeW { s += "\n" + String(localized: "Average while awake \(watts(w))") }
        return s
    }

    /// Tooltip of "Battery" in the Sleeps table: period, charge used, time asleep, energy and average power.
    static func sleepTip(_ s: SleepReport.Session) -> String {
        let sameDay = Calendar.current.isDate(s.start, inSameDayAs: s.end)
        let start = Clock.dayTime(s.start)
        let end = sameDay ? Clock.time(s.end) : Clock.dayTime(s.end)
        var t = start + " – " + end
        if s.levels == nil { t += "\n" + String(localized: "Charge before and after: not in macOS's battery log") }
        if let l = s.levels {
            t += "\n" + (l.to > l.from + 1
                ? String(localized: "Charged while asleep: \(pct(l.from)) → \(pct(l.to))")     // plugged in during the sleep
                : String(localized: "\(pct(max(0, l.from - l.to))) used (\(pct(l.from)) → \(pct(l.to)))"))
        }
        t += "\n" + String(localized: "\(ContentView.duration(s.hours)) asleep")      // as in the table
        if let wh = s.wh, let w = s.avgW {
            t += "\n" + String(localized: "\(SleepTexts.wh(wh)) Wh used with \(watts(w)) avg. power")
        }
        return t
    }

    // Tooltips that explain the values
    static let tipHealth = String(localized: "How much charge the battery holds compared with when it was new, as macOS rates it. macOS recommends service when it falls well below 80 %.")
    static let tipCycles = String(localized: "One cycle = 100 % of the battery used in total, also spread over several charges. Mac batteries are designed for about 1000 cycles.")
    static let tipCapacity = String(localized: "The charge a full battery holds today, and what it held when new (milliampere-hours).")
    static let tipTemperature = String(localized: "Battery temperature from macOS's battery log (updated about once a minute).")
    static let tipAwake = String(localized: "Time the Mac was awake since unplugging, with the display on or off. In brackets: the part with the display on.")
    static let tipAsleep = String(localized: "Time the Mac was asleep since unplugging (lid closed or idle), including short wake-ups in the background.")
    static let tipOff = String(localized: "Time the Mac was shut down since unplugging. It doesn't count as awake or asleep.")
    static let tipDrawing = String(localized: "Power the Mac takes from the battery now, and the current (power divided by the battery voltage). Updated every second.")
    static let tipChargingWith = String(localized: "Power going into the battery now: what the charger delivers minus what the Mac itself uses. Updated every second.")
    static let tipCharger = String(localized: "The connected power adapter and the most power it can deliver.")
    static let tipVoltage = String(localized: "The battery's voltage now. It falls slowly as the battery empties.")
    static let tipState = String(localized: "Since when the Mac is on battery or on the charger, and the charge at that moment. Big: the charge now and the time left or until full: the energy left (or missing) in the battery divided by the average power of the last 5 minutes, updated every 10 seconds.")
    static let tipAvgAwake = String(localized: "Energy taken from the battery while awake, divided by the time awake.")
    static let tipMacUses = String(localized: "What the Mac itself uses now; the rest of the charger's power goes into the battery.")
    static let tipChart = String(localized: "Each group is one charge: from unplugging to plugging in again. Unplugs shorter than 10 minutes or using less than 3 % are left out.")
}

/// "How these numbers are measured" for the battery view.
extension Explanations {
    static var battery: [InfoSection] { [
        InfoSection(title: String(localized: "Live values"), points: [
            String(localized: "Charge, cycles, capacity and voltage come from the battery's own record in macOS. Power and current (Drawing now, Charging with, Mac uses now) come from the Mac's power controller and update every second; the current is the power divided by the battery voltage."),
            String(localized: "Time left = energy still in the battery (its remaining mAh × voltage) ÷ the average power of the last 5 minutes. Time until full adds up each remaining 1 % at the power this Mac's battery typically charges with at that level, learned from its own battery log (above about 80 % it charges much more slowly), but never faster than it charges right now. Recomputed every 10 seconds; for the first 30 seconds after plugging in or out it shows \"Calculating…\"."),
            String(localized: "Battery health is macOS's own rating (as in System Settings › Battery); the temperature comes from macOS's battery log (about once a minute)."),
        ]),
        InfoSection(title: String(localized: "Per charge"), points: [
            String(localized: "One charge runs from unplugging to plugging in again, newest on the left. Unplugs shorter than 10 minutes that used less than 3 % are left out. All charges as far back as macOS's battery log reaches (about 10 days)."),
            String(localized: "Awake and asleep come from macOS's sleep log; for charges before that log starts only the total time on battery is known. Display on comes from macOS's hourly screen-time log (shared out by minutes at the start and end of a charge)."),
            String(localized: "Energy used is the drop of the battery's charge (mAh) times its voltage; the average while awake leaves out the energy used while asleep and appears after 30 minutes awake."),
        ]),
    ] }
}
