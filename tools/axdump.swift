// Test tool: reads what a running app window really shows, through macOS's accessibility interface (as VoiceOver
// does), and can press its controls. Usage: axdump <pid> dump | press <title> | tab <title>
// Needs the accessibility permission of the app that starts it (Terminal / the shell's parent app).
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String? {
    if let s = attr(e, a) as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
    if let n = attr(e, a) as? NSNumber, a == kAXValueAttribute { return n.stringValue }
    return nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] {
    let role = str(e, kAXRoleAttribute) ?? ""
    if role == "AXTable" || role == "AXOutline", let rows = attr(e, kAXRowsAttribute) as? [AXUIElement] {
        let header = (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { str($0, kAXRoleAttribute) != "AXRow" }
        return header + rows
    }
    return attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func walk(_ e: AXUIElement, _ depth: Int, _ f: (AXUIElement, Int) -> Bool) {
    guard depth < 60, f(e, depth) else { return }
    for k in kids(e) { walk(k, depth + 1, f) }
}
let a = CommandLine.arguments
guard a.count >= 3, let pid = Int32(a[1]) else { print("usage: axdump <pid> dump|press <title>|tab <title>"); exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)
// A busy app may not answer for a moment: ask again a few times before giving up.
var found: AXUIElement?
for _ in 0..<8 {
    if let w = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first { found = w; break }
    Thread.sleep(forTimeInterval: 1)
}
guard let win = found else { print("no window"); exit(1) }
switch a[2] {
case "dump":
    walk(win, 0) { e, d in
        let role = (str(e, kAXRoleAttribute) ?? "?").replacingOccurrences(of: "AX", with: "")
        // Buttons and tabs: their label first (their value is only on/off).
        let labelFirst = ["RadioButton", "CheckBox"].contains(role)
        let parts = (labelFirst ? [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute)]
                                : [str(e, kAXValueAttribute), str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute)]).compactMap { $0 }
        let help = str(e, kAXHelpAttribute)
        if !parts.isEmpty || help != nil || role == "Row" || role == "Table" {
            let t = parts.first.map { $0.replacingOccurrences(of: "\n", with: " ⏎ ") } ?? ""
            print(String(repeating: " ", count: d) + role + ": " + t + (help.map { "  ⟨tip: " + $0.replacingOccurrences(of: "\n", with: " ⏎ ") + "⟩" } ?? ""))
        }
        return true
    }
case "press", "tab":
    let want = a.count > 3 ? a[3] : ""
    var done = false
    walk(win, 0) { e, _ in
        guard !done else { return false }
        let t = str(e, kAXTitleAttribute) ?? str(e, kAXDescriptionAttribute) ?? str(e, kAXValueAttribute) ?? ""
        let role = str(e, kAXRoleAttribute) ?? ""
        if t.hasPrefix(want), ["AXButton", "AXRadioButton", "AXCheckBox", "AXLink", "AXStaticText"].contains(role) {
            done = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        }
        return true
    }
    print(done ? "pressed \(want)" : "not found: \(want)"); exit(done ? 0 : 1)
default: print("unknown command"); exit(2)
}
