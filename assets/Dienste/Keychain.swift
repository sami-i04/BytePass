import SwiftUI
import AppKit
import Combine
import Security
import UniformTypeIdentifiers
import os

enum Keychain {
    static let service = "local.dateizilla.app"
    private static func base(_ acc: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: acc]
    }
    static func get(_ acc: String) -> String? {
        var q = base(acc)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ value: String, for acc: String) {
        SecItemDelete(base(acc) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base(acc)
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
