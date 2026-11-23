import SwiftUI

/// Loads the sleep analysis for the period the history view shows (on the log queue; pmset's log is read
/// once and kept for 5 minutes).
@MainActor
final class SleepModel: ObservableObject {
    /// What the view shows: the analysis with the Power / Minimum energy filters applied (cards, tables, hints).
    /// Published, so every change of the data or the filters redraws the view.
    @Published private(set) var shown: SleepReport?
    @Published var loading = false
    private var full: SleepReport?                  // the analysis before the filters
    private var power = "All", minEnergy = 0.0
    private var generation = 0
    private var loaded: (from: Date, to: Date)?
    private var running: (from: Date, to: Date)?    // being calculated
    private var waiting: (from: Date, to: Date)?    // asked for while that runs (the newest only)

    /// The analysis for this period, or nil while it is loaded: never another period's numbers. When a refresh
    /// only moves the period a little (its end follows the clock), the last analysis stays on screen while the
    /// new one is calculated in the background, instead of a spinner every time.
    func report(from: Date, to: Date) -> SleepReport? {
        guard let l = loaded, Self.close(l, (from, to)) else { return nil }
        return shown
    }
    private static func close(_ a: (from: Date, to: Date), _ b: (from: Date, to: Date)) -> Bool {
        abs(a.from.timeIntervalSince(b.from)) < 900 && abs(a.to.timeIntervalSince(b.to)) < 900
    }

    /// The filters changed (or are set the first time): applied at once to the loaded analysis.
    func setFilters(power: String, minEnergy: Double) {
        guard power != self.power || minEnergy != self.minEnergy else { return }
        self.power = power; self.minEnergy = minEnergy
        shown = full?.filtered(power: power, minEnergy: minEnergy)
    }

    func load(from: Date, to: Date, force: Bool = false) {
        if !force, let l = loaded, abs(l.from.timeIntervalSince(from)) < 1, abs(l.to.timeIntervalSince(to)) < 1 { return }
        // The same period (moved a little) is already being calculated: calculate the newest once that is done,
        // instead of starting over (with repeated reloads it would never finish).
        if let r = running, Self.close(r, (from, to)) { waiting = (from, to); return }
        start(from: from, to: to)
    }

    private func start(from: Date, to: Date) {
        generation += 1
        let gen = generation
        if !(loaded.map { Self.close($0, (from, to)) } ?? false) {
            loading = true
            shown = nil; full = nil; loaded = nil    // another period: the old period's numbers go at once
        }
        running = (from, to); waiting = nil
        let log = sharedLog
        logQueue.async {
            var r = SleepAnalysis.report(log, from: from, to: to)
            // Battery charge at the start and end of each sleep on battery (for the Power column's tooltip).
            let lv = BatteryHistory.levels(log, r.sessions.filter { $0.onBattery == true }.map { ($0.start, $0.end) })
            for i in r.sessions.indices where r.sessions[i].onBattery == true {
                r.sessions[i].levels = lv[r.sessions[i].start.timeIntervalSince1970]
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }    // another period was chosen meanwhile
                self.running = nil
                self.loading = false
                self.full = r
                self.shown = r.filtered(power: self.power, minEnergy: self.minEnergy)
                self.loaded = (from, to)
                if let w = self.waiting { self.waiting = nil; self.start(from: w.from, to: w.to) }
            }
        }
    }

    /// Reads pmset's log in the background when the window opens and keeps it while the window is open, so
    /// "Sleep only" is quick (reading it takes ~5 s).
    static func prefetch() {
        PMSetLog.shared.setWindowOpen(true)
        DispatchQueue.global(qos: .utility).async { _ = PMSetLog.shared.events() }
    }
    static func windowClosed() { PMSetLog.shared.setWindowOpen(false) }
}

/// "Sleep only": the sleeps, the wake-ups grouped by reason, and the times the Mac didn't sleep — laid out like
/// the energy view: hints in place of the hardware breakdown (at most its height), two filters in the same place,
/// and one sortable table at a time (tabs) that fills the rest of the window.
struct SleepSectionsView: View {
    let report: SleepReport
    let periodStart: Date

    enum Tab: Hashable { case sleeps, wakes, noSleep }

