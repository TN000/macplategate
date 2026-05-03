import Foundation
import Darwin

/// Safe wrapper na stderr write — používá POSIX `write(2)` syscall místo NSFileHandle.
///
/// **Důvod:** `NSFileHandle.write(data:)` throws ObjC `NSFileHandleOperationException`
/// s `EBADF` když je stderr fd uzavřený nebo invalid (např. .app bundle launch
/// kde je stderr redirected na /dev/null). NSException leakne až do top-level
/// a SIGABRT-uje proces.
///
/// `write(STDERR_FILENO, ...)` je POSIX syscall — neumí throw. Žádný crash,
/// žádný exception. Loguje "best effort".
extension FileHandle {

    /// Best-effort POSIX write na STDERR — never throws, never crashes.
    /// Pokud fd je invalid (EBADF) → silent no-op. Pokud částečný write → OK,
    /// loguje co stihne (no retry loop pro logging).
    @inline(__always)
    static func safeStderrWrite(_ data: Data) {
        guard !data.isEmpty else { return }
        _ = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Darwin.write(STDERR_FILENO, base, buf.count)
        }
    }
}
