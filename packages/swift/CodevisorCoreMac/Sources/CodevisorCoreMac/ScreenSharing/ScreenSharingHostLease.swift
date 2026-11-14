import Foundation
import CodevisorCore

struct ScreenSharingHostLease {
  struct Owner: Equatable, Sendable {
    enum Admission: Equatable { case replacesOwn, takesOver, refused }
    let workspaceId: UUID
    let paneId: UUID
    let viewerId: UUID
    let appKey: String?
    let name: String?
    init(_ request: ServerScreenSharingRequest) {
      workspaceId = request.workspaceId; paneId = request.paneId; viewerId = request.viewerId
      appKey = request.app?.key.lowercased(); name = request.app.flatMap { Self.displayName($0.name) }
    }
    static func displayName(_ raw: String) -> String? {
      let printable = raw.unicodeScalars.filter {
        ![.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
      }
      let name = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : String(name.prefix(64))
    }
    static func == (lhs: Owner, rhs: Owner) -> Bool {
      guard lhs.appKey == nil, rhs.appKey == nil else { return lhs.appKey == rhs.appKey }
      return lhs.isSameHolder(as: rhs) && lhs.viewerId == rhs.viewerId
    }
    func isSameHolder(as other: Owner) -> Bool {
      guard appKey == nil, other.appKey == nil else { return appKey == other.appKey }
      return workspaceId == other.workspaceId && paneId == other.paneId
    }
    func isSameAttempt(as other: Owner) -> Bool { self == other && viewerId == other.viewerId }
    func admission(against holder: Owner, intent: ServerScreenSharingRequest.Intent?) -> Admission {
      if isSameHolder(as: holder) { return .replacesOwn }
      if appKey != nil, intent == .open { return .takesOver }
      return .refused
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
