import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct SettingsView: View {
    @ObservedObject var app = AppModel.shared
    var body: some View {
        TabView(selection: $app.settingsTab) {
            SiteManagerView().tabItem { Label("Server", systemImage: "server.rack") }.tag(0)
            AppearanceSettings().tabItem { Label("Darstellung", systemImage: "circle.lefthalf.filled") }.tag(1)
            BackupSettings().tabItem { Label("Backup", systemImage: "archivebox") }.tag(2)
        }
        .frame(minWidth: 820, minHeight: 540)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var app = AppModel.shared
    var body: some View {
        Form {
            Section("Erscheinungsbild") {
                Picker("Darstellung", selection: Binding(get: { app.appearance }, set: { app.setAppearance($0) })) {
                    Text("Wie System").tag(0)
                    Text("Hell").tag(1)
                    Text("Dunkel").tag(2)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }
}

final class RestoreUI: ObservableObject {
    @Published var backup: UUID?
    @Published var target: UUID?
    @Published var replaceAll = false
    @Published var safety = true
    @Published var server: String?
    @Published var picking = false
    @Published var restoreItem: BackupMeta?
    @Published var scrollTick = 0
}

struct BackupSettings: View {
    @ObservedObject var app = AppModel.shared
    @ObservedObject var store = AppModel.shared.backups
    @StateObject private var ui = RestoreUI()

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if let b = store.busy {
                    Section("Aktueller Vorgang") {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(b).fontWeight(.medium)
                            Spacer()
                        }
                        if let j = store.job { JobRow(job: j).padding(.horizontal, -14) }
                    }
                }
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.currentSite.map { String(localized: "Verbunden mit \($0.name)") } ?? String(localized: "Nicht verbunden")).fontWeight(.medium)
                            Text("Backups werden vom aktuell verbundenen Server erstellt.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Ordner sichern …") { ui.picking = true }
                            .disabled(!app.isConnected || store.busy != nil)
                            .help("Server-Ordner auswählen und sichern")
                        Button("Komplett-Backup") { store.create() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!app.isConnected || store.busy != nil)
                    }
                    Toggle("Mit Passwort schützen (verschlüsseltes Disk-Image, AES-256)", isOn: $store.encrypt)
                } header: { Text("Neues Backup") } footer: {
                    Text("Ordner-Backups auch per Rechtsklick auf einen Server-Ordner. Gespeichert wird in BytePass – nicht im Download-Ordner.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Section("Gespeicherte Backups") {
                    if store.items.isEmpty {
                        Text("Noch keine Backups vorhanden.").foregroundStyle(.secondary)
                    } else {
                        backupBrowser.frame(height: 280)
                    }
                }

                Section("Wiederherstellen") {
                    Picker(String(localized: "1. Ziel-Server"), selection: $ui.target) {
                        Text("Bitte wählen").tag(UUID?.none)
                        ForEach(app.store.sites) { s in Text(s.name).tag(UUID?.some(s.id)) }
                    }
                    Picker(String(localized: "2. Backup"), selection: $ui.backup) {
                        Text("Bitte wählen").tag(UUID?.none)
                        ForEach(store.items) { m in
                            Text("\(m.siteName) · \(m.title) · \(Fmt.date.string(from: m.date))").tag(UUID?.some(m.id))
                        }
                    }
                    if let m = store.items.first(where: { $0.id == ui.backup }) {
                        if m.full {
                            Picker(String(localized: "3. Modus"), selection: $ui.replaceAll) {
                                Text("Ergänzen – vorhandene Dateien bleiben, gleiche werden überschrieben").tag(false)
                                Text("Ersetzen – Server leeren und komplett aus dem Backup laden").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            if ui.replaceAll { Toggle("Vorher automatisch ein Sicherheits-Backup des Ziels erstellen", isOn: $ui.safety) }
                        } else {
                            Text("Der Ordner „\(m.relPath)“ wird im Home-Verzeichnis des Ziels ersetzt, falls vorhanden – sonst neu angelegt.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Wiederherstellen") {
                            if let m = store.items.first(where: { $0.id == ui.backup }),
                               let s = app.store.sites.first(where: { $0.id == ui.target }) {
                                store.restore(m, to: s, replaceAll: m.full && ui.replaceAll, safetyBackup: ui.safety)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(ui.backup == nil || ui.target == nil || store.busy != nil)
                    }
                }
            }
                .id("restore")
            .formStyle(.grouped)
            .onChange(of: ui.scrollTick) { _, _ in
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("restore", anchor: .top) }
            }
        }
        .onAppear {
            store.reload()
            if ui.target == nil { ui.target = app.currentSite?.id }
        }
        .sheet(item: $ui.restoreItem) { m in
            let home = app.session?.home ?? "/"
            let original = RPath.join(home, m.relPath)
            RemoteFolderPicker(start: m.full ? home : RPath.parent(original),
                               title: m.full ? String(localized: "Wohin soll das Komplett-Backup?") : String(localized: "Wohin soll „\(RPath.name(m.relPath))“?"),
                               action: String(localized: "Hier wiederherstellen"),
                               describe: { m.full ? String(localized: "Wiederherstellen nach: \($0)") : String(localized: "Wiederherstellen nach: \(RPath.join($0, RPath.name(m.relPath)))") + ($0 == RPath.parent(original) ? String(localized: "  (ursprünglicher Ort)") : "") }) { path in
                ui.restoreItem = nil
                if let path { DispatchQueue.main.async { finishRestore(m, path) } }
            }
        }
        .sheet(isPresented: $ui.picking) {
            RemoteFolderPicker(start: app.remote.path.isEmpty ? (app.session?.home ?? "/") : app.remote.path) { path in
                ui.picking = false
                if let path { store.create(folder: path) }
            }
        }
    }

    private func startRestore(_ m: BackupMeta) {
        let sites = app.store.sites
        let site = sites.first(where: { $0.id == ui.target })
            ?? app.currentSite
            ?? sites.first(where: { $0.host == m.host && $0.user == m.user })
        guard let site else { Prompt.info(String(localized: "Kein Ziel-Server"), String(localized: "Bitte unter „Wiederherstellen“ einen Ziel-Server wählen.")); return }
        ui.backup = m.id
        ui.target = site.id
        ui.scrollTick += 1
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            store.busy = String(localized: "Verbinde mit \(site.name) …")
            let ok = await store.ensureConnected(site)
            store.busy = nil
            guard ok else { Prompt.info(String(localized: "Keine Verbindung"), String(localized: "Verbindung zu \(site.name) fehlgeschlagen.")); return }
            ui.restoreItem = m
        }
    }

    private func finishRestore(_ m: BackupMeta, _ chosen: String) {
        guard let site = app.currentSite else { return }
        if m.full {
            let a = NSAlert()
            a.messageText = String(localized: "Komplett-Backup nach „\(chosen)“ wiederherstellen")
            a.informativeText = String(localized: "Ergänzen: vorhandene Dateien bleiben, gleiche werden überschrieben.\nErsetzen: Ziel wird geleert und komplett aus dem Backup geladen.")
            a.addButton(withTitle: String(localized: "Ergänzen"))
            a.addButton(withTitle: String(localized: "Ersetzen …"))
            a.addButton(withTitle: String(localized: "Abbrechen"))
            switch a.runModal() {
            case .alertFirstButtonReturn: store.restore(m, to: site, replaceAll: false, safetyBackup: false, targetPath: chosen)
            case .alertSecondButtonReturn: store.restore(m, to: site, replaceAll: true, safetyBackup: ui.safety, targetPath: chosen)
            default: break
            }
        } else {
            store.restore(m, to: site, replaceAll: false, safetyBackup: false, targetPath: RPath.join(chosen, RPath.name(m.relPath)))
        }
    }

    private var backupBrowser: some View {
        let groups = store.grouped
        let key = ui.server ?? groups.first?.key
        let current = groups.first(where: { $0.key == key })
        return HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(groups, id: \.key) { g in
                        let sel = g.key == key
                        Button { ui.server = g.key } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "server.rack").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(sel ? Color.white : Theme.download).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(g.key).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                                        .foregroundStyle(sel ? Color.white.opacity(0.8) : .secondary)
                                }
                                Spacer(minLength: 4)
                                Text("\(g.items.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(sel ? Color.white.opacity(0.9) : .secondary)
                            }
                            .foregroundStyle(sel ? Color.white : .primary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(sel ? Color.accentColor : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(width: 230)
            .background(Theme.subtle)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(current?.items ?? []) { m in
                        row(m).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(ui.backup == m.id ? Color.accentColor.opacity(0.18) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { ui.backup = m.id }
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }

    private func row(_ m: BackupMeta) -> some View {
        HStack(spacing: 10) {
            Image(systemName: m.full ? "externaldrive.fill" : "folder.fill").foregroundStyle(Theme.download).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.title).fontWeight(.medium)
                    if m.encrypted { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text("\(Fmt.date.string(from: m.date)) · \(Fmt.size(m.size)) · \(m.files) Dateien")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button { startRestore(m) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderless).help("Wiederherstellen – Zielort auf dem Server wählen")
                .disabled(store.busy != nil)
            Button { store.export(m) } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless).help("Exportieren …")
            Button { NSWorkspace.shared.activateFileViewerSelecting([store.file(m)]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Im Finder zeigen")
            Button { store.delete(m) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.red).help("Löschen")
        }
    }
}
