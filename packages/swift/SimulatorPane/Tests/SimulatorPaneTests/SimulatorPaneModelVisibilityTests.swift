import CodevisorClient
import CodevisorCore
import CodevisorTestSupport
import CoreGraphics
import Foundation
import ScreenSharing
import Synchronization
import Testing

@testable import SimulatorPane

@MainActor
@Suite struct SimulatorPaneModelVisibilityTests {
  private final class FakeConnection: SimulatorConnection {
    let phase: SimulatorConnectionPhase = .streaming
    let state: ScreenSharingSimulatorState? = nil
    let source: SimulatorScreenSource? = nil
    let frameSize: CGSize? = nil
    var isWaitingForTheSimulator = false
    private(set) var visibility: [Bool] = []
    private(set) var isStopped = false
    private(set) var retries = 0
    private(set) var appearances = 0

    func start() {}
    func stop() { isStopped = true }
    func send(_ message: ScreenSharingSimulatorMessage) -> Bool { true }
    func presented(frameSize: CGSize) {}
    func setVisible(_ visible: Bool) { if visibility.last != visible { visibility.append(visible) } }
    func retry() { retries += 1 }
    func simulatorAppeared() { appearances += 1 }
  }

  private final class Client: SimulatorClienting {
    static let udid = "booted"

    private let state = Mutex("Booted")

    func set(state value: String) { state.withLock { $0 = value } }

    func simulators() async throws -> ServerSimulatorList {
      let device = ServerSimulatorDevice(
        udid: Self.udid, name: "iPhone", state: state.withLock { $0 },
        runtime: .init(identifier: "ios", name: "iOS 27.0", platform: "iOS", version: "27.0"),
        deviceType: .init(identifier: "iphone", name: "iPhone", productFamily: "iPhone"))
      return ServerSimulatorList(devices: [device], deviceTypes: [], runtimes: [])
    }
    func simulatorDeviceType(identifier: String) async throws -> ServerSimulatorDeviceTypeDetail {
      throw CancellationError()
    }
    func simulatorChrome(identifier: String) async throws -> ServerSimulatorChrome { throw CancellationError() }
    func performSimulatorAction(_ action: ServerSimulatorAction, udid: String) async throws {}
    func createSimulator(name: String, deviceTypeIdentifier: String, runtimeIdentifier: String) async throws -> String {
      ""
    }
    func renameSimulator(udid: String, name: String) async throws {}
    func simulatorSettings(udid: String) async throws -> ServerSimulatorSettings { throw CancellationError() }
    func changeSimulatorSettings(_ change: ServerSimulatorSettingsChange) async throws -> ServerSimulatorSettings {
      throw CancellationError()
    }
    func simulatorScreenshot(udid: String) async throws -> Data { Data() }
  }

  private final class Connections {
    var made: [FakeConnection] = []
  }

  private let client = Client()
  private let connections = Connections()

  private func makeModel() -> SimulatorPaneModel {
    let connections = connections
    return SimulatorPaneModel(client: client, preferences: SimulatorPanePreferences(udid: Client.udid)) { _ in
      let connection = FakeConnection()
      connections.made.append(connection)
      return connection
    }
  }

  private func shownModel() async -> SimulatorPaneModel {
    let model = makeModel()
    await model.refresh()
    model.appeared()
    return model
  }

  @Test func hidingAndShowingAgainKeepsTheStreamAndOnlyReportsWhetherItIsOnScreen() async {
    let model = await shownModel()
    model.disappeared()
    model.appeared()
    await model.refresh()

    #expect(connections.made.count == 1 && !connections.made[0].isStopped)
    #expect(connections.made[0].visibility == [true, false, true])
    model.closed()
  }

  @Test func closingThePaneEndsItsStreamAtOnceShownOrHidden() async {
    let shown = await shownModel()
    shown.closed()
    let hidden = await shownModel()
    hidden.disappeared()
    hidden.closed()

    #expect(connections.made.count == 2 && connections.made.allSatisfy(\.isStopped))
  }

  @Test func aSimulatorThatIsNoLongerBootedEndsItsStreamAndBootingAgainStartsANewOne() async {
    let model = await shownModel()
    client.set(state: "Shutdown")
    await model.refresh()
    #expect(connections.made.count == 1 && connections.made[0].isStopped)

    client.set(state: "Booted")
    await model.refresh()
    #expect(connections.made.count == 2 && !connections.made[1].isStopped)
    model.closed()
  }

  @Test func aSimulatorTheHostIsNotReadyToShowIsAskedForAgainWhenTheListStillHasItBooted() async {
    let model = await shownModel()
    await model.refresh()
    #expect(connections.made[0].appearances == 0)

    connections.made[0].isWaitingForTheSimulator = true
    await model.refresh()

    #expect(connections.made.count == 1 && connections.made[0].appearances >= 1)
    model.closed()
  }

  @Test func reconnectRetriesTheSameStream() async {
    let model = await shownModel()

    model.reconnect()

    #expect(connections.made.count == 1 && connections.made[0].retries == 1 && !connections.made[0].isStopped)
    model.closed()
  }
}
