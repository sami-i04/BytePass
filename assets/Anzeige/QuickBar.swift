import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

final class QuickStore: ObservableObject {
    static let shared = QuickStore()
    @Published var slots: [String] {
        didSet { UserDefaults.standard.set(slots, forKey: "quickSlots") }
    }
    init() {
        var s = UserDefaults.standard.stringArray(forKey: "quickSlots") ?? []
        while s.count < 5 { s.append("") }
        slots = Array(s.prefix(5))
    }
}

struct QuickBar: View {
    @ObservedObject var store = QuickStore.shared
    @ObservedObject var local = AppModel.shared.local

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(Theme.upload)
                .help("Schnellzugriff")
            ForEach(0..<5, id: \.self) { i in slot(i) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .modifier(Card())
    }

    @ViewBuilder private func slot(_ i: Int) -> some View {
        let path = store.slots[i]
        if path.isEmpty {
            Button { choose(i) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("Ordner").font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color.secondary.opacity(0.4)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ordner für Schnellzugriff festlegen")
            .contextMenu {
                Button("Aktuellen Ordner hier speichern") { store.slots[i] = local.path }
                Button("Ordner wählen …") { choose(i) }
            }
        } else {
            let active = local.path == path
            Button { AppModel.shared.navigate(local, to: path) } label: {
                HStack(spacing: 6) {
                    Image(nsImage: Icons.sidebarSymbol(path)).renderingMode(.template)
                        .font(.system(size: 14)).foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    Text(path == "/" ? "Macintosh HD" : Icons.displayName(path))
                        .font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.upload.opacity(0.16) : Theme.subtle))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(path)
            .contextMenu {
                Button("Öffnen") { AppModel.shared.navigate(local, to: path) }
                Button("Durch aktuellen Ordner ersetzen") { store.slots[i] = local.path }
                Button("Ordner wählen …") { choose(i) }
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Divider()
                Button("Entfernen", role: .destructive) { store.slots[i] = "" }
            }
        }
    }

    private func choose(_ i: Int) {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.prompt = String(localized: "Festlegen")
        p.directoryURL = URL(fileURLWithPath: store.slots[i].isEmpty ? local.path : store.slots[i])
        if p.runModal() == .OK, let u = p.url { store.slots[i] = u.path }
    }
}
