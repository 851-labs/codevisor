import AppKit

@MainActor
final class TranscriptHostPool {
  private static let parkedLimit = 24
  private var recycledHosts: [TranscriptRowHost] = []
  private var retiringHosts: [TranscriptRowHost] = []
  private var recycledMarkdownHosts: [TranscriptMarkdownRowHost] = []
  private var parkedHosts: [String: TranscriptRowHost] = [:]
  private var parkedOrder: [String] = []
  private var parkedBubbles: [String: TranscriptBotBubbleRowHost] = [:]
  private var parkedBubbleOrder: [String] = []
  private var recycledBubbles: [TranscriptBotBubbleRowHost] = []
  private static let parkedBubbleLimit = 48

  var hasRetiringHosts: Bool { !retiringHosts.isEmpty }

  func takeHostedRow() -> TranscriptRowHost? {
    retiringHosts.popLast() ?? recycledHosts.popLast()
  }

  func retire(_ host: TranscriptRowHost) {
    retiringHosts.append(host)
  }

  func park(_ host: TranscriptRowHost, for key: String) {
    if let replaced = parkedHosts.updateValue(host, forKey: key), replaced !== host { retire(replaced) }
    parkedOrder.removeAll { $0 == key }
    parkedOrder.append(key)
    while parkedOrder.count > Self.parkedLimit {
      let evicted = parkedOrder.removeFirst()
      if let host = parkedHosts.removeValue(forKey: evicted) { retire(host) }
    }
  }

  func takeParked(for key: String) -> TranscriptRowHost? {
    guard let host = parkedHosts.removeValue(forKey: key) else { return nil }

    parkedOrder.removeAll { $0 == key }
    return host
  }

  func takeBubble(for key: String) -> TranscriptBotBubbleRowHost {
    if let parked = parkedBubbles.removeValue(forKey: key) {
      parkedBubbleOrder.removeAll { $0 == key }
      return parked
    }
    return recycledBubbles.popLast() ?? TranscriptBotBubbleRowHost(frame: .zero)
  }

  func parkBubble(_ host: TranscriptBotBubbleRowHost, for key: String) {
    if let replaced = parkedBubbles.updateValue(host, forKey: key), replaced !== host { recycleBubble(replaced) }
    parkedBubbleOrder.removeAll { $0 == key }
    parkedBubbleOrder.append(key)
    while parkedBubbleOrder.count > Self.parkedBubbleLimit {
      let evicted = parkedBubbleOrder.removeFirst()
      if let host = parkedBubbles.removeValue(forKey: evicted) { recycleBubble(host) }
    }
  }

  func recycleBubble(_ host: TranscriptBotBubbleRowHost) {
    if recycledBubbles.count < 8 { recycledBubbles.append(host) }
  }

  func retireParkedHosts() {
    for host in parkedHosts.values {
      retire(host)
    }
    parkedHosts.removeAll()
    parkedOrder.removeAll()
    parkedBubbles.removeAll()
    parkedBubbleOrder.removeAll()
  }

  func drainRetiringHosts(limit: Int) {
    for _ in 0..<max(0, limit) {
      guard let host = retiringHosts.popLast() else { return }
      if recycledHosts.count < 8 {
        recycledHosts.append(host)
      }
    }
  }

  func takeMarkdownRow() -> TranscriptMarkdownRowHost? {
    recycledMarkdownHosts.popLast()
  }

  func recycle(_ hosts: [TranscriptMarkdownRowHost]) {
    for host in hosts {
      if recycledMarkdownHosts.count < 8 {
        recycledMarkdownHosts.append(host)
      }
    }
  }
}
