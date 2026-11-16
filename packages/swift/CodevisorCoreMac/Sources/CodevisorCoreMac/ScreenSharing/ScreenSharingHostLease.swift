import Foundation
import CodevisorCore

struct ScreenSharingHostLease {
  struct Owner: Equatable, Sendable {
    enum Admission: Equatable { case replacesOwn, takesOver, refused }
    let viewerId: UUID
    let appKey: String
    let name: String?
    init?(_ request: ServerScreenSharingRequest) {
      guard let app = request.app else { return nil }

      viewerId = request.viewerId
      appKey = app.key.lowercased()
      name = Self.displayName(app.name)
    }
    static func displayName(_ raw: String) -> String? {
      let printable = raw.unicodeScalars.filter {
        ![.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
      }
      let name = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : String(name.prefix(64))
    }
    static func == (lhs: Owner, rhs: Owner) -> Bool { lhs.appKey == rhs.appKey }
    func isAttempt(of request: ServerScreenSharingRequest) -> Bool { viewerId == request.viewerId }
    func admission(against holder: Owner, intent: ServerScreenSharingRequest.Intent?) -> Admission {
      if self == holder { return .replacesOwn }
      if intent == .open { return .takesOver }
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
