import AppKit

/// Owns detached row hosts and the bounded warm pools used when rows mount again.
/// Hosted SwiftUI rows retire incrementally so releasing an abandoned window
/// cannot tear down all its hosting controllers during a scroll gesture.
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
      // Dropping the final reference here releases excess hosts outside live
      // scrolling. The caller bounds this work per display frame.
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
