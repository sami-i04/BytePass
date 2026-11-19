import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct SiteManagerView: View {
    @ObservedObject var store = AppModel.shared.store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = SiteUI()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 240)
                Divider()
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Aus .env importieren …") { importEnv() }
                Spacer()
                Button("Verbinden") {
                    commit()
                    if let d = ui.draft { dismiss(); AppModel.shared.connect(d) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(ui.draft == nil || ui.draft?.host.isEmpty == true || ui.draft?.user.isEmpty == true)
            }
            .padding(14)
        }
        .background(Theme.bg)
        .onDisappear { commit() }
        .onAppear {
            ui.selected = AppModel.shared.currentSite?.id ?? AppModel.shared.lastSiteID ?? store.sites.first?.id
            if !store.sites.contains(where: { $0.id == ui.selected }) { ui.selected = store.sites.first?.id }
            load(ui.selected)
        }
        .onChange(of: ui.selected) { old, new in commit(); load(new) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Meine Server").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
            List(selection: $ui.selected) {
                ForEach(store.sites) { s in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.download.opacity(0.12)).frame(width: 28, height: 28)
                            Image(systemName: "server.rack").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.download)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(s.host.isEmpty ? "—" : "\(s.user)@\(s.host)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(s.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 2) {
                IconButton(symbol: "plus", help: String(localized: "Neuer Server")) { addSite() }
                IconButton(symbol: "minus", help: String(localized: "Server löschen")) { deleteSite() }.disabled(ui.draft == nil)
                IconButton(symbol: "plus.square.on.square", help: String(localized: "Duplizieren")) { duplicate() }.disabled(ui.draft == nil)
                Spacer()
            }
            .padding(6)
        }
        .background(Theme.card.opacity(0.6))
    }

    @ViewBuilder private var editor: some View {
        if ui.draft != nil {
            Form {
                Section("Allgemein") {
                    TextField("Name", text: binding(\.name))
                    Toggle("Schnellzugriff über den Blitz-Button", isOn: Binding(get: { ui.draft?.quick == true }, set: { ui.draft?.quick = $0 ? true : nil }))
                    LabeledContent("Protokoll") { Text("SFTP – SSH File Transfer Protocol").foregroundStyle(.secondary) }
                }
                Section("Verbindung") {
                    TextField("Server", text: binding(\.host), prompt: Text("example.com"))
                    TextField("Port", value: binding(\.port), format: .number.grouping(.never))
                    TextField("Benutzer", text: binding(\.user))
                    LabeledContent("Passwort") {
                        HStack {
                            if ui.showPassword { TextField("", text: $ui.password).labelsHidden() }
                            else { SecureField("", text: $ui.password).labelsHidden() }
                            Button { ui.showPassword.toggle() } label: { Image(systemName: ui.showPassword ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless).help(ui.showPassword ? String(localized: "Verbergen") : String(localized: "Anzeigen"))
                        }
                    }
                }
                Section {
                    TextField("Remote-Verzeichnis", text: binding(\.remoteDir), prompt: Text("Standard: Home-Verzeichnis"))
                    LabeledContent("Lokales Verzeichnis") {
                        HStack {
                            TextField("", text: binding(\.localDir), prompt: Text("Standard: Benutzerordner")).labelsHidden()
                            Button("Wählen …") { chooseLocalDir() }
                        }
                    }
                } header: { Text("Startverzeichnisse") } footer: {
                    Text("Zugangsdaten werden von BytePass gespeichert (nur für deinen Benutzer lesbar).").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                Text("Kein Server ausgewählt").font(.system(size: 14, weight: .semibold))
                Button("Neuen Server anlegen") { addSite() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func binding<T>(_ kp: WritableKeyPath<Site, T>) -> Binding<T> {
        Binding(get: { (ui.draft ?? Site(name: "", host: "", user: ""))[keyPath: kp] }, set: { ui.draft?[keyPath: kp] = $0 })
    }

    private func load(_ id: UUID?) {
        guard let id, let s = store.sites.first(where: { $0.id == id }) else { ui.draft = nil; ui.password = ""; ui.originalPassword = ""; return }
        ui.draft = s
        ui.password = store.password(for: s)
        ui.originalPassword = ui.password
        ui.showPassword = false
    }

    private func commit() {
        guard let d = ui.draft, store.sites.contains(where: { $0.id == d.id }) else { return }
        var s = d
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        s.user = s.user.trimmingCharacters(in: .whitespaces)
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = s.host.isEmpty ? String(localized: "Neuer Server") : s.host }
        s.secret = store.sites.first(where: { $0.id == s.id })?.secret
        if store.sites.first(where: { $0.id == s.id }) != s { store.upsert(s) }
        if ui.password != ui.originalPassword { store.setPassword(ui.password, for: s); ui.originalPassword = ui.password }
    }

    private func addSite() {
        commit()
        let s = Site(name: String(localized: "Neuer Server"), host: "", user: "")
        store.upsert(s)
        ui.selected = s.id
    }
    private func duplicate() {
        commit()
        guard let d = ui.draft else { return }
        var s = d; s.id = UUID(); s.name += String(localized: " (Kopie)")
        store.upsert(s)
        store.setPassword(ui.password, for: s)
        ui.selected = s.id
    }
    private func deleteSite() {
        guard let d = ui.draft, Prompt.confirm(String(localized: "„\(d.name)“ löschen?"), String(localized: "Der Server und sein gespeichertes Passwort werden entfernt."), ok: String(localized: "Löschen"), destructive: true) else { return }
        ui.draft = nil
        store.remove(d)
        ui.selected = store.sites.first?.id
    }
    private func importEnv() {
        let p = NSOpenPanel()
        p.showsHiddenFiles = true
        p.canChooseDirectories = false
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard p.runModal() == .OK, let u = p.url else { return }
        commit()
        if let s = store.importEnv(u) { ui.selected = s.id; load(s.id) }
        else { Prompt.info(String(localized: "Import fehlgeschlagen"), String(localized: "In der Datei wurden keine Einträge „server“ und „user“ gefunden.")) }
    }
    private func chooseLocalDir() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        if p.runModal() == .OK, let u = p.url { ui.draft?.localDir = u.path }
    }
}
