import Foundation

/// In-memory `SerialStore` for previews and tests. Never touches the Keychain.
///
/// Behaves like the Keychain implementation: save replaces, read of a missing id returns nil,
/// delete of a missing id succeeds. Empty strings are stored as given (empty-serial policy belongs
/// to the repository). When a failure is set, every operation throws it.
actor InMemorySerialStore: SerialStore {
    private var serials: [UUID: String]
    private var failure: (any Error)?

    init(serials: [UUID: String] = [:], failure: (any Error)? = nil) {
        self.serials = serials
        self.failure = failure
    }

    /// Number of stored items.
    var itemCount: Int { serials.count }

    func setFailure(_ error: (any Error)?) { failure = error }

    func save(_ serial: String, for id: UUID) async throws {
        try check()
        serials[id] = serial
    }

    func serial(for id: UUID) async throws -> String? {
        try check()
        return serials[id]
    }

    func deleteSerial(for id: UUID) async throws {
        try check()
        serials[id] = nil
    }

    private func check() throws {
        if let failure { throw failure }
    }
}
