import Foundation
import Observation
import StreamMarkdown
import TranscriptKit

/// The transcript that a find bar searches. The macOS virtualized scroll view
/// adopts this: it owns the rows, the mounted text surfaces, and the viewport
/// the current match must be scrolled into.
@MainActor
public protocol TranscriptFindTarget: AnyObject {
  func transcriptFindQueryDidChange(_ model: TranscriptFindModel)
  func transcriptFind(_ model: TranscriptFindModel, step delta: Int)
  func transcriptFindDidDismiss(_ model: TranscriptFindModel)
}

/// Find-in-chat state for one chat pane, shared by the find bar, the menu
/// commands, and the transcript it searches.
@MainActor
@Observable
public final class TranscriptFindModel {
  public private(set) var isPresented = false
  public private(set) var query = ""
  public private(set) var matchCount = 0
  /// One-based position of the current match, for "3 of 12".
  public private(set) var currentMatchNumber: Int?
  /// Bumped whenever the bar should take keyboard focus, including a repeat
  /// ⌘F while it is already open.
  public private(set) var focusRequest = 0
  @ObservationIgnored public weak var target: (any TranscriptFindTarget)?

  public init() {}

  public func present() {
    focusRequest &+= 1
    guard !isPresented else { return }
    isPresented = true
    target?.transcriptFindQueryDidChange(self)
  }

  public func dismiss() {
    guard isPresented else { return }
    isPresented = false
    target?.transcriptFindDidDismiss(self)
  }

  public func updateQuery(_ query: String) {
    guard query != self.query else { return }
    self.query = query
    target?.transcriptFindQueryDidChange(self)
  }

  /// ⌘G with the bar closed reopens it on the previous query, as browsers do.
  public func findNext() {
    guard isPresented else { return present() }
    target?.transcriptFind(self, step: 1)
  }

  public func findPrevious() {
    guard isPresented else { return present() }
    target?.transcriptFind(self, step: -1)
  }

  public func publish(_ results: TranscriptFindResults) {
    if matchCount != results.count { matchCount = results.count }
    let number = results.currentIndex.map { $0 + 1 }
    if currentMatchNumber != number { currentMatchNumber = number }
  }

  /// "3 of 12", "No results", or nothing before the user has typed.
  public var status: String? {
    guard !query.isEmpty else { return nil }
    guard matchCount > 0 else { return "No results" }
    return "\(currentMatchNumber ?? 0) of \(matchCount)"
  }
}
