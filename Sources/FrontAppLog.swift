import AppKit
import Foundation

/// The app's own record of which app is in front, because macOS's front-app log is unreliable
/// (it sometimes logs nothing for hours). Kept in
/// ~/Library/Application Support/MacEnergyMonitor/frontapps.tsv as "time<TAB>bundle id" lines:
/// an empty id means no app is in use (screen locked, display asleep, Mac asleep or this app quit),
/// "#alive" lines (every 5 minutes) show the record is running. Entries older than 60 days are dropped.
final class FrontAppLog: @unchecked Sendable {
    static let shared = FrontAppLog()
    let file: URL
    private let lock = NSLock()
    private var timer: Timer?
    static let aliveEvery: TimeInterval = 300

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacEnergyMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("frontapps.tsv")
    }

    // MARK: recording (main thread)

    // While the display is asleep or the screen is locked, nobody is using an app: switches macOS makes then
    // (the lock screen "loginwindow" comes to the front) are ignored until the Mac is awake *and* unlocked.
    @MainActor private var displayAsleep = false
    @MainActor private var locked = false
    @MainActor private var paused: Bool { displayAsleep || locked }

    @MainActor func start() {
        prune()
        recordFrontmost()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard !FrontAppLog.shared.paused else { return }
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                FrontAppLog.shared.record(Self.id(app))
            }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FrontAppLog.shared.displayAsleep = true; FrontAppLog.shared.record("") }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    FrontAppLog.shared.displayAsleep = false
                    if !FrontAppLog.shared.paused { FrontAppLog.shared.recordFrontmost() }
                }
            }
        }
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FrontAppLog.shared.locked = true; FrontAppLog.shared.record("") }
        }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                FrontAppLog.shared.locked = false
                if !FrontAppLog.shared.paused { FrontAppLog.shared.recordFrontmost() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.aliveEvery, repeats: true) { _ in
            FrontAppLog.shared.record("#alive")
        }
        timer?.tolerance = Self.aliveEvery * 0.1
    }

    /// Called when the app quits: from now on nothing is known.
    func stop() { record("") }

    /// The lock / login screen is not an app in use.
    private static func id(_ app: NSRunningApplication?) -> String {
        let id = app?.bundleIdentifier ?? app?.localizedName ?? ""
        return id == "com.apple.loginwindow" ? "" : id
    }

    @MainActor private func recordFrontmost() {
        record(Self.id(NSWorkspace.shared.frontmostApplication))
    }

    func record(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        let line = String(format: "%.1f\t%@\n", Date().timeIntervalSince1970, id.replacingOccurrences(of: "\t", with: " "))
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file)
        }
    }

    private func prune() {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let cutoff = Date().timeIntervalSince1970 - 60 * 86400
        let kept = text.split(separator: "\n").filter { (Double($0.split(separator: "\t").first ?? "") ?? 0) >= cutoff }
        if kept.count < text.split(separator: "\n").count {
            try? (kept.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: reading (any thread)

    /// Front-app changes and the time spans the record covers (where the app was running), within [from, to].
    func read(from: Double, to: Double) -> (events: [(Double, String)], covered: [(Double, Double)]) {
        lock.lock()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        lock.unlock()
        var events: [(Double, String)] = [], covered: [(Double, Double)] = []
        var spanStart: Double?, last: Double?
        let gap = Self.aliveEvery * 2.5
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let t = Double(parts.first ?? "") else { continue }
            let id = parts.count > 1 ? String(parts[1]) : ""
            if let l = last, t - l > gap, let s = spanStart {        // the app wasn't running in between
                covered.append((s, l)); events.append((l, "")); spanStart = nil
            }
            if spanStart == nil { spanStart = t }
            last = t
            if id != "#alive" { events.append((t, id)) }
        }
        if let s = spanStart, let l = last {
            let running = Date().timeIntervalSince1970 - l <= gap      // still running: covered up to now
            covered.append((s, running ? max(l, Date().timeIntervalSince1970) : l))
            if !running { events.append((l, "")) }
        }
        return (events.filter { $0.0 < to }.sorted { $0.0 < $1.0 },
                covered.filter { $0.1 > from && $0.0 < to })
    }
}
