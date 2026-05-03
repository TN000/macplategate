import Foundation
import Security

/// Spravuje self-signed TLS certifikát pro WebServer.
///
/// Při prvním startu volá `/usr/bin/openssl` subprocess a generuje:
/// - `webserver-key.pem` (RSA 2048)
/// - `webserver-cert.pem` (X.509, valid 10 let, CN=SPZ-ALPR, SAN=IP:0.0.0.0)
/// - `webserver.p12` (PKCS#12 bundle cert+key, password v `cert-pass.bin`)
///
/// PKCS#12 bundle je chráněný **per-install random heslem** uloženým vedle
/// (cert-pass.bin, 0600). Žádné hardcoded heslo v zdrojovém kódu.
///
/// Pak načte p12 přes `SecPKCS12Import` → získá `SecIdentity` který Network.framework
/// použije pro TLS v NWListener.
///
/// **Pozor:** Prohlížeče varují na self-signed cert — user musí kliknout
/// "Advanced → Pokračovat" při prvním navštívení. Jednorázově.
enum CertManager {
    private static var baseDir: URL { AppPaths.baseDir }
    private static var keyURL: URL { baseDir.appendingPathComponent("webserver-key.pem") }
    private static var certURL: URL { baseDir.appendingPathComponent("webserver-cert.pem") }
    private static var p12URL: URL { baseDir.appendingPathComponent("webserver.p12") }
    private static var p12PassURL: URL { baseDir.appendingPathComponent("cert-pass.bin") }

    private static let p12PassLock = NSLock()
    private static var _p12PasswordCached: String?

    /// Per-install random heslo pro PKCS#12 bundle. Loaduje se z `cert-pass.bin`
    /// nebo se vygeneruje při prvním přístupu (UUID, 36 znaků). Soubor 0600.
    private static var p12Password: String {
        p12PassLock.lock()
        defer { p12PassLock.unlock() }
        if let cached = _p12PasswordCached { return cached }
        if let data = try? Data(contentsOf: p12PassURL),
           let s = String(data: data, encoding: .utf8), !s.isEmpty {
            _p12PasswordCached = s
            return s
        }
        let pwd = UUID().uuidString
        if let data = pwd.data(using: .utf8) {
            try? SecureFile.writeAtomic(data, to: p12PassURL)
        }
        _p12PasswordCached = pwd
        return pwd
    }

    /// Vrací načtený `SecIdentity` — vygeneruje cert pokud chybí.
    /// Vrací nil pokud generování selhalo (openssl missing, permissions atd.).
    static func loadOrGenerateIdentity() -> SecIdentity? {
        // Jednorázový cleanup staré identity z login.keychainu. Dřívější verze
        // appky importovaly klíč default do user loginu → macOS po každém rebuildu
        // promptoval „povolení podepsání". Nová verze používá izolovaný temp
        // keychain (viz ensureTempKeychain), takže login.keychain už nepotřebujeme.
        cleanupLoginKeychainIdentityOnce()

        let p12Exists = FileManager.default.fileExists(atPath: p12URL.path)
        let passExists = FileManager.default.fileExists(atPath: p12PassURL.path)
        if !p12Exists || !passExists {
            try? FileManager.default.removeItem(at: p12URL)
            try? FileManager.default.removeItem(at: p12PassURL)
            p12PassLock.lock(); _p12PasswordCached = nil; p12PassLock.unlock()
            guard generateSelfSigned() else {
                logError("cert generation failed")
                return nil
            }
        }
        return loadIdentityFromP12()
    }

    /// Smaže existující cert a vygeneruje nový. Užitečné pokud user
    /// chce cert regenerovat (změna IP, expiry, etc.).
    @discardableResult
    static func regenerate() -> Bool {
        try? FileManager.default.removeItem(at: keyURL)
        try? FileManager.default.removeItem(at: certURL)
        try? FileManager.default.removeItem(at: p12URL)
        try? FileManager.default.removeItem(at: p12PassURL)
        p12PassLock.lock(); _p12PasswordCached = nil; p12PassLock.unlock()
        // Reset temp keychain cache — při regenerate zahodíme starou instanci
        // a příští loadIdentityFromP12 vytvoří fresh. Bez tohoto by pracoval
        // se starým keychainem obsahujícím smazaný klíč → SecItemCopyMatching
        // by fail a cleanupStaleTempKeychains by ho nesmazal (aktivní ref).
        resetTempKeychainCacheAndCleanup()
        return generateSelfSigned()
    }

