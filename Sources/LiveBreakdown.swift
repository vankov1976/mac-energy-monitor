import AppKit
import Darwin
import SwiftUI

/// One row of the live breakdown: an app (all its processes together), a background process, or a hardware part.
struct LiveRow: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String          // "App", "Background", "Hardware"
    let appPath: String?
    let watts: Double
    var share: Double         // % of the whole Mac
}

/// Live split of the whole Mac's power, every second, without admin rights (see `Breakdown`):
/// display (SMC PDBR), CPU / GPU / memory / chip package (hidden CLPC counters, see `CLPCEnergy`),
/// your apps (each process's own energy counter) and the whole Mac (SMC PSTR).
/// macOS's own processes are not listed one by one: their CPU share is CPU − your apps.
/// Sampling only runs while someone is looking (the window's Live view or the menu bar panel).
@MainActor
final class LiveBreakdown: ObservableObject {
    static let shared = LiveBreakdown()

    // Only `breakdown` is @Published and it is set last, so each reading refreshes views once.
    private(set) var rows: [LiveRow] = []        // your apps and background services only
    @Published private(set) var breakdown = Breakdown()
    private(set) var readable = 0
    private(set) var unreadable = 0
    var ready: Bool { !rows.isEmpty || breakdown.total != nil }


    private var viewers = 0
    private var timer: Timer?
    private let queue = DispatchQueue(label: "live-breakdown")
    private let sampler = ProcessSampler()
    private let clpc = CLPCEnergy()
    private let model = EnergyModel()
    /// The documented CPU counters only update before macOS 27.
    private let modelHasCPU = TestSwitch.legacy || ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    /// Last few seconds of per-app power, so the table lists every app active recently (not only this second).
    private var recent: [[String: LiveRow]] = []
    /// The table averages over at least the last 5 seconds.
    static var tableWindow: Int { max(1, Int((5 / LiveSettings.shared.interval).rounded(.up))) }
    static var tableSeconds: Int { Int(Double(tableWindow) * LiveSettings.shared.interval) }

    func start() {
        viewers += 1
        guard timer == nil else { return }
        tick()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: LiveSettings.shared.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = LiveSettings.shared.interval * 0.1   // lets macOS group wake-ups (values use the real elapsed time)
    }

    /// New interval chosen: restart the timer if sampling is running.
    func reschedule() {
        guard timer != nil else { return }
        recent = []
        schedule()
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate(); timer = nil
        recent = []
        queue.async { [sampler, clpc, model] in sampler.reset(); clpc.reset(); model.reset() }
    }

    private func tick() {
        let total = LivePower.shared.current
        let display = SMC.shared.float("PDBR").flatMap { $0 >= 0 && $0 < 100 ? $0 : nil }
        let psvc = SMC.shared.float("PSVC").flatMap { $0 >= 0 && $0 < 300 ? $0 : nil }
        let modelHasCPU = self.modelHasCPU
        queue.async { [sampler, clpc, model] in
            let s = sampler.sample()
            let c = clpc.watts()
            let m = clpc.available ? nil : model.watts()
            let fallback = !clpc.available
            DispatchQueue.main.async {
                self.publish(s, total: total, display: display, clpc: c, model: m, modelHasCPU: modelHasCPU,
                             psvc: psvc, fallback: fallback)
            }
        }
    }

