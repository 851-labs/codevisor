import CodevisorClient
import CoreGraphics
import Foundation
import Testing

@testable import CodevisorCoreMac

struct ScreenSharingHostDisplayChoiceTests {
  private let side: ScreenSharingHostDisplayChoice.Display = (
    CGMainDisplayID() &+ 1, .init(id: "side", name: "Side Display", width: 1280, height: 720)
  )
  private let main: ScreenSharingHostDisplayChoice.Display = (
    CGMainDisplayID(), .init(id: "main", name: "Built-in Display", width: 1280, height: 720)
  )
  private let other: ScreenSharingHostDisplayChoice.Display = (
    CGMainDisplayID() &+ 2, .init(id: "other", name: "Other Display", width: 1280, height: 720)
  )

  @Test func anAppGetsTheDisplayItAskedForThenItsLastOneThenTheMainOne() {
    let app = owner(app: .init(key: String(repeating: "a", count: 64), name: "Alexandru's MacBook Pro"))
    var choice = ScreenSharingHostDisplayChoice()
    let all = [side, main, other]

    #expect(choice.display(for: app, asking: "other", among: all)?.description.id == "other")
    #expect(choice.display(for: app, asking: "gone", among: all)?.description.id == "main")
    #expect(choice.display(for: app, asking: nil, among: [side, other])?.description.id == "side")

    choice.remember(other, for: app)
    #expect(choice.display(for: app, asking: "gone", among: all)?.description.id == "other")
    #expect(choice.display(for: app, asking: "side", among: all)?.description.id == "side")
    #expect(choice.display(for: app, asking: nil, among: [side, main])?.description.id == "main")
    #expect(choice.display(for: app, asking: nil, among: []) == nil)
  }

  @Test func aStableViewerOnlyGetsTheDisplayItAskedFor() {
    var choice = ScreenSharingHostDisplayChoice()
    let stable = owner(app: nil)
    choice.remember(main, for: stable)

    #expect(choice.display(for: stable, asking: "side", among: [side, main])?.description.id == "side")
    #expect(choice.display(for: stable, asking: "gone", among: [side, main]) == nil)
    #expect(choice.display(for: stable, asking: nil, among: [side, main]) == nil)
  }

  private func owner(app: ServerScreenSharingApp?) -> ScreenSharingHostLease.Owner {
    var request = ServerScreenSharingRequest(operation: .start, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    request.app = app
    return .init(request)
  }
}
