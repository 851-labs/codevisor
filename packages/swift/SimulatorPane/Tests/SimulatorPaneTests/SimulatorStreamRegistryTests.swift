import CodevisorClient
import CoreGraphics
import CoreVideo
import Foundation
import ScreenSharing
import Testing

@testable import SimulatorPane

@MainActor
@Suite struct SimulatorStreamRegistryTests {
  private final class FakeConnection: SimulatorSharedConnection {
    var phase: SimulatorConnectionPhase = .streaming
    let state: ScreenSharingSimulatorState? = nil
    var source: SimulatorScreenSource?
    let frameSize: CGSize? = nil
    private(set) var sponsors: [UUID]
    private(set) var starts = 0
    private(set) var stops = 0
    init(sponsor: SimulatorStreamSponsor) { sponsors = [sponsor.paneId] }
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func send(_ message: ScreenSharingSimulatorMessage) -> Bool { true }
    func presented(frameSize: CGSize) {}
    func rebind(to sponsor: SimulatorStreamSponsor) { sponsors.append(sponsor.paneId) }
  }

  private final class Made {
    var connections: [FakeConnection] = []
  }

  private let made = Made()
  private let registry: SimulatorStreamRegistry

  init() {
    let made = made
    registry = SimulatorStreamRegistry { _, sponsor in
      let connection = FakeConnection(sponsor: sponsor)
      made.connections.append(connection)
      return connection
    }
  }

  private func pane(machine: String = "studio", udid: String = "iphone") -> SimulatorStreamHandle {
    let sponsor = SimulatorStreamSponsor(
      workspaceId: UUID(), paneId: UUID(), client: CodevisorServerClient(config: .init()), openTunnel: nil)
    return registry.handle(machineId: machine, udid: udid, sponsor: sponsor)
  }

  private static func frame() throws -> ScreenSharingVideoFrame {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
    return ScreenSharingVideoFrame(pixelBuffer: try #require(buffer), timestampNs: 0)
  }

  @Test func panesShowingTheSameSimulatorShareOneStream() {
    let first = pane()
    let second = pane()
    let otherMachine = pane(machine: "laptop")
    for handle in [first, second, otherMachine] { handle.start() }
    #expect(made.connections.count == 2)
    #expect(made.connections.map(\.starts) == [1, 1])
  }

  @Test func theStreamEndsOnlyWhenTheLastPaneStops() {
    let first = pane()
    let second = pane()
    first.start()
    second.start()
    first.stop()
    #expect(made.connections[0].stops == 0)
    second.stop()
    #expect(made.connections[0].stops == 1)
    first.start()
    #expect(made.connections.count == 2)
  }

  @Test func closingTheSponsoringPaneMovesTheStreamToARemainingPane() {
    let sponsor = pane()
    let viewer = pane()
    sponsor.start()
    viewer.start()
    sponsor.stop()
    #expect(made.connections[0].sponsors == [sponsor.sponsor.paneId])
    registry.retire(paneId: viewer.sponsor.paneId)
    #expect(made.connections[0].sponsors == [sponsor.sponsor.paneId])
    registry.retire(paneId: sponsor.sponsor.paneId)
    #expect(made.connections[0].sponsors == [sponsor.sponsor.paneId, viewer.sponsor.paneId])
  }

  @Test func showingAFailedStreamAgainRestartsIt() {
    let first = pane()
    let second = pane()
    first.start()
    made.connections[0].phase = .failed("The simulator shut down.")
    second.start()
    #expect(made.connections.count == 1)
    #expect(made.connections[0].stops == 1 && made.connections[0].starts == 2)
  }

  @Test func everyPaneReceivesFramesAndALatePaneGetsTheCurrentOne() throws {
    let source = ScreenSharingFrameMailbox()
    let first = pane()
    first.start()
    made.connections[0].source = .video(source, ScreenSharingMetrics())
    guard case .video(let firstOutput, _) = first.source else { Issue.record("no video"); return }
    let frame = try Self.frame()
    source.put(frame)
    let late = pane()
    late.start()
    guard case .video(let lateOutput, _) = late.source else { Issue.record("no video"); return }
    #expect(firstOutput !== lateOutput)
    #expect(firstOutput.take()?.pixelBuffer === frame.pixelBuffer)
    #expect(lateOutput.take()?.pixelBuffer === frame.pixelBuffer)
  }
}
