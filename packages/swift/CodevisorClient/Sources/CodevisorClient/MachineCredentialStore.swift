import Foundation
import Security

public protocol MachineCredentialStore: Sendable {
  func token(forMachineID id: String) throws -> String?
  func saveToken(_ token: String, forMachineID id: String) throws
  func removeToken(forMachineID id: String) throws
}

public struct MachineCredentialError: Error, LocalizedError, Sendable {
  public let operation: String
  public let status: OSStatus

  public var errorDescription: String? {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
    return "Machine credential \(operation) failed: \(detail)"
  }
}

/// Device-local credential storage for remote Codevisor server tokens.
public final class KeychainMachineCredentialStore: MachineCredentialStore, @unchecked Sendable {
  public static let shared = KeychainMachineCredentialStore()

  private let values: KeychainValueStore

  public convenience init() {
    self.init(service: KeychainCredentialServices.machine)
  }

  public init(service: String) {
    values = KeychainValueStore(service: service)
  }

  public init(service: String, operations: KeychainOperations) {
    values = KeychainValueStore(service: service, operations: operations)
  }

  public func token(forMachineID id: String) throws -> String? {
    try mapFailure { try values.value(forAccount: id) }
  }

  public func saveToken(_ token: String, forMachineID id: String) throws {
    try mapFailure { try values.saveValue(token, forAccount: id) }
  }

  public func removeToken(forMachineID id: String) throws {
    try mapFailure { try values.removeValue(forAccount: id) }
  }

  private func mapFailure<T>(_ operation: () throws -> T) throws -> T {
    do {
      return try operation()
    } catch let failure as KeychainStorageFailure {
      throw MachineCredentialError(operation: failure.operation, status: failure.status)
    }
  }
}

public final class InMemoryMachineCredentialStore: MachineCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String: String] = [:]

  public init(tokens: [String: String] = [:]) {
    self.tokens = tokens
  }

  public func token(forMachineID id: String) throws -> String? {
    lock.withLock { tokens[id] }
  }

  public func saveToken(_ token: String, forMachineID id: String) throws {
    lock.withLock { tokens[id] = token }
  }

  public func removeToken(forMachineID id: String) throws {
    lock.withLock { tokens[id] = nil }
  }
}
