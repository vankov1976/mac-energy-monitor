import Foundation
import IOKit
import SwiftUI

/// Split of the whole Mac's power (live, in W) or energy (a period, in Wh) into hardware parts.
/// The CPU is further split into your apps and macOS's own processes. The parts always add up to `whole`.
struct Breakdown: Equatable, Codable {
    var display: Double?
    var cpu: Double?          // whole CPU
    var apps = 0.0            // your apps' processor energy (their graphics are in `gpu`)
    var gpu: Double?
    var memory: Double?       // DRAM
    var chip: Double?         // whole chip package (CPU + GPU + memory + the rest of the chip)
    var total: Double?        // whole Mac while awake, measured
    // History only (nil live and in daily summaries saved before 1.1.5):
    var sleep: Double?        // energy while asleep (Wh); nil = not known (e.g. desktop Mac)
    var sleepEstimated: Bool? // part of `sleep` is estimated (charger connected during sleep)
    var awakeH: Double?       // hours awake in the period
    var sleepH: Double?       // hours asleep in the period (without switched off)
    var offH: Double?         // hours switched off (a restart in a gap), counted with 0 Wh
    // Days from daily summaries saved before 1.1.5, which don't know when the Mac slept:
    var unknownH: Double?     // their hours (neither awake nor asleep is known)
    var unknownWh: Double?    // their whole-Mac energy (counted in the parts, left out of the awake average)

    struct Part: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: String
        let color: Color
        let value: Double
    }

    var parts: [Part] {
        var p: [Part] = []
        if let display { p.append(Part(id: "display", name: "Display", icon: "display", color: .yellow, value: display)) }
        if let cpu {
            p.append(Part(id: "apps", name: "CPU · user apps/services", icon: "app.badge", color: .blue, value: min(apps, cpu)))
            p.append(Part(id: "system", name: "CPU · system processes", icon: "gearshape.2", color: .indigo,
                          value: max(0, cpu - apps)))
        } else {
            p.append(Part(id: "apps", name: "User apps/services", icon: "app.badge", color: .blue, value: apps))
        }
        if let gpu { p.append(Part(id: "gpu", name: "GPU", icon: "cube.transparent", color: .purple, value: gpu)) }
        if let memory { p.append(Part(id: "memory", name: "Memory", icon: "memorychip", color: .teal, value: memory)) }
        if let chip {
            let known = (cpu ?? apps) + (gpu ?? 0) + (memory ?? 0)
            p.append(Part(id: "chip", name: cpu == nil ? "CPU · macOS & other chip parts" : "CPU · other chip parts", icon: "cpu",
                          color: .cyan, value: max(0, chip - known)))
        }
        if let total {
            let inner = p.reduce(0) { $0 + $1.value }
            p.append(Part(id: "other", name: "Other hardware", icon: "externaldrive", color: .gray,
                          value: max(0, total - inner)))
        }
        if let sleep { p.append(Part(id: "sleep", name: "Sleep", icon: "moon.zzz", color: .mint, value: sleep)) }
        return p
    }

    var whole: Double { parts.reduce(0) { $0 + $1.value } }

    /// Average power while awake (W): the energy without sleep ÷ the hours awake.
    /// Without a known awake time (old daily summaries): everything ÷ `fallbackHours`, as before 1.1.5.
    func averageAwakeW(fallbackHours: Double) -> Double? {
        if let awakeH, awakeH > 0.01 { return max(0, whole - (sleep ?? 0) - (unknownWh ?? 0)) / awakeH }
        // Known, but (almost) never awake in the period: no average (N/A), not "everything ÷ the period".
        if awakeH != nil, (unknownH ?? 0) <= 0.01 { return nil }
        if awakeH != nil, let unknownH, unknownH > 0 { return whole / unknownH }   // only old summaries: as before
        return fallbackHours > 0 && whole > 0 ? whole / fallbackHours : nil
    }

    /// The explanation of a row. "Other hardware" also names the parts macOS doesn't log separately on this
    /// Mac (no display, memory or chip-part values), because their energy is then in it.
    func help(_ id: String) -> String {
        let base = Self.help[id] ?? ""
        guard id == "other" else { return base }
        var inside: [String] = []
        if display == nil { inside.append("display") }
        if memory == nil { inside.append("memory") }
        if chip == nil, cpu != nil { inside.append("rest of the chip") }
        guard !inside.isEmpty else { return base }
        let list = inside.count == 1 ? inside[0] : inside.dropLast().joined(separator: ", ") + " and " + inside.last!
        return "Incl. \(list) (macOS doesn't log them separately on this Mac). " + base
    }

    static let help: [String: String] = [
        "display": "Screen backlight",
        "apps": "Processor energy of the user apps and services you run (the table below)",
        "system": "Processor energy of the system processes, macOS's own (WindowServer, kernel, system services) = CPU − user apps/services",
        "gpu": "Graphics processor",
        "memory": "Memory (DRAM)",
        "chip": "Rest of the chip besides the processor cores: memory controller, Neural Engine, media engines, interconnect",
        "other": "SSD, Wi-Fi, Bluetooth, ports, keyboard light, power supply losses = whole Mac − chip − display",
        "sleep": "Whole Mac while asleep, incl. short wake-ups: measured by macOS's power counter, which keeps running in sleep",
    ]
}

