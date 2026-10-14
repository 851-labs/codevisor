import Foundation
import Observation
import StreamMarkdown
import TranscriptKit

@MainActor
public protocol TranscriptFindTarget: AnyObject {
  func transcriptFindQueryDidChange(_ model: TranscriptFindModel)
  func transcriptFind(_ model: TranscriptFindModel, step delta: Int)
  func transcriptFindDidDismiss(_ model: TranscriptFindModel)
}

@MainActor
@Observable
public final class TranscriptFindModel {
  public private(set) var isPresented = false
  public private(set) var query = ""
  public private(set) var matchCount = 0
  public private(set) var currentMatchNumber: Int?
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

  public var status: String? {
    guard !query.isEmpty else { return nil }
    guard matchCount > 0 else { return "No results" }
    return "\(currentMatchNumber ?? 0) of \(matchCount)"
  }
}
