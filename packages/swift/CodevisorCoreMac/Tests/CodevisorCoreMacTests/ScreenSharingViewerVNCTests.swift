import CodevisorClient
import CodevisorCore
import CodevisorScreenSharing
import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import Testing
@testable import CodevisorCoreMac

/// The viewer's VNC target handling: entering a server saves its password
/// and connects, a machine without screen sharing still lists the saved
/// server, and forgetting it removes the password and refreshes.
@MainActor
struct ScreenSharingViewerVNCTests {
  private let display = ScreenSharingViewerFixtures.display

  private static let vncTarget = ScreenSharingVNCTarget(host: "mini.local", port: 5901)
  private static let vncDisplay = ServerScreenSharingDisplay(
    id: "vnc:mini.local:5901", name: "mini.local:5901", width: 0, height: 0)

  @Test func aVNCServerIsSavedListedAndConnected() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let credentials = FakeVNCCredentials()
      let store = makeStore(backend, credentials: credentials)
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) {
        $0.displays = [self.display]
        $0.preferences.preferredDisplayId = self.display.id
        $0.preferencesRevision = 1
        $0.selectedDisplayId = self.display.id
        $0.phase = .connecting
      }
      await store.send(.vncTargetSubmitted(Self.vncTarget, password: "pw")) {
        $0.preferences.vnc = Self.vncTarget
        $0.preferences.preferredDisplayId = Self.vncDisplay.id
        $0.preferencesRevision = 2
        $0.displays = [self.display, Self.vncDisplay]
        $0.selectedDisplayId = Self.vncDisplay.id
      }
      #expect(await awaitPolled { credentials.saved == ["mini.local:5901=pw"] })
      expectNoDifference(backend.connections, [self.display.id, Self.vncDisplay.id])
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func aMachineWithoutScreenSharingStillOffersTheSavedVNCServer() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      backend.discoveryFailure = "Screen Sharing is unavailable on this Mac."
      let store = makeStore(
        backend, preferences: .init(preferredDisplayId: Self.vncDisplay.id, vnc: Self.vncTarget))
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.failure) {
        $0.displays = [Self.vncDisplay]
        $0.selectedDisplayId = Self.vncDisplay.id
        $0.phase = .connecting
      }
      expectNoDifference(backend.connections, [Self.vncDisplay.id])
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  @Test func forgettingTheVNCServerRemovesItsPasswordAndRefreshes() async {
    await withMainSerialExecutor {
      let backend = FakeBackend(displays: [display])
      let credentials = FakeVNCCredentials()
      let store = makeStore(
        backend, preferences: .init(preferredDisplayId: Self.vncDisplay.id, vnc: Self.vncTarget),
        credentials: credentials)
      await store.send(.paneAppeared) {
        $0.visible = true
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) {
        $0.displays = [self.display, Self.vncDisplay]
        $0.selectedDisplayId = Self.vncDisplay.id
        $0.phase = .connecting
      }
      await store.send(.vncTargetRemoved) {
        $0.preferences.vnc = nil
        $0.preferences.preferredDisplayId = nil
        $0.preferencesRevision = 1
        $0.phase = .loading
      }
      await store.receive(\.discoveryResponse.success) {
        $0.displays = [self.display]
        $0.preferences.preferredDisplayId = self.display.id
        $0.preferencesRevision = 2
        $0.selectedDisplayId = self.display.id
        $0.phase = .connecting
      }
      #expect(await awaitPolled { credentials.saved == ["mini.local:5901=<removed>"] })
      await store.send(.paneClosed) {
        $0.visible = false
        $0.phase = .suspended
      }
      await store.finish()
    }
  }

  private func makeStore(
    _ backend: FakeBackend, preferences: ScreenSharingPanePreferences = .init(),
    credentials: FakeVNCCredentials = FakeVNCCredentials()
  ) -> TestStoreOf<ScreenSharingViewer> {
    TestStore(initialState: ScreenSharingViewer.State(preferences: preferences)) {
      ScreenSharingViewer()
    } withDependencies: {
      $0[ScreenSharingViewerBackend.self] = backend.value
      $0[ScreenSharingEndpointClient.self] = FakeEndpointClient().value
      $0[ScreenSharingVNCCredentials.self] = credentials.value
      $0.continuousClock = Clocks.TestClock()
      $0.uuid = .incrementing
    }
  }
}

/// Records every save as "account=password" ("<removed>" for a removal).
@MainActor
final class FakeVNCCredentials {
  private(set) var saved: [String] = []
  var value: ScreenSharingVNCCredentials {
    ScreenSharingVNCCredentials(
      password: { _ in nil },
      save: { [self] account, password in
        await MainActor.run { saved.append("\(account)=\(password ?? "<removed>")") }
      })
  }
}
