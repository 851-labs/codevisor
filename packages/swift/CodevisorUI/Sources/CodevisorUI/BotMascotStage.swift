import CodevisorCore
import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class BotMascotStage {
  static let settleSeconds = 3.0
  static let frame = 1.0 / 60
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

  func dress(as mascot: ServerBotMascot) {
    wanted = mascot
    guard mascot != dressedAs, dressing == nil else { return }

    dressing = Task { await dressRig(as: mascot) }
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

  private func dressRig(as mascot: ServerBotMascot) async {
    await attemptDressing(as: mascot)
    dressing = nil
    guard let wanted, wanted != dressedAs, wanted != mascot else { return }

    dress(as: wanted)
  }

  private func attemptDressing(as mascot: ServerBotMascot) async {
    do {
      try await putOn(mascot)
      dressedAs = mascot
    } catch {
      dressedAs = nil
      botMascotLog.error("Failed to dress a mascot: \(String(describing: error), privacy: .public)")
    }
  }

  private func putOn(_ mascot: ServerBotMascot) async throws {
    let values = try await BotMascotArtwork.shared.values(for: mascot)
    if let rig { return rig.dress(values) }

    reveal(try await BotMascotRig.make(file: try await BotMascotArtwork.shared.riveFile(), values: values))
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
