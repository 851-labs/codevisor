import Foundation

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

  @discardableResult
  public mutating func begin(hasOlderHistory: Bool) -> UInt64? {
    guard hasOlderHistory, activeToken == nil else { return nil }
    nextToken &+= 1
    activeToken = nextToken
    requiredProjectionKey = nil
    presentationTarget = nil
    return nextToken
  }

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
