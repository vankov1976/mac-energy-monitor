import AppKit
import Combine
import SwiftUI

/// Average power over a chosen period for the menu bar panel; refreshes every 5 minutes.
@MainActor
final class MenuModel: ObservableObject {
    static let periods: [Preset] = [.hour, .day, .threeDays, .week, .all]
    @Published var avgW: Double?
    @Published var period: Preset {
        didSet { UserDefaults.standard.set(period.rawValue, forKey: "menuPeriod"); refresh() }
    }
    @Published var error: String?
    @Published var systemW: Double?
    @Published var loading = false
    private var timer: Timer?
    private var liveSub: AnyCancellable?
    /// The panel is open: only then is the average kept up to date (opening it reloads anyway).
    var visible = false

    init() {
        let saved = Preset(rawValue: UserDefaults.standard.string(forKey: "menuPeriod") ?? "")
        period = saved.flatMap { Self.periods.contains($0) ? $0 : nil } ?? .hour
        liveSub = LivePower.shared.$current.sink { [weak self] w in self?.systemW = w }
        refresh()
        // The sleep log arrived (read in the background): the average while awake changes, so reload.
        NotificationCenter.default.addObserver(forName: PMSetLog.updated, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.visible == true { self?.refresh() } }
        }
        // While the panel is open, the average follows new log entries; closed, nothing runs (saves energy).
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.visible == true { self?.refresh() } }
        }
        timer?.tolerance = 60
    }

    func refresh() {
        let now = Date()
        let period = period
        loading = true
        logQueue.async {
            let result = Result { () throws -> Report in
                // "All": from the oldest data (macOS's logs or the app's saved days), as in the window.
                let from = period.hours.map { now.addingTimeInterval(-$0 * 3600) }
                    ?? (try? sharedLog.fullRange())?.lowerBound ?? now.addingTimeInterval(-14 * 86400)
                return try sharedLog.fullReport(from: from, to: now)
            }
            DispatchQueue.main.async {
                guard period == self.period else { return }   // the choice changed meanwhile; a newer load follows
                self.loading = false
                switch result {
                case .success(let r):
                    self.error = nil
                    // Same as the window's "Avg. power" card: energy while awake / hours awake.
                    self.avgW = r.hardware.averageAwakeW(fallbackHours: r.coveredHours)
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
    @AppStorage(StatusBarController.batteryKey) private var batteryInMenuBar = true
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: the battery (as in the window; click opens the window's battery view) and Start at login.
            HStack {
                BatteryButton(isOn: Binding(get: { false }, set: { _ in
                    close()
                    BatteryModel.requestView()
                    StatusBarController.showMainWindow()
                }))
                if BatteryModel.shared.hasBattery {
                    Spacer(minLength: 4)
                    Toggle(BT.inMenuBar, isOn: $batteryInMenuBar).toggleStyle(.checkbox).fixedSize()
                        .controlSize(.small).help(BT.inMenuBarTip)
                        .onChange(of: batteryInMenuBar) { NotificationCenter.default.post(name: StatusBarController.batteryToggled, object: nil) }
                }
                Spacer(minLength: 4)
                StartAtLoginToggle().controlSize(.small).fixedSize()
            }
            Divider()
            // The two boxes, with the same space above (the panel's edge) and below (to the line): 14 pt.
            HStack(spacing: 10) {
                statBox { Text("Whole Mac now").foregroundStyle(.secondary) } value: {
                    valueText(model.systemW)
                }
                statBox {
                    Menu {
                        ForEach(MenuModel.periods) { p in
                            Toggle(Self.periodName(p), isOn: Binding(get: { model.period == p }, set: { if $0 { model.period = p } }))
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text("Avg. power · " + Self.periodName(model.period))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Average power while the Mac was awake. Click to choose the period.")
                    .accessibilityLabel("Average power period, " + Self.periodName(model.period))
                } value: {
                    HStack {
                        // Loaded but nothing logged for the period yet: "N/A" with the reason, as in the window.
                        valueText(model.avgW, missing: model.loading || model.error != nil ? "–– W" : "N/A")
                            .help(model.avgW == nil && !model.loading ? "Not logged by macOS yet" : "")
                        Spacer(minLength: 4)
                        Button { model.refresh() } label: {
                            if model.loading { ProgressView().controlSize(.mini).frame(width: 14, height: 14) }
                            else { Image(systemName: "arrow.clockwise").frame(width: 14, height: 14) }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.loading)
                        .help("Reload the average power from macOS's power log")
                        .accessibilityLabel("Reload average power")
                    }
                }
            }
            .padding(.bottom, 4)            // + the stack's 10 pt spacing = 14 pt, as above
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
            UpdateBanner(before: { close() })
            Divider()
            HStack {
                Button("Open Mac Energy Monitor") {
                    close()
                    StatusBarController.showMainWindow()
                }
                Spacer()
                VersionLink(before: { close() }).font(.caption)
                Spacer()
                SupportLink(iconOnly: true).buttonStyle(.borderless)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit")
                    .accessibilityLabel("Quit Mac Energy Monitor")
            }
        }
        .padding(14)
        .frame(width: 384)
    }

    /// One framed box: a caption line and a value line, both starting at the same left edge.
    /// Both boxes have the same width and height.
    private func statBox<C: View, V: View>(@ViewBuilder caption: () -> C, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            caption().font(.caption).lineLimit(1)
            value().frame(height: 24)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
    }

    private func valueText(_ w: Double?, missing: String = "–– W") -> some View {
        Text(w.map { fmt($0, 1) + " W" } ?? missing).font(.title3.weight(.semibold)).monospacedDigit()
    }

    static func periodName(_ p: Preset) -> String {
        switch p {
        case .hour: return "last 1 hour"
        case .all: return "all history"
        default: return "last " + p.rawValue
        }
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

    /// Hidden start only when macOS opened the app as a login item (see LoginAgent), or with `--background`.
    private static func isLoginLaunch() -> Bool {
        if CommandLine.arguments.contains("--background") { return true }
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEOpenApplication else { return false }
        return e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

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
        // New sleeps can only appear after the Mac wakes: read macOS's sleep log again then (in the background).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            PMSetLog.shared.markStale()
        }
        if !Self.isDiagnosticRun {
            FrontAppLog.shared.start()
            UpdateChecker.shared.start()
        }
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
            b.alignment = .left        // fixed positions: a narrower text (e.g. the calculating dots) doesn't shift the rest
            b.target = self
            b.action = #selector(toggle)
        }
        popover.behavior = .transient
        // No arrow (the small triangle pointing at the menu bar icon). Undocumented popover setting, used only if
        // this macOS has it: otherwise the arrow simply stays.
        if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) { popover.setValue(true, forKey: "shouldHideAnchor") }
        popover.appearance = NSAppearance(named: .darkAqua)   // the menu bar panel is always dark
        popover.delegate = self
        // One container for the panel; its content is the real panel only while it is open, an empty view while
        // closed (popoverDidClose). A hidden panel would otherwise keep its views and the battery button's 1-second
        // timer running (measured: about 7 % CPU with everything closed). Swapping the content (instead of making a
        // new container each time) lets SwiftUI remove the old views properly: no invisible copies stay behind.
        popover.contentViewController = panelHost
        // Fixed width: digits all have the same width and the text always has the same number of characters.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // The battery after the watts (Macs with a battery): icon with % and the time left / until full, fixed width.
        let bat = BatteryModel.shared
        // The battery after the watts (Macs with a battery), in the same menu bar item: icon with % and the time
        // left / until full. The item is exactly as wide as what it shows: a time and the calculating dots always
        // have the same width ("12:34"), so it only changes when the state does (plugged in or out, Full, Paused).
        // The icon image is made only when the % or charging changes.
        toggledObserver = NotificationCenter.default.addObserver(forName: Self.batteryToggled, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.popover.isShown {                       // closes at once, without fading out
                    self.popover.animates = false; self.popover.performClose(nil); self.popover.animates = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.model.systemW = self.model.systemW }   // resize + redraw now
            }
        }
        if bat.hasBattery { bat.startMenuBar() }
        watch = model.$systemW.sink { [weak self] w in
            guard let self else { return }
            // The battery can be switched off in the panel ("In menu bar").
            let wantBattery = bat.hasBattery && (UserDefaults.standard.object(forKey: Self.batteryKey) as? Bool ?? true)
            // The battery's text now: on the charger but not charging, "Full" or "Paused" (no time, no dots).
            var time = ""
            if wantBattery, let b = bat.now {
                bat.menuBarTick()                                       // same rhythm as the watts
                time = b.onCharger && !b.charging ? (b.fullyCharged || b.level >= 100 ? BT.menuFull : BT.menuPaused)
                    : Self.batteryTime(b.onCharger ? bat.secondsToFull : bat.secondsLeft, animate: true)
            }
            let showBattery = wantBattery
            let text = " " + (w.map(Self.label) ?? "–– W")
            let out = NSMutableAttributedString(string: text, attributes: [.font: font])
            var key = text
            if showBattery, let b = bat.now {
                let level = b.level.rounded(), charging = b.onCharger && !b.fullyCharged || b.charging
                let full = b.onCharger && !b.charging && (b.fullyCharged || b.level >= 100)     // only a bolt inside
                key += "|\(level)|\(charging)|\(full)|" + time
                if self.batteryImageKey != "\(level)|\(charging)|\(full)" {
                    self.batteryImageKey = "\(level)|\(charging)|\(full)"
                    self.batteryAttachment.image = Self.batteryImage(level: level, charging: charging, full: full)
                    self.batteryAttachment.bounds = CGRect(x: 0, y: -4, width: Self.batteryIconSize.width, height: Self.batteryIconSize.height)
                }
                out.append(NSAttributedString(string: "  ", attributes: [.font: font]))
                out.append(NSAttributedString(attachment: self.batteryAttachment))
                out.append(NSAttributedString(string: " " + time, attributes: [.font: font]))
            }
            guard key != self.lastTitle else { return }                // redraw the menu bar only when it changes
            self.lastTitle = key
            guard let button = self.item.button else { return }
            button.attributedTitle = out
            // Exactly as wide as the content (the button knows its own margins): no empty space left or right.
            // macOS doesn't lay the item out again while the panel is open (and a wider item would move the panel):
            // then a battery that doesn't fit waits until the panel closes ("In menu bar" closes it first).
            let need = ceil(button.intrinsicContentSize.width)
            if !self.popover.isShown {
                if self.item.length != need { self.item.length = need }
            } else if need > self.item.length + 0.5 {
                button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
                self.lastTitle = ""
            }
            // VoiceOver can't read the battery picture: a spoken label for the whole item.
            var spoken = "Mac Energy Monitor, " + text.trimmingCharacters(in: .whitespaces)
            if showBattery, let b = bat.now {
                let t = b.onCharger && !b.charging ? (b.fullyCharged || b.level >= 100 ? BT.fullyCharged : BT.pausedAt(b.level))
                    : b.onCharger ? bat.secondsToFull.map(BT.untilFull) : bat.secondsLeft.map(BT.left)
                spoken += ", " + String(localized: "battery \(BT.pct(b.level))") + (t.map { ", " + $0 } ?? "")
            }
            self.item.button?.setAccessibilityLabel(spoken)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        LiveBreakdown.shared.stop(); model.visible = false
        panelHost.rootView = AnyView(EmptyView())   // its views and timers stop (see where the panel is made)
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        lastTitle = ""                     // redraw (and apply a changed width) at the next update
    }
    /// Clicks outside the panel close it, also on an empty spot of the menu bar (which the popover's own
    /// "transient" closing doesn't see).
    private var outsideClicks: Any?
    private let panelHost: NSHostingController<AnyView> = {
        let h = NSHostingController(rootView: AnyView(EmptyView()))
        // No size reporting on every update: measuring the whole panel again at each live reading (every second)
        // was most of its processor time (sampled: ~23 % of a core while open). Its size is set once when it opens.
        h.sizingOptions = []
        return h
    }()
    private var lastTitle = "", batteryImageKey = ""
    static let batteryToggled = Notification.Name("menuBarBatteryToggled")
    private var toggledObserver: Any?
    private let batteryAttachment = NSTextAttachment()

    static let batteryIconSize = NSSize(width: 46, height: 17)
    static let batteryKey = "menuBarBattery"

    /// "4:36", padded to the same width; while still calculating, dots that build up with each update (·, ··, ···).
    private static var dots = 0
    static func batteryTime(_ s: Double?, animate: Bool = false) -> String {
        guard let s else {
            if animate { dots = (dots + 1) % 3 }
            let d = String(repeating: "·", count: dots + 1)
            return d + String(repeating: "\u{2007}", count: 5 - d.count)       // same width as "12:34"
        }
        let t = BT.dur(s)
        return String(repeating: "\u{2007}", count: max(0, 5 - t.count)) + t
    }

    /// The battery for the menu bar (monochrome): outline, fill with the charge, % inside, ⚡ while charging.
    static func batteryImage(level: Double, charging: Bool, full: Bool = false) -> NSImage {
        let size = batteryIconSize
        return NSImage(size: size, flipped: false) { r in
            let body = NSRect(x: 0.5, y: 0.5, width: r.width - 4, height: r.height - 1)
            let tint = NSColor.labelColor.withAlphaComponent(0.35)     // monochrome, like the other menu bar icons
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5); outline.lineWidth = 1; outline.stroke()
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.width - 2.5, y: r.height / 2 - 2.5, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: max(1.5, (body.width - 3) * min(1, level / 100)), height: body.height - 3),
                         xRadius: 2, yRadius: 2).fill()
            // Fully charged: only a bolt inside (the text after the icon says "Full"), the same symbol as in the window.
            if full, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.labelColor]))) {
                bolt.draw(in: NSRect(x: body.midX - bolt.size.width / 2, y: body.midY - bolt.size.height / 2,
                                     width: bolt.size.width, height: bolt.size.height))
                return true
            }
            // Charging: the bolt at the left edge, the % centred in the rest (a little gap between them).
            var area = body.insetBy(dx: 2, dy: 0)
            if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.labelColor]))) {
                bolt.draw(in: NSRect(x: body.minX + 3, y: body.midY - bolt.size.height / 2, width: bolt.size.width, height: bolt.size.height))
                area = NSRect(x: body.minX + 3 + bolt.size.width + 2, y: body.minY, width: body.maxX - 2 - (body.minX + 3 + bolt.size.width + 2), height: body.height)
            }
            let label = "\(Int(level))%"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor]
            let ts = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: area.midX - ts.width / 2, y: body.midY - ts.height / 2), withAttributes: attrs)
            return true
        }
    }

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
            model.visible = true
            model.refresh()
            LiveBreakdown.shared.start()
            panelHost.rootView = AnyView(MenuBarView(model: model, close: { [weak self] in self?.popover.performClose(nil) }))
            popover.contentSize = panelHost.view.fittingSize
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            if outsideClicks == nil {
                outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    MainActor.assumeIsolated { if self?.popover.isShown == true { self?.popover.performClose(nil) } }
                }
            }
            if let w = popover.contentViewController?.view.window {
                // Also over full-screen apps (their own Space): without this macOS keeps the panel off screen.
                w.collectionBehavior.formUnion([.fullScreenAuxiliary, .canJoinAllSpaces])
                w.orderFrontRegardless()
                w.makeKey()
            }
        }
    }
}
