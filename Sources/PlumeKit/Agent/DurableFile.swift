import Darwin
import Foundation

/// Atomically writes a private file and requests persistence from the file system.
///
/// `Data.write(options: .atomic)` survives a crash — temp file plus rename — but not a power cut:
/// on APFS the rename can reach the disk before the data does, and `fsync` alone does not flush the
/// drive's own cache. So: write a temporary file, `F_FULLFSYNC` it, rename it into place, then
/// `fsync` the directory so the rename is submitted too. Every failed synchronization is reported.
/// File systems that reject full synchronization fall back to `fsync`; they do not provide the same
/// power-loss guarantee as a local APFS volume. Hardware and file-system failures remain outside
/// the recovery guarantee.
///
/// Files are created `0600` and directories `0700`: the journal holds note text, and nothing else
/// on the machine needs to read it.
public enum DurableFile {

    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("open", temporary) }
        var closed = false
        defer {
            if !closed { close(fd) }
            unlink(temporary.path)
        }

        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    throw posixError("write", temporary)
                }
                offset += written
            }
        }
        // F_FULLFSYNC asks the drive to flush its cache, which plain fsync does not on macOS. Some
        // file systems (network, FAT) refuse it; fsync is the best that is left there.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw posixError("fsync", temporary) }
        guard close(fd) == 0 else { closed = true; throw posixError("close", temporary) }
        closed = true

        guard rename(temporary.path, url.path) == 0 else {
            let error = posixError("rename", url)
            unlink(temporary.path)
            throw error
        }
        try syncDirectory(directory)
    }

    /// Removes a file and makes the removal durable.
    public static func remove(_ url: URL) {
        unlink(url.path)
        try? syncDirectory(url.deletingLastPathComponent())
    }

    /// Creates the directory `0700` if missing, and tightens it if it exists with wider access.
    /// Refuses a symlink: a link planted in place of a private directory would redirect the writes.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentFailure(.saveFailed, "\(url.path) is not a directory")
            }
            guard info.st_uid == getuid() else {
                throw AgentFailure(.saveFailed, "\(url.path) belongs to another user")
            }
            if info.st_mode & 0o077 != 0, chmod(url.path, 0o700) != 0 { throw posixError("chmod", url) }
            return
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError("open directory", directory) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError("fsync directory", directory) }
    }

    static func posixError(_ call: String, _ url: URL) -> AgentFailure {
        AgentFailure(.saveFailed, "\(call) \(url.lastPathComponent): \(String(cString: strerror(errno)))")
    }
}
