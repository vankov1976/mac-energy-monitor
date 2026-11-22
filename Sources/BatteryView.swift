import SwiftUI
import Charts

/// Live battery values for the button and the view. Read every second while the window shows (a cheap read).
@MainActor final class BatteryModel: ObservableObject {
    static let shared = BatteryModel()
    @Published private(set) var now: BatteryNow? = BatteryNow.read()
    @Published private(set) var health: BatteryHealth?
    @Published private(set) var history: BatteryHistory?
    private(set) var historyVersion = 0
    let estimator: BatteryTimeEstimator = OwnTimeEstimate()     // MacOSTimeEstimate() for macOS's own
    private var timer: Timer?
    /// When this app saw the charger plugged in or out, and the charge then (for when the log hasn't caught up).
    private(set) var changedAt: (t: Date, level: Double)?
    private var users = 0
    /// The battery view is showing: only then are macOS's logs read (the button needs only the live values).
    var viewOpen = false { didSet { if viewOpen { loadHistory() } } }
    var hasBattery: Bool { now != nil }

    /// The menu bar panel's battery button: the main window should open on the battery view.
    nonisolated static let showViewNote = Notification.Name("BatteryShowView")
    static var viewRequested = false
    static func requestView() {
        viewRequested = true                 // read when the window's content appears (it may not exist yet)
        NotificationCenter.default.post(name: showViewNote, object: nil)
    }

    func start() {
        users += 1
        guard timer == nil else { return }
        refresh()
        seedEstimate()
        let iv = 1.0
        timer = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer?.tolerance = iv * 0.1
    }
    func stop() {
        users = max(0, users - 1)
        if users == 0 { timer?.invalidate(); timer = nil }
    }

    /// The menu bar shows the battery too: it reads the live values in the menu bar's own rhythm (no extra timer).
    func startMenuBar() { seedEstimate() }
    func menuBarTick() { if timer == nil { refresh() } }
    private func refresh() {
        let n = BatteryNow.read()
        if let n, let o = now, n.onCharger != o.onCharger || n.charging != o.charging {
            if n.onCharger != o.onCharger { changedAt = (Date(), o.level) }
            estimator.reset()
        }
        if let n { estimator.update(n) }
        // Plugged in or out, or the log hasn't caught up with the live state yet: read the log again (at most once a minute).
        if viewOpen && (n?.onCharger != now?.onCharger || (history != nil && history?.lastOnCharger != n?.onCharger
                                              && Date().timeIntervalSince(loadedAt) > 60)
            || Date().timeIntervalSince(loadedAt) > 300) { loadHistory() }      // and every 5 minutes while the view is open
        now = n
    }

    /// Fill the estimate's 5-minute average from macOS's battery log, so it's ready as soon as the window opens.
    private func seedEstimate() {
        guard let n = now else { return }
        let log = sharedLog, onCharger = n.onCharger
        logQueue.async {
            let s = BatteryHistory.recentPower(log, onCharger: onCharger)
            let curve = BatteryHistory.chargeCurve(log)
            DispatchQueue.main.async {
                self.estimator.setChargeCurve(curve)
                if self.now?.onCharger == onCharger { self.estimator.seed(s) }
            }
        }
    }

