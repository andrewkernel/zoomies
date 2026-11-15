import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum SHA256Hex {
    public static func digest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        #error("SHA-256 needs CryptoKit (or swift-crypto on Linux/Windows; not wired up yet)")
        #endif
    }

    /// Streams a file through SHA-256 in 8 MiB chunks, so multi-GB models
    /// never sit in memory at once.
    public static func file(at url: URL, progress: ((UInt64) -> Void)? = nil) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done: UInt64 = 0
        while true {
            let chunk = try handle.read(upToCount: 8 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += UInt64(chunk.count)
            progress?(done)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        #error("SHA-256 needs CryptoKit")
        #endif
    }
}