/// Hidden AppleCLPC "Energy Counters" (CPU, GPU, Neural Engine, memory, memory controller, chip package),
/// readable without admin rights on macOS 27, where the documented IOReport CPU counters stopped updating.
/// Based on macmon by vladkens (MIT licence, see THIRD-PARTY-NOTICES.md): the counter IDs are from its clpc.rs.
final class CLPCEnergy: @unchecked Sendable {   // only used on LiveBreakdown's serial queue
    struct Watts { var cpu, gpu, ane, dram, dcs, package: Double }

    /// macOS 27 counter IDs per chip driver: (cpu, gpu, ane, dram, dcs, package) keys.
    /// Taken from macmon's src/clpc.rs (generated there from macOS 27.2) — all 17 chip drivers it knows.
    private static let keys: [String: [UInt32]] = [
        "com.apple.driver.AppleT6000CLPCv3": [0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8, 0xd6ca_0cfb, 0x05ca_c729, 0x3c7a_f4b5],
        "com.apple.driver.AppleT6002CLPC": [0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574, 0x7670_4b08, 0x2d7b_7fb2, 0xe16c_1380],
        "com.apple.driver.AppleT6020CLPC": [0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f, 0x2624_4bb6, 0x5f31_a20f, 0x9877_104c],
        "com.apple.driver.AppleT6022CLPC": [0x76f5_fd21, 0x9062_4499, 0x3c09_7307, 0xe8f2_ddf9, 0xfa86_5a91, 0xef56_ddf3],
        "com.apple.driver.AppleT6030CLPC": [0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38, 0x2380_9c0f, 0xb594_4c6a, 0xd9ac_8450],
        "com.apple.driver.AppleT6031CLPC": [0xd81e_0084, 0x1085_f98b, 0x313a_3be1, 0x65ff_699d, 0x10cb_1f6a, 0xfc3f_ce99],
        "com.apple.driver.AppleT6032CLPC": [0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25, 0x63dc_aae5, 0x8cc1_3c13, 0xfaa8_ecc3],
        "com.apple.driver.AppleT6041CLPC": [0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c, 0xfe93_2624, 0x8fc8_575c, 0xf708_48a3],
        "com.apple.driver.AppleT6050CLPC": [0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59, 0xf3c8_1737, 0x3d89_affa, 0x958c_fda5],
        "com.apple.driver.AppleT6050dCLPC": [0x18b3_010e, 0xedec_a11a, 0x188b_d883, 0xa331_96f9, 0x0b3c_717e, 0x9ee7_9a95],
        "com.apple.driver.AppleT8103CLPCv3": [0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81, 0xc0c2_0839, 0x31d3_e1e7, 0xd685_8d06],
        "com.apple.driver.AppleT8112CLPC": [0xb543_5137, 0x638d_9d52, 0xea08_9c36, 0x8b6e_0faa, 0x9a6e_145a, 0x824b_cad4],
        "com.apple.driver.AppleT8122CLPC": [0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f, 0x0b96_41d3, 0x0d80_2b66, 0x9709_cb31],
        "com.apple.driver.AppleT8132CLPC": [0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec, 0x9a44_d225, 0xe340_48d2, 0x6ab9_90d0],
        "com.apple.driver.AppleT8140CLPC": [0x9bf5_4436, 0xef70_589c, 0x569d_941b, 0x035f_5005, 0x5344_2391, 0x7f14_616c],
        "com.apple.driver.AppleT8142CLPC": [0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0, 0xe136_33aa, 0x2b8d_7fec, 0xa65a_b9a8],
        "com.apple.driver.AppleT8152CLPC": [0x485d_4bfc, 0x1178_4654, 0x9380_c6bb, 0xe17c_13bf, 0x4e80_dc41, 0xf6ed_063b],
    ]
    private static let indices: [UInt64] = [16, 25, 24, 26, 27, 9]
    private static let names = ["cpu", "gpu", "ane", "dram", "dcs", "package"]

    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StrGet = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntGet = @convention(c) (CFDictionary, Int32) -> Int64