    /// Charges, health and temperature (slower reads, in the background).
    private var loadedAt = Date.distantPast
    private(set) var historyAt = Date()
    private var healthAt = Date.distantPast
    func loadHistory() {
        guard hasBattery else { return }
        loadedAt = Date()
        let log = sharedLog
        logQueue.async {
            let spans = PMSetLog.shared.spansIfRead() ?? []
            let h = BatteryHistory.read(log, sleep: spans, sleepFrom: PMSetLog.shared.fromIfRead())
            DispatchQueue.main.async { self.historyVersion += 1; self.history = h; self.historyAt = Date() }
        }
        // macOS's health rating changes slowly, and system_profiler is slow: at most once an hour.
        guard health == nil || Date().timeIntervalSince(healthAt) > 3600 else { return }
        healthAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let h = BatteryHealth.read()
            DispatchQueue.main.async { self.health = h }
        }
    }

    /// Right after plugging in or out, macOS's estimate still belongs to the previous state: "Calculating…".
    private var justChanged: Bool { changedAt.map { Date().timeIntervalSince($0.t) < 90 } ?? false }
    /// The current state, live: since when (and at which charge) the Mac is on battery or on the charger, and for
    /// the running charge on battery the time awake (display on), asleep and switched off up to now. The state card
    /// and the chart's running charge both use this, so they always show the same values.
    struct Live {
        var since: Date?, at: Double
        var logCurrent: Bool                 // macOS's log already has the current state
        var awake: Double?, displayOn: Double?, asleep: Double?, off = 0.0   // on battery only; nil = unknown
    }
    func live(_ b: BatteryNow, now: Date = Date()) -> Live {
        let h = history
        // The log lags: if its last state differs from the live one, the change happened after it.
        // A change this app saw itself that is newer than the log's wins (the log may not have it yet).
        let seen = changedAt.flatMap { c in (h?.since).map { c.t > $0 } ?? true ? c : nil }
        let logCurrent = h?.lastOnCharger == b.onCharger && seen == nil
        let since = seen?.t ?? (logCurrent ? h?.since : nil)
        let at = seen?.level ?? (logCurrent ? (h?.sinceLevel ?? b.level) : b.level)
        var r = Live(since: since, at: at, logCurrent: logCurrent)
        guard !b.onCharger, let sl = logCurrent ? h?.current?.asleep : 0 else { return r }
        // Live: the time since unplugging is awake + asleep + switched off (the window is open, so the Mac is awake
        // now; the logs lag behind). Display on: the log's value plus the time awake since then.
        let forS = since.map { now.timeIntervalSince($0) } ?? 0
        r.off = logCurrent ? (h?.current?.off ?? 0) : 0
        let aw = max(0, forS - sl - r.off)
        let logged = logCurrent ? (h?.current?.awake ?? 0) : 0
        r.awake = aw; r.asleep = sl
        r.displayOn = min(aw, (logCurrent ? (h?.current?.displayOn ?? 0) : 0) + max(0, aw - logged))
        return r
    }

    /// The charges for the chart, brought up to date with what this app saw live (macOS's log lags a minute or more):
    /// the running charge has exactly the state card's values; a charge that started after the log's last entry
    /// appears at once as "running"; plugged in: nothing is running.
    var chartCharges: [BatteryCharge] {
        var cs = history?.charges ?? []
        guard let b = now else { return cs }
        let t = Date(), l = live(b, now: t)
        if b.onCharger {
            if let i = cs.indices.last, cs[i].running {
                cs[i].running = false
                if !l.logCurrent, let s = l.since { cs[i].end = s }
            }
        } else if l.logCurrent, let i = cs.indices.last, cs[i].running {
            let c = cs[i]
            var r = BatteryCharge(start: l.since ?? c.start, end: t, startLevel: l.at, endLevel: b.level,
                                  awake: l.awake ?? c.awake, asleep: l.asleep ?? c.asleep, displayOn: l.displayOn ?? c.displayOn,
                                  wh: c.wh, avgAwakeW: c.avgAwakeW, running: true)
            r.off = l.off
            cs[i] = r
        } else if !l.logCurrent, let s = l.since, cs.last.map({ s.timeIntervalSince($0.start) > 60 }) ?? true {
            if let i = cs.indices.last, cs[i].running { cs[i].running = false }
            cs.append(BatteryCharge(start: s, end: t, startLevel: l.at, endLevel: b.level,
                                    awake: l.awake, asleep: l.asleep, displayOn: l.displayOn, wh: nil, avgAwakeW: nil, running: true))
        }
        return cs
    }
    /// Changes when the chart's data changes (history read, or a live (un)plug); not every second.
    var chartVersion: Int {
        let minute = now?.onCharger == false ? Int(Date().timeIntervalSince1970 / 60) : 0     // running charge: every minute
        return historyVersion &* 31 &+ Int(changedAt?.t.timeIntervalSince1970 ?? 0) &+ (now?.onCharger == true ? 1 : 0) &+ minute &* 7
    }

    var secondsLeft: Double? { now.flatMap { estimator.secondsLeft($0) } }      // own estimate: no 90 s pause needed
    var secondsToFull: Double? { now.flatMap { estimator.secondsToFull($0) } }
}

// MARK: - Button in the window's top row

struct BatteryButton: View {
    @ObservedObject var model = BatteryModel.shared
    @Binding var isOn: Bool

