import Foundation

/// Stores the serial of each license, keyed by the license UUID.
///
/// Internal to the data layer: only `LicenseRepository` implementations use it, the GUI never does.
/// Values are stored exactly as given: no trimming, validation or interpretation.
protocol SerialStore: Sendable {
    /// Stores `serial` for `id`, replacing any existing value. The value is stored as given.
    func save(_ serial: String, for id: UUID) async throws
    /// Returns nil when no item exists for `id`.
    func serial(for id: UUID) async throws -> String?
    /// Succeeds when no item exists for `id`.
    func deleteSerial(for id: UUID) async throws
}

/// A failure of the serial storage. Never carries the serial, the query or any item data.
enum SerialStoreError: Error, Equatable, Sendable {
    /// The user or the system refused access, or user interaction was not allowed.
    case accessDenied
    /// The stored item data is missing or is not valid UTF-8.
    case undecodableData
    /// Any other failure, with the underlying Keychain status code.
    case unexpected(status: OSStatus)
}
