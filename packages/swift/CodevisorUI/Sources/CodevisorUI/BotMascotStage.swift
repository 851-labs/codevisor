import CodevisorCore
import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class BotMascotStage {
  private static let settleSeconds = 3.0
  private static let frame = 1.0 / 60
  private static let longestStep = 0.25

  private(set) var isReady = false

  @ObservationIgnored private var motion: BotMascotMotion?
  @ObservationIgnored private var rig: BotMascotRig?
  @ObservationIgnored private var wanted: ServerBotMascot?
  @ObservationIgnored private var dressedAs: ServerBotMascot?
  @ObservationIgnored private var dressing: Task<Void, Never>?
  @ObservationIgnored private var viewers: [BotMascotViewer] = []
  @ObservationIgnored private var lastTick: CFTimeInterval?
  @ObservationIgnored private var tickerHost: BotMascotCanvasView?
  @ObservationIgnored private var follower = BotMascotGazeFollower()
  @ObservationIgnored private let painter = BotMascotPainter()
  @ObservationIgnored private lazy var ticker = BotMascotTicker { [weak self] in self?.tick(at: $0) }

  func show(_ motion: BotMascotMotion) {
    guard motion != self.motion else { return }

    self.motion = motion
    rig?.show(motion)
    guard !motion.followsPointer else { return }

    follower = BotMascotGazeFollower()
    rig?.look(.none)
  }

  func dress(as mascot: ServerBotMascot, serverId: String, client: any CodevisorServerClienting) {
    wanted = mascot
    guard mascot != dressedAs, dressing == nil else { return }

    dressing = Task { await dressRig(as: mascot, serverId: serverId, client: client) }
  }

  func attach(_ view: BotMascotCanvasView, pointer: BotMascotPointer) {
    viewers.append(BotMascotViewer(view: view, pointer: pointer))
    view.onWindowChange = { [weak self] in self?.restartTicker() }
    if let rig { paint(rig) }
    restartTicker()
  }

  func detach(_ view: BotMascotCanvasView) {
    view.onWindowChange = nil
    viewers.removeAll { $0.view === view || $0.view == nil }
    restartTicker()
  }

  private func dressRig(as mascot: ServerBotMascot, serverId: String, client: any CodevisorServerClienting) async {
    do {
      let values = try await BotMascotRiveFiles.shared.values(for: mascot, client: client)
      try await putOn(values, serverId: serverId, client: client, mascot: mascot)
      dressedAs = mascot
    } catch {
      dressedAs = nil
    }
    dressing = nil
    if let wanted, wanted != dressedAs { dress(as: wanted, serverId: serverId, client: client) }
  }

  private func putOn(
    _ values: BotMascotRiveValues, serverId: String, client: any CodevisorServerClienting, mascot: ServerBotMascot
  ) async throws {
    if let rig { return rig.dress(values) }

    let file = try await BotMascotRiveFiles.shared.file(serverId: serverId, client: client, mascot: mascot)
    reveal(try await BotMascotRig.make(file: file, values: values))
  }

  private func reveal(_ rig: BotMascotRig) {
    self.rig = rig
    if let motion { rig.show(motion) }
    rig.settle(for: Self.settleSeconds, step: Self.frame)
    paint(rig)
    isReady = true
  }

  private func restartTicker() {
    let host = viewers.lazy.compactMap(\.view).first { $0.window != nil }
    guard host !== tickerHost else { return }

    tickerHost = host
    lastTick = nil
    guard let host else { return ticker.stop() }

    ticker.start(on: host)
  }

  private func tick(at time: CFTimeInterval) {
    let seconds = lastTick.map { min(max(time - $0, 0), Self.longestStep) } ?? 0
    lastTick = time
    guard let rig else { return }

    followPointer(for: seconds, on: rig)
    rig.advance(by: seconds)
    paint(rig)
  }

  private func paint(_ rig: BotMascotRig) {
    painter.paint(rig, into: viewers.compactMap(\.view))
  }

  private func followPointer(for seconds: Double, on rig: BotMascotRig) {
    guard motion?.followsPointer == true else { return }

    let target = viewers.reversed().lazy.compactMap(\.target).first
    rig.look(follower.step(toward: target, seconds: seconds))
  }
}
