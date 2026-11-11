import Crypto
import FileWorkspace
import Foundation
import TerminalCore

/// How the downloaded bytes were checked.
public enum ArtifactVerification: String, Codable, Sendable {
    /// SHA-256 computed on the remote host matched the bytes received.
    case remoteChecksumMatched
    /// Directories are transferred as a tar stream; only the local archive checksum is known.
    case localChecksumOnly
}

public struct ArtifactRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var hostID: UUID
    public var hostName: String
    public var remotePath: String
    public var wasDirectory: Bool
    public var size: Int64
    public var sha256: String
    public var verification: ArtifactVerification
    /// Location inside the app workspace, e.g. `/artifacts/2026-11-01/MyApp.app.tar`.
    public var localPath: String
    public var buildRunID: UUID?
    public var downloadedAt: Date
}

public enum ArtifactError: Error, LocalizedError, Equatable {
    case notFound(String)
    case tooLarge(Int64, limit: Int64)
    case checksumMismatch(expected: String, actual: String)
    case transferFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "\(path) was not found on the remote host."
        case .tooLarge(let size, let limit):
            "The artifact is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)); the limit is \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))."
        case .checksumMismatch(let expected, let actual): "Checksum mismatch (remote \(expected.prefix(12))…, received \(actual.prefix(12))…). The file was discarded."
        case .transferFailed(let message): "Transfer failed: \(message)"
        }
    }
}

/// Index of downloaded artifacts, stored in the workspace at `/artifacts/index.json`.
public actor ArtifactIndex {
    private let workspace: FileWorkspace
    private var records: [ArtifactRecord]
    static let indexPath = WorkspacePath.artifacts.appending("index.json")

    public init(workspace: FileWorkspace) {
        self.workspace = workspace
        if let data = try? workspace.readData(Self.indexPath), let decoded = try? JSONDecoder().decode([ArtifactRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
    }

    public func all() -> [ArtifactRecord] { records.sorted { $0.downloadedAt > $1.downloadedAt } }

    public func add(_ record: ArtifactRecord) throws {
        records.append(record)
        try persist()
    }

    public func remove(_ id: UUID) throws {
        if let record = records.first(where: { $0.id == id }), let path = try? WorkspacePath(record.localPath) {
            try? workspace.remove(path, recursive: true)
        }
        records.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try workspace.write(encoder.encode(records), to: Self.indexPath)
    }
}

/// Downloads files and directories from a remote host over the SSH exec channel and verifies them.
public struct ArtifactDownloader: Sendable {
    public var sizeLimit: Int64

    public init(sizeLimit: Int64 = 2 * 1024 * 1024 * 1024) {
        self.sizeLimit = sizeLimit
    }

    /// `kind\tsize` for a remote path (`f`, `d` or `-`). Directory size is summed with `du -k`.
    static func statScript(_ path: String) -> String {
        let p = ShellQuote.quote(path)
        return "if [ -f \(p) ]; then printf 'f\\t%s\\n' \"$(wc -c < \(p) | tr -d ' ')\"; elif [ -d \(p) ]; then printf 'd\\t%s\\n' \"$(( $(du -sk \(p) | cut -f1) * 1024 ))\"; else printf -- '-\\t0\\n'; fi"
    }

    static func checksumScript(_ path: String) -> String {
        let p = ShellQuote.quote(path)
        return "(shasum -a 256 \(p) 2>/dev/null || sha256sum \(p)) | cut -d' ' -f1"
    }

    public func download(
        remotePath: String,
        from executor: any RemoteCommandExecuting,
        into workspace: FileWorkspace,
        index: ArtifactIndex,
        buildRunID: UUID? = nil,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> ArtifactRecord {
        let stat = try await executor.run(Self.statScript(remotePath))
        let fields = stat.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
        guard fields.count == 2, fields[0] != "-" else { throw ArtifactError.notFound(remotePath) }
        let isDirectory = fields[0] == "d"
        let expectedSize = Int64(fields[1]) ?? 0
        guard expectedSize <= sizeLimit else { throw ArtifactError.tooLarge(expectedSize, limit: sizeLimit) }

        let name = (remotePath as NSString).lastPathComponent
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let folder = WorkspacePath.artifacts.appending(day)
        try workspace.createDirectory(folder, intermediates: true)
        var destination = folder.appending(isDirectory ? name + ".tar" : name)
        var suffix = 1
        while workspace.exists(destination) {
            destination = folder.appending((isDirectory ? name + ".tar" : name) + ".\(suffix)")
            suffix += 1
        }

        let remoteChecksum: String? = isDirectory ? nil : try await executor.run(Self.checksumScript(remotePath)).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let command: String
        if isDirectory {
            let parent = (remotePath as NSString).deletingLastPathComponent
            command = "tar -C \(ShellQuote.quote(parent.isEmpty ? "/" : parent)) -cf - \(ShellQuote.quote(name))"
        } else {
            command = "cat -- \(ShellQuote.quote(remotePath))"
        }

        let url = try workspace.url(for: destination)
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var hasher = SHA256()
        var received: Int64 = 0
        var status: Int32 = -1
        var errorText = ""
        do {
            for try await event in executor.stream(command) {
                switch event {
                case .stdout(let data):
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    received += Int64(data.count)
                    progress(received, expectedSize)
                    if received > sizeLimit { throw ArtifactError.tooLarge(received, limit: sizeLimit) }
                case .stderr(let data):
                    errorText += String(decoding: data, as: UTF8.self)
                case .exit(let code):
                    status = code
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? workspace.remove(destination)
            throw (error as? ArtifactError) ?? ArtifactError.transferFailed(error.localizedDescription)
        }
        guard status == 0 else {
            try? workspace.remove(destination)
            throw ArtifactError.transferFailed(errorText.isEmpty ? "exit \(status)" : errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let remoteChecksum, !remoteChecksum.isEmpty, remoteChecksum != digest {
            try? workspace.remove(destination)
            throw ArtifactError.checksumMismatch(expected: remoteChecksum, actual: digest)
        }

        let record = ArtifactRecord(
            id: UUID(), name: name, hostID: executor.endpoint.hostID, hostName: executor.endpoint.displayName,
            remotePath: remotePath, wasDirectory: isDirectory, size: received, sha256: digest,
            verification: (remoteChecksum?.isEmpty == false) ? .remoteChecksumMatched : .localChecksumOnly,
            localPath: destination.string, buildRunID: buildRunID, downloadedAt: Date()
        )
        try await index.add(record)
        return record
    }
}
