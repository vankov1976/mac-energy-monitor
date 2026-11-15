import AppKit
import SwiftUI

/// A published version of the app.
struct Release: Equatable {
    let version: String     // "1.0.2" (without the "v" of the tag)
    let page: URL           // release page (fallback when no zip is attached)
    var download: URL?      // the release's zip, if one is attached
    var notes = ""          // the release notes as plain text ("What's new")
}

/// Where the newest release comes from. Swapping the source (another host, a test stub) touches only this.
protocol ReleaseSource {
    func latest() async throws -> Release
}

/// The newest release on GitHub. Sends one anonymous request; nothing about the user or the Mac.
struct GitHubReleases: ReleaseSource {
    let repo = "vankov1976/mac-energy-monitor"

    /// Release notes are Markdown; shown as plain text (keeps line breaks, drops ** and links' URLs).
    static func plain(_ md: String) -> String {
        let text = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? md
        return text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func latest() async throws -> Release {
        var url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
#if DIAGNOSTICS
        // Test builds only: `defaults write local.mac-energy-monitor updateTestURL <url>` to test errors.
        if let t = UserDefaults.standard.string(forKey: "updateTestURL"), let u = URL(string: t) { url = u }
#endif
        var req = URLRequest(url: url,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Mac-Energy-Monitor", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Body: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset]?; let body: String? }
        let b = try JSONDecoder().decode(Body.self, from: data)
        let v = b.tag_name.hasPrefix("v") ? String(b.tag_name.dropFirst()) : b.tag_name
        let zip = b.assets?.first { $0.name.lowercased().hasSuffix(".zip") }?.browser_download_url
        return Release(version: v, page: b.html_url, download: zip, notes: Self.plain(b.body ?? ""))
    }
}

/// Checks for a newer version: on request ("Check for Updates…") and, only if the user turned it on,
/// at start and once a day. Off by default, so the app makes no network access unless asked.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var available: Release?      // a newer version than this one, if found
    @Published var automatic: Bool {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "checkUpdates")
            schedule()
        }
    }

    private let source: ReleaseSource
    private var timer: Timer?
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    init(source: ReleaseSource = GitHubReleases()) {
        self.source = source
        automatic = UserDefaults.standard.bool(forKey: "checkUpdates")    // false on first start
    }

    /// Called once at launch.
    func start() { schedule() }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await UpdateChecker.shared.check(manual: false) }
        }
    }

    /// Manual checks always answer with a message; automatic ones stay silent and only show the banner.
    func check(manual: Bool) async {
        let ok = await fetch()
        guard manual else { return }
        if ok { report(available) }
        else { alert("Couldn't check for updates", "GitHub could not be reached. Check the internet connection and try again.") }
    }

    /// Asks GitHub and updates `available`; false if GitHub could not be reached. No messages (About shows the result itself).
    @discardableResult
    func fetch() async -> Bool {
        do {
            let r = try await source.latest()
            available = Self.isNewer(r.version, than: current) ? r : nil
            return true
        } catch {
            return false
        }
    }

    /// Downloads the new version inside the app; About shows the progress and the result.
    func download() {
        guard let r = available else { NSWorkspace.shared.open(Self.releases); return }
        AboutWindow.show()
        UpdateDownloader.shared.start(r)
    }

    static let howTo = "Download saves the new version in your Downloads folder and shows it in Finder. Then quit Mac Energy Monitor and drag the new app into your Applications folder (replace the old one). Your settings and saved history are kept."

    private static var releases: URL { EnergyMonitorApp.homepage.appendingPathComponent("releases") }

    private func report(_ r: Release?) {
        guard let r else {
            alert("You're up to date", "Mac Energy Monitor \(current) is the newest version.")
            return
        }
        let a = NSAlert()
        a.messageText = "Version \(r.version) is available"
        let news = r.notes.isEmpty ? "" : "What's new:\n\(r.notes)\n\n"
        a.informativeText = news + "You have version \(current). " + Self.howTo
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { download() }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// Compares dotted version numbers part by part: 1.0.10 > 1.0.9, 1.1 > 1.0.1, 1.0 == 1.0.0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// "Version X is available · Download" line, shown in the window and the menu bar panel when a newer version was found.
struct UpdateBanner: View {
    @ObservedObject var checker = UpdateChecker.shared

    var body: some View {
        if let r = checker.available {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                Text("Version \(r.version) is available").font(.callout)
                Spacer(minLength: 4)
                Button("Download") { checker.download() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .help(r.notes.isEmpty ? "" : "What's new:\n" + r.notes)
        }
    }
}

/// App menu items: "Check for Updates…" and the on/off switch for the daily check.
struct UpdateCommands: View {
    @ObservedObject var checker = UpdateChecker.shared

    var body: some View {
        Button("Check for Updates…") { Task { await checker.check(manual: true) } }
        Toggle("Check for Updates Automatically", isOn: $checker.automatic)
    }
}
