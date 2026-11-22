import Charts
import Combine
import SwiftUI

/// Samples whole-Mac power once a second and keeps the last 5 minutes.
/// Shared by the menu bar and the main window.
@MainActor
final class LivePower: ObservableObject {
    static let shared = LivePower()
    struct Sample: Identifiable { let t: Date; let w: Double; var id: Date { t } }

    @Published private(set) var current: Double?
    /// Not @Published: updated just before `current`, so each reading refreshes views only once.
    private(set) var samples: [Sample] = []
    let window: TimeInterval = 300
    private var timer: Timer?

    private init() {
        tick()
        reschedule()
    }

    /// (Re)starts sampling at the chosen live update interval.
    func reschedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: LiveSettings.shared.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = LiveSettings.shared.interval * 0.1   // lets macOS group wake-ups (values use the real elapsed time)
    }

    private func tick() {
        let now = Date()
        let w = SystemPower.watts()
        if let w { samples.append(Sample(t: now, w: w)) }
        samples.removeAll { now.timeIntervalSince($0.t) > window }
        current = w
    }
}

/// Live whole-Mac power card with a 5-minute chart, for the main window.
struct LivePowerView: View {
    @ObservedObject var live = LivePower.shared

    var body: some View {
        let ws = live.samples.map(\.w)
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Whole Mac now", systemImage: "bolt.fill").font(.caption).foregroundStyle(.secondary)
                Text(live.current.map { fmt($0, 1) + " W" } ?? "—")
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                if !ws.isEmpty {
                    Text("5 min: min \(fmt(ws.min()!, 1)) · avg \(fmt(ws.reduce(0, +) / Double(ws.count), 1)) · max \(fmt(ws.max()!, 1)) W")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 250, alignment: .leading)

            // A plain line over at most ~150 points keeps redrawing cheap (it redraws at every reading).
            Chart(Self.thinned(live.samples)) { s in
                LineMark(x: .value("Time", s.t), y: .value("W", s.w))
                    .foregroundStyle(.green)
            }
            .chartXScale(domain: Date().addingTimeInterval(-live.window)...Date())
            .chartXAxis { AxisMarks(values: .stride(by: .minute)) { v in
                AxisGridLine(); AxisValueLabel { if let d = v.as(Date.self) { Text(Clock.time(d)) } }
            } }
            .chartYAxis { AxisMarks(position: .leading) { v in
                AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) W") } }
            } }
            .frame(height: 64)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .help("Live power draw of the whole Mac (screen, chip, memory, SSD, Wi-Fi), read at the chosen update interval (1–10 s) from the system management controller. Shows the last 5 minutes.")
    }

    private static func thinned(_ s: [LivePower.Sample]) -> [LivePower.Sample] {
        let step = max(1, s.count / 150)
        return step == 1 ? s : s.enumerated().filter { $0.offset % step == 0 || $0.offset == s.count - 1 }.map(\.element)
    }
}

/// How often live values update (menu bar total, menu panel, Live view). Remembered between launches.
@MainActor
final class LiveSettings: ObservableObject {
    static let shared = LiveSettings()
    static let choices: [Double] = [1, 2, 5, 10]

    @Published var interval: Double {
        didSet {
            UserDefaults.standard.set(interval, forKey: "liveInterval")
            LivePower.shared.reschedule()
            LiveBreakdown.shared.reschedule()
        }
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: "liveInterval")
        interval = Self.choices.contains(saved) ? saved : 1
    }

    static func label(_ s: Double) -> String { s == 1 ? "1 second" : "\(Int(s)) seconds" }
}

/// Picker for the live update interval, used in the Live view and the menu bar panel.
struct LiveIntervalPicker: View {
    @ObservedObject var settings = LiveSettings.shared
    var body: some View {
        Picker("Update every", selection: $settings.interval) {
            ForEach(LiveSettings.choices, id: \.self) { Text("\(Int($0)) s").tag($0) }
        }
        .help("How often live values update. Longer intervals use slightly less energy.")
    }
}
