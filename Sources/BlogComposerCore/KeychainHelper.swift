// Copyright © 2026 Randy Wilson. All rights reserved.

import Foundation
import Security

struct GmailCredentials {
    let email: String
    let appPassword: String
}

enum KeychainHelper {
    private static let server = "imap.gmail.com"
    private static let label  = "BlogComposer Gmail"

    static func save(_ creds: GmailCredentials) throws {
        delete(email: creds.email)
        guard let data = creds.appPassword.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String:       kSecClassInternetPassword,
            kSecAttrServer as String:  server,
            kSecAttrAccount as String: creds.email,
            kSecAttrLabel as String:   label,
            kSecValueData as String:   data
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.failed(status) }
    }

    static func load() -> GmailCredentials? {
        let q: [String: Any] = [
            kSecClass as String:            kSecClassInternetPassword,
            kSecAttrServer as String:       server,
            kSecAttrLabel as String:        label,
            kSecReturnAttributes as String: true,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String,
              let raw = dict[kSecValueData as String] as? Data,
              let password = String(data: raw, encoding: .utf8) else { return nil }
        return GmailCredentials(email: account, appPassword: password)
    }

    static func delete(email: String) {
        let q: [String: Any] = [
            kSecClass as String:       kSecClassInternetPassword,
            kSecAttrServer as String:  server,
            kSecAttrAccount as String: email
        ]
        SecItemDelete(q as CFDictionary)
    }

    enum KeychainError: Error, LocalizedError {
        case failed(OSStatus)
        var errorDescription: String? {
            if case .failed(let s) = self { return "Keychain error \(s)" }
            return nil
        }
    }
}