    private func publish(_ s: ProcessSampler.Result, total: Double?, display: Double?,
                         clpc: CLPCEnergy.Watts?, model: EnergyModel.Watts?, modelHasCPU: Bool,
                         psvc: Double?, fallback: Bool) {
        readable = s.readable; unreadable = s.unreadable
        guard s.ready else { return }                 // first round only sets the baseline
        if !fallback && clpc == nil { return }        // counter hiccup: keep the previous values
        let mine = s.groups.filter { $0.kind != "System" }
        var b = Breakdown()
        b.display = display
        b.apps = mine.reduce(0) { $0 + $1.watts }
        if let c = clpc {                              // macOS 27 on a chip macmon's table knows
            b.cpu = c.cpu; b.gpu = c.gpu; b.memory = c.dram; b.chip = c.package
        } else if modelHasCPU, let m = model, let cpu = m.cpu, cpu > 0.01 {   // macOS 14–26: documented counters
            // (a counter that reports nothing — frozen, as on macOS 27 — is not trusted: combined fallback below)
            b.cpu = cpu; b.gpu = m.gpu; b.memory = m.dram; b.chip = psvc
        } else {                                       // macOS 27 on an unknown chip: no separate CPU
            b.gpu = model?.gpu; b.chip = psvc
        }
        b.total = total
        let whole = max(b.whole, 1e-9)
        recent.append(Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        if recent.count > Self.tableWindow { recent.removeFirst(recent.count - Self.tableWindow) }
        var avg: [String: LiveRow] = [:]
        for snap in recent {
            for (id, r) in snap {
                var a = avg[id] ?? LiveRow(id: id, name: r.name, kind: r.kind, appPath: r.appPath, watts: 0, share: 0)
                a = LiveRow(id: id, name: a.name, kind: a.kind, appPath: a.appPath,
                            watts: a.watts + r.watts / Double(recent.count), share: 0)
                avg[id] = a
            }
        }
        rows = avg.values.map { var r = $0; r.share = r.watts / whole * 100; return r }
        breakdown = b
    }
}

/// CPU, GPU and memory energy from the documented IOReport "Energy Model" group (no admin rights needed).
/// On macOS 14–26 all three update; on macOS 27 only the GPU counter does (the CPU counters stay frozen),
/// so there the CPU comes from CLPCEnergy instead.
final class EnergyModel: @unchecked Sendable {   // only used on LiveBreakdown's serial queue
    struct Watts { var cpu: Double?, gpu: Double?, dram: Double? }

    private typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StrGet = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntGet = @convention(c) (CFDictionary, Int32) -> Int64

    private var sub: OpaquePointer?
    private var subbed: CFMutableDictionary?
    private var samples: CreateSamples?
    private var name: StrGet?, unit: StrGet?
    private var value: IntGet?
    private var last: ([String: Double], Date)?

    init() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyGroup.self),
              let create = sym("IOReportCreateSubscription", CreateSub.self),
              let ch = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        var out: Unmanaged<CFMutableDictionary>?
        sub = create(nil, ch, &out, 0, nil)
        subbed = out?.takeRetainedValue()
        samples = sym("IOReportCreateSamples", CreateSamples.self)
        name = sym("IOReportChannelGetChannelName", StrGet.self)
        unit = sym("IOReportChannelGetUnitLabel", StrGet.self)
        value = sym("IOReportSimpleGetIntegerValue", IntGet.self)
    }

    func reset() { last = nil }

    /// Average power since the previous call, per part, in watts (nil on the first call or if unavailable).
    func watts() -> Watts? {
        guard let sub, let subbed, let samples, let name, let unit, let value,
              let snap = samples(sub, subbed, nil)?.takeRetainedValue() as NSDictionary? else { return nil }
        var joules: [String: Double] = [:]          // cumulative joules per channel name
        for item in (snap["IOReportChannels"] as? [NSDictionary]) ?? [] {
            let d = item as CFDictionary
            guard let n = name(d)?.takeUnretainedValue() as String? else { continue }
            let u = (unit(d)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
            guard let scale = ["nJ": 1e-9, "uJ": 1e-6, "mJ": 1e-3][u] else { continue }
            joules[n, default: 0] += Double(value(d, 0)) * scale
        }
        let now = Date()
        defer { last = (joules, now) }
        guard let (j0, t0) = last, now.timeIntervalSince(t0) > 0.2 else { return nil }
        let dt = now.timeIntervalSince(t0)
        func w(_ keys: [String]) -> Double? {
            let present = keys.filter { joules[$0] != nil && j0[$0] != nil }
            guard !present.isEmpty else { return nil }
            let d = present.reduce(0) { $0 + joules[$1]! - j0[$1]! }
            return d >= 0 && d / dt < 300 ? d / dt : nil
        }
        // Memory: the aggregate channel if there is one, otherwise the per-controller channels (DRAM0, DRAM1 …).
        let dramParts = joules.keys.filter { $0.hasPrefix("DRAM") && $0.dropFirst(4).allSatisfy(\.isNumber) && $0.count > 4 }
        let dram = w(["DRAM Energy"]) ?? w(dramParts.sorted()) ?? w(["DRAM"])
        return Watts(cpu: w(["CPU Energy"]), gpu: w(["GPU Energy"]), dram: dram)
    }
}

