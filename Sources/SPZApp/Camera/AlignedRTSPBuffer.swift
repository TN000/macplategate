import Foundation

/// 64-byte cache-line aligned RTSP receive buffer s NEON-accelerated scan.
///
/// `posix_memalign(64)` garantuje že base pointer je 64-byte aligned → všechny
/// NEON vld1q_u8 loads padnou uvnitř jedné cache line. `memchr(3)` z libc je na
/// Apple Silicon implementované v handwritten NEON assembly — scan ~4–8× rychlejší
/// než naivní byte loop.
///
/// **Lifetime:** `final class` s manual `free()` v deinit. Storage je malloc'd,
/// musí přežít dokud existuje instance.
final class AlignedRTSPBuffer {
    /// Aligned storage pointer. Alignment = 64 B (cache line).
    private var storage: UnsafeMutableRawPointer
    private var capacity: Int
    private(set) var count: Int = 0

    /// Max velikost než caller (RTSPClient) aktivuje backpressure guard.
    /// Sám buffer ale grow-ovat může dál — growth limit je na caller side.
    private static let alignment = 64

    init(capacity: Int = 65536) {
        var p: UnsafeMutableRawPointer? = nil
        let rc = posix_memalign(&p, Self.alignment, capacity)
        precondition(rc == 0, "posix_memalign failed: \(rc)")
        self.storage = p!
        self.capacity = capacity
    }

    deinit {
        free(storage)
    }

    // MARK: - Mutation

    func append(_ data: Data) {
        let needed = count + data.count
        if needed > capacity { grow(to: needed) }
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(storage.advanced(by: count), base, data.count)
        }
        count += data.count
    }

    /// Drop first N bytes (shift remaining down). memmove na aligned pointer = NEON-backed.
    func removeFirst(_ n: Int) {
        guard n > 0 else { return }
        let clamped = min(n, count)
        let remaining = count - clamped
        if remaining > 0 {
            memmove(storage, storage.advanced(by: clamped), remaining)
        }
        count = remaining
    }

    // MARK: - Reads

    subscript(offset: Int) -> UInt8 {
        // Caller je odpovědný za bounds — hot path, nebudeme zdržovat bounds-check.
        return storage.advanced(by: offset).assumingMemoryBound(to: UInt8.self).pointee
    }

    /// Read 16-bit big-endian integer na daném offsetu (RTSP interleaved frame length).
    func readUInt16BE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        return (b0 << 8) | b1
    }

    /// Extract subrange jako Data (kopie). Používáme pro předání interleaved RTP
    /// payload do depacketizeru (ten pracuje s Data).
    func subdata(in range: Range<Int>) -> Data {
        Data(bytes: storage.advanced(by: range.lowerBound), count: range.count)
    }

    /// UTF-8 decode subrange do String (RTSP text responses).
    func utf8String(in range: Range<Int>) -> String? {
        let bufPtr = UnsafeBufferPointer(
            start: storage.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self),
            count: range.count
        )
        return String(bytes: bufPtr, encoding: .utf8)
    }

    // MARK: - NEON-accelerated scans

    /// Najdi first `\r\n\r\n` v bufferu. Vrátí offset **za** pattern (tj. start body).
    /// nil = pattern nenalezen, caller čeká na další data.
    ///
    /// Používá `memchr` pro locate 0x0D (CR), pak ověří zbylé 3 byty. memchr je na
    /// darwin-arm64 implementované v handwritten NEON assembly — scan je ~4–8×
    /// rychlejší než naivní byte loop.
    func findHeaderEnd() -> Int? {
        guard count >= 4 else { return nil }
        let base = storage.assumingMemoryBound(to: UInt8.self)
        var searchStart = 0
        while searchStart <= count - 4 {
            let remaining = count - searchStart
            // memchr returns UnsafeMutableRawPointer? na first match, nebo NULL
            guard let found = memchr(
                base.advanced(by: searchStart),
                0x0D,  // CR
                remaining - 3  // minus 3 aby měl prostor pro LF + CR + LF
            ) else {
                return nil
            }
            // Offset z base
            let foundPtr = found.assumingMemoryBound(to: UInt8.self)
            let i = foundPtr - base
            // Ověř LF + CR + LF
            if base[i + 1] == 0x0A, base[i + 2] == 0x0D, base[i + 3] == 0x0A {
                return i + 4
            }
            searchStart = i + 1
        }
        return nil
    }

    // MARK: - Internal growth

    private func grow(to needed: Int) {
        var newCap = max(capacity * 2, needed)
        // Round up na 64 B multiple aby alignment zůstal konzistentní i kdyby
        // caller request nečíslo násobek cache-line.
        newCap = (newCap + Self.alignment - 1) & ~(Self.alignment - 1)
        var newPtr: UnsafeMutableRawPointer? = nil
        let rc = posix_memalign(&newPtr, Self.alignment, newCap)
        precondition(rc == 0, "posix_memalign grow failed: \(rc)")
        memcpy(newPtr, storage, count)
        free(storage)
        storage = newPtr!
        capacity = newCap
    }
}