    var body: some View {
        if let b = model.now {
            // A narrow window (the top row has to fit 940 pt): a shorter text ("3:45", "Full"), or only the icon.
            ViewThatFits(in: .horizontal) {
                button(b, status(b))
                button(b, shortStatus(b))
                button(b, nil)
            }
            .tip(status(b) + "\n" + (isOn ? BT.hideTip : BT.showTip))
            .accessibilityLabel(BT.pct(b.level) + ", " + status(b))
            .onAppear { model.start() }
            .onDisappear { model.stop() }
        }
    }

    private func button(_ b: BatteryNow, _ text: String?) -> some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                BatteryIcon(level: b.level, charging: b.onCharger && !b.fullyCharged || b.charging,
                            full: b.onCharger && !b.charging && (b.fullyCharged || b.level >= 100))
                if let text { Text(text).font(.callout).monospacedDigit() }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isOn ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOn ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.3), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// As in the menu bar: the time alone, "Full" or "Paused".
    private func shortStatus(_ b: BatteryNow) -> String {
        if b.onCharger && !b.charging { return b.fullyCharged || b.level >= 100 ? BT.menuFull : BT.menuPaused }
        return (b.onCharger ? model.secondsToFull : model.secondsLeft).map(BT.dur) ?? "…"
    }

    private func status(_ b: BatteryNow) -> String {
        if b.onCharger {
            if !b.charging { return b.fullyCharged || b.level >= 100 ? BT.fullyCharged : BT.pausedAt(b.level) }
            return model.secondsToFull.map(BT.untilFull) ?? BT.calculating
        }
        return model.secondsLeft.map(BT.left) ?? BT.calculating
    }
}

