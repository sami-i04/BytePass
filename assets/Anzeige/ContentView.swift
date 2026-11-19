import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

struct ContentView: View {
    @ObservedObject var app = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    PaneView(pane: app.local)
                    QuickBar()
                }
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 6, trailing: 6))
                PaneView(pane: app.remote)
                    .padding(EdgeInsets(top: 12, leading: 6, bottom: 6, trailing: 12))
            }
            .frame(minHeight: 420)
            LogTicker()
                .padding(EdgeInsets(top: 6, leading: 12, bottom: 12, trailing: 12))
        }
        .background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .principal) { StatusChip() }
            ToolbarItemGroup(placement: .primaryAction) {
                if app.conn == .disconnected {
                    let quick = app.quickSites
                    if quick.count > 1 {
                        Menu {
                            ForEach(quick) { s in Button(s.name) { app.connect(s) } }
                        } label: { Label("Verbinden", systemImage: "bolt.fill") }
                        .help("Mit Server verbinden")
                    } else {
                        Button {
                            if let s = quick.first { app.connect(s) } else { app.openSettings(0) }
                        } label: { Label("Verbinden", systemImage: "bolt.fill") }
                        .help(quick.first.map { String(localized: "Mit \($0.name) verbinden") } ?? String(localized: "Im Server-Manager einen Server für den Schnellzugriff anhaken"))
                    }
                } else {
                    Button { app.disconnect() } label: { Label("Trennen", systemImage: "bolt.slash.fill") }.help("Verbindung trennen")
                }
                Button { app.activityTab = 0; openWindow(id: "activity") } label: {
                    Label(app.activeJobs > 0 ? String(localized: "Warteschlange & Protokoll (\(app.activeJobs))") : String(localized: "Warteschlange & Protokoll"),
                          systemImage: app.activeJobs > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                }
                .help("Warteschlange & Protokoll öffnen")
                Button { app.openSettings(app.settingsTab) } label: { Label("Einstellungen", systemImage: "gearshape") }
                    .help("Einstellungen (⌘,)")
            }
        }
        .onAppear { app.openWindowHandler = { id in openWindow(id: id) } }
    }
}

struct StatusChip: View {
    @ObservedObject var app = AppModel.shared
    var body: some View {
        HStack(spacing: 7) {
            switch app.conn {
            case .disconnected:
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text("Nicht verbunden").foregroundStyle(.secondary)
            case .connecting(let s):
                ProgressView().controlSize(.mini)
                Text("Verbinde mit \(s.name) …")
            case .connected(let s):
                Circle().fill(Theme.download).frame(width: 8, height: 8)
                Text(s.name).fontWeight(.medium)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .lineLimit(1)
    }
}

final class PaneUI: ObservableObject {
    @Published var dropTarget = false
    @Published var pathText = ""
    @Published var listShown = false
    @Published var treeHeight: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "treeHeight").nonZero ?? 260)
}
extension Double { var nonZero: Double? { self == 0 ? nil : self } }

struct SplitHandle: View {
    @Binding var height: CGFloat
    @StateObject private var drag = DragState()
    final class DragState: ObservableObject { var start: CGFloat? }
    var body: some View {
        ZStack {
            Color.clear.frame(height: 14)
            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 36, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if drag.start == nil { drag.start = height }
                let h = min(max((drag.start ?? height) + v.translation.height, 150), 600).rounded()
                if abs(h - height) >= 1 {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { height = h }
                }
            }
            .onEnded { _ in drag.start = nil; UserDefaults.standard.set(Double(height), forKey: "treeHeight") })
    }
}
final class SiteUI: ObservableObject {
    @Published var selected: UUID?
    @Published var draft: Site?
    @Published var password = ""
    @Published var originalPassword = ""
    @Published var showPassword = false
}