    private var sub: OpaquePointer?
    private var subbed: CFMutableDictionary?
    private var samples: CreateSamples?, delta: Delta?, name: StrGet?, value: IntGet?
    private var last: (CFDictionary, Date)?
    private(set) var available = false

    init() {
        let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard !TestSwitch.noCLPC else { return }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleCLPC"))
        guard os == 27, svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var driver: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(svc, &driver)
        guard let bundle = IORegistryEntryCreateCFProperty(svc, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
              let ids = Self.keys[bundle],
              let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }

        let type: Int64 = 1 | (2 << 16) | (1 << 32)      // simple integer, power category, one element
        let unit: Int64 = (3 << 56) | (118 << 32)        // nanojoules
        let channels = NSMutableArray()
        for (i, key) in ids.enumerated() {
            let id = (Self.indices[i] << 32) | UInt64(key)
            channels.add(NSMutableDictionary(dictionary: [
                "DriverID": NSNumber(value: Int64(bitPattern: driver)), "DriverName": "AppleCLPC",
                "IOReportGroupName": "CLPC", "IOReportSubGroupName": "Energy Counters",
                "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: unit)],
                "LegendChannel": [NSNumber(value: Int64(bitPattern: id)), NSNumber(value: type), Self.names[i]],
            ]))
        }
        let request = NSMutableDictionary(dictionary: ["IOReportChannels": channels])
        guard let create = sym("IOReportCreateSubscription", CreateSub.self) else { return }
        var out: Unmanaged<CFMutableDictionary>?
        sub = create(nil, request as CFMutableDictionary, &out, 0, nil)
        subbed = out?.takeRetainedValue()
        samples = sym("IOReportCreateSamples", CreateSamples.self)
        delta = sym("IOReportCreateSamplesDelta", Delta.self)
        name = sym("IOReportChannelGetChannelName", StrGet.self)
        value = sym("IOReportSimpleGetIntegerValue", IntGet.self)
        available = sub != nil && subbed != nil && samples != nil && delta != nil && name != nil && value != nil
    }

    func reset() { last = nil }

    /// Average power of each part since the previous call (nil on the first call, if unavailable,
    /// or when a counter jumps to an impossible value — they sometimes catch up in one step).
    func watts() -> Watts? {
        guard available, let sub, let subbed, let samples, let delta, let name, let value,
              let cur = samples(sub, subbed, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { last = (cur, now) }
        guard let (prev, t0) = last, now.timeIntervalSince(t0) > 0.2,
              let d = delta(prev, cur, nil)?.takeRetainedValue() as NSDictionary? else { return nil }
        let dt = now.timeIntervalSince(t0)
        var w: [String: Double] = [:]
        for item in (d["IOReportChannels"] as? [NSDictionary]) ?? [] {
            let c = item as CFDictionary
            guard let n = name(c)?.takeUnretainedValue() as String? else { continue }
            w[n] = Double(value(c, 0)) / 1e9 / dt
        }
        guard let cpu = w["cpu"], let gpu = w["gpu"], let pkg = w["package"],
              w.values.allSatisfy({ $0 >= 0 && $0 < 300 }) else { return nil }
        return Watts(cpu: cpu, gpu: gpu, ane: w["ane"] ?? 0, dram: w["dram"] ?? 0, dcs: w["dcs"] ?? 0, package: pkg)
    }
}

/// Pinned breakdown shown above the apps table (live and history), one line per part, largest first.
/// Not affected by the table's sorting or filtering. The whole-Mac total is shown elsewhere (chart / tile).
struct BreakdownStrip: View {
    let breakdown: Breakdown
    let unit: String              // "W" live, "Wh" for a period
    var hours: Double? = nil      // period length, to show average watts

