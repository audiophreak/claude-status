import AppKit
import ClaudeStatusCore
import SwiftUI

/// Colour + symbol + text for each state. Colour is never the only signal.
enum StatusStyle {
    static func symbol(_ s: SessionState, activity: Activity = .none, unobserved: Bool = false) -> String {
        if unobserved { return "eye.slash.circle" }
        switch s {
        case .working:
            switch activity {
            case .background: return "hourglass.circle.fill"
            case .scheduled: return "clock.circle.fill"
            default: return "arrow.triangle.2.circlepath.circle.fill"
            }
        case .complete: return "checkmark.circle.fill"
        case .waiting: return "exclamationmark.bubble.fill"
        case .error: return "xmark.octagon.fill"
        case .idle: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    static func symbol(_ e: EffectiveSession) -> String { symbol(e.state, activity: e.activity, unobserved: e.unobserved) }

    static func nsColor(_ s: SessionState, activity: Activity = .none) -> NSColor {
        if s == .working && activity == .scheduled { return .systemTeal }
        switch s {
        case .working: return .systemBlue
        case .complete: return .systemGreen
        case .waiting: return .systemOrange
        case .error: return .systemRed
        case .idle, .unknown: return .systemGray
        }
    }

    static func color(_ s: SessionState, activity: Activity = .none) -> Color { Color(nsColor: nsColor(s, activity: activity)) }

    /// Non-template coloured symbol for the menu bar (system colours adapt to light/dark).
    static func menuBarImage(_ s: SessionState, activity: Activity = .none) -> NSImage {
        // Two-colour palette: glyph (primary layer) in white, shape (secondary) in the state
        // colour, so the checkmark / arrows / x / ! remain visible on every state.
        let palette: [NSColor] = (s == .idle || s == .unknown) ? [nsColor(s)] : [.white, nsColor(s, activity: activity)]
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        let base = NSImage(systemSymbolName: symbol(s, activity: activity), accessibilityDescription: "Claude Status: \(s.label)")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = false
        return img
    }
}

struct StateBadge: View {
    let state: SessionState
    var activity: Activity = .none
    var unobserved = false
    var body: some View {
        Image(systemName: StatusStyle.symbol(state, activity: activity, unobserved: unobserved))
            .symbolRenderingMode(.palette)
            .foregroundStyle((state == .idle || state == .unknown) ? Color(nsColor: .systemGray) : .white, StatusStyle.color(state, activity: activity))
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 18)
            .accessibilityLabel(unobserved ? "Unknown, not observed" : (activity == .scheduled ? "Continuation scheduled" : (activity == .background ? "Working in the background" : state.label)))
    }
}