/// Battery symbol that fills with the charge, % inside, ⚡ while charging, red below 20 %.
struct BatteryIcon: View {
    let level: Double, charging: Bool
    var full = false          // fully charged: only a bolt inside
    var body: some View {
        let low = level < 20 && !charging
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).strokeBorder(low ? Color.red : Color.green.opacity(0.8), lineWidth: 1.2)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(low ? Color.red.opacity(0.85) : Color.green.opacity(charging ? 0.9 : 0.75))
                        .frame(width: max(2, (g.size.width - 4) * min(1, level / 100)))
                        .padding(2)
                }
                HStack(spacing: 1) {
                    if full {
                        Image(systemName: "bolt.fill").font(.system(size: 11, weight: .semibold))
                    } else {
                        if charging { Image(systemName: "bolt.fill").font(.system(size: 8)) }
                        Text("\(Int(level.rounded()))%").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 50, height: 20)
            RoundedRectangle(cornerRadius: 1).fill(low ? Color.red : Color.green.opacity(0.8)).frame(width: 2.5, height: 7)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The view

struct BatteryView: View {
    @ObservedObject var model = BatteryModel.shared
    @State private var chartWidth: CGFloat = 1000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let b = model.now {
                HStack(alignment: .top, spacing: 12) {
                    stateCard(b)
                    healthCard(b)
                }
                .fixedSize(horizontal: false, vertical: true)     // both cards as tall as the taller one
                ChargeChart(charges: model.chartCharges, loaded: model.history != nil,
                            version: model.chartVersion, width: chartWidth - 24).equatable()
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
        .onAppear { model.start(); model.viewOpen = true }
        .onDisappear { model.viewOpen = false; model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: PMSetLog.updated)) { _ in model.loadHistory() }
    }

    private func card<C: View>(_ title: String, tip: String, _ big: String, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text(big).font(.title2.weight(.semibold)).monospacedDigit()
            }
            .tip(tip)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) { rows() }.padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // fill the row: equal heights
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ k: String, _ v: String, tip: String? = nil) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
        .tip(tip ?? "")
    }

    @ViewBuilder private func stateCard(_ b: BatteryNow) -> some View {
        let h = model.history
        let l = model.live(b)
        let since = l.since, at = l.at, logCurrent = l.logCurrent
        let forS = since.map { Date().timeIntervalSince($0) } ?? 0
        if !b.onCharger {
            let title = since.map { BT.onBatteryFor(forS, since: $0, at: at) } ?? BT.onBattery
            card(title, tip: BT.tipState, BT.pct(b.level) + " · " + (model.secondsLeft.map(BT.left) ?? BT.calculating)) {
                if let aw = l.awake, let sl = l.asleep {
                    row(BT.awakeRow, BT.dur(aw) + " (" + BT.displayLabel(l.displayOn ?? 0) + ")", tip: BT.tipAwake)
                    row(BT.asleepRow, BT.dur(sl), tip: BT.tipAsleep)
                    if l.off >= 60 { row(BT.offRow, BT.dur(l.off), tip: BT.tipOff) }
                }
                row(BT.drawingNow, BT.watts(b.batteryW) + " · \(Int(b.batteryMilliamps.rounded())) mA", tip: BT.tipDrawing)
                if logCurrent, let w = h?.current?.avgAwakeW { row(BT.avgAwake, BT.watts(w), tip: BT.tipAvgAwake) }
            }
        } else if b.charging && !b.fullyCharged {
            let title = since.map { BT.chargingFor(forS, since: $0, at: at) } ?? BT.onCharger
            card(title, tip: BT.tipState, BT.pct(b.level) + " · " + (model.secondsToFull.map(BT.untilFull) ?? BT.calculating)) {
                row(BT.chargingWith, BT.watts(b.batteryW) + " · \(Int(b.batteryMilliamps.rounded())) mA", tip: BT.tipChargingWith)
                chargerRows(b)
            }
        } else {
            card(since.map(BT.onChargerSince) ?? BT.onCharger, tip: BT.tipState, BT.pct(b.level) + " · " + (b.fullyCharged || b.level >= 100 ? BT.fullyCharged : BT.pausedAt(b.level))) {
                chargerRows(b)
            }
        }
    }

    @ViewBuilder private func chargerRows(_ b: BatteryNow) -> some View {
        if let n = b.adapterName {
            row(BT.charger, n + (b.adapterMaxW.map { " · max " + BT.watts($0) } ?? ""), tip: BT.tipCharger)
        }
        if let w = b.systemLoad { row(BT.macUses, BT.watts(w), tip: BT.tipMacUses) }
    }

    private func healthCard(_ b: BatteryNow) -> some View {
        let hl = model.health
        let pct = hl?.maxCapacity ?? (b.capacityDesign > 0 ? min(100, b.capacityNow / b.capacityDesign * 100) : 0)
        let big = BT.pct(pct) + (hl.map { " · " + BT.condition($0.condition) } ?? "")
        return card(BT.health, tip: BT.tipHealth, big) {
            row(BT.capacity, "\(Int(b.capacityNow)) / \(Int(b.capacityDesign)) mAh", tip: BT.tipCapacity)
            row(BT.cycles, "\(b.cycles)", tip: BT.tipCycles)
            if let t = model.history?.temperature {
                row(BT.temperature, t.formatted(.number.precision(.fractionLength(0))) + " °C", tip: BT.tipTemperature)
            }
            row(BT.voltage, b.voltage.formatted(.number.precision(.fractionLength(2))) + " V", tip: BT.tipVoltage)
        }
    }

}

// MARK: - Chart per charge: charge used (%) and awake / asleep (hours), newest on the LEFT

/// Its own view, redrawn only when the charges or the width change (not by the every-second live values),
/// so the hover areas and their tooltips stay in place.
struct ChargeChart: View, Equatable {
    let charges: [BatteryCharge]
    let loaded: Bool
    let version: Int
    let width: CGFloat

    static func == (a: Self, b: Self) -> Bool { a.version == b.version && a.loaded == b.loaded && a.width == b.width }

    private struct Bar: Identifiable { let id: String; let label: String; let series: String; let value: Double }
    private static let axisW: CGFloat = 46          // one value axis (labels 38 + gap)

