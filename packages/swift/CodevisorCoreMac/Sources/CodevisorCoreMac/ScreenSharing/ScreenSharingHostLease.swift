import Foundation
import CodevisorCore

/// Time is supplied by the host, so ownership and expiry are deterministic.
struct ScreenSharingHostLease {
  struct Owner: Equatable, Sendable {
    let workspaceId: UUID
    let paneId: UUID
    let viewerId: UUID
    init(_ request: ServerScreenSharingRequest) {
      workspaceId = request.workspaceId; paneId = request.paneId; viewerId = request.viewerId
    }
  }
  private(set) var owner: Owner?
  private(set) var expiresAt: TimeInterval = 0
  static let lifetime: TimeInterval = 25

  mutating func reserve(_ candidate: Owner, now: TimeInterval) -> Bool {
    guard owner == nil else { return false }
    owner = candidate; expiresAt = now + Self.lifetime
    return true
  }
  func owns(_ candidate: Owner, now: TimeInterval) -> Bool { owner == candidate && now < expiresAt }
  struct ReplacementPermit {
    let revision: Int
    let deadline: TimeInterval
    func isValid(revision: Int, now: TimeInterval) -> Bool { self.revision == revision && now < deadline }
  }
  func replacementPermit(_ candidate: Owner, revision: Int, now: TimeInterval) -> ReplacementPermit? {
    guard owns(candidate, now: now) else { return nil }
    return .init(revision: revision, deadline: expiresAt)
  }
  mutating func renew(_ candidate: Owner, now: TimeInterval) -> Bool {
    guard owns(candidate, now: now) else { return false }
    expiresAt = now + Self.lifetime
    return true
  }
  func isExpired(now: TimeInterval) -> Bool { owner != nil && now >= expiresAt }
  mutating func release(_ candidate: Owner) -> Bool {
    guard owner == candidate else { return false }
    owner = nil
    return true
  }
}