    var body: some View {
        let parts = breakdown.parts.sorted { $0.value > $1.value }
        let whole = max(breakdown.whole, 1e-9)
        let top = max(parts.first?.value ?? 0, 1e-9)
        let pct = Self.roundedPercents(parts.map { $0.value / whole * 100 })
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 8) {
                    Image(systemName: p.icon).foregroundStyle(p.color).frame(width: 18)
                    // Only the name has a tooltip (the full explanation); normal colour here (blue only in tables and hints).
                    Text(p.name).lineLimit(1)
                        .tip(breakdown.help(p.id))
                        .frame(width: 230, alignment: .leading)
                    Text(breakdown.help(p.id)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    Capsule().fill(p.color.gradient)
                        .frame(width: max(2, 120 * p.value / top), height: 6)
                        .frame(width: 120, alignment: .leading)
                    Text("\(pct[i])%")
                        .foregroundStyle(.secondary).monospacedDigit().frame(width: 40, alignment: .trailing)
                    Text("\(fmt(p.value)) \(unit)").monospacedDigit().fontWeight(.semibold)
                        .frame(width: 90, alignment: .trailing)
                    if unit == "Wh", hours != nil || breakdown.awakeH != nil {   // same column in every row
                        Text(avgHours(p.id).flatMap { h in h > 0 ? "avg \((p.value / h).formatted(.number.precision(.fractionLength(2)))) W" : nil } ?? "")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Sleep: per hour asleep; everything else: per hour awake (or the whole period for old summaries).
    private func avgHours(_ id: String) -> Double? {
        // The parts also hold the energy of days without sleep data, so their hours count here too.
        id == "sleep" ? breakdown.sleepH : breakdown.awakeH.map { $0 + (breakdown.unknownH ?? 0) } ?? hours
    }

    /// History (Wh): always one decimal, so all rows line up; live (W): two below 10 W.
    private func fmt(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(unit == "Wh" || v >= 10 ? 1 : 2)))
    }

    /// Whole-number percentages that add up to the rounded total (100 when the parts make up the whole):
    /// round everything down, then give the missing points to the largest remainders.
    static func roundedPercents(_ exact: [Double]) -> [Int] {
        let e = exact.map { max(0, $0) }
        var r = e.map { Int($0.rounded(.down)) }
        var missing = Int(e.reduce(0, +).rounded()) - r.reduce(0, +)
        for i in e.indices.sorted(by: { e[$0] - Double(r[$0]) > e[$1] - Double(r[$1]) }) where missing > 0 {
            r[i] += 1; missing -= 1
        }
        return r
    }
}

struct TintedIcon: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.foregroundStyle(color); configuration.title }
    }
}

/// One section of the "How these numbers are measured" explanation.
struct InfoSection: Identifiable {
    let title: String
    let points: [String]
    var id: String { title }
}

/// Which explanation is open (one at a time, shown by InfoPanel over the whole window).
@MainActor
final class InfoPanelState: ObservableObject {
    static let shared = InfoPanelState()
    @Published var sections: [InfoSection]?
    private init() {
        // Switching to another app closes it too.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { InfoPanelState.shared.sections = nil }
        }
    }
}

