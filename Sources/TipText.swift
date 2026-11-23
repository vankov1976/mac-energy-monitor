import SwiftUI

extension Color {
    /// Text that shows a tooltip on hover: the same blue as links ("How these numbers are measured").
    static let tip = Color(nsColor: .linkColor)
}

/// Text written with «plain name|tooltip» parts: those parts are blue and show their tooltip on hover; the rest
/// is normal text. Wraps by words like normal text.
struct TipText: View {
    let markup: String
    /// «words|→target» is a link: clicking it calls this with "target" (e.g. to switch to a tab).
    var onLink: ((String) -> Void)? = nil

    private struct Word: Identifiable { let id: Int; let text: String; let tip: String?; let glued: Bool }

    /// The words in order; a word right after a «…» part without a space (e.g. "." or ":") sticks to it.
    private var words: [Word] {
        var out: [Word] = []
        var rest = Substring(markup)
        var gluedNext = false
        func add(_ s: Substring, tip: String?) {
            var first = true
            let startsWithSpace = s.first?.isWhitespace ?? true
            // A link stays one piece: underlined without gaps, never split across lines.
            if let tip, tip.hasPrefix("→") {
                out.append(Word(id: out.count, text: s.trimmingCharacters(in: .whitespaces), tip: tip, glued: gluedNext && !startsWithSpace))
                return
            }
            for w in s.split(whereSeparator: { $0.isWhitespace }) {
                out.append(Word(id: out.count, text: String(w), tip: tip, glued: first && gluedNext && !startsWithSpace))
                first = false
            }
        }
        while let open = rest.range(of: "«") {
            add(rest[..<open.lowerBound], tip: nil)
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "»") else { rest = afterOpen; break }
            let part = afterOpen[..<close.lowerBound]
            let bar = part.firstIndex(of: "|")
            let name = bar.map { part[..<$0] } ?? part
            let tip = bar.map { String(part[part.index(after: $0)...]) }
            let beforeEndsWithSpace = rest[..<open.lowerBound].last?.isWhitespace ?? true
            gluedNext = !beforeEndsWithSpace && !out.isEmpty
            add(name, tip: tip)
            gluedNext = true
            rest = afterOpen[close.upperBound...]
        }
        add(rest, tip: nil)
        return out
    }

    var body: some View {
        WordFlow {
            ForEach(words) { w in
                Group {
                    if let tip = w.tip, tip.hasPrefix("→") {
                        Text(w.text).underline().foregroundStyle(Color.tip)
                            .onTapGesture { onLink?(String(tip.dropFirst())) }
                            .onContinuousHover { if case .active = $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                    } else if let tip = w.tip {
                        Text(w.text).foregroundStyle(Color.tip).tip(tip)
                    } else {
                        Text(w.text)
                    }
                }
                .layoutValue(key: Glued.self, value: w.glued)
            }
        }
    }
}

private struct Glued: LayoutValueKey { static let defaultValue = false }

/// Lays words out in lines like text: a space between words, a new line when the next word doesn't fit;
/// glued words stay with the word before them.
private struct WordFlow: Layout {
    var lineSpacing: CGFloat = 2
    /// Width of a space in the hints' font (measured once).
    static let space = (" " as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .callout)]).width

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let r = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width.map { min($0, r.size.width) } ?? r.size.width, height: r.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, p) in r.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let space = Self.space
        var units: [Range<Int>] = [], i = 0
        while i < subviews.count {
            var j = i + 1
            while j < subviews.count && subviews[j][Glued.self] { j += 1 }
            units.append(i..<j); i = j
        }
        var pts = Array(repeating: CGPoint.zero, count: subviews.count)
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for u in units {
            let w = u.reduce(0) { $0 + sizes[$1].width }
            if x > 0 && x + space + w > width { y += lineH + lineSpacing; x = 0; lineH = 0 }
            if x > 0 { x += space }
            for k in u { pts[k] = CGPoint(x: x, y: y); x += sizes[k].width; lineH = max(lineH, sizes[k].height) }
            maxX = max(maxX, x)
        }
        return (pts, CGSize(width: maxX, height: y + lineH))
    }
}

/// A tooltip that keeps working: SwiftUI's `.help` can stop showing after the content changes while the window
/// stays active (e.g. switching tabs) until the window is activated again. An AppKit view's own `toolTip` is
/// tracked by macOS itself. The overlay lets clicks through.
private struct ToolTipArea: NSViewRepresentable {
    let text: String
    final class TipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks go to the view below
        // VoiceOver (and the test build's app audit) can read the tooltip too: a help tag right after its value.
        override func isAccessibilityElement() -> Bool { toolTip != nil }
        override func accessibilityRole() -> NSAccessibility.Role? { .helpTag }
        override func accessibilityHelp() -> String? { toolTip }
    }
    func makeNSView(context: Context) -> TipView { let v = TipView(); v.toolTip = text; return v }
    func updateNSView(_ v: TipView, context: Context) { if v.toolTip != text { v.toolTip = text } }
}

extension View {
    /// Tooltip shown on hover (reliable replacement for `.help`); empty text = no tooltip.
    func tip(_ text: String) -> some View {
        overlay { if !text.isEmpty { ToolTipArea(text: text) } }
    }
}