    /// The two filters, owned by the window (ContentView): the same values filter the report it passes in.
    @Binding var power: String
    @Binding var minEnergy: Double
    /// Height of the hardware breakdown in the energy view, measured there; the hints are never taller.
    @AppStorage("breakdownHeight") private var breakdownHeight = 150.0
    @State private var tab = Self.firstTab         // Sleeps at every start and every new period
    #if DIAGNOSTICS
    private static var firstTab: Tab {
        switch ProcessInfo.processInfo.environment["MEM_SHOT_TAB"] { case "wakes": .wakes; case "nosleep": .noSleep; default: .sleeps }
    }
    #else
    private static let firstTab = Tab.sleeps
    #endif
    /// The sleep whose wake-ups the "Wake-ups by reason" table shows (clicked in the Sleeps table); nil = the
    /// whole period. Only that table follows it; back to the whole period when the Sleeps tab is shown again.
    @State private var focus: (start: Date, end: Date)?
    @State private var hintsHeight: CGFloat = 0
    @State private var hintBottoms: [Int: CGFloat] = [:]   // bottom of each hint inside the hint box
    @State private var sessionSort = [KeyPathComparator(\SleepReport.Session.whSort, order: .reverse)]
    @State private var groupSort = [KeyPathComparator(\SleepReport.Group.count, order: .reverse)]
    @State private var noSleepSort = [KeyPathComparator(\SleepReport.NoSleep.whSort, order: .reverse)]

    /// Wide enough for the longest label, "An app or a command", plus the sort arrow in the header.
    static let causeWidth: CGFloat = 165

    /// First columns of the other two tables: as wide as their longest possible value (a fixed set), plus the
    /// header's sort arrow and cell padding.
    static let reasonWidth = textWidth(WakeGroup.allCases.map(\.rawValue) + ["Reason"]) + 30
    static let whileWidth = textWidth(["Lid closed", "Display off", "While"]) + 30
    /// From/To: as wide as the longest date in the user's own format (e.g. "Dec 28, 2026 at 10:58 PM" is much
    /// longer than "28. Dez. 2026, 22:58"), so dates are never cut off. Measured on every redraw (12 short texts),
    /// so a format changed in System Settings applies without restarting the app.
    static var dateWidth: CGFloat {
        let cal = Calendar.current
        let dates = (1...12).compactMap { cal.date(from: DateComponents(year: 2026, month: $0, day: 28, hour: 22, minute: 58)) }
        return textWidth(dates.map(Clock.dateTime)) + 16
    }
    private static func textWidth(_ texts: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil(texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
    }

    private var sessions: [SleepReport.Session] {
        report.sessions.sorted(using: sessionSort)   // the report is already filtered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !report.hints.isEmpty { hints }
            if let d = report.detailsFrom, d > periodStart.addingTimeInterval(3600) {
                Label("Sleep details reach back to \(Clock.dateTime(d)): macOS keeps its sleep log for about a week.",
                      systemImage: "calendar.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            filters
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("Sleeps (\(sessions.count))").tag(Tab.sleeps)
                    Text("Wake-ups by reason (\(focusedWakes.count))").tag(Tab.wakes)
                    if focus == nil {   // one sleep shown: "Didn't sleep" never overlaps a sleep, so hidden
                        Text("Didn't sleep (\(report.noSleep.count))").tag(Tab.noSleep)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .id(focus == nil)   // a new control when a tab is hidden or shown: macOS doesn't resize the segments again
                if tab == .wakes, let f = focus {   // which sleep "Wake-ups by reason" shows
                    Text("Sleep \(Clock.dateTime(f.start)) – \(Clock.dateTime(f.end))")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Group {
                switch tab {
                case .sleeps: sleepsTable
                case .wakes: wakeTable
                case .noSleep: noSleepTable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: periodStart) { tab = .sleeps; focus = nil }
        .onChange(of: tab) { if tab == .sleeps { focus = nil } }
        .onChange(of: power) { focus = nil }
        .onChange(of: minEnergy) { focus = nil }
    }

    // MARK: hints and filters

    private var hints: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(report.hints.enumerated()), id: \.offset) { i, h in
                    Label { TipText(markup: h) } icon: { Image(systemName: "lightbulb") }
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .labelStyle(TintedIcon(color: .yellow))
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("hints")).maxY } action: { hintBottoms[i] = $0 }
                }
            }
            .padding(10).padding(.trailing, 16)   // room for the always-shown scroll bar (SwiftUI doesn't know its width)
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(.named("hints"))
            .background(AlwaysShownScroller())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hintsHeight = $0 }
        }
        // When not all hints fit, the bottom padding stays empty: no sliver of the next hint shows in it.
        .mask(alignment: .top) {
            Rectangle().frame(height: hintsBoxHeight < hintsHeight ? max(0, hintsBoxHeight - 10) : nil)
        }
        .frame(height: hintsBoxHeight)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// All hints if they fit in the breakdown's height; otherwise the box ends after the last hint that fits
    /// completely (the hints wrap with the window width), so no line is cut in half — the rest scrolls.
    private var hintsBoxHeight: CGFloat {
        let cap = CGFloat(breakdownHeight)
        if hintsHeight <= cap { return hintsHeight }
        let fitting = hintBottoms.values.filter { $0 + 10 <= cap }.max()
        return fitting.map { $0 + 10 } ?? cap
    }

