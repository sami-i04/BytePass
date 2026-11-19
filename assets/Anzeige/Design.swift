import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

enum Theme {
    static func dyn(_ l: NSColor, _ d: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l })
    }
    static let bg = dyn(NSColor(srgbRed: 0.955, green: 0.96, blue: 0.972, alpha: 1), NSColor(srgbRed: 0.10, green: 0.105, blue: 0.115, alpha: 1))
    static let card = dyn(.white, NSColor(srgbRed: 0.155, green: 0.16, blue: 0.172, alpha: 1))
    static let border = dyn(NSColor.black.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0.09))
    static let upload = Color(red: 0.16, green: 0.45, blue: 0.96)
    static let download = Color(red: 0.13, green: 0.66, blue: 0.42)
    static let subtle = dyn(NSColor.black.withAlphaComponent(0.04), NSColor.white.withAlphaComponent(0.07))
}

struct Card: ViewModifier {
    var highlight = false
    func body(content: Content) -> some View {
        content
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlight ? Color.accentColor : Theme.border, lineWidth: highlight ? 2 : 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
