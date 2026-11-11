import Crypto
import Foundation

/// SSH wire-format helpers (RFC 4251 strings).
public enum SSHWire {
    public static func string(_ bytes: some Collection<UInt8>) -> [UInt8] {
        let length = UInt32(bytes.count)
        return [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + Array(bytes)
    }

    public static func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

    /// OpenSSH-style fingerprint: `SHA256:` + unpadded base64 of SHA-256 over the key blob.
    public static func fingerprint(ofKeyBlob blob: some DataProtocol) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    /// Parses an OpenSSH public key line (`type base64 [comment]`) into type and blob.
    public static func parsePublicKeyLine(_ line: String) -> (type: String, blob: Data)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return (String(parts[0]), blob)
    }
}

/// Metadata for a key generated on the device. The private key itself lives only in the
/// credential store (Keychain on iOS).
public struct SSHKeyRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var comment: String
    public var algorithm: String
    /// OpenSSH `authorized_keys` line.
    public var publicKeyLine: String
    public var fingerprint: String
    public var createdAt: Date
}

public enum SSHKeyError: Error, LocalizedError {
    case missingPrivateKey(UUID)
    case corruptPrivateKey

    public var errorDescription: String? {
        switch self {
        case .missingPrivateKey: "The private key is missing from secure storage."
        case .corruptPrivateKey: "The stored private key could not be read."
        }
    }
}

/// Generates and stores Ed25519 SSH keys.
public struct SSHKeyManager: Sendable {
    private let credentials: any CredentialStore
    private let metadataURL: URL

    public init(credentials: any CredentialStore, metadataURL: URL) {
        self.credentials = credentials
        self.metadataURL = metadataURL
    }

    public func generateEd25519(comment: String) throws -> SSHKeyRecord {
        let key = Curve25519.Signing.PrivateKey()
        let record = Self.record(for: key.publicKey, id: UUID(), comment: comment)
        try credentials.save(key.rawRepresentation, for: .privateKey(record.id))
        var all = list()
        all.append(record)
        try persist(all)
        return record
    }

    public func list() -> [SSHKeyRecord] {
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        return (try? JSONDecoder().decode([SSHKeyRecord].self, from: data)) ?? []
    }

    public func privateKey(for id: UUID) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = try credentials.load(.privateKey(id)) else { throw SSHKeyError.missingPrivateKey(id) }
        do { return try Curve25519.Signing.PrivateKey(rawRepresentation: raw) } catch { throw SSHKeyError.corruptPrivateKey }
    }

    public func delete(_ id: UUID) throws {
        try credentials.delete(.privateKey(id))
        try persist(list().filter { $0.id != id })
    }

    public static func record(for publicKey: Curve25519.Signing.PublicKey, id: UUID, comment: String) -> SSHKeyRecord {
        let blob = SSHWire.string("ssh-ed25519") + SSHWire.string(publicKey.rawRepresentation)
        let line = "ssh-ed25519 \(Data(blob).base64EncodedString())" + (comment.isEmpty ? "" : " \(comment)")
        return SSHKeyRecord(
            id: id, comment: comment, algorithm: "ssh-ed25519", publicKeyLine: line,
            fingerprint: SSHWire.fingerprint(ofKeyBlob: blob), createdAt: Date()
        )
    }

    private func persist(_ records: [SSHKeyRecord]) throws {
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: metadataURL, options: [.atomic])
    }
}
