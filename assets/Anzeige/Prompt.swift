import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

@MainActor enum Prompt {
    static func text(_ title: String, _ message: String, initial: String, ok: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: String(localized: "Abbrechen"))
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = initial
        a.accessoryView = tf
        a.window.initialFirstResponder = tf
        return a.runModal() == .alertFirstButtonReturn ? tf.stringValue.trimmingCharacters(in: .whitespaces) : nil
    }
    static func password(_ title: String, _ message: String, confirm: Bool) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: String(localized: "Abbrechen"))
        let p1 = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 280, height: 24))
        p1.placeholderString = String(localized: "Passwort")
        let p2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        p2.placeholderString = String(localized: "Passwort wiederholen")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: confirm ? 54 : 24))
        box.addSubview(p1)
        if confirm { box.addSubview(p2) }
        a.accessoryView = box
        a.window.initialFirstResponder = p1
        while a.runModal() == .alertFirstButtonReturn {
            if p1.stringValue.isEmpty { continue }
            if confirm && p1.stringValue != p2.stringValue { info(String(localized: "Passwörter stimmen nicht überein"), ""); continue }
            return p1.stringValue
        }
        return nil
    }
    static func confirmTyped(_ title: String, _ message: String, word: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message + String(localized: "\n\nZum Bestätigen „\(word)“ eingeben:")
        a.alertStyle = .critical
        let b = a.addButton(withTitle: ok); b.hasDestructiveAction = true
        a.addButton(withTitle: String(localized: "Abbrechen"))
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = tf
        a.window.initialFirstResponder = tf
        return a.runModal() == .alertFirstButtonReturn && tf.stringValue == word
    }
    static func confirm(_ title: String, _ message: String, ok: String, destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = destructive ? .critical : .informational
        let b = a.addButton(withTitle: ok)
        b.hasDestructiveAction = destructive
        a.addButton(withTitle: String(localized: "Abbrechen"))
        return a.runModal() == .alertFirstButtonReturn
    }
    static func info(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
    static func overwrite(_ names: [String]) -> OverwriteChoice {
        let a = NSAlert()
        a.messageText = names.count == 1 ? String(localized: "„\(names[0])“ existiert bereits am Ziel.") : String(localized: "\(names.count) Elemente existieren bereits am Ziel.")
        a.informativeText = names.count > 1 ? names.prefix(8).joined(separator: "\n") + (names.count > 8 ? "\n…" : "")
                                            : String(localized: "Soll das vorhandene Element ersetzt werden? Ordner werden zusammengeführt.")
        a.addButton(withTitle: String(localized: "Überschreiben"))
        a.addButton(withTitle: String(localized: "Überspringen"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        switch a.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .skip
        default: return .cancel
        }
    }
}