/// Reads every process's cumulative energy counter (rusage v6, nanojoules) and turns the change since
/// the last call into watts, grouped by app bundle. Processes owned by other users (root) can't be read.
final class ProcessSampler: @unchecked Sendable {   // only used on LiveBreakdown's serial queue
    struct Result { var ready = false; var groups: [LiveRow] = []; var readable = 0; var unreadable = 0 }
    private struct Info { let id: String; let name: String; let kind: String; let appPath: String? }

    private var last: [pid_t: UInt64] = [:]
    private var lastTime: Date?
    /// What doesn't change while a process runs: executable path, start time, coalition.
    private struct Proc { let path: String; let start: Double?; let coalition: UInt64? }
    private var procs: [pid_t: Proc] = [:]
    private var infoByPath: [String: Info] = [:]

    func reset() { last = [:]; lastTime = nil; procs = [:]; infoByPath = [:] }

    func sample() -> Result {
        let now = Date()
        var current: [pid_t: UInt64] = [:]
        var r = Result()
        for pid in Self.allPids() where pid > 0 {
            if let e = Self.energy(pid) { current[pid] = e; r.readable += 1 } else { r.unreadable += 1 }
        }
        defer { last = current; lastTime = now; procs = procs.filter { current[$0.key] != nil } }
        guard let t0 = lastTime else { return r }
        let dt = now.timeIntervalSince(t0)
        guard dt > 0.2 else { return r }

        // Group like macOS's power log (and so like the history views): by coalition, the group of processes
        // an app started (helpers, XPC services, command-line tools such as Claude Code's). The group is named
        // after its app that started first, e.g. Claude, not the Claude Code it launched.
        for pid in current.keys where procs[pid] == nil { procs[pid] = Self.proc(pid) }
        var leaders: [UInt64: (start: Double, path: String)] = [:]
        for p in procs.values where p.path.contains(".app/") {
            guard let c = p.coalition, let st = p.start else { continue }
            if let l = leaders[c], l.start <= st { continue }
            leaders[c] = (st, p.path)
        }

        var byGroup: [String: (Info, Double)] = [:]
        for (pid, e) in current {
            // A process started since the last reading: its counter began at 0, so all of it falls in this interval.
            // (One that existed before but couldn't be read then has no known start value: baseline only.)
            let e0: UInt64
            if let l = last[pid] { e0 = l }
            else if let born = Self.startTime(pid), born >= t0.timeIntervalSince1970 { e0 = 0 }
            else { continue }
            guard e >= e0 else { continue }
            let w = Double(e - e0) / 1e9 / dt
            guard w > 0 else { continue }
            let p = procs[pid]
            // Without a coalition app: the app macOS holds responsible (e.g. Safari for its web pages, which run
            // from WebKit's folder), else the process's own path.
            let resp = Self.responsible(pid).map(Self.path) ?? ""
            let path = p?.coalition.flatMap { leaders[$0]?.path }
                ?? (resp.contains(".app/") ? resp : (p?.path ?? Self.path(pid)))
            let i = infoByPath[path] ?? describe(path, pid)
            if path.contains(".app/") { infoByPath[path] = i }     // names of plain tools come from the pid
            byGroup[i.id, default: (i, 0)].1 += w
        }
        r.groups = byGroup.values.map { LiveRow(id: $0.0.id, name: $0.0.name, kind: $0.0.kind,
                                                appPath: $0.0.appPath, watts: $0.1, share: 0) }
        r.ready = true
        return r
    }

