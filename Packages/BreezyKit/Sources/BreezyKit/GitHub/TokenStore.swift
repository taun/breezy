import Foundation
import Security

/// Where the GitHub token lives. The app uses the Keychain; tests use `MemoryTokenStore`.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String) throws
    func delete()
}

/// The token in the Keychain, synced through iCloud Keychain so every device signed in to the same Apple ID
/// (with iCloud Keychain on) gets it after it is entered once. Needs builds signed with the same team, since the
/// item lives in the app's default access group (TeamID.bundle-id).
public struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String

    public init(service: String = "org.taun.Breezy", account: String = "github-token") {
        self.service = service
        self.account = account
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// The synced item. On macOS it must be in the data protection keychain (the iOS-style one) to sync.
    private var synced: [String: Any] {
        var q = base
        q[kSecAttrSynchronizable as String] = true
        q[kSecUseDataProtectionKeychain as String] = true
        return q
    }

    /// The device-only item earlier versions saved (on macOS, in the legacy file keychain).
    private var legacy: [String: Any] {
        var q = base
        q[kSecAttrSynchronizable as String] = false
        return q
    }

    public enum Status: Equatable, Sendable {
        case synced
        /// Saved, but only on this device; the reason sync is not possible (usually signing / entitlements).
        case deviceOnly(String)
        case missing
    }

    /// Where the token is, moving a device-only token from an earlier version into iCloud Keychain when possible.
    public func status() -> Status {
        if read(synced) != nil { return .synced }
        guard let old = read(legacy) else { return .missing }
        do {
            try save(old)
            SecItemDelete(legacy as CFDictionary)
            return .synced
        } catch {
            return .deviceOnly(error.localizedDescription)
        }
    }

    public func load() -> String? {
        _ = status() // migrate if needed
        return read(synced) ?? read(legacy)
    }

    public func save(_ token: String) throws {
        SecItemDelete(synced as CFDictionary)
        var q = synced
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // the only class iCloud Keychain syncs
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Removes the token here and, through iCloud Keychain, on the other devices.
    public func delete() {
        SecItemDelete(synced as CFDictionary)
        SecItemDelete(legacy as CFDictionary)
    }

    private func read(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        if status == errSecMissingEntitlement {
            return "\(detail). Sign the app with your development team in Xcode so the Keychain can sync the token."
        }
        return detail
    }
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(_ token: String? = nil) { self.token = token }
    public func load() -> String? { lock.withLock { token } }
    public func save(_ token: String) throws { lock.withLock { self.token = token } }
    public func delete() { lock.withLock { token = nil } }
}
