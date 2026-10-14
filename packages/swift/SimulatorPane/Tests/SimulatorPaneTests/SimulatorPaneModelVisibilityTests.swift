import CodevisorClient
import CodevisorCore
import CodevisorTestSupport
import CoreGraphics
import Foundation
import ScreenSharing
import Testing

@testable import SimulatorPane

@MainActor
@Suite struct SimulatorPaneModelVisibilityTests {
  private final class FakeConnection: SimulatorConnection {
    let phase: SimulatorConnectionPhase = .streaming
    let state: ScreenSharingSimulatorState? = nil
    let source: SimulatorScreenSource? = nil
    let frameSize: CGSize? = nil
    private let stops: TestSignal
    private(set) var stopped = false
    init(stops: TestSignal) { self.stops = stops }
    func start() {}
    func stop() {
      stopped = true
      stops.signal()
    }
    func send(_ message: ScreenSharingSimulatorMessage) -> Bool { true }
    func presented(frameSize: CGSize) {}
  }

  private final class Connections {
    let starts = TestSignal()
    let stops = TestSignal()
    var made: [FakeConnection] = []
  }

  private struct BootedClient: SimulatorClienting {
    static let device = ServerSimulatorDevice(
      udid: "booted", name: "iPhone", state: "Booted",
      runtime: .init(identifier: "ios", name: "iOS 27.0", platform: "iOS", version: "27.0"),
      deviceType: .init(identifier: "iphone", name: "iPhone", productFamily: "iPhone"))

    func simulators() async throws -> ServerSimulatorList {
      ServerSimulatorList(devices: [Self.device], deviceTypes: [], runtimes: [])
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

  private let clock = TestClock()
  private let connections = Connections()

  private func makeModel() -> SimulatorPaneModel {
    let connections = connections
    return SimulatorPaneModel(
      client: BootedClient(), preferences: SimulatorPanePreferences(udid: BootedClient.device.udid), clock: clock
    ) { _ in
      let connection = FakeConnection(stops: connections.stops)
      connections.made.append(connection)
      connections.starts.signal()
      return connection
    }
  }

  private func streamThenHide(_ model: SimulatorPaneModel) async {
    model.appeared()
    await connections.starts.wait(for: 1)
    model.disappeared()
    await clock.waitForSleep(SimulatorPaneModel.hiddenGrace)
  }

  @Test func showingAgainWithinTheGraceKeepsTheStream() async {
    let model = makeModel()
    await streamThenHide(model)
    clock.advance(by: SimulatorPaneModel.hiddenGrace - .seconds(1))
    model.appeared()
    clock.advance(by: .seconds(1))
    await model.refresh()
    #expect(connections.made.count == 1 && connections.stops.value == 0)
  }

  @Test func stayingHiddenPastTheGraceEndsTheStream() async {
    let model = makeModel()
    await streamThenHide(model)
    clock.advance(by: SimulatorPaneModel.hiddenGrace)
    await connections.stops.wait(for: 1)
    model.appeared()
    await connections.starts.wait(for: 2)
    #expect(connections.made.count == 2 && connections.made[0].stopped && !connections.made[1].stopped)
  }

  @Test func closingWhileHiddenEndsTheStreamAtOnce() async {
    let model = makeModel()
    await streamThenHide(model)
    model.closed()
    #expect(connections.made[0].stopped && clock.pendingCount == 0)
  }
}
