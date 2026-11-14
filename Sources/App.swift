import AppKit
import SwiftUI

@main
struct EnergyMonitorApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBar

    init() {
        // Tooltips after 0.3 s instead of macOS's default (about 1 s); only for this app.
        UserDefaults.standard.set(300, forKey: "NSInitialToolTipDelay")
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
        Self.liveTestIfAsked()
        Self.diagnosticsIfAsked()
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
                let text = ContentView.fmt(row.energyWh, row.energyWh < 10 ? 2 : 1)
                let shown = Double(text.replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: ".", with: "")
                                       .replacingOccurrences(of: ",", with: ".")) ?? -1
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

    var body: some Scene {
        WindowGroup("Mac Energy Monitor", id: "main") {
            ContentView()
                .overlay { InfoPanel() }      // "How these numbers are measured", drawn inside the window
                .frame(minWidth: 940, minHeight: 470)   // + ~52 pt title bar: fits 960 x 600-point screens (smallest scaled resolution)
        }
        .windowResizability(.contentMinSize)
    }
}

enum Preset: String, CaseIterable, Identifiable {
    case live = "Live", hour = "1 hour", day = "24 hours", threeDays = "3 days", week = "7 days", all = "All", custom = "Custom"
    var id: String { rawValue }
    var hours: Double? {
        switch self {
        case .hour: return 1
        case .day: return 24
        case .threeDays: return 72
        case .week: return 168
        case .all, .custom, .live: return nil
        }
    }
}

/// One reader and one queue for the window and the menu bar, so log copies never overlap.
let sharedLog = PowerLog()
let logQueue = DispatchQueue(label: "powerlog")

@MainActor
final class Model: ObservableObject {
    @Published var report: Report?
    @Published var available: ClosedRange<Date>?
    @Published var loading = false
    @Published var error: String?

