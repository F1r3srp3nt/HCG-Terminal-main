import Crypto
import Foundation
import TerminalCore
import TerminalSecurity
import XCTest

final class PrivilegeClassifierTests: XCTestCase {
    func testElevationAndPackageChangesRequireAuthorization() {
        XCTAssertTrue(PrivilegeClassifier.assess("sudo ls").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("/var/jb/usr/bin/sudo apt install vim").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("apt-get install -y htop").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("dpkg -i pkg.deb").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("FOO=1 env -i launchctl list").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("ls && killall SpringBoard").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("rm -rf /var/jb/usr/lib").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("echo x > /etc/hosts").requiresAuthorization)
        XCTAssertTrue(PrivilegeClassifier.assess("sysctl -w kern.x=1").requiresAuthorization)
    }

    func testOrdinaryCommandsDoNot() {
        for command in ["ls -la", "apt list --installed", "dpkg -l", "cat /etc/hosts", "rm notes.txt", "sysctl kern.ostype", "grep sudo file.txt", "echo hi > out.txt"] {
            XCTAssertFalse(PrivilegeClassifier.assess(command).requiresAuthorization, command)
        }
    }
}

final class AuthorizationGateTests: XCTestCase {
    func testNoPresenterMeansDenied() async {
        let gate = AuthorizationGate()
        let granted = await gate.requestAuthorization(AuthorizationRequest(title: "t", commandLine: "sudo x", target: .local(.unleashed), reasons: []))
        XCTAssertFalse(granted)
        let trail = await gate.auditTrail()
        XCTAssertEqual(trail.count, 1)
        XCTAssertEqual(trail.first?.granted, false)
    }

    func testEachRequestIsDecidedIndividually() async {
        let gate = AuthorizationGate(presenter: { request in request.commandLine.contains("yes") })
        let first = await gate.requestAuthorization(AuthorizationRequest(title: "", commandLine: "yes", target: .local(.unleashed), reasons: []))
        let second = await gate.requestAuthorization(AuthorizationRequest(title: "", commandLine: "no", target: .local(.unleashed), reasons: []))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }
}

final class KnownHostsTests: XCTestCase {
    func testTrustOnFirstUseRequiresExplicitTrustAndDetectsMismatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = KnownHostsStore(fileURL: url)
        let key = PresentedHostKey(algorithm: "ssh-ed25519", blob: Data([1, 2, 3]))
        let other = PresentedHostKey(algorithm: "ssh-ed25519", blob: Data([9, 9, 9]))

        guard case .unknown = await store.verdict(host: "Mac.local", port: 22, key: key) else { return XCTFail() }
        try await store.trust(host: "Mac.local", port: 22, key: key)
        let trusted = await store.verdict(host: "mac.local", port: 22, key: key)
        XCTAssertEqual(trusted, .trusted)
        guard case .mismatch = await store.verdict(host: "mac.local", port: 22, key: other) else { return XCTFail() }

        // Persisted.
        let reloaded = KnownHostsStore(fileURL: url)
        let reloadedVerdict = await reloaded.verdict(host: "mac.local", port: 22, key: key)
        XCTAssertEqual(reloadedVerdict, .trusted)
    }
}

final class SSHKeyTests: XCTestCase {
    func testGenerateStoreAndExport() throws {
        let credentials = InMemoryCredentialStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = SSHKeyManager(credentials: credentials, metadataURL: url)
        let record = try manager.generateEd25519(comment: "hcg-terminal@ipad")
        XCTAssertTrue(record.publicKeyLine.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        XCTAssertTrue(record.publicKeyLine.hasSuffix(" hcg-terminal@ipad"))
        XCTAssertTrue(record.fingerprint.hasPrefix("SHA256:"))
        XCTAssertEqual(manager.list(), [record])

        let key = try manager.privateKey(for: record.id)
        XCTAssertEqual(SSHKeyManager.record(for: key.publicKey, id: record.id, comment: record.comment).publicKeyLine, record.publicKeyLine)

        try manager.delete(record.id)
        XCTAssertTrue(manager.list().isEmpty)
        XCTAssertThrowsError(try manager.privateKey(for: record.id))
    }

    func testFingerprintMatchesOpenSSH() throws {
        // Key and fingerprint produced by OpenSSH 9.6 (`ssh-keygen -t ed25519`, `ssh-keygen -lf`).
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAXrljeRlH9CVoRGHsYkGEnyEbiTRwPm3bliHnLDfcTa test"
        let key = try XCTUnwrap(PresentedHostKey(openSSHLine: line))
        XCTAssertEqual(key.algorithm, "ssh-ed25519")
        XCTAssertEqual(key.fingerprint, "SHA256:uT+x9ZGUSEqAUKxJvMa2bwuraHR7xCLGnEHzvNCZSNs")
    }
}
