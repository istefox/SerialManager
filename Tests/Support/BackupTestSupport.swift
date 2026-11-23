import CryptoKit
import Foundation
@testable import SerialManager

/// Fake fixtures shared by the backup tests. Public repository: fake data and passwords only.
/// Dates use binary-exact fractions (.125, .250, .500, .750) so the three-digit formatting can
/// neither round nor truncate them.
enum BackupFixtures {
    static let password = "sample-backup-pass"

    /// 2026-01-01T09:00:00.250Z
    static let editorCreated = Date(timeIntervalSince1970: 1_767_258_000.250)
    /// 2026-01-01T09:00:00.500Z
    static let editorUpdated = Date(timeIntervalSince1970: 1_767_258_000.500)
    /// 2026-01-01T09:01:00.125Z
    static let viewerCreated = Date(timeIntervalSince1970: 1_767_258_060.125)
    /// 2026-01-01T00:00:00.000Z
    static let viewerPurchased = Date(timeIntervalSince1970: 1_767_225_600)
    /// 2026-01-01T10:00:00.750Z
    static let exportedAt = Date(timeIntervalSince1970: 1_767_261_600.750)

    static let editor = LicenseSummary(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        productName: "Sample Editor",
        vendor: "Example Software",
        // Empty on purpose: `BackupImportFixture` is a sealed v1 file written before `registeredName`
        // existed, so it decodes to "" and these fixtures must match it byte for byte.
        registeredName: "",
        registeredEmail: "user@example.com",
        purchaseDate: nil,
        version: "1.0",
        notes: "",
        createdAt: editorCreated,
        updatedAt: editorUpdated
    )

    static let viewer = LicenseSummary(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
        productName: "Sample Viewer",
        vendor: "Example Labs",
        registeredName: "",
        registeredEmail: "viewer@example.com",
        purchaseDate: viewerPurchased,
        version: "2.5",
        notes: "Fake note",
        createdAt: viewerCreated,
        updatedAt: viewerCreated
    )

    static let editorSerial = "FAKE-0000-0000-0000"

    static let salt = Data((0..<16).map { UInt8(0xA0 + $0) })
    static let nonceBytes = Data((0..<12).map { UInt8(0x10 + $0) })
    static var nonce: AES.GCM.Nonce { try! AES.GCM.Nonce(data: nonceBytes) }

    /// Editor with its serial, Viewer with no Keychain item. Returned in reverse creation order,
    /// so the tests also see the service sort them.
    static func repository() -> ScriptedLicenseRepository {
        ScriptedLicenseRepository(
            licenses: [viewer, editor],
            serials: [editor.id: .value(editorSerial)]
        )
    }

    /// Service with fixed salt, nonce and clock.
    static func service(
        repository: any LicenseRepository = repository(),
        saltSource: (@Sendable (Int) throws -> Data)? = nil,
        maxFileSize: Int = BackupFormat.maxBackupFileSize,
        stageProbe: (@Sendable (BackupStage) -> Void)? = nil
    ) -> EncryptedBackupService {
        EncryptedBackupService(
            repository: repository,
            saltSource: saltSource ?? { _ in salt },
            nonceSource: { nonce },
            now: { exportedAt },
            maxFileSize: maxFileSize,
            deriveKey: { password, salt, iterations in
                stageProbe?(.keyDerivation)
                return try BackupKeyDerivation.key(password: password, salt: salt, iterations: iterations)
            },
            seal: { plaintext, key, nonce, header in
                stageProbe?(.encryption)
                return try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
            }
        )
    }
}

/// The CPU-bound export stages a test can observe through `BackupFixtures.service(stageProbe:)`.
enum BackupStage: Equatable, Sendable {
    case keyDerivation
    case encryption
}

/// A temporary directory for one test, removed by `remove()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "SerialManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String = "Licenses.smbackup") -> URL {
        url.appending(path: name, directoryHint: .notDirectory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Thread-safe list of values recorded from `@Sendable` closures (macOS 14: no `Mutex`).
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }
}

extension Data {
    /// True when `needle` appears anywhere in these bytes.
    func contains(bytes needle: Data) -> Bool {
        range(of: needle) != nil
    }
}

/// A `deriveKey` seam for the import tests (plan 0010, T3, A16 and R17): through
/// `BackupFixtures.service(stageProbe:)`, it holds the first key derivation until `open()`.
///
/// The hold is a bounded synchronous wait inside the derivation, which runs in the reader's detached
/// task. If it times out, `didTimeOut` is set, so a service that cannot run `cancelImport()` while a
/// derivation is held fails the test instead of hanging it.
final class DerivationGate: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callCount = 0
    private var timedOut = false

    /// Call from the `.keyDerivation` stage probe. Holds the first call only.
    func hold() {
        let isFirst = lock.withLock {
            callCount += 1
            return callCount == 1
        }
        guard isFirst else { return }
        if release.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { timedOut = true }
        }
    }

    func open() {
        release.signal()
    }

    var calls: Int { lock.withLock { callCount } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    /// True once `count` derivations have started; false after 10 seconds.
    func waitForCalls(_ count: Int) async -> Bool {
        for _ in 0..<1_000 {
            if calls >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return calls >= count
    }
}
