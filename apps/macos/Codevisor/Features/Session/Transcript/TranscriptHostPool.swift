import AppKit

@MainActor
final class TranscriptHostPool {
  private var recycledHosts: [TranscriptRowHost] = []
  private var retiringHosts: [TranscriptRowHost] = []
  private var recycledMarkdownHosts: [TranscriptMarkdownRowHost] = []

  var hasRetiringHosts: Bool { !retiringHosts.isEmpty }

  func takeHostedRow() -> TranscriptRowHost? {
    retiringHosts.popLast() ?? recycledHosts.popLast()
  }

  func retire(_ host: TranscriptRowHost) {
    retiringHosts.append(host)
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
