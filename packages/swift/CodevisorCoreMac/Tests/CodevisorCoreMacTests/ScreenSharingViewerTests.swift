import CodevisorClient
import CodevisorCore
import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import ScreenSharing
import Testing

@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerTests {
  private let display = ScreenSharingViewerFixtures.display
  private let second = ScreenSharingViewerFixtures.second

  @Test(arguments: [ScreenSharingViewer.InteractionMode.view, .control])
  func connectingKeepsTheLatestModeAndRequestsControlOnlyOnceLive(mode: ScreenSharingViewer.InteractionMode) async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      await harness.connect()
      await harness.store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view }
      await harness.store.send(.interactionModeChanged(.control)) { $0.interactionMode = .control }
      if mode == .view { await harness.store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view } }
      let endpoint = await harness.open()
      expectNoDifference(harness.client.messages(to: endpoint.id), [])

      await harness.goLive(expectingRequest: UUID(0))

      expectNoDifference(harness.client.messages(to: endpoint.id), mode == .control ? [.request(id: UUID(0))] : [])
      #expect(harness.store.state.interactionMode == mode)
      await harness.finish()
    }
  }

  @Test func dynamicResolutionReachesTheEndpointAndTheToggleFlipsIt() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      let endpoint = await harness.view(channelAvailable: false)
      await awaitObserved { harness.client.dynamicResolutions.count == 1 }
      #expect(harness.client.dynamicResolutions.map(\.enabled) == [false])
      #expect(harness.client.dynamicResolutions.first?.endpoint == endpoint.id)

      await harness.store.send(.dynamicResolutionToggled) {
        $0.dynamicResolution = true
        $0.dynamicResolutionRevision = 1
      }
      await awaitObserved { harness.client.dynamicResolutions.count == 2 }

      #expect(harness.client.dynamicResolutions.map(\.enabled) == [false, true])
      await harness.finish()
    }
  }

  @Test func controlIsRequestedWhenTheChannelOpensAfterVideoUnlessViewWasChosen() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      let endpoint = await harness.view(channelAvailable: false)
      expectNoDifference(harness.client.messages(to: endpoint.id), [])
      await harness.store.send(.interactionModeChanged(.view)) { $0.interactionMode = .view }
      await harness.store.receive(\.lease.controlReleased) { $0.lease?.wantsControl = false }
      harness.client.emit(.availability(true), to: endpoint.id)
      await harness.store.receive(\.lease.event) { $0.lease?.available = true }
      expectNoDifference(harness.client.messages(to: endpoint.id), [])

      await harness.store.send(.interactionModeChanged(.control)) { $0.interactionMode = .control }
      await harness.store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(0)
        $0.lease?.phase = .requesting
      }

      expectNoDifference(harness.client.messages(to: endpoint.id), [.request(id: UUID(0))])
      await harness.finish()
    }
  }

  @Test(arguments: [true, false])
  func deniedOrRevokedControlKeepsControlSelectedToAskAgain(grantFirst: Bool) async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      let endpoint = await harness.view()
      if grantFirst {
        let lease = await harness.grantControl(to: endpoint)
        expectNoDifference(harness.client.beginInputs.map(\.lease), [lease])
        harness.client.emit(.message(.revoked(lease: lease, reason: "Host ended control")), to: endpoint.id)
        await harness.store.receive(\.lease.event) {
          $0.lease?.wantsControl = false
          $0.lease?.lease = nil
          $0.lease?.phase = .viewing
          $0.lease?.message = "Host ended control"
        }
      } else {
        harness.client.emit(.message(.denied(request: UUID(0), reason: "Host denied control")), to: endpoint.id)
        await harness.store.receive(\.lease.event) {
          $0.lease?.wantsControl = false
          $0.lease?.requestID = nil
          $0.lease?.phase = .viewing
          $0.lease?.message = "Host denied control"
        }
      }
      await harness.store.receive(\.lease.delegate.released)
      expectNoDifference(harness.client.endInputs, [endpoint.id])
      #expect(harness.store.state.interactionMode == .control)

      await harness.store.send(.interactionModeChanged(.control))
      await harness.store.receive(\.lease.controlRequested) {
        $0.lease?.wantsControl = true
        $0.lease?.requestID = UUID(1)
        $0.lease?.phase = .requesting
        $0.lease?.message = nil
      }

      expectNoDifference(harness.client.messages(to: endpoint.id).last, .request(id: UUID(1)))
      await harness.finish()
    }
  }

  @Test(arguments: [ScreenSharingViewer.InteractionMode.view, .control])
  func reconnectingReplacesTheEndpointAndPreservesTheMode(mode: ScreenSharingViewer.InteractionMode) async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      await harness.view(mode)
      await harness.surface {
        $0.connection = .reconnecting
        $0.picture = .none
      } then: {
        $0.lease = nil
      }

      let replacement = await harness.open()
      await harness.goLive(expectingRequest: UUID(1))

      expectNoDifference(
        harness.client.messages(to: replacement.id), mode == .control ? [.request(id: UUID(1))] : [])
      #expect(harness.store.state.interactionMode == mode)
      await harness.finish()
    }
  }

  @Test func losingThePictureToAnotherSurfaceDropsControlAndTakingItBackAsksAgain() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      let endpoint = await harness.view()
      _ = await harness.grantControl(to: endpoint)
      await harness.store.send(.showHereTapped)
      #expect(harness.askedOfTheConnection.isEmpty, "a surface that has the picture has nothing to take")

      await harness.surface {
        $0.picture = .elsewhere(endpoint)
      } then: {
        $0.lease = nil
      }
      await harness.store.send(.showHereTapped)
      await awaitObserved { harness.askedOfTheConnection == ["take picture"] }
      await harness.surface {
        $0.picture = .here(endpoint)
      } then: {
        $0.lease = ControlLease.State(endpoint: endpoint.id)
        $0.picturesTaken = 2
      }

      await harness.store.receive(\.lease.controlRequested) { $0.lease?.wantsControl = true }
      await harness.finish()
    }
  }

  @Test func choosingADisplaySavesItForThePaneAndMovesTheConnection() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      await harness.connect(showing: [display, second])
      await harness.store.send(.displaySelected("unplugged"))

      await harness.store.send(.displaySelected(second.id)) {
        $0.preferences.preferredDisplayId = second.id
        $0.preferencesRevision = 1
      }

      await awaitObserved { harness.askedOfTheConnection == ["switch to second"] }
      #expect(harness.store.state.selectedDisplayId == display.id, "the picker follows the connection")
      await harness.finish()
    }
  }

  @Test(arguments: [true, false])
  func aDisplaySyncedFromAnotherDeviceMovesAShownPaneWithoutEchoingTheWrite(shown: Bool) async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness(preferences: .init(preferredDisplayId: display.id))
      if shown { await harness.connect(showing: [display, second]) }
      let synced = ScreenSharingPanePreferences(preferredDisplayId: second.id)

      await harness.store.send(.preferencesSynced(synced)) { $0.preferences = synced }
      await harness.store.send(.preferencesSynced(synced))
      await harness.finish()

      #expect(harness.askedOfTheConnection == (shown ? ["switch to second"] : []))
      #expect(harness.store.state.preferencesRevision == 0)
    }
  }

  @Test func retryAsksTheConnectionAndAFailureReadsAsASentenceAboutTheMachine() async {
    await withMainSerialExecutor {
      let harness = ScreenSharingViewerHarness()
      await harness.connect()
      await harness.surface { $0.isTakingLong = true }
      #expect(harness.store.state.stillConnectingStep != nil && harness.store.state.failure == nil)
      await harness.surface {
        $0.isTakingLong = false
        $0.connection = .failed(.cantReach)
      }
      #expect(harness.store.state.failure == "Can't reach croissant. Check that it's awake and online.")
      #expect(harness.store.state.stillConnectingStep == nil)

      await harness.store.send(.retryButtonTapped)
      await harness.finish()

      #expect(harness.askedOfTheConnection == ["retry"])
    }
  }
}
