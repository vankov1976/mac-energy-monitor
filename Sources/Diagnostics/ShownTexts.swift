import AppKit

/// What a window really shows: its texts as macOS's accessibility reads them (what VoiceOver reads, the same strings
/// that are drawn), in reading order, plus every tooltip of its views. Used by `--windowshot` with MEM_SHOT_TEXTS.
@MainActor enum ShownTexts {
    static func collect(_ root: NSView) -> [String] {
        var out: [String] = []
        var seen = Set<ObjectIdentifier>()
        func text(_ o: NSAccessibilityProtocol) -> String? {
            let v = o.accessibilityValue() as? String, l = o.accessibilityLabel(), t = o.accessibilityTitle()
            return [v, l, t].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        func walk(_ any: Any, _ depth: Int) {
            guard depth < 80, let o = any as? NSObject, seen.insert(ObjectIdentifier(o)).inserted,
                  let a = o as? NSAccessibilityProtocol else { return }
            let role = a.accessibilityRole()
            let kids = a.accessibilityChildren() ?? []
            if role == .staticText || role == .button || role == .link || role == .cell && kids.isEmpty || role == .popUpButton
                || role == .radioButton || role == .checkBox, let t = text(a) {
                out.append("\(role?.rawValue.replacingOccurrences(of: "AX", with: "") ?? "?"): \(t.replacingOccurrences(of: "\n", with: " ⏎ "))")
            }
            for k in kids { walk(k, depth + 1) }
        }
        walk(root, 0)
        func tips(_ v: NSView) {
            if let t = v.toolTip, !t.isEmpty { out.append("TIP: " + t.replacingOccurrences(of: "\n", with: " ⏎ ")) }
            for s in v.subviews { tips(s) }
        }
        tips(root)
        return out
    }
}
