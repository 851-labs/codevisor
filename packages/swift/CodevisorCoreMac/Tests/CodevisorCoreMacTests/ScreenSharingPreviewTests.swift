import ScreenSharingConnection
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingPreviewTests {
  private func state(
    _ connection: ScreenSharingConnectionState, picture: ScreenSharingSurfaceSnapshot.Picture = .none
  ) -> ScreenSharingViewer.State {
    var state = ScreenSharingViewer.State(machineName: "croissant")
    state.surface.connection = connection
    state.surface.picture = picture
    return state
  }

  @Test(arguments: [ScreenSharingConnectionState.off, .connecting(.reachingHost), .live])
  func previewKeepsConnectingUntilAPictureArrives(connection: ScreenSharingConnectionState) {
    #expect(state(connection).preview == .connecting)
  }

  @Test func previewIsLiveOnceTheConnectionIsLiveAndHasAPicture() {
    let endpoint = ScreenSharingViewerHarness.endpoint()

    #expect(state(.live, picture: .elsewhere(endpoint)).preview == .live(endpoint))
    #expect(state(.live, picture: .here(endpoint)).preview == .live(endpoint))
    #expect(state(.connecting(.waitingForVideo), picture: .elsewhere(endpoint)).preview == .connecting)
    #expect(state(.reconnecting).preview == .reconnecting)
  }

  @Test func previewShowsTheFailureAsASentence() {
    #expect(state(.failed(.noVideo)).preview == .failed("Connected, but croissant sent no picture."))
  }
}
