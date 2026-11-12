import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingPreviewTests {
  @Test(arguments: [ScreenSharingViewer.Phase.idle, .loading, .connecting, .suspended, .elsewhere])
  func previewKeepsConnectingUntilAPictureArrives(phase: ScreenSharingViewer.Phase) {
    var state = ScreenSharingViewer.State()
    state.phase = phase
    #expect(state.preview == .connecting)
  }

  @Test func previewIsLiveOnlyWhileItMirrorsAStream() {
    let endpoint = ScreenSharingViewerEndpoint(session: FakeMediaSession(), surface: FakeSurface())
    defer { endpoint.close() }
    var state = ScreenSharingViewer.State()
    state.phase = .elsewhere
    state.mirror = endpoint
    #expect(state.preview == .live(endpoint))

    state.phase = .reconnecting
    state.mirror = nil
    #expect(state.preview == .reconnecting)
  }

  @Test func previewShowsTheFailureMessage() {
    var state = ScreenSharingViewer.State()
    state.phase = .failed
    state.message = "No displays are available on this Mac."
    #expect(state.preview == .failed("No displays are available on this Mac."))
  }
}