    /// Same place as the energy view's two filters; they apply to the whole view (cards, all tables, hints).
    private var filters: some View {
        HStack(spacing: 16) {
            Picker("Power", selection: $power) {
                Text("All").tag("All")
                Text("Battery").tag("Battery")
                Text("Charger").tag("Charger")
            }.frame(width: 180)
            Picker("Minimum energy", selection: $minEnergy) {
                Text("Show all").tag(0.0)
                Text("≥ 0.1 Wh").tag(0.1)
                Text("≥ 1 Wh").tag(1.0)
                Text("≥ 10 Wh").tag(10.0)
            }.frame(width: 230)
            Spacer()
            if tab == .sleeps {
                Text("\(sessions.count) of \(report.allSessions) sleeps").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: sleeps

    @ViewBuilder private var sleepsTable: some View {
        if report.sessions.isEmpty {
            empty(report.allSessions > 0 ? "No sleep matches the Power and Minimum energy filters." : "No sleep in this period.")
        } else {
            Table(sessions, sortOrder: $sessionSort) {
                TableColumn("Power", value: \.power) { s in
                    // Blue like every other value with a tooltip.
                    tinted(s, Text(s.power).foregroundColor(s.onBattery == true ? Color.tip : nil))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tip(s.onBattery == true ? BT.sleepTip(s) : "")
                }
                    .width(min: 80, ideal: 80)        // "Charger" and the header with its sort arrow; the table scrolls sideways if needed
                TableColumn("Sleep started by", value: \.cause) { s in
                    if let t = s.causeTip { Text(s.cause).foregroundStyle(Color.tip).tip(t) } else { Text(s.cause) }
                }
                    .width(Self.causeWidth)
                TableColumn("Wake-ups", value: \.wakes) { s in wakesLink(s).frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(84)
                TableColumn("Energy", value: \.whSort) { s in
                    Text(s.wh.map { fmt($0, 2) + " Wh" } ?? "unknown").foregroundStyle(Color.tip)
                        .tip(energyTip(s)).frame(maxWidth: .infinity, alignment: .trailing)
                }.width(85)
                TableColumn("Avg. power", value: \.avgSort) { s in
                    HStack(spacing: 3) {
                        if s.unusual {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.tip)
                                .tip("More than twice this Mac's usual sleep power on \(s.onBattery == true ? "battery" : "the charger")")
                        }
                        if s.avgW == nil { Text("unknown").foregroundStyle(Color.tip).tip(energyTip(s)) }
                        else { tinted(s, Text(s.avgW.map { fmt($0, 2) + " W" } ?? "")) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(95)
                TableColumn("Duration", value: \.hours) { s in
                    tinted(s, Text(ContentView.duration(s.hours))).frame(maxWidth: .infinity, alignment: .trailing)
                }.width(95)
                TableColumn("From", value: \.start) { s in tinted(s, Text(Clock.dateTime(s.start))) }
                    .width(Self.dateWidth)
                TableColumn("To", value: \.end) { s in tinted(s, Text(Clock.dateTime(s.end))) }
                    .width(Self.dateWidth)
            }
            .monospacedDigit()
        }
    }

    /// Tooltip of a sleep's energy: the whole sleep = its wake-ups (the seconds it was awake) + the time asleep in
    /// between. That's why the wake-ups' energy (shown when you click the number) is less than the sleep's.
    private func energyTip(_ s: SleepReport.Session) -> String {
        let w = report.wakes.filter { $0.time >= s.start && $0.time < s.end }
        let wWh = w.compactMap(\.wh).reduce(0, +), awake = ContentView.duration(w.reduce(0) { $0 + $1.secs } / 3600)
        let n = w.count == 1 ? "1 wake-up" : "\(w.count) wake-ups"
        guard let wh = s.wh else {
            return "Energy of the whole sleep unknown: macOS's logs don't cover enough of it (its energy counter missed "
                + "too much of the time, and the battery's charge drop can't be measured)."
                + (w.isEmpty ? "" : "\nIts \(n): \(fmt(wWh, 2)) Wh (\(awake) awake)")
        }
        if w.isEmpty { return "\(fmt(wh, 2)) Wh for the whole sleep, asleep all the time (no wake-ups)" }
        return "\(fmt(wh, 2)) Wh for the whole sleep:\n\(fmt(wWh, 2)) Wh during its \(n) (\(awake) awake)\n"
            + "\(fmt(max(0, wh - wWh), 2)) Wh asleep in between"
    }

    /// The number of wake-ups as a link: shows this sleep's wake-ups in "Wake-ups by reason".
    @ViewBuilder private func wakesLink(_ s: SleepReport.Session) -> some View {
        if s.wakes == 0 {
            Text("0")
        } else {
            Button { focus = (s.start, s.end); tab = .wakes } label: {
                Text("\(s.wakes)").underline().foregroundStyle(Color.tip)
            }
            .buttonStyle(.plain)
            .onContinuousHover { phase in   // pointing hand, as over a link (set on every move: the table resets it)
                if case .active = phase { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .tip("Show details")
        }
    }

    /// The wake-ups the "Wake-ups by reason" table shows: one sleep's, or the whole period's.
    private var focusedWakes: [SleepReport.Wake] {
        guard let f = focus else { return report.wakes }
        return report.wakes.filter { $0.time >= f.start && $0.time < f.end }
    }
    private var focusedGroups: [SleepReport.Group] { focus == nil ? report.groups : SleepReport.groups(focusedWakes) }

    /// Normal text in every row; a sleep with unusually high power is marked only by the orange ⚠ next to its power.
    private func tinted(_ s: SleepReport.Session, _ t: Text) -> some View { t }

    // MARK: wake reasons

    @ViewBuilder private var wakeTable: some View {
        if focusedGroups.isEmpty {
            empty("No wake-ups during sleep in this period.")
        } else {
            Table(focusedGroups.sorted(using: groupSort), sortOrder: $groupSort) {
                TableColumn("Reason", value: \.name) { g in Text(g.name) }
                    .width(min: Self.reasonWidth, ideal: Self.reasonWidth)   // never cut off; a narrow window scrolls sideways
                TableColumn("Wake-ups", value: \.count) { g in Text("\(g.count)").frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(84)
                TableColumn("Awake", value: \.secs) { g in Text(ContentView.duration(g.secs / 3600)).frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(85)
                TableColumn("Energy", value: \.wh) { g in Text(fmt(g.wh, 2) + " Wh").frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(85)
                TableColumn("Details") { g in
                    bullets(lines: groupLines, g.reasons.sorted { $0.value > $1.value }.prefix(3).map {
                                Bullet(name: FriendlyNames.reason($0.key), after: " (\($0.value)×)",
                                       tip: Self.reasonTip($0.key)) }
                            + g.requesters.sorted { $0.value > $1.value }.prefix(3).map {
                                Bullet(before: "Planned: ", name: FriendlyNames.requester($0.key), after: " (\($0.value)×)",
                                       tip: Self.requestTip($0.key)) })
                }
                .width(440)
            }
            .monospacedDigit()
            .lined()
        }
    }

    // MARK: didn't sleep

    @ViewBuilder private var noSleepTable: some View {
        if report.noSleep.isEmpty {
            empty("No times found where the Mac stayed awake with the lid closed (more than 10 minutes) or with the display off (more than 30 minutes).")
        } else {
            Table(report.noSleep.sorted(using: noSleepSort), sortOrder: $noSleepSort) {
                TableColumn("Power", value: \.power) { n in Text(n.power) }
                    .width(min: 80, ideal: 80)
                TableColumn("While", value: \.cause) { n in Text(n.cause) }
                    .width(min: Self.whileWidth, ideal: Self.whileWidth)
                TableColumn("Energy", value: \.whSort) { n in Text(n.wh.map { fmt($0, 2) + " Wh" } ?? "—").frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(85)
                TableColumn("Duration", value: \.hours) { n in Text(ContentView.duration(n.hours)).frame(maxWidth: .infinity, alignment: .trailing) }
                    .width(90)
                TableColumn("From", value: \.start) { n in Text(Clock.dateTime(n.start)) }.width(Self.dateWidth)
                TableColumn("To", value: \.end) { n in Text(Clock.dateTime(n.end)) }.width(Self.dateWidth)
                TableColumn("Kept awake by") { n in
                    bullets(lines: noSleepLines, n.blockers.isEmpty ? [Bullet(name: "Not logged")] : n.blockers.map {
                        Bullet(name: $0.name, after: " · \(ContentView.duration($0.secs / 3600))",
                               tip: Self.blockerTip($0.name, $0.tech)) })
                }
                .width(360)
            }
            .monospacedDigit()
            .lined()
        }
    }

    // MARK: helpers

    private static func reasonTip(_ key: String) -> String {
        let e = Explain.reason(key)
        return TipFormat.make(e.0, bullets: e.1, tech: ["macOS wake reason: \(key)"])
    }
    private static func requestTip(_ key: String) -> String {
        let e = Explain.requester(key)
        return TipFormat.make(e.0, bullets: e.1, tech: ["macOS wake request: \(key)"])
    }
    private static func blockerTip(_ name: String, _ tech: String) -> String? {
        let t = SleepAnalysis.blockerTip(name, tech)
        return t.isEmpty ? nil : t
    }

    /// Bullet lines in the tallest row; every row gets that height, so all rows are the same.
    private var groupLines: Int { focusedGroups.map { min($0.reasons.count, 3) + min($0.requesters.count, 3) }.max() ?? 1 }
    private var noSleepLines: Int { report.noSleep.map { max($0.blockers.count, 1) }.max() ?? 1 }

    /// One bullet per entry, one line each; the tooltip has the full text and macOS's technical name.
    /// `lines` sets the row height.
    private func bullets(lines: Int, _ items: [Bullet]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("• ").foregroundStyle(item.name == "macOS power management" ? .secondary : .primary)
                    if !item.before.isEmpty { Text(item.before).lineLimit(1) }
                    if let tip = item.tip {
                        Text(item.name).foregroundStyle(Color.tip).lineLimit(1).truncationMode(.middle)
                            .tip(tip)
                    } else {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                    }
                    Text(item.after).lineLimit(1).layoutPriority(1)
                        .foregroundStyle(item.name == "macOS power management" ? .secondary : .primary)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: CGFloat(max(lines, 1)) * 16 + 6, maxHeight: CGFloat(max(lines, 1)) * 16 + 6, alignment: .leading)
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
    }
}

/// One bullet in a table cell: the plain name (blue, with macOS's technical name as tooltip) and the text around it.
private struct Bullet: Hashable {
    var before = ""
    let name: String
    var after = ""
    var tip: String? = nil
}

private extension View {
    /// Tall rows with several lines: no alternating row colours, a grid instead, so each row is easy to follow.
    func lined() -> some View {
        self.tableStyle(.bordered(alternatesRowBackgrounds: false))
    }
}

/// Makes the enclosing scroll view use the classic scroll bar: always shown while there is more to scroll to
/// (macOS's overlay scroll bars appear only while scrolling), hidden when everything fits.
private struct AlwaysShownScroller: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let sv = self?.enclosingScrollView else { return }
                sv.scrollerStyle = .legacy
                sv.autohidesScrollers = true
                sv.hasVerticalScroller = true
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
