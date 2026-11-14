import Foundation
import ServiceManagement
import SwiftUI

/// "Start at login": the app itself as a login item (SMAppService.mainApp, listed under System Settings →
/// General → Login Items → Open at Login). macOS opens it with a "launched as login item" Apple event, which
/// makes the app start hidden (see StatusBarController.isLoginLaunch); every other start shows the window.
/// (A login agent inside the bundle was used before: macOS ties such an agent to the exact build of a
/// self-signed app and refuses to start it after any update, so it's no longer used.)
enum LoginAgent {
    static var service: SMAppService { .mainApp }

    static var isEnabled: Bool { service.status == .enabled }

    static func enable() throws { try service.register() }

    static func disable() { try? service.unregister() }
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
            .help("Opens Mac Energy Monitor in the menu bar (no window) when you log in. macOS lists it under System Settings → General → Login Items → Open at Login.")
    }
}
