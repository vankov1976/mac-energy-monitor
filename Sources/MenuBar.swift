import AppKit
import Combine
import SwiftUI

/// Last-hour summary for the menu bar; refreshes every 5 minutes.
@MainActor
final class MenuModel: ObservableObject {
    @Published var report: Report?
    @Published var watts: Double?
    @Published var error: String?
    @Published var systemW: Double?
    @Published var loading = false
    private var timer: Timer?
    private var liveSub: AnyCancellable?

    init() {
        liveSub = LivePower.shared.$current.sink { [weak self] w in self?.systemW = w }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let now = Date()
        loading = true
        logQueue.async {
            let result = Result { try sharedLog.fullReport(from: now.addingTimeInterval(-3600), to: now) }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let r):
                    self.report = r
                    self.error = nil
                    self.watts = r.totals.hours > 0 ? r.totals.energyWh / r.totals.hours : nil
                case .failure(let e):
                    self.error = e.localizedDescription
                }
            }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var live = LiveBreakdown.shared
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Power").font(.headline)
            HStack(alignment: .center, spacing: 18) {
                if let w = model.systemW { stat("Whole Mac now", w, "W", 1) }
                if let r = model.report, r.hardware.whole > 0 { stat("Last hour", r.hardware.whole, "Wh", 1) }
                Spacer()
                Button { model.refresh() } label: {
                    if model.loading { ProgressView().controlSize(.small) } else { Label("Reload", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(model.loading)
                .help("Reload the last hour from the power log")
            }
            Divider()
            HStack {
                Text("Live breakdown").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("update every").font(.caption).foregroundStyle(.secondary)
                LiveIntervalPicker().labelsHidden().pickerStyle(.menu).fixedSize()
                    .controlSize(.small)
            }
            if !live.ready {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                ForEach(live.breakdown.parts.sorted { $0.value > $1.value }) { p in
                    liveRow(hwIcon(p.icon, p.color), p.name, p.value)
                }
                Divider()
                Text("Top apps · live").font(.caption).foregroundStyle(.secondary)
                ForEach(live.rows.sorted { $0.watts > $1.watts }.prefix(5)) { row in
                    liveRow(AnyView(AppIcon(path: row.appPath)), row.name, row.watts)
                }
            }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
            Divider()
            StartAtLoginToggle()
            Divider()
            HStack {
                Button("Open Mac Energy Monitor") {
                    close()
                    StatusBarController.showMainWindow()
                }
                Spacer()
                SupportLink(iconOnly: true).buttonStyle(.borderless)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit")
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func liveRow(_ icon: AnyView, _ name: String, _ w: Double) -> some View {
        HStack(spacing: 8) {
            icon
            Text(name).lineLimit(1)
            Spacer()
            Text(fmt(w, 2) + " W").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func hwIcon(_ name: String, _ color: Color) -> AnyView {
        AnyView(Image(systemName: name).resizable().scaledToFit().foregroundStyle(color).padding(3)
            .frame(width: 22, height: 22))
    }

    private func stat(_ title: String, _ v: Double, _ unit: String, _ d: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(fmt(v, d) + " " + unit).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

/// Puts a bolt + last-hour watts in the menu bar; click shows MenuBarView in a popover.
@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let model = MenuModel()
    private var watch: Any?

    // MARK: window & Dock icon

    static func isMainWindow(_ w: NSWindow) -> Bool {
        w.title == "Mac Energy Monitor" && w.styleMask.contains(.titled)
    }

    /// Shows the main window (re-creating it if it was closed) and the Dock icon.
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: isMainWindow) {
            w.makeKeyAndOrderFront(nil)
        } else {
            // "Reopen" the app, which makes SwiftUI create the window again (with the remembered view).
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    /// Closing the window keeps the app running in the menu bar only.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon clicked (when pinned) or app opened again: show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        return true                               // let SwiftUI bring back / re-create the window
    }

    @objc private func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, Self.isMainWindow(w) else { return }
        DispatchQueue.main.async {
            // No main window left: hide the Dock icon (a pinned icon stays, as for any app).
            if !NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible && $0 !== w }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc private func windowDidBecomeKey(_ n: Notification) {
        guard let w = n.object as? NSWindow, Self.isMainWindow(w), NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: start hidden when opened as a login item

    private var launchedAtLogin = false

    /// Hidden start only when the login agent (see LoginAgent) opened the app with `--background`.
    private static func isLoginLaunch() -> Bool { CommandLine.arguments.contains("--background") }

    func applicationWillFinishLaunching(_ note: Notification) {
        // Never two copies of the app (e.g. the login agent while it already runs): show the running one instead.
        if !Self.isDiagnosticRun,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            if !CommandLine.arguments.contains("--background") { other.activate() }
            exit(0)
        }
        launchedAtLogin = Self.isLoginLaunch()
        if launchedAtLogin { NSApp.setActivationPolicy(.accessory) }    // no Dock icon
    }

    /// Test and diagnostic runs (`--livetest`, `--range` …) must not write to the front-app record.
    static var isDiagnosticRun: Bool {
        CommandLine.arguments.contains { $0.hasPrefix("--") && $0 != "--background" }
    }

    func applicationWillTerminate(_ note: Notification) {
        if !Self.isDiagnosticRun { FrontAppLog.shared.stop() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        if !Self.isDiagnosticRun { FrontAppLog.shared.start() }
        launchedAtLogin = launchedAtLogin || Self.isLoginLaunch()
        if launchedAtLogin {
            // Close the window SwiftUI opens at launch; the app stays in the menu bar.
            for delay in [0.0, 0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for w in NSApp.windows where Self.isMainWindow(w) { w.close() }
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Mac Energy Monitor")
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(toggle)
        }
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)   // the menu bar panel is always dark
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model, close: { [weak self] in
            self?.popover.performClose(nil)
        }))
        // Fixed width: digits all have the same width and the text always has the same number of characters.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let sample = " " + Self.label(88.8)
        let textW = (sample as NSString).size(withAttributes: [.font: font]).width
        item.length = ceil(textW + (item.button?.image?.size.width ?? 16) + 12)
        watch = model.$systemW.sink { [weak self] w in
            self?.item.button?.attributedTitle = NSAttributedString(
                string: " " + (w.map(Self.label) ?? "–– W"), attributes: [.font: font])
        }
    }

    func popoverDidClose(_ notification: Notification) { LiveBreakdown.shared.stop() }

    /// Always 4 characters before " W": "9.4" → " 9.4", "18.7", "105" (no decimal from 100 W).
    static func label(_ w: Double) -> String {
        let n = w >= 99.95 ? w.formatted(.number.precision(.fractionLength(0)))
                           : w.formatted(.number.precision(.fractionLength(1)))
        return String(repeating: "\u{2007}", count: max(0, 4 - n.count)) + n + " W"   // figure spaces = digit width
    }

    @objc private func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            model.refresh()
            LiveBreakdown.shared.start()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
