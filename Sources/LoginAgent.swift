import Foundation
import ServiceManagement
import SwiftUI

/// "Start at login": a login agent shipped inside the app bundle (Contents/Library/LaunchAgents, see build.sh)
/// and registered with SMAppService, so macOS ties it to the app (its name and icon in System Settings →
/// General → Login Items → Allow in the Background). It starts the app with `--background` — the only thing
/// that makes the app start hidden; every other start (Finder, Dock, Spotlight) shows the window.
enum LoginAgent {
    static let label = "local.mac-energy-monitor.startatlogin"
    static var service: SMAppService { SMAppService.agent(plistName: label + ".plist") }
    /// Name of the earlier loose agent (macOS may still list it until it cleans up stale entries).
    static let legacyLabel = "local.mac-energy-monitor.login"

    /// The earlier version used a loose file in ~/Library/LaunchAgents (shown by macOS with a terminal icon).
    static var legacyPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    static var isEnabled: Bool { service.status == .enabled }

    static func enable() throws {
        removeLegacy()
        try service.register()
    }

    static func disable() {
        try? service.unregister()
        removeLegacy()
    }

    /// Replaces the old loose agent (once, at launch) with the registered one.
    static func migrateLegacy() {
        guard FileManager.default.fileExists(atPath: legacyPlist.path) else { return }
        removeLegacy()
        try? service.register()
    }

    private static func removeLegacy() {
        guard FileManager.default.fileExists(atPath: legacyPlist.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(legacyLabel)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(at: legacyPlist)
    }
}

/// One shared on/off state for the "Start at login" switches in the window and the menu bar panel.
@MainActor
final class LoginAgentSetting: ObservableObject {
    static let shared = LoginAgentSetting()
    @Published private(set) var enabled = LoginAgent.isEnabled

    func set(_ on: Bool) {
        if on { try? LoginAgent.enable() } else { LoginAgent.disable() }
        enabled = LoginAgent.isEnabled
    }

    /// macOS may change it too (System Settings → Login Items): re-read when the window or panel appears.
    func refresh() { enabled = LoginAgent.isEnabled }
}

/// The "Start at login" switch (window and menu bar panel).
struct StartAtLoginToggle: View {
    @ObservedObject var setting = LoginAgentSetting.shared
    var body: some View {
        // Label as separate text: the window's top row hides control labels (for the time-frame buttons).
        HStack(spacing: 6) {
            Text("Start at login").font(.callout)
            Toggle("Start at login", isOn: Binding(get: { setting.enabled }, set: { setting.set($0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .fixedSize()
            .onAppear { setting.refresh() }
            .help("Opens Mac Energy Monitor in the menu bar (no window) when you log in. macOS lists it under System Settings → General → Login Items → Allow in the Background. Don't also add it to \"Open at Login\" there.")
    }
}
