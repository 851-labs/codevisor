import CodevisorCore
import Foundation
import Testing
@testable import CodevisorCoreMac

struct ScreenSharingHostLeaseTests {
  @Test func secondAppCannotDisplaceOrRenewAnotherAppsLease() throws {
    let first = try owner(key: "a")
    let second = try owner(key: "b")
    var lease = ScreenSharingHostLease()
    let reserved = lease.reserve(first, now: 100)
    let displaced = lease.reserve(second, now: 101)
    let foreignRenewed = lease.renew(second, now: 102)
    let foreignReleased = lease.release(second)
    #expect(reserved)
    #expect(!displaced)
    #expect(!foreignRenewed)
    #expect(!foreignReleased)
    #expect(lease.owner == first)
    #expect(!lease.isExpired(now: 124))
    #expect(lease.isExpired(now: 125))
    let expiredRenewed = lease.renew(first, now: 125)
    let released = lease.release(first)
    let nextReserved = lease.reserve(second, now: 125)
    #expect(!expiredRenewed)
    #expect(released)
    #expect(nextReserved)
  }

  @Test func theSameAppIsTheSameHolderAcrossAttemptsAndOnlyAnOpenTakesOver() throws {
    let first = try owner(key: "a")
    let again = try owner(key: "a")
    let other = try owner(key: "b")
    #expect(first == again && first.viewerId != again.viewerId)
    #expect(again.admission(against: first, intent: .attach) == .replacesOwn)
    #expect(other.admission(against: first, intent: .attach) == .refused)
    #expect(other.admission(against: first, intent: .open) == .takesOver)
  }

  @Test func aRequestWithoutAnAppHasNoOwner() {
    #expect(ScreenSharingHostLease.Owner(request()) == nil)
  }

  @Test func anAppsNameIsShownOnOneLineWithoutControlCharactersAndAtMost64Long() {
    var named = request()
    named.app = .init(key: String(repeating: "a", count: 64), name: "  Alexandru's\r\nMac\u{0}Book\u{2028} Pro\t ")
    #expect(ScreenSharingHostLease.Owner(named)?.name == "Alexandru'sMacBook Pro")
    named.app = .init(key: String(repeating: "a", count: 64), name: String(repeating: "n", count: 70))
    #expect(ScreenSharingHostLease.Owner(named)?.name == String(repeating: "n", count: 64))
    named.app = .init(key: String(repeating: "a", count: 64), name: " \n ")
    #expect(ScreenSharingHostLease.Owner(named)?.name == nil)
  }

  private func owner(key: Character) throws -> ScreenSharingHostLease.Owner {
    var request = request()
    request.app = .init(key: String(repeating: key, count: 64), name: "Viewer")
    return try #require(ScreenSharingHostLease.Owner(request))
  }

  private func request() -> ServerScreenSharingRequest {
    .init(operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
  }
}
