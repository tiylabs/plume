import CryptoKit
import Foundation

/// The opaque handle an agent uses for a note.
///
/// Carries the profile, the vault and the filename, and nothing else — no UUID is written into the
/// note and no front matter, so the file identity model stays what it is: a note is its filename in
/// the vault. Opaque so that callers pass it back rather than build paths out of it; the filename is
/// returned beside it as a readable field, never accepted as an input.
///
/// Not signed. It does not need to be: every field is checked against the running app on the way
/// in, and a hand-made ref can only ever name a note the same caller could have listed.
public struct NoteRef: Equatable, Sendable {
    public var profile: String
    public var vaultID: String
    public var filename: String

    public init(profile: String, vaultID: String, filename: String) {
        self.profile = profile
        self.vaultID = vaultID
        self.filename = filename
    }

    static let prefix = "note:"

    private struct Wire: Codable {
        var p: String
        var v: String
        var f: String
    }

    public var encoded: String {
        let wire = Wire(p: profile, v: vaultID, f: filename)
        let data = (try? AgentJSON.encoder.encode(wire)) ?? Data()
        return Self.prefix + Base64URL.encode(data)
    }

    /// Parses and checks a ref. The filename goes through the same boundary check as everything
    /// else that names a file, so a forged ref cannot reach outside the vault.
    public static func decode(_ raw: String, profile: String, vaultID: String) throws -> NoteRef {
        guard raw.hasPrefix(prefix),
              let data = Base64URL.decode(String(raw.dropFirst(prefix.count))),
              let wire = try? AgentJSON.decoder.decode(Wire.self, from: data)
        else {
            throw AgentFailure(.invalidNoteRef, "not a note_ref returned by Plume")
        }
        guard wire.p == profile else {
            throw AgentFailure(.invalidNoteRef, "this note_ref belongs to another Plume installation")
        }
        guard wire.v == vaultID else {
            throw AgentFailure(.vaultChanged, "the notes folder changed since this note_ref was issued; list or search again")
        }
        try NotePathPolicy.validate(wire.f)
        return NoteRef(profile: wire.p, vaultID: wire.v, filename: wire.f)
    }
}

/// A vault's identity: its resolved path, hashed. Moving or re-pointing the vault changes it, which
/// is what makes every ref issued for the old one fail with `VAULT_CHANGED` instead of quietly
/// naming a same-named file in the new folder.
public enum VaultIdentity {
    public static func of(_ vault: URL) -> String {
        let path = vault.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Which filenames the API may touch: an ordinary, visible `.md` file directly in the vault.
///
/// `NoteFilename.isNoteFile` only checks the extension and the leading dot, which is right for a
/// directory listing and not enough for a name that arrived from outside. This is the boundary
/// check; the I/O layer checks again, on the file itself, inside the coordinated access.
public enum NotePathPolicy {
    public static func validate(_ filename: String) throws {
        let invalid = AgentFailure(.invalidNoteRef, "not a note in the notes folder")
        guard !filename.isEmpty,
              filename.utf8.count <= 255,
              NoteFilename.isNoteFile(filename),
              // With no separator there is no traversal: `a..b.md` is an ordinary name.
              !filename.contains("/"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw invalid }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    /// A random token for versions and cursors: 128 bits, URL-safe.
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return encode(Data(bytes))
    }
}
