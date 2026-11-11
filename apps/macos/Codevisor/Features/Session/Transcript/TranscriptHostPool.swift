import AppKit

@MainActor
final class TranscriptHostPool {
  private static let parkedLimit = 24
  private var recycledHosts: [TranscriptRowHost] = []
  private var retiringHosts: [TranscriptRowHost] = []
  private var recycledMarkdownHosts: [TranscriptMarkdownRowHost] = []
  private var parkedHosts: [String: TranscriptRowHost] = [:]
  private var parkedOrder: [String] = []
  var bubbles = TranscriptKeyedHostShelf<TranscriptBotBubbleRowHost>(limit: 48)
  var images = TranscriptKeyedHostShelf<TranscriptBotImageRowHost>(limit: 32)

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

  func retireParkedHosts() {
    for host in parkedHosts.values {
      retire(host)
    }
    parkedHosts.removeAll()
    parkedOrder.removeAll()
    bubbles.removeAll()
    images.removeAll()
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