    /// `from == nil` means "All": from the oldest data (looked up first, on the log queue).
    func load(from: Date?, to: Date, onRange: ((Date) -> Void)? = nil) {
        loading = true
        error = nil
        let log = sharedLog
        logQueue.async {
            let range = try? log.fullRange()
            let start = from ?? range?.lowerBound ?? to.addingTimeInterval(-14 * 86400)
            let result = Result { try log.fullReport(from: start, to: to) }
            DispatchQueue.main.async {
                self.loading = false
                if let range { self.available = range }
                onRange?(start)
                switch result {
                case .success(let r): self.report = r
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    // Remembered between launches: the chosen view, filters and custom dates.
    @AppStorage("preset") private var preset: Preset = .week
    @AppStorage("kind") private var kind = "All"
    @AppStorage("minEnergy") private var minEnergy = 0.1
    @AppStorage("screenOnly") private var screenOnly = false
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @State private var from = ContentView.savedDate("customFrom") ?? Date().addingTimeInterval(-7 * 86400)
    @State private var to = ContentView.savedDate("customTo") ?? Date()
    @State private var search = ""

    private static func savedDate(_ key: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    @State private var sortOrder = [KeyPathComparator(\AppRow.energyWh, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if preset == .custom { customRow }
            if preset == .live {
                LivePowerView()
                LiveTableView(search: search, kind: $kind)
            } else {
                if let r = model.report {
                    cards(r)
                    BreakdownStrip(breakdown: r.hardware, unit: "Wh", hours: r.coveredHours)
                    if !r.missingDays.isEmpty {
                        Label("No data for \(Self.dayRanges(r.missingDays)). macOS's own power logs on this Mac start on \(r.macOSLogsStart.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"), and Mac Energy Monitor has no saved summary for these days (it can save a day only while macOS still has that day's logs). These days are left out of all figures; averages use only the \(Self.duration(r.coveredHours)) with data.", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    // Only worth mentioning when the not-yet-split minutes are a noticeable part of the period.
                    if let e = r.estimatedFrom, r.end.timeIntervalSince(e) > 0.1 * r.end.timeIntervalSince(r.start) {
                        Label("The last \(Self.duration(r.end.timeIntervalSince(e) / 3600)) (since \(e.formatted(date: .omitted, time: .shortened))) aren't split into parts by macOS yet — it writes the CPU, GPU, memory and per-app split only about every 30 minutes, while the whole-Mac total is logged every minute. For these minutes the total is measured and the split follows the proportions of the time just before.", systemImage: "clock.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                filters
                table
            }
if preset != .live {
                InfoNote(sections: Explanations.history)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // same position in every view
        .padding(12)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter apps")
        .toolbar {
            ToolbarItem {
                HStack(spacing: 6) {
                    // Symbol explicitly before the text (a toolbar Label may place it elsewhere).
                    HStack(spacing: 4) {
                        Image(systemName: "circle.lefthalf.filled")
                        Text("Appearance")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    Picker("Appearance", selection: $appearance) {
                        Text("Follow system").tag(AppAppearance.system)
                        Text("Light").tag(AppAppearance.light)
                        Text("Dark").tag(AppAppearance.dark)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
                .help("Window appearance: follow the system, or always light or dark")
            }
            ToolbarItem {
                if preset != .live {    // Live updates by itself
                    Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Reload the power logs")
                }
            }
        }
        .onAppear { reload(); appearance.apply() }
        .onChange(of: appearance) { _, a in a.apply() }
    }

    // MARK: sections

    private var controls: some View {
        HStack(alignment: .center, spacing: 16) {
            Picker("Time frame", selection: $preset) {
                ForEach(Preset.allCases) { p in
                    if p == .live { Image(nsImage: Self.liveLabel).tag(p) } else { Text(p.rawValue).tag(p) }
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: preset) { _, p in
                if p == .custom {   // keep the dates shown so far and remember them for the next start
                    UserDefaults.standard.set(from.timeIntervalSince1970, forKey: "customFrom")
                    UserDefaults.standard.set(to.timeIntervalSince1970, forKey: "customTo")
                } else if p != .live { reload() }
            }

            Spacer()
            StartAtLoginToggle()
            // Always takes its space, so the buttons don't shift while a time frame loads.
            ProgressView().controlSize(.small).opacity(model.loading ? 1 : 0)
        }
        .labelsHidden()
    }

    /// Custom period: on its own row, so the top row also fits the smallest window.
    private var customRow: some View {
        HStack(spacing: 10) {
            Text("From").foregroundStyle(.secondary)
            DatePicker("From", selection: $from.saved("customFrom"), in: (model.available?.lowerBound ?? .distantPast)...Date())
                .labelsHidden()
            Text("to").foregroundStyle(.secondary)
            DatePicker("To", selection: $to.saved("customTo"), in: from...Date())
                .labelsHidden()
            Button("Apply") { reload() }.keyboardShortcut(.defaultAction)
            Spacer()
        }
    }

    private func cards(_ r: Report) -> some View {
        let t = r.totals
        return HStack(spacing: 12) {
            card("Whole Mac", "\(r.hardware.whole.formatted(.number.precision(.fractionLength(1)))) Wh", "bolt.fill")
            card("Avg. power", "\((r.hardware.whole / max(r.coveredHours, 0.001)).formatted(.number.precision(.fractionLength(2)))) W", "gauge.medium")
            card("Screen on", duration(t.screenOnH), "display")
            card("Period", Self.periodText(r.start, r.end), "calendar", small: true)
        }
    }

    private func card(_ title: String, _ value: String, _ icon: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(small ? .callout.weight(.semibold) : .title2.weight(.semibold))
                .lineLimit(small ? 2 : 1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56, alignment: .leading)   // all tiles the same height
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var filters: some View {
        HStack(spacing: 16) {
            Picker("Type", selection: $kind) {
                ForEach(["All", "App", "Background"], id: \.self) { Text($0) }
            }.frame(width: 170)
            Picker("Minimum energy", selection: $minEnergy) {
                Text("Show all").tag(0.0)
                Text("≥ 0.1 Wh").tag(0.1)
                Text("≥ 1 Wh").tag(1.0)
                Text("≥ 10 Wh").tag(10.0)
            }.frame(width: 230)
            Toggle("Only apps with screen time", isOn: $screenOnly)
            Spacer()
            if let r = model.report {
                // Both numbers without macOS's own processes (they are in the breakdown above, never in the table).
                Text("\(rows.count) of \(r.rows.filter { $0.kind != "System" }.count) apps and services")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Shown: apps and services that pass the filters (type, minimum energy, screen time, search). The second number is all your apps and services with any energy or screen time in this period.")
            }
        }
    }

    private var rows: [AppRow] {
        guard let r = model.report else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return r.rows.filter { row in
            (q.isEmpty || row.name.lowercased().contains(q) || row.id.lowercased().contains(q)) &&
            row.kind != "System" &&     // macOS's own processes are in the breakdown above
            (kind == "All" || row.kind == kind) &&
            // Filter on the values as the table shows them (rounded), so the filters match what you see.
            shownEnergy(row.energyWh) >= minEnergy &&
            (!screenOnly || row.screenH >= Self.minScreenH)
        }.sorted(using: sortOrder)
    }

    @ViewBuilder private var table: some View {
        if let e = model.error {
            ContentUnavailableView("Couldn't read the power logs", systemImage: "exclamationmark.triangle",
                                   description: Text(e))
        } else if model.report == nil {
            ProgressView("Reading macOS power logs…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("App / service", value: \.name) { r in
                    HStack(spacing: 8) {
                        AppIcon(path: r.appPath)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).lineLimit(1)
                            Text(r.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(height: 32)   // same height in every row, so the second line always shows
                    .help(r.name + "\n" + r.id)
                }.width(min: 150, ideal: 150)   // grows with the window; the number columns stay fixed
                // Minimum widths fit each title (+ sort arrow) and its longest value, e.g. "Background",
                // "12 d 23 h 59 min" — all columns together fit the smallest window (980 pt).
                TableColumn("Type", value: \.kind) { Text($0.kind).foregroundStyle(.secondary).lineLimit(1) }
                    .width(80)
                TableColumn("Share", value: \.share) { r in
                    HStack(spacing: 6) {
                        Capsule().fill(.tint).frame(width: max(2, min(20, r.share / 5)), height: 5)
                        Text(fmt(r.share, 1) + "%").monospacedDigit().lineLimit(1)
                    }
                }.width(80)
                TableColumn("Energy (Wh)", value: \.energyWh) { num(fmt($0.energyWh, $0.energyWh < 10 ? 2 : 1)) }
                    .width(90)
                TableColumn("Avg. W", value: \.avgW) { num($0.avgW < 0 ? "—" : fmt($0.avgW, 2)) }
                    .width(68)
                TableColumn("Running", value: \.runningH) { cellDuration($0.runningH) }
                    .width(85)
                TableColumn("CPU time", value: \.cpuH) { cellDuration($0.cpuH) }
                    .width(85)
                TableColumn("Screen time", value: \.screenH) { $0.screenH < Self.minScreenH ? AnyView(num("—")) : AnyView(cellDuration($0.screenH)) }
                    .width(95)
            }
            .frame(minHeight: 110)   // SwiftUI's default minimum (~210 pt) would not fit small screens
        }
    }

    // MARK: helpers

    /// Table cells: from one day on without minutes ("12 d 23 h"), full value in the tooltip.
    private func cellDuration(_ h: Double) -> some View {
        let full = duration(h)
        let m = Int((h * 60).rounded())
        let short = m >= 1440 ? "\(m / 1440) d \((m % 1440) / 60) h" : full
        return num(short).help(full)
    }

    private func num(_ s: String) -> some View {
        Text(s).monospacedDigit().lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// "14 Nov, 01:13 – 02:13" on one day, otherwise "7 Nov 02:13 – 14 Nov 02:13" (year only if not this year).
    static func periodText(_ a: Date, _ b: Date) -> String {
        let cal = Calendar.current
        let thisYear = cal.isDate(a, equalTo: Date(), toGranularity: .year) && cal.isDate(b, equalTo: Date(), toGranularity: .year)
        let day = thisYear ? Date.FormatStyle().day().month(.abbreviated) : Date.FormatStyle().day().month(.abbreviated).year()
        let time = Date.FormatStyle().hour().minute()
        if cal.isDate(a, inSameDayAs: b) { return "\(a.formatted(day)), \(a.formatted(time)) – \(b.formatted(time))" }
        return "\(a.formatted(day)) \(a.formatted(time)) – \(b.formatted(day)) \(b.formatted(time))"
    }

    /// "Live" with a small red dot in front. Segmented buttons draw symbols in grey only, so dot and text are
    /// drawn together as one non-template image; it is redrawn on each display, so the text follows light/dark mode.
    static let liveLabel: NSImage = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = "Live" as NSString
        let tw = text.size(withAttributes: [.font: font]).width
        let dot: CGFloat = 6, gap: CGFloat = 4
        let size = NSSize(width: ceil(dot + gap + tw), height: ceil(font.ascender - font.descender))
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: (rect.height - dot) / 2 + 0.5, width: dot, height: dot)).fill()
            text.draw(at: NSPoint(x: dot + gap, y: -font.descender),
                      withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Live"
        return img
    }()

    /// Consecutive days joined: "3 – 5 Nov, 14 Nov".
    static func dayRanges(_ days: [Date]) -> String {
        let cal = Calendar.current
        var groups: [(Date, Date)] = []
        for d in days.sorted() {
            if let last = groups.last, let next = cal.date(byAdding: .day, value: 1, to: last.1),
               cal.isDate(next, inSameDayAs: d) { groups[groups.count - 1].1 = d } else { groups.append((d, d)) }
        }
        let f = Date.FormatStyle().day().month(.abbreviated)
        return groups.map { a, b in a == b ? a.formatted(f) : "\(a.formatted(f)) – \(b.formatted(f))" }
            .joined(separator: ", ")
    }

    /// Screen time is shown (as "1 min" or more) from 30 seconds on.
    static let minScreenH = 1.0 / 120

    /// Energy rounded the way the "Energy (Wh)" column shows it.
    static func shownEnergy(_ wh: Double) -> Double {
        let f = wh < 10 ? 100.0 : 10.0
        return (wh * f).rounded() / f
    }

    /// 1.33 h → "1 h 20 min", 0.25 h → "15 min", tiny → "< 1 min".
    /// 0.25 h → "15 min", 1.33 h → "1 h 20 min", 312.15 h → "13 d 0 h 9 min".
    static func duration(_ hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        if m < 1 { return hours > 0 ? "< 1 min" : "—" }
        if m < 60 { return "\(m) min" }
        let d = m / 1440, h = (m % 1440) / 60, min = m % 60
        if d == 0 { return min == 0 ? "\(h) h" : "\(h) h \(min) min" }
        return min == 0 ? "\(d) d \(h) h" : "\(d) d \(h) h \(min) min"
    }

    private func shownEnergy(_ wh: Double) -> Double { Self.shownEnergy(wh) }
    private func duration(_ hours: Double) -> String { Self.duration(hours) }
    private func fmt(_ v: Double, _ digits: Int) -> String { Self.fmt(v, digits) }

    static func fmt(_ v: Double, _ digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }

    private func reload() {
        let now = Date()
        switch preset {
        case .live:
            return
        case .custom:
            model.load(from: from, to: to)
        case .all:
            to = now
            model.load(from: nil, to: now) { start in from = start }   // the real oldest data, not a guess
        default:
            to = now
            from = now.addingTimeInterval(-(preset.hours ?? 168) * 3600)
            model.load(from: from, to: to)
        }
    }
}

struct AppIcon: View {
    let path: String?
    var body: some View {
        Group {
            if let path {
                Image(nsImage: Self.icon(path))
                    .resizable()
            } else {
                Image(systemName: "gearshape.2").resizable().scaledToFit()
                    .foregroundStyle(.secondary).padding(3)
            }
        }
        .frame(width: 22, height: 22)
    }

    /// One icon per app, kept: live views redraw every second, and asking macOS for a new icon image
    /// each time made memory creep up while the Live view stayed open.
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor private static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 500 { cache.removeAll() }
        cache[path] = i
        return i
    }
}

extension Binding where Value == Date {
    /// Also stores every change in UserDefaults under `key` (used for the custom time frame).
    func saved(_ key: String) -> Binding<Date> {
        Binding(get: { wrappedValue }, set: { v in
            wrappedValue = v
            UserDefaults.standard.set(v.timeIntervalSince1970, forKey: key)
        })
    }
}

/// Window appearance (remembered). Applied to the whole app; the menu bar panel sets its own (always dark).
enum AppAppearance: String {
    case system, light, dark

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil                                   // follow macOS
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
