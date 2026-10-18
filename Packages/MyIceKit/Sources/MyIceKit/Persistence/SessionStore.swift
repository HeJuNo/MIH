import Foundation
#if canImport(Security)
import Security
#endif

/// Replaces the original `localStorage` keys (ANALYSIS.md §4.1).
/// Design change: tokens live in the Keychain, not plain storage, and
/// logout clears *all* session data (the original kept `accounts`/`selectedClub`).
public protocol SessionStore: Sendable {
    func loadToken() -> String?
    func saveToken(_ token: String?)
    func loadUser() -> User?
    func saveUser(_ user: User?)
    func loadSelectedClub() -> String?
    func saveSelectedClub(_ id: String?)
    func loadAccounts() -> [SavedAccount]
    func saveAccounts(_ accounts: [SavedAccount])
    func loadLanguage() -> String?
    func saveLanguage(_ code: String)
}

public extension SessionStore {
    func clearSession() {
        saveToken(nil)
        saveUser(nil)
        saveSelectedClub(nil)
        saveAccounts([])
    }
}

/// UserDefaults for non-secret values + Keychain for tokens.
public final class DefaultSessionStore: SessionStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keychain: SecretStore

    public init(defaults: UserDefaults = .standard, keychain: SecretStore = KeychainSecretStore(service: "hockey.myice.session")) {
        self.defaults = defaults
        self.keychain = keychain
    }

    private enum Key { static let user = "user", club = "selectedClub", lang = "language", token = "apiToken", accounts = "accounts" }

    public func loadToken() -> String? { keychain.read(Key.token).flatMap { String(data: $0, encoding: .utf8) } }
    public func saveToken(_ token: String?) { keychain.write(Key.token, token.map { Data($0.utf8) }) }

    public func loadUser() -> User? { defaults.data(forKey: Key.user).flatMap { try? JSONDecoder().decode(User.self, from: $0) } }
    public func saveUser(_ user: User?) { defaults.set(user.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.user) }

    public func loadSelectedClub() -> String? { defaults.string(forKey: Key.club) }
    public func saveSelectedClub(_ id: String?) { defaults.set(id, forKey: Key.club) }

    // Saved accounts carry tokens → Keychain.
    public func loadAccounts() -> [SavedAccount] {
        keychain.read(Key.accounts).flatMap { try? JSONDecoder().decode([SavedAccount].self, from: $0) } ?? []
    }
    public func saveAccounts(_ accounts: [SavedAccount]) {
        keychain.write(Key.accounts, accounts.isEmpty ? nil : try? JSONEncoder().encode(accounts))
    }

    public func loadLanguage() -> String? { defaults.string(forKey: Key.lang) }
    public func saveLanguage(_ code: String) { defaults.set(code, forKey: Key.lang) }
}

public protocol SecretStore: Sendable {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ value: Data?)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ key: String) -> Data? { lock.withLock { storage[key] } }
    public func write(_ key: String, _ value: Data?) { lock.withLock { storage[key] = value } }
}

#if canImport(Security)
public struct KeychainSecretStore: SecretStore {
    let service: String
    public init(service: String) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func read(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public func write(_ key: String, _ value: Data?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
#endif

/// Supported UI languages; mirrors LanguageContext normalisation.
public enum AppLanguage: String, CaseIterable, Sendable {
    case en, it, de, fr

    public static func normalize(_ raw: String?) -> AppLanguage {
        let base = (raw ?? "").split(separator: "-").first.map(String.init) ?? ""
        return AppLanguage(rawValue: base.lowercased()) ?? .en
    }
}
