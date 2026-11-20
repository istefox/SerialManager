import Foundation
@testable import SerialManager

/// `SerialStore` double for the repository tests (plan 0004, section 2.5). Never touches the Keychain.
///
/// Each operation can fail on its own, after letting a number of calls through, and can be held on
/// a gate until the test opens it. Every call is logged, before any gate or failure, so a test can
/// see that a call started even while it is suspended.
actor ScriptedSerialStore: SerialStore {
    enum Operation: Equatable, Hashable, Sendable {
        case read
        case save
        case delete
    }

    struct Call: Equatable, Sendable {
        let operation: Operation
        let id: UUID
    }

    private struct Failure {
        let error: any Error
        var passesLeft: Int
    }

    private(set) var items: [UUID: String]
    private(set) var log: [Call] = []
    private var failures: [Operation: Failure] = [:]
    private var closedGates: Set<Operation> = []
    private var gateWaiters: [Operation: [CheckedContinuation<Void, Never>]] = [:]

    init(items: [UUID: String] = [:]) {
        self.items = items
    }

    /// Makes `operation` throw `error` once `passes` calls have gone through, and on every call after.
    func fail(_ operation: Operation, with error: any Error, after passes: Int = 0) {
        failures[operation] = Failure(error: error, passesLeft: passes)
    }

    /// Calls of `operation` suspend until `openGate(_:)`.
    func closeGate(_ operation: Operation) {
        closedGates.insert(operation)
    }

    func openGate(_ operation: Operation) {
        closedGates.remove(operation)
        for waiter in gateWaiters.removeValue(forKey: operation) ?? [] {
            waiter.resume()
        }
    }

    /// Removes an item without logging, as if it had been deleted outside the app.
    func removeItem(for id: UUID) {
        items[id] = nil
    }

    func clearLog() {
        log.removeAll()
    }

    func calls(_ operation: Operation) -> [Call] {
        log.filter { $0.operation == operation }
    }

    func save(_ serial: String, for id: UUID) async throws {
        try await begin(.save, id)
        items[id] = serial
    }

    func serial(for id: UUID) async throws -> String? {
        try await begin(.read, id)
        return items[id]
    }

    func deleteSerial(for id: UUID) async throws {
        try await begin(.delete, id)
        items[id] = nil
    }

    private func begin(_ operation: Operation, _ id: UUID) async throws {
        log.append(Call(operation: operation, id: id))
        if closedGates.contains(operation) {
            await withCheckedContinuation { gateWaiters[operation, default: []].append($0) }
        }
        guard var failure = failures[operation] else { return }
        if failure.passesLeft > 0 {
            failure.passesLeft -= 1
            failures[operation] = failure
            return
        }
        throw failure.error
    }
}
