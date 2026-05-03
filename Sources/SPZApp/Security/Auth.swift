import Foundation
import Security
import CryptoKit

/// Admin autentizace + session management.
///
/// **Storage:** lokální soubory v `AppPaths.baseDir` s perms 600. Keychain
/// je vyloučen, protože adhoc-signed app trigguje opakované ACL prompty u každé
/// položky. Threat model (local-only Mac) Keychain ACL nepotřebuje; 600-perm
/// soubor dává stejnou ochranu proti jiným userům na stroji.
@MainActor
final class Auth: ObservableObject {
    static let shared = Auth()

    private static var baseDir: URL { AppPaths.baseDir }
    private static var hashFileURL: URL { baseDir.appendingPathComponent("admin-hash.dat") }
    private static var rememberFileURL: URL { baseDir.appendingPathComponent("admin-remember.dat") }

    init() {
        migrateFromKeychainIfNeeded()

        // Seed při prvním startu — generujeme RANDOM heslo (žádný hardcoded default
        // v source kódu) a zapisujeme ho do souboru s perms 600, aby ho user mohl
        // přečíst a změnit přes Settings. Po úspěšné změně hesla se soubor smaže.
        if loadHashData() == nil {
            let pwd = Self.generateRandomPassword(length: 20)
            try? setPassword(pwd)
            writeInitialPasswordFile(pwd)
            FileHandle.safeStderrWrite(
                "[Auth] seeded RANDOM admin password → \(Self.initialPasswordFileURL.path) (600 perms). Change it in Settings.\n"
                    .data(using: .utf8)!)
        }
    }

    /// One-shot migrace z Keychainu (starý storage) do 600-perm souboru.
    /// Pokud hash-file existuje, migrace už proběhla / nebyla potřeba; skip.
    private func migrateFromKeychainIfNeeded() {
        guard !FileManager.default.fileExists(atPath: Self.hashFileURL.path) else { return }

        // Hash item
        if let hashData = keychainRead(service: "app.macplategate.admin", account: "admin-password-v1"),
           hashData.count == 48 {
            ensureBaseDir()
            try? SecureFile.writeAtomic(hashData, to: Self.hashFileURL)
            keychainDelete(service: "app.macplategate.admin", account: "admin-password-v1")
        }
        // Remember item (pokud user při předchozím loginu zaškrtl "zapamatovat")
        if let pwdData = keychainRead(service: "app.macplategate.admin-remember", account: "admin-remember-v1") {
            ensureBaseDir()
            try? SecureFile.writeAtomic(pwdData, to: Self.rememberFileURL)
            keychainDelete(service: "app.macplategate.admin-remember", account: "admin-remember-v1")
        }
    }

    private func keychainRead(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private func keychainDelete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Alphanumeric + safe symbols, kryptograficky silný random.
    private static func generateRandomPassword(length: Int) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!#%&*+-_")
        var out = ""
        let bytes = (try? secureRandomBytes(count: length)) ?? fallbackRandomBytes(count: length)
        for b in bytes { out.append(chars[Int(b) % chars.count]) }
        return out
    }

    private enum RandomError: Error {
        case secRandomFailed(OSStatus)
    }

    private static func secureRandomBytes(count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw RandomError.secRandomFailed(status) }
        return bytes
    }

    private static func fallbackRandomBytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<max(0, count)).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }

    private static var initialPasswordFileURL: URL {
        baseDir.appendingPathComponent("admin-initial-password.txt")
    }

    private func writeInitialPasswordFile(_ pwd: String) {
        let url = Self.initialPasswordFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "Initial admin password (change it in Settings, then this file will be deleted):\n\(pwd)\n"
        guard let data = text.data(using: .utf8) else { return }
        try? SecureFile.writeAtomic(data, to: url)
    }

    private func deleteInitialPasswordFileIfExists() {
        let url = Self.initialPasswordFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Vrátí počáteční heslo vygenerované při prvním spuštění, pokud soubor
    /// `admin-initial-password.txt` ještě existuje (= user heslo nezměnil).
    /// Použito v `WelcomeSheet` pro zobrazení hesla na first-run obrazovce.
    func readInitialPasswordIfExists() -> String? {
        let url = Self.initialPasswordFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0) }
        return lines.last
    }

    /// Ověří heslo proti uloženému hashi. Constant-time compare.
    func verify(_ input: String) -> Bool {
        guard let stored = loadHashData(), stored.count == 48 else { return false }
        let salt = stored.prefix(16)
        let expectedHash = stored.suffix(32)
        let h = SHA256.hash(data: salt + Data(input.utf8))
        let computed = Data(h)
        return constantTimeEqual(Data(expectedHash), computed)
    }

    /// Nastaví nové heslo (random salt + SHA256). Volá se při onboardingu /
    /// změně hesla z admin UI. Po úspěšné změně smaže initial-password soubor
    /// (pokud existoval od seed) i remember soubor (zastaralé heslo).
    func setPassword(_ newPassword: String) throws {
        let salt = Data(try Self.secureRandomBytes(count: 16))
        let hash = SHA256.hash(data: salt + Data(newPassword.utf8))
        let payload = salt + Data(hash)
        try storeHashData(payload)
        deleteInitialPasswordFileIfExists()
        clearRememberedPassword()
    }

    // MARK: - File I/O

    private func ensureBaseDir() {
        try? FileManager.default.createDirectory(
            at: Self.baseDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: Self.baseDir.path)
    }

    private func loadHashData() -> Data? {
        try? Data(contentsOf: Self.hashFileURL)
    }

    private func storeHashData(_ data: Data) throws {
        ensureBaseDir()
        try SecureFile.writeAtomic(data, to: Self.hashFileURL)
    }

    // MARK: - Remember me (plaintext 600-file, žádné Keychain prompty)

    /// Uloží plaintext heslo do 600-perm souboru pro auto-login při startu.
    func rememberPassword(_ password: String) {
        guard let data = password.data(using: .utf8) else { return }
        ensureBaseDir()
        try? SecureFile.writeAtomic(data, to: Self.rememberFileURL)
    }

    /// Vrátí uložené plaintext heslo, pokud existuje a stále odpovídá hashi.
    /// Při mismatchi (user změnil heslo) → smaže zastaralý soubor a vrátí nil.
    func recallPassword() -> String? {
        guard let data = try? Data(contentsOf: Self.rememberFileURL),
              let pwd = String(data: data, encoding: .utf8) else { return nil }
        if verify(pwd) {
            return pwd
        } else {
            clearRememberedPassword()
            return nil
        }
    }

    func clearRememberedPassword() {
        try? FileManager.default.removeItem(at: Self.rememberFileURL)
    }

    private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= (a[i] ^ b[i]) }
        return diff == 0
    }
}
