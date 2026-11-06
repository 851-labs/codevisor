import CodevisorCore
import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class BotMascotStage {
  private enum Attempt {
    case dressed
    case retry
    case stop
  }

  private static let settleSeconds = 3.0
  private static let frame = 1.0 / 60
  private static let longestStep = 0.25

  private(set) var isReady = false

  @ObservationIgnored private var motion: BotMascotMotion?
  @ObservationIgnored private var pacer = BotMascotMotionPacer()
  @ObservationIgnored private var queued: BotMascotMotion?
  @ObservationIgnored private var queuedPlay: Task<Void, Never>?
  @ObservationIgnored private let clock = ContinuousClock()
  @ObservationIgnored private var rig: BotMascotRig?
  @ObservationIgnored private var wanted: ServerBotMascot?
  @ObservationIgnored private var dressedAs: ServerBotMascot?
  @ObservationIgnored private var dressing: Task<Void, Never>?
  @ObservationIgnored private var failures = 0
  @ObservationIgnored private var viewers: [BotMascotViewer] = []
  @ObservationIgnored private var lastTick: CFTimeInterval?
  @ObservationIgnored private var tickerHost: BotMascotCanvasView?
  @ObservationIgnored private var follower = BotMascotGazeFollower()
  @ObservationIgnored private let painter = BotMascotPainter()
  @ObservationIgnored private lazy var ticker = BotMascotTicker { [weak self] in self?.tick(at: $0) }

  func show(_ motion: BotMascotMotion) {
    let wait = pacer.wait(before: motion, at: clock.now)
    guard wait > .zero else { return playNow(motion) }

    queued = motion
    guard queuedPlay == nil else { return }

    queuedPlay = Task { [weak self] in
      guard (try? await Task.sleep(for: wait)) != nil else { return }
      self?.playQueued()
    }
  }

  func dress(as mascot: ServerBotMascot, retrying retry: MachineRetry) {
    wanted = mascot
    guard mascot != dressedAs, dressing == nil else { return }

    dressing = Task { await dressRig(as: mascot, retrying: retry) }
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

  private func playNow(_ motion: BotMascotMotion) {
    queuedPlay?.cancel()
    queuedPlay = nil
    queued = nil
    play(motion)
  }

  private func playQueued() {
    queuedPlay = nil
    guard let queued else { return }

    self.queued = nil
    play(queued)
  }

  private func play(_ motion: BotMascotMotion) {
    pacer.shown(motion, at: clock.now)
    guard motion != self.motion else { return }

    self.motion = motion
    rig?.show(motion)
    guard !motion.followsPointer else { return }

    follower = BotMascotGazeFollower()
    rig?.look(.none)
  }

  private func dressRig(as mascot: ServerBotMascot, retrying retry: MachineRetry) async {
    let attempt = await attemptDressing(as: mascot, retrying: retry)
    dressing = nil
    guard let wanted, shouldDressAgain(as: wanted, after: attempt, of: mascot) else { return }

    dress(as: wanted, retrying: retry)
  }

  private func attemptDressing(as mascot: ServerBotMascot, retrying retry: MachineRetry) async -> Attempt {
    do {
      try await putOn(mascot, serverId: retry.machineId, client: retry.client())
      dressedAs = mascot
      failures = 0
      return .dressed
    } catch {
      dressedAs = nil
      failures += 1
      return await retry.shouldRetry(after: error, failures: failures) ? .retry : .stop
    }
  }

  private func shouldDressAgain(as wanted: ServerBotMascot, after attempt: Attempt, of tried: ServerBotMascot) -> Bool {
    guard wanted != dressedAs else { return false }
    return attempt != .stop || wanted != tried
  }

  private func putOn(_ mascot: ServerBotMascot, serverId: String, client: any CodevisorServerClienting) async throws {
    let values = try await BotMascotRiveFiles.shared.values(for: mascot, client: client)
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