    var body: some View {
        // Newest first (left).
        let cs = Array(charges.reversed())          // all charges macOS's battery log still has (about 10 days)
        VStack(alignment: .leading, spacing: 6) {
            Text(BT.perCharge).font(.headline).tip(BT.tipChart)
            if loaded && cs.isEmpty {
                Text(BT.noCharges).foregroundStyle(.secondary)
            } else if !cs.isEmpty {
                let labels = cs.map { "\($0.id)" }
                let byLabel = Dictionary(zip(labels, cs), uniquingKeysWith: { a, _ in a })
                let used = zip(cs, labels).map { Bar(id: "u\($0.1)", label: $0.1, series: BT.chargeUsed, value: $0.0.used) }
                let hours = zip(cs, labels).flatMap { c, l -> [Bar] in
                    guard let aw = c.awake, let sl = c.asleep else { return [] }     // unknown: before the sleep log
                    let on = c.displayOn ?? 0
                    return [Bar(id: "d\(l)", label: l, series: BT.displayOn, value: on / 3600),
                            Bar(id: "a\(l)", label: l, series: BT.awakeDisplayOff, value: max(0, aw - on) / 3600),
                            Bar(id: "s\(l)", label: l, series: BT.asleep, value: sl / 3600)]
                }
                // Each charge's column is wide enough for its labels on one line; wider than the window: scroll sideways.
                // Column width from the longest label (date formats differ, e.g. US "Nov 19 at 2:50 AM").
                let font = NSFont.preferredFont(forTextStyle: .caption2)
                let longest = cs.flatMap { c -> [String] in
                    [BT.range(c), c.awake.map { BT.awakeLabel($0, displayOn: c.displayOn ?? 0) } ?? BT.onBatteryLabel(c.end.timeIntervalSince(c.start)),
                     BT.asleepLabel(c.asleep ?? 0) + (c.off >= 60 ? " · " + BT.offLabel(c.off) : "")]
                }.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 160
                let colW = max(178, longest * 1.05 + 24)
                let contentW = max(width - 2 * Self.axisW, CGFloat(cs.count) * colW)
                let band = contentW / CGFloat(cs.count)
                // Hours scale: up to the longest charge, rounded up to 10 h.
                let longestH = cs.map { ($0.awake ?? 0) + ($0.asleep ?? 0) }.max() ?? 0
                let maxH = max(10, (longestH / 3600 / 10).rounded(.up) * 10)
                let hourMarks = Array(stride(from: 0.0, through: maxH, by: maxH > 30 ? 10 : 5))
                let pctMarks: [Double] = [0, 25, 50, 75, 100]
                let barW = band * 0.5
                HStack(spacing: 14) {      // colour key, fixed above the scrolling charts
                    ForEach([(BT.displayOn, Color.blue), (BT.awakeDisplayOff, Color.blue.opacity(0.45)), (BT.asleep, Color.gray.opacity(0.35))], id: \.0) { k in
                        HStack(spacing: 4) { Circle().fill(k.1).frame(width: 8, height: 8); Text(k.0) }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 0) {
                Color.clear.frame(width: Self.axisW)            // room for the fixed scale on the left
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 10) {
                        Chart(used) { b in
                            BarMark(x: .value("Charge", b.label), y: .value(BT.chargeUsed, b.value), width: .fixed(barW))
                                .foregroundStyle(LinearGradient(colors: [Color.green.opacity(0.55), Color.green],
                                                                startPoint: .bottom, endPoint: .top))
                                .cornerRadius(6, style: .continuous)
                                .opacity(byLabel[b.label]?.running == true ? 0.5 : 1)
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxis { AxisMarks(values: pctMarks) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])) } }
                        .chartXAxis {       // "… % used" under each bar
                            AxisMarks { v in
                                AxisValueLabel(centered: true) {
                                    if let l = v.as(String.self), let c = byLabel[l] {
                                        Text(BT.usedLabel(c)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                        .chartXScale(domain: labels)
                        .chartOverlay { tipColumns($0, labels, byLabel, report: 1) }
                        .chartLegend(.hidden)                  // one series; each bar says "… % used"
                        .padding(.top, 8)                      // the top value label ("100 %") isn't cut off
                        .frame(minHeight: 35, maxHeight: 230)

                        Chart(hours) { b in
                            BarMark(x: .value("Charge", b.label), y: .value("Hours", b.value), width: .fixed(barW))
                                .foregroundStyle(by: .value("", b.series))
                                .cornerRadius(4, style: .continuous)
                        }
                        .chartForegroundStyleScale([BT.displayOn: Color.blue, BT.awakeDisplayOff: Color.blue.opacity(0.4),
                                                    BT.asleep: Color.gray.opacity(0.35)])
                        .chartXAxis {
                            AxisMarks { v in
                                AxisValueLabel(centered: true, anchor: .top) {
                                    if let l = v.as(String.self), let c = byLabel[l] {
                                        // Starts at the bar's left edge (a frame as wide as the bar, text leading-aligned
                                        // and allowed to run past it to the right).
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(BT.range(c)).foregroundStyle(.secondary)
                                            if let aw = c.awake, let sl = c.asleep {
                                                Text(BT.awakeLabel(aw, displayOn: c.displayOn ?? 0)).foregroundStyle(.blue)
                                                Text(BT.asleepLabel(sl) + (c.off >= 60 ? " · " + BT.offLabel(c.off) : ""))
                                            } else {        // before macOS's sleep log: only the total time is known
                                                Text(BT.onBatteryLabel(c.end.timeIntervalSince(c.start))).foregroundStyle(.blue)
                                                Text(" ")
                                            }
                                        }
                                        .font(.caption2).monospacedDigit().lineLimit(1).fixedSize()
                                        .frame(width: barW, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .chartYScale(domain: 0...maxH)
                        .chartYAxis { AxisMarks(values: hourMarks) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])) } }
                        .chartXScale(domain: labels)
                        .chartOverlay { tipColumns($0, labels, byLabel, report: 2) }
                        .chartLegend(.hidden)
                        .frame(minHeight: 74, maxHeight: 300)
                    }
                    .frame(width: contentW)
                    .padding(.bottom, 4)
                }
                .defaultScrollAnchor(.leading)          // starts at the newest charge (left)
                Color.clear.frame(width: Self.axisW)            // and on the right
                }
                .coordinateSpace(.named("batteryCharts"))
                // The value scales, fixed on both sides while the charts scroll, placed at the charts' real plot areas.
                .overlayPreferenceValue(PlotRects.self) { r in
                    GeometryReader { g in
                        let sides: [CGFloat] = [Self.axisW - 6, g.size.width - Self.axisW + 6]
                        ForEach(0..<2, id: \.self) { side in
                            if let p = r[1] {
                                let n = max(1, Int((16 * CGFloat(pctMarks.count - 1) / max(1, p.height)).rounded(.up)))
                                ForEach(pctMarks.enumerated().filter { $0.offset % n == 0 }.map(\.element), id: \.self) { v in
                                    scaleLabel("\(Int(v)) %", side: side, x: sides[side], y: p.maxY - p.height * v / 100)
                                }
                            }
                            if let p = r[2] {
                                // Low chart: only every n-th label, so they don't overlap (at least 16 pt apart).
                                let n = max(1, Int((16 * CGFloat(hourMarks.count - 1) / max(1, p.height)).rounded(.up)))
                                ForEach(hourMarks.enumerated().filter { $0.offset % n == 0 }.map(\.element), id: \.self) { v in
                                    scaleLabel("\(Int(v)) h", side: side, x: sides[side], y: p.maxY - p.height * v / maxH)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func scaleLabel(_ t: String, side: Int, x: CGFloat, y: CGFloat) -> some View {
        Text(t).font(.caption2).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            .frame(width: Self.axisW - 8, alignment: side == 0 ? .trailing : .leading)
            .position(x: side == 0 ? x - (Self.axisW - 8) / 2 : x + (Self.axisW - 8) / 2, y: y)
    }

    /// One invisible hover area per charge column, with the charge's details as tooltip.
    private func tipColumns(_ proxy: ChartProxy, _ labels: [String], _ byLabel: [String: BatteryCharge], report: Int) -> some View {
        GeometryReader { g in
            let plot = proxy.plotFrame.map { g[$0] } ?? g.frame(in: .local)
            let inCharts = g.frame(in: .named("batteryCharts"))
            Color.clear.preference(key: PlotRects.self, value: [report: plot.offsetBy(dx: inCharts.minX, dy: inCharts.minY)])
            let w = plot.width / CGFloat(max(1, labels.count))
            ForEach(labels, id: \.self) { l in
                if let x = proxy.position(forX: l), let c = byLabel[l] {
                    Color.clear.contentShape(Rectangle())
                        .frame(width: w, height: plot.height)
                        .tip(BT.chargeTip(c))
                        .position(x: plot.minX + x, y: plot.midY)
                }
            }
        }
    }
}

/// The plot areas of the two charts (in the charts' coordinate space), for the fixed value scales.
struct PlotRects: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
}
