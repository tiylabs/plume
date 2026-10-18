import CryptoKit
import Darwin
import Foundation

/// `get_writing_context`'s answer: how Plume renders Markdown, how this person likes notes written,
/// and — when asked — a template, the target note's shape and a few examples.
///
/// Every part says where it came from and carries a version, so an agent can tell whether to read
/// it again. `priority` states the order to resolve disagreements in: the user's explicit request,
/// then their saved preferences and the chosen template, then the target's existing structure, then
/// Plume's defaults. The format capabilities are a constraint, not a preference — no preference makes
/// an unsupported syntax render.
public struct WritingContextResult: Codable, Sendable, Equatable {
    public struct Format: Codable, Sendable, Equatable {
        public var version: Int
        public var guide: String
        public var capabilities: JSONValue
        public var source: String
    }

    public struct File: Codable, Sendable, Equatable {
        public var id: String?
        public var version: String
        public var markdown: String
        public var source: String
    }

    public struct TemplateInfo: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var version: String
    }

    public struct Target: Codable, Sendable, Equatable {
        public var noteRef: String
        public var title: String
        public var headings: [String]
        public var excerpt: String
        public var truncated: Bool

        enum CodingKeys: String, CodingKey {
            case noteRef = "note_ref"
            case title, headings, excerpt, truncated
        }
    }

    public struct Example: Codable, Sendable, Equatable {
        public var noteRef: String
        public var title: String
        public var markdown: String
        public var truncated: Bool

        enum CodingKeys: String, CodingKey {
            case noteRef = "note_ref"
            case title, markdown, truncated
        }
    }

    public var apiVersion = AgentAPI.apiVersion
    public var formatVersion = AgentAPI.formatVersion
    public var format: Format
    public var preferences: File?
    public var preferencesVersion: String
    public var template: File?
    public var templates: [TemplateInfo]
    public var target: Target?
    public var examples: [Example]
    public var priority: [String]
    public var warnings: [AgentWarning]

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case formatVersion = "format_version"
        case format, preferences
        case preferencesVersion = "preferences_version"
        case template, templates, target, examples, priority, warnings
    }

    public static let priorityOrder = [
        "the user's explicit request in this conversation",
        "the user's saved writing preferences and the chosen template",
        "the existing structure of the target note or chosen examples",
        "Plume's default suggestions in the format guide",
    ]
}

/// Reads the writing files: Plume's format guide from the app bundle, and the person's preferences
/// and templates from `Agent/` under Application Support.
///
/// Those are the person's own documents — plain UTF-8 Markdown they edit in any editor, outside the
/// vault, not synced unless they sync them. A missing preferences file means "no preferences"; Plume
/// does not infer a style from the vault. A file that is too large, not UTF-8, or a symlink is
/// reported as a warning and left out, never half-returned as if it were the whole rule set.
public struct WritingFiles: Sendable {
    public let agentDirectory: URL
    public let formatDirectory: URL

    public init(agentDirectory: URL, formatDirectory: URL) {
        self.agentDirectory = agentDirectory
        self.formatDirectory = formatDirectory
    }

    public var preferencesURL: URL { agentDirectory.appendingPathComponent("preferences.md") }
    public var templatesDirectory: URL { agentDirectory.appendingPathComponent("Templates", isDirectory: true) }

    public func format() -> WritingContextResult.Format {
        let guide = (try? String(contentsOf: formatDirectory.appendingPathComponent("format.md"), encoding: .utf8)) ?? ""
        let capabilities = (try? Data(contentsOf: formatDirectory.appendingPathComponent("capabilities.json")))
            .flatMap { try? AgentJSON.decoder.decode(JSONValue.self, from: $0) } ?? .object([:])
        return .init(version: AgentAPI.formatVersion, guide: guide, capabilities: capabilities, source: "plume")
    }

    /// The preferences file, or nil with a warning when it exists but cannot be used.
    public func preferences(warnings: inout [AgentWarning]) -> WritingContextResult.File? {
        switch readUserFile(preferencesURL) {
        case .missing:
            return nil
        case .unusable(let reason):
            warnings.append(AgentWarning("preferences_unreadable", "The user's writing preferences file was left out: \(reason)."))
            return nil
        case .text(let text):
            return .init(id: nil, version: Self.version(of: text), markdown: text, source: "user_preferences")
        }
    }

