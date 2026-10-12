import Foundation

/// Whether an address is one `git remote add` should be handed.
public enum GitRemoteAddress {

    public enum Problem: Equatable, Sendable {
        case empty
        case unsupported
        /// `https://user:token@host/…` — the token would be written in plain text to
        /// `settings.json` and `.git/config`. Refused; the credential helper is the place for it.
        case embeddedCredentials
    }

    /// nil when the address is acceptable.
    public static func problem(with address: String) -> Problem? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .empty }
        // A leading dash would be read by git as an option, and whitespace is never in an address.
        guard !value.hasPrefix("-"), value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .unsupported
        }

        if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
           value.contains("://") {
            guard ["https", "http", "ssh", "git", "file"].contains(scheme) else { return .unsupported }
            if scheme == "http" || scheme == "https", components.password != nil {
                return .embeddedCredentials
            }
            if scheme != "file", (components.host ?? "").isEmpty { return .unsupported }
            return nil
        }
        // scp-like: user@host:path/to/repo.git
        if let colon = value.firstIndex(of: ":"), !value.hasPrefix("/"), !value.contains("::") {
            let host = value[..<colon]
            let path = value[value.index(after: colon)...]
            return !host.isEmpty && !path.isEmpty && !host.contains("/") ? nil : .unsupported
        }
        // A path on this Mac — a bare repository on a NAS mount, or a test fixture.
        if value.hasPrefix("/") { return nil }
        return .unsupported
    }
}
