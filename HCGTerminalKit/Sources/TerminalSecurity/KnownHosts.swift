import Foundation

/// A host key as presented by a server.
public struct PresentedHostKey: Hashable, Sendable {
    public var algorithm: String
    public var blob: Data
    public var fingerprint: String

    public init(algorithm: String, blob: Data) {
        self.algorithm = algorithm
        self.blob = blob
        self.fingerprint = SSHWire.fingerprint(ofKeyBlob: blob)
    }

    /// Parses an OpenSSH public key line.
    public init?(openSSHLine: String) {
        guard let parsed = SSHWire.parsePublicKeyLine(openSSHLine) else { return nil }
        self.init(algorithm: parsed.type, blob: parsed.blob)
    }
}

public struct KnownHostEntry: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var algorithm: String
    public var blobBase64: String
    public var fingerprint: String
    public var trustedAt: Date
}

public enum HostKeyVerdict: Hashable, Sendable {
    case trusted
    /// First contact. The user must explicitly confirm the fingerprint.
    case unknown(PresentedHostKey)
    /// The server presented a different key than the one previously trusted. Connection is
    /// refused; the user must remove the old entry deliberately to proceed.
    case mismatch(expected: String, presented: PresentedHostKey)
}

/// Trust-on-first-use known-hosts store with explicit confirmation. Persisted as JSON.
public actor KnownHostsStore {
    private let fileURL: URL?
    private var entries: [KnownHostEntry]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([KnownHostEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    public func verdict(host: String, port: Int, key: PresentedHostKey) -> HostKeyVerdict {
        let normalized = host.lowercased()
        let forHost = entries.filter { $0.host == normalized && $0.port == port }
        if forHost.isEmpty { return .unknown(key) }
        if forHost.contains(where: { $0.algorithm == key.algorithm && $0.blobBase64 == key.blob.base64EncodedString() }) {
            return .trusted
        }
        return .mismatch(expected: forHost.map(\.fingerprint).joined(separator: ", "), presented: key)
    }

    /// Called only after the user explicitly confirmed the fingerprint.
    public func trust(host: String, port: Int, key: PresentedHostKey) throws {
        entries.removeAll { $0.host == host.lowercased() && $0.port == port && $0.algorithm == key.algorithm }
        entries.append(KnownHostEntry(
            host: host.lowercased(), port: port, algorithm: key.algorithm,
            blobBase64: key.blob.base64EncodedString(), fingerprint: key.fingerprint, trustedAt: Date()
        ))
        try persist()
    }

    public func forget(host: String, port: Int) throws {
        entries.removeAll { $0.host == host.lowercased() && $0.port == port }
        try persist()
    }

    public func all() -> [KnownHostEntry] { entries }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: fileURL, options: [.atomic])
    }
}
