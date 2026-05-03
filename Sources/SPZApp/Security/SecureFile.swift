import Foundation

/// Pomocník pro ukládání konfiguračních souborů s restriktivními právy.
/// Atomic write + následný chmod 0600 (pouze owner může číst/psát).
enum SecureFile {
    static func writeAtomic(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir.path)
        try data.write(to: url, options: .atomic)
        // Nastav 0600 — bez tohoto macOS default je umask-dependent (typicky
        // 0644 → všichni uživatelé na stroji čtou credentials).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
    }
}
