import Foundation
import Security
import Supabase

/// Keychain-backed Supabase session storage, pinned to this device.
///
/// The Supabase SDK's default keychain accessibility (`AfterFirstUnlock`) is a
/// device-transferable class, so a session can migrate to another device via an
/// encrypted backup restore. This storage writes items with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the access/refresh
/// token cannot leave the device it was issued to.
///
/// Note: because this uses its own keychain service, an existing session stored
/// under the SDK default will not be found on first launch after the update —
/// affected users sign in once more, then stay pinned.
final class KeychainAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let service = "com.divinedavis.crease.supabase.auth"

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func store(key: String, value: Data) throws {
        SecItemDelete(baseQuery(key) as CFDictionary)
        var attrs = baseQuery(key)
        attrs[kSecValueData as String] = value
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
        return out as? Data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }

    enum KeychainError: Error { case unexpected(OSStatus) }
}
