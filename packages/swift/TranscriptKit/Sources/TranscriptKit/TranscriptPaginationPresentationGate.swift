import Foundation

/// Owns the user-visible lifetime of one reverse-pagination operation.
///
/// Network completion is intentionally not the terminal state: native
/// transcript views can defer a prepend while scrolling, so feedback remains
/// visible until the virtualizer confirms that the fetched rows have entered
/// its document geometry.
public struct TranscriptPaginationPresentationTarget: Sendable, Equatable {
  public let token: UInt64
  public let projectionRevision: UInt64

  public init(token: UInt64, projectionRevision: UInt64) {
    self.token = token
    self.projectionRevision = projectionRevision
  }
}

public struct TranscriptPaginationPresentationGate: Sendable, Equatable {
  private var nextToken: UInt64 = 0
  public private(set) var activeToken: UInt64?
  public private(set) var requiredProjectionKey: TranscriptProjectionKey?
  public private(set) var presentationTarget: TranscriptPaginationPresentationTarget?

  public init() {}

  public var isPresented: Bool { activeToken != nil }

  /// Starts feedback only when another page is known to exist. The returned
  /// token binds the eventual response and native-layout acknowledgement to
  /// this exact request.
  @discardableResult
  public mutating func begin(hasOlderHistory: Bool) -> UInt64? {
    guard hasOlderHistory, activeToken == nil else { return nil }
    nextToken &+= 1
    activeToken = nextToken
    requiredProjectionKey = nil
    presentationTarget = nil
    return nextToken
  }

  /// A non-empty page keeps feedback alive until the projection containing
  /// that page publishes. Empty pages and failures end it immediately
  /// because there is no new document geometry for the virtualizer to commit.
  public mutating func requestDidFinish(
    token: UInt64,
    insertedItemCount: Int,
    requiredProjectionKey: TranscriptProjectionKey?
  ) {
    guard activeToken == token else { return }
    guard insertedItemCount > 0, let requiredProjectionKey else {
      activeToken = nil
      self.requiredProjectionKey = nil
      presentationTarget = nil
      return
    }
    self.requiredProjectionKey = requiredProjectionKey
  }

  /// Binds native acknowledgement to a committed projection revision rather
  /// than a row identity. A later projection is also valid: transcript
  /// projections are cumulative, so it necessarily contains the requested
  /// history page while avoiding races with unrelated projection updates.
  public mutating func projectionDidPublish(
    key: TranscriptProjectionKey,
    revision: UInt64
  ) {
    guard let token = activeToken,
      presentationTarget == nil,
      let requiredProjectionKey,
      key.includes(requiredProjectionKey)
    else { return }
    self.requiredProjectionKey = nil
    presentationTarget = .init(token: token, projectionRevision: revision)
  }

  /// Returns true only when the matching native virtualizer commit completes
  /// the active pagination presentation.
  @discardableResult
  public mutating func didPresent(token: UInt64) -> Bool {
    guard activeToken == token, presentationTarget?.token == token else { return false }
    activeToken = nil
    requiredProjectionKey = nil
    presentationTarget = nil
    return true
  }

  public mutating func cancel(token: UInt64? = nil) {
    guard token == nil || activeToken == token else { return }
    activeToken = nil
    requiredProjectionKey = nil
    presentationTarget = nil
  }
}

private extension TranscriptProjectionKey {
  func includes(_ required: Self) -> Bool {
    sessionID == required.sessionID
      && controllerRevision >= required.controllerRevision
      && modelRevision >= required.modelRevision
  }
}
