import CodevisorClient
import CoreGraphics
import Foundation
import ScreenSharing
import Synchronization
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingHostSessionInputTests {
  private static let center = ScreenSharingPointer(x: 0.5, y: 0.5)

  @Test func viewerInputLandsOnTheSharedDisplayAfterItsResolutionChanges() throws {
    let displays = FakeDisplays([1: CGRect(x: 0, y: 0, width: 1512, height: 982)])
    let session = try Self.session(sharing: 1, on: displays)
    #expect(session.injector.location(Self.center) == CGPoint(x: 756, y: 491))

    displays.set(1, CGRect(x: 0, y: 0, width: 1920, height: 1200))
    #expect(session.injector.location(Self.center) == CGPoint(x: 960, y: 600))

    displays.set(1, CGRect(x: 0, y: 0, width: 1512, height: 945))
    #expect(session.injector.location(Self.center) == CGPoint(x: 756, y: 472.5))
  }

  @Test func viewerInputFollowsTheSharedDisplayToItsNewID() throws {
    let displays = FakeDisplays([
      1: CGRect(x: 0, y: 0, width: 1512, height: 982), 2: CGRect(x: -1440, y: -900, width: 1440, height: 900),
    ])
    let session = try Self.session(sharing: 1, on: displays)

    session.displayID = 2

    #expect(session.injector.location(Self.center) == CGPoint(x: -720, y: -450))
  }

  @Test func viewerInputLandsOnTheVirtualDisplayStandingInForTheSharedOne() throws {
    let displays = FakeDisplays([1: CGRect(x: 0, y: 0, width: 1920, height: 1080)])
    let session = try Self.session(sharing: 1, on: displays)

    session.sharedDisplay.virtualDisplayID = 9
    displays.set(1, .null)
    displays.set(9, CGRect(x: 0, y: 0, width: 1920, height: 1080))

    #expect(session.injector.location(Self.center) == CGPoint(x: 960, y: 540))
  }

  private static func session(
    sharing displayID: CGDirectDisplayID, on displays: FakeDisplays
  ) throws -> ScreenSharingHostSession {
    let request = ServerScreenSharingRequest(operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    let display = ServerScreenSharingDisplay(id: "display", name: "Built-in Display", width: 1512, height: 982)
    return try ScreenSharingHostSession(
      request: request, display: display, displayID: displayID, viewerEndpointId: "viewer",
      encoder: .videoToolbox, displayBounds: displays.bounds)
  }
}

private final class FakeDisplays: Sendable {
  private let rects: Mutex<[CGDirectDisplayID: CGRect]>

  init(_ rects: [CGDirectDisplayID: CGRect]) { self.rects = Mutex(rects) }

  func set(_ id: CGDirectDisplayID, _ rect: CGRect) { rects.withLock { $0[id] = rect } }

  @Sendable func bounds(_ id: CGDirectDisplayID) -> CGRect { rects.withLock { $0[id] ?? .null } }
}
