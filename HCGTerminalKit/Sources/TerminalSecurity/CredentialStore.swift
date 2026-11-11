import Foundation
#if canImport(Security)
import Security
#endif

/// Identifies one secret.
public struct CredentialKey: Hashable, Sendable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static func hostPassword(_ hostID: UUID) -> CredentialKey {
        CredentialKey(service: "com.hakmicapitalgroup.hcgterminal.ssh-password", account: hostID.uuidString)
    }

    public static func privateKey(_ keyID: UUID) -> CredentialKey {
        CredentialKey(service: "com.hakmicapitalgroup.hcgterminal.ssh-key", account: keyID.uuidString)
    }
}

public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case unexpectedStatus(Int32)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): "Keychain error \(status)."
        case .unavailable: "Secure credential storage is not available on this platform."
        }
    }
}

/// Secure storage for secrets (SSH passwords, private keys).
public protocol CredentialStore: Sendable {
    func save(_ secret: Data, for key: CredentialKey) throws
    func load(_ key: CredentialKey) throws -> Data?
    func delete(_ key: CredentialKey) throws
}

#if canImport(Security)
/// Keychain-backed store. Items are device-only and readable only while the device is
/// unlocked (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), so they are excluded from
/// backups and never sync.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    private func baseQuery(_ key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
    }

    public func save(_ secret: Data, for key: CredentialKey) throws {
        let query = baseQuery(key)
        let update: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(update) { $1 }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func load(_ key: CredentialKey) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(status) }
        return result as? Data
    }

    public func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }
}
#endif

/// Process-memory store for tests and for platforms without a Keychain. Never persists.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [CredentialKey: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ secret: Data, for key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = secret
    }

    public func load(_ key: CredentialKey) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func delete(_ key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }
}

/// The platform's default secure store.
public enum DefaultCredentialStore {
    public static func make() -> any CredentialStore {
        #if canImport(Security)
        KeychainCredentialStore()
        #else
        InMemoryCredentialStore()
        #endif
    }
}