    /// Datum kdy byl cert vygenerován (pro UI display).
    static func certCreationDate() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: certURL.path),
              let date = attrs[.creationDate] as? Date else { return nil }
        return date
    }

    // MARK: - Private

    private static func generateSelfSigned() -> Bool {
        // Step 1 — generate key + self-signed cert (RSA 2048, 10 let).
        // SAN zahrnuje localhost, loopback a 0.0.0.0 aby cert matchoval libovolnou
        // IP na lokální síti (prohlížeč kontroluje IP SAN, ne jen CN).
        let req = Process()
        req.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        req.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "3650",
            "-nodes",  // bez passphrase na private key
            "-subj", "/CN=SPZ-ALPR",
            "-addext", "subjectAltName = DNS:localhost,IP:127.0.0.1,IP:0.0.0.0"
        ]
        req.standardOutput = FileHandle.nullDevice
        req.standardError = FileHandle.nullDevice
        do {
            try req.run()
            req.waitUntilExit()
            guard req.terminationStatus == 0 else {
                logError("openssl req failed code=\(req.terminationStatus)")
                return false
            }
        } catch {
            logError("openssl req launch failed: \(error)")
            return false
        }

        // Step 2 — bundle do PKCS#12. /usr/bin/openssl na macOS je LibreSSL,
        // který už defaultně používá 3DES (legacy formát kompatibilní s
        // SecPKCS12Import). `-legacy` flag LibreSSL nezná → vynecháno.
        let p12 = Process()
        p12.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p12.arguments = [
            "pkcs12", "-export",
            "-out", p12URL.path,
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-password", "pass:\(p12Password)"
        ]
        p12.standardOutput = FileHandle.nullDevice
        p12.standardError = FileHandle.nullDevice
        do {
            try p12.run()
            p12.waitUntilExit()
            guard p12.terminationStatus == 0 else {
                logError("openssl pkcs12 export failed code=\(p12.terminationStatus)")
                return false
            }
        } catch {
            logError("openssl pkcs12 launch failed: \(error)")
            return false
        }

        // Step 3 — chmod 0600 na všechny soubory (private key!).
        for url in [keyURL, p12URL] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path)
        }
        FileHandle.safeStderrWrite(
            "[CertManager] self-signed cert generated, valid 10 let\n".data(using: .utf8)!)
        return true
    }

    private static func loadIdentityFromP12() -> SecIdentity? {
        // Přepsáno na `security` CLI přístup:
        //   1. fresh temp keychain v /tmp/ per process
        //   2. `security import -A` = no ACL restrictions (žádná app nepromptuje)
        //   3. `security set-key-partition-list` = otevřít partition list aby
        //      se Network.framework nemuselo ptát uživatele na unlock
        //   4. SecKeychainOpen + SecItemCopyMatching pro získání SecIdentity
        //
        // Proč: native SecPKCS12Import + SecKeychainCreate cesta na macOS 26
        // promptovala dialog „Aplikace SPZ žádá o použití svazku klíčů". `security`
        // CLI s `-A` je standardní CI/CD workaround pro headless import a macOS
        // ho respektuje.
        guard let kcPath = ensureTempKeychainCLI() else {
            logError("temp keychain CLI setup failed")
            return nil
        }
        var kc: SecKeychain?
        let openStatus = SecKeychainOpen(kcPath, &kc)
        guard openStatus == errSecSuccess, let kc else {
            logError("SecKeychainOpen failed status=\(openStatus)")
            return nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
            kSecMatchSearchList as String: [kc] as CFArray,
        ]
        var item: CFTypeRef?
        let qStatus = SecItemCopyMatching(query as CFDictionary, &item)
        guard qStatus == errSecSuccess, let item else {
            logError("SecItemCopyMatching identity failed status=\(qStatus)")
            return nil
        }
        guard CFGetTypeID(item) == SecIdentityGetTypeID() else {
            logError("SecItemCopyMatching returned unexpected item type")
            return nil
        }
        // CFTypeID guard above proves the runtime type. Swift requires a
        // downcast for CoreFoundation identity refs here.
        return (item as! SecIdentity)
    }

    // MARK: - Temp keychain lifecycle (via /usr/bin/security)

    private static let tempKeychainLock = NSLock()
    private static var tempKeychainPath: String?
    /// Per-process random heslo pro temp keychain (UUID — eval-once per app launch).
    /// Keychain je v /tmp/, mažeme ho při exitu; password nikdy nezapisujeme na disk.
    private static let tempKcPass = UUID().uuidString

    /// Vytvoří temp keychain přes `security` CLI a naimportuje do něj náš p12.
    /// Cesta se cachuje pro process lifetime.
    private static func ensureTempKeychainCLI() -> String? {
        tempKeychainLock.lock()
        defer { tempKeychainLock.unlock() }
        if let p = tempKeychainPath { return p }
        cleanupStaleTempKeychains()
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("spz-tls-\(UUID().uuidString).keychain")

        // 1. Vytvořit keychain. -p = password.
        guard runSecurity(["create-keychain", "-p", tempKcPass, path]) else {
            logError("security create-keychain failed")
            return nil
        }
        // 2. Odemknout (create ho vytvoří zamčený).
        _ = runSecurity(["unlock-keychain", "-p", tempKcPass, path])
        // 3. Žádný auto-lock (bez argumentů = no timeout, no lock on sleep).
        _ = runSecurity(["set-keychain-settings", path])
        // 4. Import p12 s -A = allow ANY application to access the imported key
        //    without prompt. Kritické pro Network.framework TLS handshake.
        guard runSecurity(["import", p12URL.path, "-k", path, "-P", p12Password, "-A"]) else {
            logError("security import failed")
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        // 5. Partition list — bez tohoto by macOS promptoval „allow signing"
        //    i přes -A na moderních macOS. S těmito partition IDs povoluje
        //    Apple tools a unsigned code (adhoc-signed SPZ.app) přístup.
        _ = runSecurity(["set-key-partition-list",
                         "-S", "apple-tool:,apple:,unsigned:",
                         "-s", "-k", tempKcPass, path])
        tempKeychainPath = path
        return path
    }

    private static func resetTempKeychainCacheAndCleanup() {
        tempKeychainLock.lock()
        defer { tempKeychainLock.unlock() }
        tempKeychainPath = nil
        cleanupStaleTempKeychains()
    }

    @discardableResult
    private static func runSecurity(_ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            logError("security subprocess failed: \(error)")
            return false
        }
    }

    /// Smaže všechny spz-tls-*.keychain* soubory z /tmp/ — zbytky z minulých
    /// runů co neuklidilo graceful shutdown. Matches i .keychain-db soubor
    /// který modernější macOS vytváří vedle hlavního souboru.
    private static func cleanupStaleTempKeychains() {
        let tmp = NSTemporaryDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: tmp) else { return }
        for f in files where f.hasPrefix("spz-tls-") && f.contains(".keychain") {
            let full = (tmp as NSString).appendingPathComponent(f)
            // Taky removejeme keychain ze search listu (best effort)
            _ = runSecurity(["delete-keychain", full])
            try? FileManager.default.removeItem(atPath: full)
        }
    }

    /// Best-effort mazání staré SPZ-ALPR identity z user login.keychainu —
    /// zbytek po starší verzi která importovala identity tam místo do per-app
    /// keychainu. Spouští `security delete-identity` jako subprocess; žádný
    /// prompt pokud je keychain unlocked.
    ///
    /// Volá se jednou per process — flag `didCleanup` zabrání opakovaným
    /// subprocess volání při každém restart serveru (toggle / port change).
    private static let loginCleanupLock = NSLock()
    private static var didCleanupLoginKeychain = false
    private static func cleanupLoginKeychainIdentityOnce() {
        loginCleanupLock.lock()
        defer { loginCleanupLock.unlock() }
        guard !didCleanupLoginKeychain else { return }
        didCleanupLoginKeychain = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["delete-identity", "-c", "SPZ-ALPR"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // ok — subprocess start fail, nic nesmažeme, není fatální
        }
    }

    private static func logError(_ msg: String) {
        FileHandle.safeStderrWrite("[CertManager] \(msg)\n".data(using: .utf8)!)
    }
}
