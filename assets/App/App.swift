import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let d = UserDefaults.standard
        if !d.bool(forKey: "migratedFromDateiZilla"), let old = UserDefaults(suiteName: "local.dateizilla.app") {
            for k in ["quickSlots", "lastSite", "appearance", "treeHeight", "kcMigrated"] {
                if let v = old.object(forKey: k), d.object(forKey: k) == nil { d.set(v, forKey: k) }
            }
            d.set(true, forKey: "migratedFromDateiZilla")
        }
        if let socks = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
            for f in socks where f.hasPrefix("dz-") && f.hasSuffix(".sock") {
                let x = Process(); x.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                x.arguments = ["-S", "/tmp/" + f, "-O", "exit", "x"]
                x.standardOutput = FileHandle.nullDevice; x.standardError = FileHandle.nullDevice
                try? x.run(); x.waitUntilExit()
                try? FileManager.default.removeItem(atPath: "/tmp/" + f)
            }
        }
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "ControlPath=/tmp/dz-"]; try? k.run(); k.waitUntilExit()
        MainActor.assumeIsolated {
            let m = AppModel.shared
            m.setAppearance(m.appearance)
            if !UserDefaults.standard.bool(forKey: "kcMigrated") { m.store.migrateKeychain(); UserDefaults.standard.set(true, forKey: "kcMigrated") }
            if ProcessInfo.processInfo.environment["DZ_AUTOTEST"] != nil {
                m.connect(Site(name: "Test", host: "__localtest__", user: "test"))
                if let nav = ProcessInfo.processInfo.environment["DZ_AUTONAV"] {
                    Task { @MainActor in
                        for p in nav.split(separator: ",") {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            m.navigate(m.remote, to: String(p))
                        }
                    }
                }
            }
            m.addLog(.info, String(localized: "BytePass bereit. \(m.store.sites.count) gespeicherte(r) Server."))
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { AppModel.shared.session?.disconnect() }
    }
}

struct BytePassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("BytePass", id: "main") {
            ContentView()
                .frame(minWidth: 924, minHeight: 602)
        }
        .defaultSize(width: 924, height: 602)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen …") { AppModel.shared.openSettings(AppModel.shared.settingsTab) }.keyboardShortcut(",")
            }
            CommandMenu("Server") {
                Button("Server-Manager …") { AppModel.shared.openSettings(0) }.keyboardShortcut("s")
                Button("Trennen") { AppModel.shared.disconnect() }.keyboardShortcut("d")
                Divider()
                Button("Lokal aktualisieren") { AppModel.shared.refresh(AppModel.shared.local) }.keyboardShortcut("r", modifiers: [.command, .option])
                Button("Server aktualisieren") { AppModel.shared.refresh(AppModel.shared.remote) }.keyboardShortcut("r")
            }
            CommandGroup(after: .windowList) {}
            CommandMenu("Darstellung") {
                Button("Wie System") { AppModel.shared.setAppearance(0) }
                Button("Hell") { AppModel.shared.setAppearance(1) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Dunkel") { AppModel.shared.setAppearance(2) }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        Window("Einstellungen", id: "settings") { SettingsView() }
            .defaultSize(width: 900, height: 600)
            .windowResizability(.contentMinSize)
        Window("Warteschlange & Protokoll", id: "activity") { ActivityWindow() }
            .defaultSize(width: 720, height: 400)
            .windowResizability(.contentMinSize)
    }
}