    /// The row for a group: the outermost ".app" in `path` (the group's app), else the tool itself.
    private func describe(_ path: String, _ pid: pid_t) -> Info {
        if let r = path.range(of: ".app/") {
            let app = String(path[..<r.lowerBound]) + ".app"
            let name = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
            // Apps you open (also Apple's in /System/Applications, and Safari, which runs from
            // /System/Volumes/Preboot/Cryptexes/App/System/Applications) vs. macOS's own helper apps.
            let rel = app.hasPrefix(Self.cryptex) ? String(app.dropFirst(Self.cryptex.count)) : app
            let mine = !rel.hasPrefix("/System/") || rel.hasPrefix("/System/Applications/")
            return Info(id: app, name: name, kind: mine ? "App" : "System", appPath: app)
        }
        var nb = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nb, 256)
        let name = String(cString: nb).isEmpty ? (path as NSString).lastPathComponent : String(cString: nb)
        let system = path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/")
            || path.hasPrefix("/sbin/") || path.isEmpty
        return Info(id: path.isEmpty ? "pid:\(name)" : path, name: name.isEmpty ? "pid \(pid)" : name,
                    kind: system ? "System" : "Background", appPath: nil)
    }

    private static func proc(_ pid: pid_t) -> Proc {
        Proc(path: path(pid), start: startTime(pid), coalition: coalition(pid))
    }

    /// The process's resource coalition (PROC_PIDCOALITIONINFO = 20 in the kernel's proc_info.h; not in the
    /// public SDK headers): the same grouping macOS's power log uses for its per-app energy.
    private static func coalition(_ pid: pid_t) -> UInt64? {
        var ids = [UInt64](repeating: 0, count: 5)          // coalition_id[2] (resource, jetsam) + 3 reserved
        let n = ids.withUnsafeMutableBytes { proc_pidinfo(pid, 20, 0, $0.baseAddress, 40) }
        return n == 40 && ids[0] != 0 ? ids[0] : nil
    }

    /// When the process started (Unix seconds), or nil if it can't be read.
    private static func startTime(_ pid: pid_t) -> Double? {
        var bi = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
        return Double(bi.pbi_start_tvsec) + Double(bi.pbi_start_tvusec) / 1e6
    }

    private static let cryptex = "/System/Volumes/Preboot/Cryptexes/App"

    private static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    /// The process macOS holds responsible for `pid` (what Activity Monitor groups by), if another one.
    /// The function is not in the public headers, so it is looked up at run time; missing → no grouping.
    private static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsible(_ pid: pid_t) -> pid_t? {
        guard let f = responsibleFn else { return nil }
        let r = f(pid)
        return r > 0 && r != pid ? r : nil
    }

    private static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var a = [pid_t](repeating: 0, count: Int(n) + 64)
        let c = proc_listallpids(&a, Int32(a.count * MemoryLayout<pid_t>.size))
        return Array(a.prefix(Int(max(0, c))))
    }

    private static func energy(_ pid: pid_t) -> UInt64? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return rc == 0 ? ri.ri_energy_nj : nil
    }
}

/// Live view for the main window: pinned breakdown above, your apps below (sortable and filterable).
/// The app list is a plain SwiftUI list, not `Table`: Apple's table leaks memory on every update
/// (about 30 MB an hour at one update per second, found Nov 2026 with malloc stack logging).
struct LiveTableView: View {
    @ObservedObject var live = LiveBreakdown.shared
    @ObservedObject var settings = LiveSettings.shared
    let search: String
    @Binding var kind: String
    @State private var sortKey = SortKey.watts
    @State private var ascending = false
    /// Sampling runs only while the window can be seen (not covered, minimized or behind the lock screen).
    @State private var sampling = false

