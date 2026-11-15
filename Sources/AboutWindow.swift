import AppKit
import SwiftUI

/// The About window: icon, name, "Version 1.0.1", project link and, when the update check found a newer
/// version, a Download box. Replaces macOS's standard About panel, which can't hold a button.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = ""
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: AboutView())
            // Detach from the main window when closed, so it doesn't come back with it.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { w.parent?.removeChildWindow(w) }
            }
            window = w
        }
        guard let w = window else { return }
        if !w.isVisible { w.contentView = NSHostingView(rootView: AboutView()) }   // fresh, without an old check result
        NSApp.activate(ignoringOtherApps: true)
        // Like other Mac apps' About: centered on top of the app's window, which stays visible behind it
        // (and moves with it). Without a visible window (opened from the menu bar panel): centered on screen, on top.
        if let main = NSApp.windows.first(where: { StatusBarController.isMainWindow($0) && $0.isVisible && !$0.isMiniaturized }) {
            if w.parent !== main {
                w.parent?.removeChildWindow(w)
                main.addChildWindow(w, ordered: .above)
            }
            w.level = main.level
            w.layoutIfNeeded()
            let f = main.frame, s = w.frame.size
            w.setFrameOrigin(NSPoint(x: f.midX - s.width / 2, y: f.midY - s.height / 2))
            main.orderFront(nil)
        } else {
            w.parent?.removeChildWindow(w)
            w.level = .floating
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    @ObservedObject var checker = UpdateChecker.shared
    @State private var state = CheckState.idle
    private enum CheckState { case idle, checking, upToDate, failed }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Mac Energy Monitor").font(.headline).padding(.top, 4)
            Text("Version \(checker.current)").font(.callout)
            Link("github.com/vankov1976/mac-energy-monitor", destination: EnergyMonitorApp.homepage)
                .font(.caption).padding(.top, 4)
            if let r = checker.available {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                        Text("Version \(r.version) is available").lineLimit(1)
                    }
                    .font(.callout.weight(.medium))
                    if !r.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("What's new").font(.caption.weight(.semibold))
                            ScrollView {
                                Text(r.notes).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 90)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DownloadControls()
                }
                .padding(10).frame(maxWidth: .infinity)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            } else {
                checkRow.padding(.top, 10)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 4)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension AboutView {
    /// "Check for Updates" in About, with the result shown right below it (no extra message window).
    @ViewBuilder var checkRow: some View {
        VStack(spacing: 6) {
            Button {
                state = .checking
                Task {
                    let ok = await checker.fetch()
                    state = ok ? (checker.available == nil ? .upToDate : .idle) : .failed
                }
            } label: {
                HStack(spacing: 6) {
                    if state == .checking { ProgressView().controlSize(.small) }
                    Text(state == .checking ? "Checking…" : "Check for Updates")
                }
            }
            .disabled(state == .checking)
            switch state {
            case .upToDate:
                Label("You're up to date", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed:
                Label("GitHub could not be reached. Check the internet connection and try again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
            Toggle("Check automatically every day", isOn: $checker.automatic)
                .toggleStyle(.checkbox).font(.caption).padding(.top, 2)
        }
    }
}

/// Download button, then progress, then where the new app is and what to do with it.
struct DownloadControls: View {
    @ObservedObject var checker = UpdateChecker.shared
    @ObservedObject var dl = UpdateDownloader.shared

    var body: some View {
        VStack(spacing: 8) {
            switch dl.state {
            case .idle:
                Button("Download") { checker.download() }.keyboardShortcut(.defaultAction)
                hint("The new version is saved in your Downloads folder and shown in Finder.")
            case .downloading(let f):
                ProgressView(value: f).frame(width: 180)
                Text("Downloading… \(Int(f * 100))%").font(.caption).monospacedDigit()
            case .ready(let app):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Downloaded")
                }
                .font(.callout)
                hint("It's in Downloads › \(app.deletingLastPathComponent().lastPathComponent). Quit Mac Energy Monitor and drag the new app into your Applications folder (replace the old one).")
                HStack(spacing: 10) {
                    Button("Show in Finder") { dl.reveal(app) }
                    Button("Quit App") { NSApp.terminate(nil) }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { checker.download() }
            }
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Version 1.0.1" as a small link that opens the About window (window footer and menu bar panel).
struct VersionLink: View {
    @ObservedObject var checker = UpdateChecker.shared
    var before: () -> Void = {}

    var body: some View {
        Button {
            before()
            AboutWindow.show()
        } label: {
            HStack(spacing: 3) {
                if checker.available != nil {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                }
                Text("Version \(checker.current)")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(checker.available.map { "Version \($0.version) is available. Click for details." } ?? "About Mac Energy Monitor")
        .accessibilityLabel(checker.available.map { "Version \(checker.current), update to \($0.version) available" }
                            ?? "Version \(checker.current), About Mac Energy Monitor")
    }
}
