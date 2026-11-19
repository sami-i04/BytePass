import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor final class PickerModel: ObservableObject {
    @Published var path = ""
    @Published var dirs: [FileItem] = []
    @Published var selected: String?
    @Published var loading = false
    @Published var error: String?

    func load(_ p: String) {
        guard let s = AppModel.shared.session else { return }
        let target = RPath.normalize(p)
        loading = true
        Task {
            defer { loading = false }
            do {
                let items = try await s.list(target)
                dirs = items.filter { $0.isDir || $0.isLink }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                path = target
                selected = nil
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct RemoteFolderPicker: View {
    let start: String
    var title = String(localized: "Ordner zum Sichern auswählen")
    var action = String(localized: "Diesen Ordner sichern")
    var describe: (String) -> String = { String(localized: "Gesichert wird: \($0)") }
    let done: (String?) -> Void
    @StateObject private var m = PickerModel()

    private var chosen: String { m.selected.map { RPath.join(m.path, $0) } ?? m.path }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Button { m.load(RPath.parent(m.path)) } label: { Image(systemName: "chevron.up") }
                        .disabled(m.path == "/" || m.path.isEmpty).help("Übergeordneter Ordner")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            let parts = m.path.split(separator: "/").map(String.init)
                            Button("/") { m.load("/") }.buttonStyle(.borderless)
                            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                                Button(p) { m.load("/" + parts[0...i].joined(separator: "/")) }.buttonStyle(.borderless)
                            }
                        }
                        .font(.system(size: 12))
                    }
                    if m.loading { ProgressView().controlSize(.small) }
                }
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if m.dirs.isEmpty && !m.loading {
                        Text(m.error ?? String(localized: "Keine Unterordner")).foregroundStyle(.secondary).padding(30)
                    }
                    ForEach(m.dirs) { d in
                        let sel = m.selected == d.name
                        HStack(spacing: 8) {
                            Image(systemName: sel ? "folder.fill" : "folder").foregroundStyle(Theme.download)
                            Text(d.name).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Color.accentColor.opacity(0.22) : Color.clear).padding(.horizontal, 4).padding(.vertical, 2))
                        .contentShape(Rectangle())
                        .gesture(TapGesture(count: 2).onEnded { m.load(RPath.join(m.path, d.name)) })
                        .simultaneousGesture(TapGesture().onEnded { m.selected = d.name })
                        Divider().opacity(0.5).padding(.leading, 14)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text(describe(chosen)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(action) { done(chosen) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(m.path.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 460)
        .onAppear { m.load(start) }
    }
}
