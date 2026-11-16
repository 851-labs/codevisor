import ScreenSharingConnection
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingPreviewTests {
  private func state(
    _ connection: ScreenSharingConnectionState, endpoint: ScreenSharingViewerEndpoint? = nil
  ) -> ScreenSharingViewer.State {
    var state = ScreenSharingViewer.State(machineName: "croissant")
    state.surface.connection = connection
    state.surface.endpoint = endpoint
    return state
  }

  @Test(arguments: [ScreenSharingConnectionState.off, .connecting(.reachingHost), .live])
  func previewKeepsConnectingUntilAPictureArrives(connection: ScreenSharingConnectionState) {
    #expect(state(connection).preview == .connecting)
  }

  @Test func previewIsLiveOnceTheConnectionIsLiveAndHasAPicture() {
    let endpoint = ScreenSharingViewerEndpoint(session: FakeMediaSession(), surface: FakeSurface())
    defer { endpoint.close() }

    #expect(state(.live, endpoint: endpoint).preview == .live(endpoint))
    #expect(state(.connecting(.waitingForVideo), endpoint: endpoint).preview == .connecting)
    #expect(state(.reconnecting).preview == .reconnecting)
  }

  @Test func previewShowsTheFailureAsASentenceWithItsButton() {
    #expect(state(.failed(.noVideo)).preview == .failed("Connected, but croissant sent no picture.", .retry))
    #expect(
      state(.failed(.inUse(by: "Alexandru's iPhone"))).preview == .failed("In use on Alexandru's iPhone.", .viewHere))
    #expect(state(.failed(.stoppedOnHost)).preview == .failed("Sharing was stopped on croissant.", .connect))
    #expect(state(.failed(.updateNeeded)).preview == .failed("Update Codevisor on croissant.", nil))
  }
}
