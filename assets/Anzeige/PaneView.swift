import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct PaneView: View {
    @ObservedObject var pane: PaneModel
    @ObservedObject var app = AppModel.shared
    @StateObject private var ui = PaneUI()

    private var isLocal: Bool { pane.kind == .local }
    private var enabled: Bool { isLocal || app.isConnected }
    private var tint: Color { isLocal ? Theme.upload : Theme.download }

    var body: some View {
        Group {
            if isLocal {
                VStack(spacing: 0) {
                    header
                    Divider().opacity(0.6)
                    listArea
                    Divider().opacity(0.6)
                    footer
                }
                .modifier(Card(highlight: ui.dropTarget))
            } else {
                GeometryReader { geo in
                    let full = geo.size.height
                    let handleH: CGFloat = ui.listShown ? 14 : 0
                    let top = ui.listShown ? min(max(ui.treeHeight, 150), max(150, full - 180)) : full
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            header
                            Divider().opacity(0.6)
                            if enabled {
                                ScrollView(.vertical) {
                                    if let root = app.treeRoot {
                                        TreeRow(node: root, depth: 0, pane: pane)
                                            .padding(.vertical, 6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            } else {
                                disconnected
                            }
                        }
                        .frame(height: top)
                        .modifier(Card())
                        SplitHandle(height: $ui.treeHeight)
                            .frame(height: handleH)
                            .opacity(ui.listShown ? 1 : 0)
                            .allowsHitTesting(ui.listShown)
                        VStack(spacing: 0) {
                            listArea
                            Divider().opacity(0.6)
                            footer
                        }
                        .frame(height: max(0, full - top - handleH))
                        .modifier(Card(highlight: ui.dropTarget))
                        .opacity(ui.listShown ? 1 : 0)
                    }
                }
                .onAppear { ui.listShown = app.isConnected }
                .onChange(of: app.isConnected) { _, connected in
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { ui.listShown = connected }
                }
            }
        }
        .onDrop(of: [AppModel.dragType, .fileURL, .utf8PlainText], isTargeted: $ui.dropTarget) { app.handleDrop($0, onto: pane) }
        .onChange(of: pane.path) { _, new in ui.pathText = new }
        .onAppear { ui.pathText = pane.path }
    }

    private var listArea: some View {
        ZStack(alignment: .topTrailing) {
            table
            if pane.loading {
                ProgressView().controlSize(.small).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)).frame(width: 30, height: 30)
                    Image(systemName: isLocal ? "laptopcomputer" : "server.rack").font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(isLocal ? String(localized: "Dieser Mac") : String(localized: "Server")).font(.system(size: 13, weight: .semibold))
                    Text(isLocal ? String(localized: "Lokale Dateien") : (app.isConnected ? String(localized: "SFTP · verbunden") : String(localized: "Nicht verbunden")))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 0) {
                    IconButton(symbol: "arrow.clockwise", help: String(localized: "Aktualisieren")) { app.refresh(pane) }
                    IconButton(symbol: "folder.badge.plus", help: String(localized: "Neuer Ordner")) { app.newFolder(in: pane) }
                    IconButton(symbol: pane.showHidden ? "eye" : "eye.slash",
                               help: pane.showHidden ? String(localized: "Versteckte Dateien ausblenden") : String(localized: "Versteckte Dateien anzeigen")) { pane.showHidden.toggle() }
                    if isLocal {
                        Menu {
                            Button("Benutzerordner") { app.navigate(pane, to: "~") }
                            Button("Schreibtisch") { app.navigate(pane, to: "~/Desktop") }
                            Button("Dokumente") { app.navigate(pane, to: "~/Documents") }
                            Button("Downloads") { app.navigate(pane, to: "~/Downloads") }
                            Divider()
                            Button("Ordner wählen …") { chooseLocal() }
                        } label: { Image(systemName: "star") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).help("Favoriten")
                    }
                }
                .disabled(!enabled)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(tint.opacity(0.8))
                TextField("Pfad", text: $ui.pathText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { app.navigate(pane, to: ui.pathText) }
                    .disabled(!enabled)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
    }

    private var table: some View {
        FileListView(pane: pane, menu: { contextMenu($0) })
            .opacity(enabled ? 1 : 0)
    }

    @ViewBuilder private func contextMenu(_ ids: Set<String>) -> some View {
        let items = pane.items.filter { ids.contains($0.id) }
        if !items.isEmpty {
            Button(isLocal ? String(localized: "Hochladen") : String(localized: "Herunterladen")) { app.transfer(items, from: pane) }.disabled(!app.isConnected)
            if items.count == 1, items[0].isDir { Button("Öffnen") { app.open(items[0], in: pane) } }
            Divider()
            if items.count == 1 { Button("Umbenennen …") { app.rename(items[0], in: pane) } }
            if isLocal {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: pane.fullPath($0.name)) }) }
            }
            if !isLocal, items.count == 1, items[0].isDir {
                Button("Backup dieses Ordners erstellen …") { AppModel.shared.backups.create(folder: pane.fullPath(items[0].name)) }
            }
            Button("Pfad kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map { pane.fullPath($0.name) }.joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button(isLocal ? String(localized: "In den Papierkorb") : String(localized: "Löschen …"), role: .destructive) { app.delete(items, in: pane) }
        } else {
            Button("Neuer Ordner …") { app.newFolder(in: pane) }
            Button("Aktualisieren") { app.refresh(pane) }
        }
    }

    private var disconnected: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Theme.download.opacity(0.1)).frame(width: 72, height: 72)
                Image(systemName: "server.rack").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.download)
            }
            Text("Mit keinem Server verbunden").font(.system(size: 15, weight: .semibold))
            Text("Oben einen Server auswählen, um loszulegen.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if case .connecting = app.conn { ProgressView().controlSize(.small) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        let sel = pane.selectedItems
        let selSize = sel.filter { !$0.isDir }.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 10) {
            if let err = pane.error {
                Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
            } else if !sel.isEmpty {
                Text("\(sel.count) ausgewählt" + (selSize > 0 ? " · \(Fmt.size(selSize))" : "")).foregroundStyle(.secondary)
            } else {
                Text(enabled ? String(localized: "\(pane.visible.count) Elemente") : "").foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 0) {
                Button { app.goBack(pane) } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 20) }
                    .help("Zurück").disabled(pane.history.isEmpty)
                Divider().frame(height: 16)
                Button { app.goForward(pane) } label: { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 20) }
                    .help("Vor").disabled(pane.forward.isEmpty)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 2).padding(.vertical, 2)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .disabled(!enabled)
            Button {
                app.transfer(sel, from: pane)
            } label: {
                Label(isLocal ? String(localized: "Hochladen") : String(localized: "Herunterladen"),
                      systemImage: isLocal ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.small)
            .disabled(sel.isEmpty || !app.isConnected)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func chooseLocal() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.directoryURL = URL(fileURLWithPath: pane.path)
        if p.runModal() == .OK, let u = p.url { app.navigate(pane, to: u.path) }
    }
}

struct TreeRow: View {
    @ObservedObject var node: TreeNode
    let depth: Int
    @ObservedObject var pane: PaneModel

    var body: some View {
        let current = pane.path == node.path
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Button { AppModel.shared.toggle(node) } label: {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 14, height: 14)
                        .opacity(node.children?.isEmpty == true ? 0 : 1)
                }
                .buttonStyle(.borderless)
                Image(systemName: node.path == "/" ? "externaldrive.fill" : (current ? "folder.fill" : "folder"))
                    .font(.system(size: 12)).foregroundStyle(Theme.download)
                Text(node.name).font(.system(size: 12, weight: current ? .semibold : .regular)).lineLimit(1)
                if node.loading { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16 + 8).padding(.trailing, 8).padding(.vertical, 3)
            .background(current ? Theme.download.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture { AppModel.shared.navigate(pane, to: node.path) }
            if node.expanded, let kids = node.children {
                ForEach(kids.filter { pane.showHidden || !$0.name.hasPrefix(".") }) { TreeRow(node: $0, depth: depth + 1, pane: pane) }
            }
        }
    }
}
