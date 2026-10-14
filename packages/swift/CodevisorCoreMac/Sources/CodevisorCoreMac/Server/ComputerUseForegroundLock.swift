import Foundation

final class ComputerUseForegroundLock: @unchecked Sendable {
  struct Token: Sendable {
    let id = UUID()
    let sessionID: String
    let pid: pid_t
    let expiresAt: TimeInterval
  }

  static let maximumDuration: TimeInterval = 8
  static let quietPeriod: TimeInterval = 2
  private let mutex = NSLock()
  private let contextKey = "computer-use-foreground-\(UUID())"
  private let now: @Sendable () -> TimeInterval
  private var owner: Token?
  private var lastHumanInput: TimeInterval = -.infinity

  init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.now = now
  }

  var currentToken: Token? { Thread.current.threadDictionary[contextKey] as? Token }

  func perform<Value>(sessionID: String, pid: pid_t, operation: () throws -> Value) throws -> Value {
    let token: Token = try mutex.withLock {
      expire()
      guard owner == nil, now() >= lastHumanInput + Self.quietPeriod else {
        throw BridgeError(
          "Foreground access is busy with the human or another agent. No input was sent. Continue in background; do not repeatedly retry foreground."
        )
      }
      let token = Token(sessionID: sessionID, pid: pid, expiresAt: now() + Self.maximumDuration)
      owner = token
      return token
    }
    let previous = Thread.current.threadDictionary[contextKey]
    Thread.current.threadDictionary[contextKey] = token
    defer {
      mutex.withLock {
        if owner?.id == token.id { owner = nil }
      }
      if let previous {
        Thread.current.threadDictionary[contextKey] = previous
      } else {
        Thread.current.threadDictionary.removeObject(forKey: contextKey)
      }
    }
    return try operation()
  }

  func check(_ token: Token?, pid: pid_t) throws {
    try withInput(token, pid: pid) {}
  }

  func withInput(_ token: Token?, pid: pid_t, operation: () -> Void) throws {
    try mutex.withLock {
      expire()
      guard let token, token.pid == pid, owner?.id == token.id else {
        throw BridgeError(
          "Foreground ownership expired or was interrupted by human activity or session closure. Some input may already have arrived. Observe and continue in background; do not take focus back."
        )
      }
      operation()
    }
  }

  func withCleanup(_ token: Token?, pid: pid_t, operation: () -> Void) {
    mutex.withLock {
      expire()
      guard let token, token.pid == pid,
        owner == nil || owner?.id == token.id || owner?.pid != pid
      else { return }
      operation()
    }
  }

  func humanInput() {
    mutex.withLock {
      lastHumanInput = now()
      owner = nil
    }
  }

  func cancel(sessionID: String) {
    mutex.withLock {
      if owner?.sessionID == sessionID { owner = nil }
    }
  }

  private func expire() {
    if let owner, now() >= owner.expiresAt { self.owner = nil }
  }
}
