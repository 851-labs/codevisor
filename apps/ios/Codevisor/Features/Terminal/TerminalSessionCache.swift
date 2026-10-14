import CodevisorCore
import UIKit

@MainActor
final class TerminalSessionCache {
  static let shared = TerminalSessionCache()

  struct Key: Hashable {
    let server: String
    let terminalKey: String
  }

  private static let budget = 8
  private var sessions: [Key: TerminalSession] = [:]
  private var order: [Key] = []
  private var memoryWarning: NSObjectProtocol?

  private init() {
    memoryWarning = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.evictHidden() }
    }
  }

  func session(
    terminalKey: String, cwd: String, config: CodevisorServerConfig
  ) -> TerminalSession {
    let key = Key(server: config.baseURL.absoluteString, terminalKey: terminalKey)
    if let existing = sessions[key], !existing.hasExited || existing.isVisible {
      touch(key)
      return existing
    }
    evict(key)
    let session = TerminalSession(
      terminalKey: terminalKey, cwd: cwd, config: config)
    session.onExit = { [weak self, weak session] in
      guard let session, !session.isVisible else { return }
      self?.evict(key)
    }
    sessions[key] = session
    touch(key)
    while order.count > Self.budget, let oldest = order.first(where: { sessions[$0]?.isVisible == false }) {
      evict(oldest)
    }
    return session
  }

  func didHide(_ session: TerminalSession) {
    guard session.hasExited, let key = sessions.first(where: { $0.value === session })?.key else { return }
    evict(key)
  }

  func reconnectAll() {
    for session in sessions.values { session.reconnect() }
  }

  func remove(terminalKey: String) {
    for key in sessions.keys where key.terminalKey == terminalKey { evict(key) }
  }

  private func evictHidden() {
    for (key, session) in sessions where !session.isVisible { evict(key) }
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func evict(_ key: Key) {
    order.removeAll { $0 == key }
    sessions.removeValue(forKey: key)?.detach()
  }
}
