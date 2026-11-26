import AppKit
import ClaudeStatusCore
import SwiftUI

/// Colour + symbol + text for each state. Colour is never the only signal.
enum StatusStyle {
    static func symbol(_ s: SessionState) -> String {
        switch s {
        case .working: return "arrow.triangle.2.circlepath.circle.fill"
        case .complete: return "checkmark.circle.fill"
        case .waiting: return "exclamationmark.bubble.fill"
        case .error: return "xmark.octagon.fill"
        case .idle: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    static func nsColor(_ s: SessionState) -> NSColor {
        switch s {
        case .working: return .systemBlue
        case .complete: return .systemGreen
        case .waiting: return .systemOrange
        case .error: return .systemRed
        case .idle, .unknown: return .systemGray
        }
    }

    static func color(_ s: SessionState) -> Color { Color(nsColor: nsColor(s)) }

    /// Non-template coloured symbol for the menu bar (system colours adapt to light/dark).
    static func menuBarImage(_ s: SessionState) -> NSImage {
        // Two-colour palette: glyph (primary layer) in white, shape (secondary) in the state
        // colour, so the checkmark / arrows / x / ! remain visible on every state.
        let palette: [NSColor] = (s == .idle || s == .unknown) ? [nsColor(s)] : [.white, nsColor(s)]
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        let base = NSImage(systemSymbolName: symbol(s), accessibilityDescription: "Claude Status: \(s.label)")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = false
        return img
    }
}

struct StateBadge: View {
    let state: SessionState
    var body: some View {
        Image(systemName: StatusStyle.symbol(state))
            .symbolRenderingMode(.palette)
            .foregroundStyle((state == .idle || state == .unknown) ? Color(nsColor: .systemGray) : .white, StatusStyle.color(state))
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 18)
            .accessibilityLabel(state.label)
    }
}