    enum SortKey { case name, kind, share, watts }

    // Column widths (the name column takes the rest).
    private static let typeW: CGFloat = 90, shareW: CGFloat = 150, powerW: CGFloat = 120

    private var rows: [LiveRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = live.rows.filter { r in
            (q.isEmpty || r.name.lowercased().contains(q) || r.id.lowercased().contains(q)) &&
            (kind == "All" || r.kind == kind) && r.watts > 0
        }
        let sorted: [LiveRow]
        switch sortKey {
        case .name: sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .kind: sorted = list.sorted { $0.kind < $1.kind }
        case .share: sorted = list.sorted { $0.share < $1.share }
        case .watts: sorted = list.sorted { $0.watts < $1.watts }
        }
        return ascending ? sorted : sorted.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BreakdownStrip(breakdown: live.breakdown, unit: "W")
            HStack {
                Text("User apps/services · live").font(.headline)
                Picker("Type", selection: $kind) {
                    ForEach(["All", "App", "Background"], id: \.self) { Text($0) }
                }.frame(width: 170).padding(.leading, 12)
                Spacer()
                Text("\(rows.count) active · power averaged over the last \(LiveBreakdown.tableSeconds) s").font(.caption).foregroundStyle(.secondary)
                LiveIntervalPicker().frame(width: 170)
            }
            if !live.ready {
                ProgressView("Measuring…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                                row(r).background(i % 2 == 1 ? Color.primary.opacity(0.04) : .clear)
                            }
                        }
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .frame(minHeight: 110)
            }
            InfoNote(sections: Explanations.live)
        }
        .onAppear { updateSampling() }
        .onDisappear { setSampling(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            updateSampling()
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerCell("User app/service", .name, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            headerCell("Type", .kind, alignment: .leading).frame(width: Self.typeW, alignment: .leading)
            headerCell("Share of whole Mac", .share, alignment: .leading).frame(width: Self.shareW, alignment: .leading)
            headerCell("Power now (W)", .watts, alignment: .trailing).frame(width: Self.powerW, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    /// Click a column title to sort by it; click again to reverse.
    private func headerCell(_ title: String, _ key: SortKey, alignment: HorizontalAlignment) -> some View {
        Button {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = key == .name || key == .kind }
        } label: {
            HStack(spacing: 3) {
                Text(title).fontWeight(sortKey == key ? .semibold : .regular)
                if sortKey == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sortKey == key ? .primary : .secondary)
        .accessibilityLabel("Sort by " + title)
        .accessibilityValue(sortKey == key ? (ascending ? "ascending" : "descending") : "")
        .accessibilityAddTraits(sortKey == key ? .isSelected : [])
    }

    private func row(_ r: LiveRow) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                AppIcon(path: r.appPath)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name).lineLimit(1)
                    Text(r.id).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.kind).foregroundStyle(.secondary).lineLimit(1).frame(width: Self.typeW, alignment: .leading)
            HStack(spacing: 6) {
                Capsule().fill(.tint).frame(width: max(2, min(60, r.share * 3)), height: 5)
                Text(fmt(r.share, 1) + "%").monospacedDigit()
            }
            .frame(width: Self.shareW, alignment: .leading)
            Text(r.watts < 0.0005 ? "< 0.001" : fmt(r.watts, r.watts < 1 ? 3 : 2)).monospacedDigit()
                .lineLimit(1).frame(width: Self.powerW, alignment: .trailing)
        }
        .frame(height: 32)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func updateSampling() {
        let w = NSApp.windows.first(where: StatusBarController.isMainWindow)
        setSampling(TestSwitch.noPause || (w?.occlusionState.contains(.visible) ?? true))
    }

    private func setSampling(_ on: Bool) {
        guard on != sampling else { return }
        sampling = on
        if on { live.start() } else { live.stop() }
    }
}
