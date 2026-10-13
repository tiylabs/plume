import CryptoKit
import Foundation

/// Content hashing, used to tell our own writes apart from everyone else's.
///
/// Decision 10 is explicit that echoes are filtered by hash and **not** by modification time. mtime
/// is the obvious choice and the wrong one: an atomic replace changes it, sync daemons rewrite it,
/// and two edits inside the same second can leave it unchanged — so it produces both false alarms
/// and misses. A hash answers the only question worth asking, which is whether the bytes on disk are
/// the bytes we last wrote.
public enum ContentHash {

    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes the UTF-8 encoding, which is what actually reaches the disk. Hashing the `String`
    /// instead would make two byte sequences that normalise to the same characters compare equal,
    /// and this whole mechanism exists to notice byte-level differences.
    public static func of(_ text: String) -> String {
        of(Data(text.utf8))
    }
}
