import Foundation

/// Single source of truth pro všechny application-data cesty.
/// Při prvním přístupu zkontroluje legacy `~/Library/Application Support/SPZ/`
/// a (pokud nový `MacPlateGate/` ještě neexistuje) přejmenuje ji.
enum AppPaths {
    private static let dirName = "MacPlateGate"
    private static let legacyDirName = "SPZ"

    private static let migrationLock = NSLock()
    nonisolated(unsafe) private static var migrationDone = false

    /// `~/Library/Application Support/MacPlateGate/` (0700 perms).
    /// První volání spustí jednorázovou migraci ze starého názvu, pokud existuje.
    static var baseDir: URL {
        ensureMigrated()
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let dir = support.appendingPathComponent(dirName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private static func ensureMigrated() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !migrationDone else { return }
        migrationDone = true

        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let target = support.appendingPathComponent(dirName, isDirectory: true)
        let legacy = support.appendingPathComponent(legacyDirName, isDirectory: true)

        let targetExists = fm.fileExists(atPath: target.path)
        let legacyExists = fm.fileExists(atPath: legacy.path)
        guard !targetExists, legacyExists else { return }
        try? fm.moveItem(at: legacy, to: target)
    }
}
