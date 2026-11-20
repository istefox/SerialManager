import Foundation

/// User-facing text for serial store failures (D4).
///
/// Only `.accessDenied` gets a dedicated message. Every other case returns nil, so
/// `localizedDescription` keeps the generic system text. The repository never wraps these
/// errors, which is what lets the existing catch sites show this text unchanged.
extension SerialStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            String(localized: "Keychain access was denied. Try again, or check the Keychain permissions for SerialManager.")
        case .undecodableData, .unexpected:
            nil
        }
    }
}