/// "How these numbers are measured": a small link that opens the explanation.
struct InfoNote: View {
    let sections: [InfoSection]
    var body: some View {
        HStack {
            Button { InfoPanelState.shared.sections = sections } label: {
                Label("How these numbers are measured", systemImage: "info.circle").font(.caption)
            }
            .buttonStyle(.link)
            .help("Click to see where these numbers come from and how they are calculated")
            Spacer()
            VersionLink().font(.caption)
            SupportLink().font(.caption).padding(.leading, 12)
        }
    }
}

/// Optional "buy me a coffee" link (the app is free; this only opens the page in the browser).
struct SupportLink: View {
    static let url = URL(string: "https://buymeacoffee.com/vankov1976")!
    var iconOnly = false
    var body: some View {
        Link(destination: Self.url) {
            if iconOnly { Image(systemName: "cup.and.saucer") }
            else { Label("Buy me a coffee", systemImage: "cup.and.saucer") }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Buy me a coffee")
        .help("Mac Energy Monitor is free. If you'd like to say thanks, you can buy the developer a coffee (opens buymeacoffee.com).")
    }
}

/// The explanation as a panel inside the window over a dimmed background:
/// a click anywhere outside the panel, Escape or switching apps closes it.
struct InfoPanel: View {
    @ObservedObject var state = InfoPanelState.shared
    var body: some View {
        if let sections = state.sections {
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { state.sections = nil }
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("How these numbers are measured").font(.title3.weight(.semibold))
                        Spacer()
                        Button { state.sections = nil } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Close (Esc)").accessibilityLabel("Close")
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.bottom, 10)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(sections) { sec in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(sec.title).font(.headline)
                                    ForEach(sec.points, id: \.self) { p in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text("•").foregroundStyle(.secondary)
                                            Text(p).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
                .frame(maxWidth: 560, maxHeight: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 20)
                .padding(24)          // always a margin to the window edges
                .onTapGesture { }     // clicks inside the panel don't close it
            }
        }
    }
}

enum Explanations {
    static let history: [InfoSection] = [
        InfoSection(title: "Where the numbers come from", points: [
            "CPU, GPU, memory and the other chip parts: energy counters that macOS writes into its power log about every 30 minutes.",
            "Whole Mac: the system load macOS logs about every minute. Only time while the Mac is awake counts.",
            "Display: screen-on time × average backlight power, worked out per day. This part is an estimate.",
            "Other hardware: whole Mac − chip − display (SSD, Wi-Fi, ports, keyboard light, power-supply losses).",
            "Sleep: macOS's whole-Mac power counter keeps running while the Mac sleeps, so the energy of each sleep (including short wake-ups for background tasks) is measured. A sleep of 30 minutes or more on battery is measured from the battery's own charge before and after (mAh × volts), because on some Macs the counter counts too little while asleep. Where neither works (e.g. the counter restarted after a shutdown), an estimate from this Mac's other sleeps is used. Switched off counts as 0.",
        ]),
        InfoSection(title: "User apps/services and system processes", points: [
            "The table lists the apps and services you run. Their energy is processor + graphics, as recorded by macOS.",
            "So the table can add up to more than \"CPU · user apps/services\", which is processor only; the apps' graphics energy is in the GPU row.",
            "Share = an app's energy ÷ the whole Mac's energy in the period, as in Live.",
            "macOS's own processes (WindowServer, kernel, system services) are counted in \"CPU · system processes\".",
        ]),
        InfoSection(title: "Times", points: [
            "Avg. power = the whole Mac's energy while awake ÷ the time awake. A sleep lasts from closing the lid (or idle sleep) until you wake the Mac, taken from macOS's sleep log (pmset, about a week); short background wake-ups in between (Power Nap, network, a moment's wake when the charger is plugged in) count as sleep, exactly as in \"Sleep only\". Time without whole-Mac records that the sleep log doesn't show as sleep counts as awake; a restart in between counts as switched off. For days older than the sleep log, the time without whole-Mac records counts as sleep.",
            "The breakdown's \"avg\" values are per hour awake; Sleep's is per hour asleep.",
            "Avg. power in the table = energy ÷ running time. Running time counts only while the Mac is awake.",
            "CPU time is added up over all processor cores, so it can be longer than the period.",
            "Screen time per app comes from Mac Energy Monitor's own record of the app in front (macOS's log for times the app wasn't running).",
        ]),
        InfoSection(title: "How far back", points: [
            "macOS keeps its power logs for about 10 days.",
            "Mac Energy Monitor saves a small summary of every finished day (in ~/Library/Application Support/MacEnergyMonitor/Daily), so older days come from those summaries.",
            "The newest minutes aren't split into parts by macOS yet; their split follows the time just before.",
        ]),
    ]