    /// Every registered template: an ordinary, visible `.md` file directly in `Templates/`.
    public func templates() -> [WritingContextResult.TemplateInfo] {
        var directoryInfo = stat()
        guard lstat(templatesDirectory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: templatesDirectory.path)) ?? []
        return names.sorted().compactMap { name in
            guard NoteFilename.isNoteFile(name) else { return nil }
            let id = (name as NSString).deletingPathExtension
            guard case .text(let text) = readUserFile(templatesDirectory.appendingPathComponent(name)) else { return nil }
            let title = MarkdownDocument.title(of: text)
            return .init(id: id, title: title.isEmpty ? id : title, version: Self.version(of: text))
        }
    }

    public func template(id: String, warnings: inout [AgentWarning]) throws -> WritingContextResult.File {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix("."),
              id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw AgentFailure(.invalidRequest, "template_id must be one of the ids in templates") }
        var directoryInfo = stat()
        guard lstat(templatesDirectory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw AgentFailure(.invalidRequest, "Templates is not a regular directory")
        }
        let url = templatesDirectory.appendingPathComponent(id + ".md")
        switch readUserFile(url) {
        case .missing:
            throw AgentFailure(.invalidRequest, "no template called \(id); use one of the ids in templates")
        case .unusable(let reason):
            warnings.append(AgentWarning("template_unreadable", "The template \(id) was left out: \(reason)."))
            throw AgentFailure(.invalidRequest, "the template \(id) cannot be used: \(reason)")
        case .text(let text):
            return .init(id: id, version: Self.version(of: text), markdown: text, source: "user_template")
        }
    }

    // MARK: - Examples on first enable

    private var examplesMarker: URL { agentDirectory.appendingPathComponent(".examples-installed") }

    /// Writes the example preferences and templates the first time access is enabled — once, ever.
    /// A marker records that it happened, so an example the person deleted or rewrote is never put
    /// back: deleting it was a decision.
    public func installExamplesIfFirstTime(document: (String) -> String?) {
        guard !FileManager.default.fileExists(atPath: examplesMarker.path) else { return }
        try? DurableFile.ensurePrivateDirectory(agentDirectory)
        try? FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: preferencesURL.path), let text = document("agent/preferences.md") {
            try? Data(text.utf8).write(to: preferencesURL, options: [.withoutOverwriting])
        }
        for name in ["meeting", "discussion", "project"] {
            let url = templatesDirectory.appendingPathComponent(name + ".md")
            if !FileManager.default.fileExists(atPath: url.path), let text = document("agent/templates/\(name).md") {
                try? Data(text.utf8).write(to: url, options: [.withoutOverwriting])
            }
        }
        try? Data().write(to: examplesMarker)
    }

    // MARK: - Pieces

    enum UserFile: Equatable {
        case missing
        case unusable(String)
        case text(String)
    }

    func readUserFile(_ url: URL) -> UserFile {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .unusable("it is not a regular file") }
        guard Int(info.st_size) <= AgentLimits.writingFileMaxBytes else {
            return .unusable("it is larger than \(AgentLimits.writingFileMaxBytes / 1024) KiB")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .unusable("it cannot be read") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o444 != 0,
              let data = try? handle.read(upToCount: AgentLimits.writingFileMaxBytes + 1),
              data.count <= AgentLimits.writingFileMaxBytes else { return .unusable("it cannot be read safely within the size limit") }
        guard let text = String(data: data, encoding: .utf8) else { return .unusable("it is not UTF-8 text") }
        return .text(text)
    }

    static func version(of text: String) -> String {
        "v:" + SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Shape of a note

    /// A note's headings, for "write in the shape this note already has".
    public static func headings(of text: String) -> [String] {
        var inFence = false
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, line.hasPrefix("#") else { continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard hashes <= 6, line.dropFirst(hashes).first == " " else { continue }
            out.append(String(line))
            if out.count >= 50 { break }
        }
        return out
    }

    /// The first `limit` bytes of a note, cut at a line break, and whether anything was cut.
    public static func excerpt(of text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var out = ""
        var bytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let next = line.utf8.count + 1
            if bytes + next > limit { break }
            out += line + "\n"
            bytes += next
        }
        return (out, true)
    }
}
