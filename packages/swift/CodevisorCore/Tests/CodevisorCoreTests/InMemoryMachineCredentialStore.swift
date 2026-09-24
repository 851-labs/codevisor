import Foundation
@testable import CodevisorCore

final class InMemoryMachineCredentialStore: MachineCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String: String] = [:]

  init(tokens: [String: String] = [:]) {
    self.tokens = tokens
  }

  func token(forMachineID id: String) throws -> String? {
    lock.withLock { tokens[id] }
  }

  func saveToken(_ token: String, forMachineID id: String) throws {
    lock.withLock { tokens[id] = token }
  }

  func removeToken(forMachineID id: String) throws {
    lock.withLock { tokens[id] = nil }
  }
}