    static let sleep: [InfoSection] = [
        InfoSection(title: "What counts as a sleep", points: [
            "From the moment the Mac goes to sleep (lid closed, idle, Apple menu) until you wake it. Short wake-ups in the background in between belong to the sleep.",
            "Sleep times, wake-ups and their reasons come from macOS's sleep log (pmset), which keeps about a week. Older periods show only what's still there.",
        ]),
        InfoSection(title: "Energy", points: [
            "macOS's whole-Mac power counter keeps running while the Mac sleeps, so each sleep's energy is measured, including its wake-ups. A sleep of 30 minutes or more on battery is measured from the battery's own charge before and after (some Macs' counter counts too little while asleep); the same rule is used in the history's Sleep row.",
            "A sleep is marked with a blue ⚠ when its average power is more than twice this Mac's usual sleep power (median of its sleeps of 30 minutes or more, separately on battery and on the charger).",
            "The Power and Minimum energy filters apply to the Sleeps tab.",
        ]),
        InfoSection(title: "Wake-ups", points: [
            "Grouped by macOS's reason: you (lid, keyboard, trackpad), Wi-Fi or Bluetooth (network activity and nearby devices, which macOS reports together), a timer set by macOS (Power Nap, maintenance), the power adapter, other.",
            "\"Planned\" is the wake macOS had scheduled for that moment and what asked for it.",
            "macOS's technical names (processes, wake reasons, settings) are shown in plain words. Hover over a blue name to see the original.",
        ]),
        InfoSection(title: "Didn't sleep", points: [
            "The lid was closed for more than 10 minutes, or the display was off for more than 30 minutes, and the Mac stayed awake (above sleep-level power).",
            "\"Kept awake by\" lists the apps and services that held a sleep blocker (a power assertion) during that time. macOS's own power management is shown last.",
        ]),
        InfoSection(title: "Hints", points: [
            "Based on this period's numbers and this Mac's sleep settings (pmset), read only. Mac Energy Monitor never changes settings.",
        ]),
    ]

    static let live: [InfoSection] = [
        InfoSection(title: "How often", points: [
            "At the update interval you choose (1–10 seconds), without admin rights.",
            "The table shows each app's power averaged over the last few seconds, so the list stays steady.",
        ]),
        InfoSection(title: "Where the numbers come from", points: [
            "User apps/services: each app's processor energy from macOS's per-process counters. An app's graphics energy is in the GPU row.",
            "CPU, GPU, memory and the other chip parts: the chip's own energy counters (method from the open-source tool macmon, MIT licence).",
            "Display and whole Mac: sensors of the Mac's system management controller.",
        ]),
        InfoSection(title: "Calculated parts", points: [
            "CPU · system processes = CPU − user apps/services. macOS's own processes can only be read one by one with admin rights.",
            "Share = an app's power ÷ the whole Mac's power.",
            "Other hardware = whole Mac − chip − display.",
        ]),
    ]
}

/// Test switches (environment variable MEM_FORCE, comma-separated) to try the fallback paths on one Mac:
/// "noclpc" = as on a chip macmon's table doesn't know, "legacy" = as on macOS 14–26 (implies noclpc),
/// "nosmc" = as if the Mac had none of the SMC sensors used here.
enum TestSwitch {
    static let flags = Set((ProcessInfo.processInfo.environment["MEM_FORCE"] ?? "").split(separator: ",").map(String.init))
    static let legacy = flags.contains("legacy")
    static let noCLPC = legacy || flags.contains("noclpc")
    static let noSMC = flags.contains("nosmc")
    /// "nopause": keep live sampling while the window is hidden (for memory tests with the screen locked).
    static let noPause = flags.contains("nopause")
}
