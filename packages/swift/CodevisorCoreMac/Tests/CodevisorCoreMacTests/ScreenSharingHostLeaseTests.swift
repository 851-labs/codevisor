import CodevisorCore
import Foundation
import Testing
@testable import CodevisorCoreMac

struct ScreenSharingHostLeaseTests {
  @Test func replacementMustStillBeAuthorizedAfterAsynchronousTeardownAndDisplayLookup() throws {
    let first = request()
    var lease = ScreenSharingHostLease()
    _ = lease.reserve(.init(first), now: 100)
    #expect(lease.replacementPermit(.init(request()), revision: 7, now: 110) == nil)
    let permit = try #require(lease.replacementPermit(.init(first), revision: 7, now: 110))
    _ = lease.release(.init(first))  // The old peer has been torn down.
    #expect(permit.isValid(revision: 7, now: 124.999))
    #expect(!permit.isValid(revision: 7, now: 125))
    #expect(!permit.isValid(revision: 8, now: 111))  // Host stop while enumeration was suspended.
    #expect(lease.replacementPermit(.init(first), revision: 7, now: 111) == nil)
  }
  @Test func secondViewerCannotDisplaceOrRenewAnotherLease() {
    let first = request()
    let second = request()
    var lease = ScreenSharingHostLease()
    let reserved = lease.reserve(.init(first), now: 100)
    let displaced = lease.reserve(.init(second), now: 101)
    let foreignRenewed = lease.renew(.init(second), now: 102)
    let foreignReleased = lease.release(.init(second))
    #expect(reserved)
    #expect(!displaced)
    #expect(!foreignRenewed)
    #expect(!foreignReleased)
    #expect(lease.owner == .init(first))
    #expect(!lease.isExpired(now: 124))
    #expect(lease.isExpired(now: 125))
    let expiredRenewed = lease.renew(.init(first), now: 125)
    let released = lease.release(.init(first))
    let nextReserved = lease.reserve(.init(second), now: 125)
    #expect(!expiredRenewed)
    #expect(released)
    #expect(nextReserved)
  }

  @Test func heartbeatExtendsOnlyAnUnexpiredMatchingWorkspaceAndPane() {
    let first = request()
    let wrongPane = ServerScreenSharingRequest(
      operation: .heartbeat, workspaceId: first.workspaceId,
      paneId: UUID(), viewerId: first.viewerId)
    var lease = ScreenSharingHostLease()
    let reserved = lease.reserve(.init(first), now: 0)
    let foreignRenewed = lease.renew(.init(wrongPane), now: 5)
    let renewed = lease.renew(.init(first), now: 24)
    #expect(reserved)
    #expect(!foreignRenewed)
    #expect(renewed)
    #expect(!lease.isExpired(now: 48))
    #expect(lease.isExpired(now: 49))
    let released = lease.release(.init(first))
    #expect(released)
    #expect(!lease.isExpired(now: 100))
  }
  private func request() -> ServerScreenSharingRequest {
    .init(operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
  }
}
