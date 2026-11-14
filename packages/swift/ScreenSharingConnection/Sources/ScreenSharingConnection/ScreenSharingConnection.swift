import CodevisorClient
import Foundation
import Observation
import ScreenSharing
import ScreenSharingV2

@MainActor
@Observable
public final class ScreenSharingConnection {
  public private(set) var state = ScreenSharingConnectionState.off
  public private(set) var isTakingLong = false
  public private(set) var session: (any ScreenSharingViewingSession)?
  public private(set) var display: ServerScreenSharingDisplay?
  public private(set) var displays: [ServerScreenSharingDisplay] = []
  public private(set) var hostNotice: String?
  public private(set) var surfaces: [ScreenSharingSurfaceState] = []
  public private(set) var isEnded = false
  public var preferredDisplayId: String?
  public let machineId: String

  @ObservationIgnored private let machine: ScreenSharingMachine
  @ObservationIgnored private let clock: ScreenSharingConnectionClock
  @ObservationIgnored private let host: ScreenSharingHostRequests
  @ObservationIgnored private var transitions = ScreenSharingConnectionStateMachine()
  @ObservationIgnored private var attempt: (id: UUID, runner: ScreenSharingAttempt?, task: Task<Void, Never>)?
  @ObservationIgnored private var pendingOpen: (surface: UUID, at: ContinuousClock.Instant)?
  @ObservationIgnored private var unseenTimer: Task<Void, Never>?
  @ObservationIgnored private var liveSince: ContinuousClock.Instant?

  init(machine: ScreenSharingMachine, clock: ScreenSharingConnectionClock) {
    self.machine = machine
    self.clock = clock
    machineId = machine.id
    host = ScreenSharingHostRequests(machine: machine, clock: clock)
  }

  public func attach(_ kind: ScreenSharingSurfaceKind) -> ScreenSharingSurface {
    let surface = ScreenSharingSurface(id: UUID(), kind: kind, connection: self)
    surfaces.append(ScreenSharingSurfaceState(id: surface.id, kind: kind))
    surfacesChanged()
    return surface
  }

  public func machineCameOnline() { handle(.machineCameOnline) }

  public func workspaceAppeared() { handle(.workspaceAppeared) }

  public func systemWoke() { handle(.systemWoke) }

  func end() { handle(.ended) }

  func surface(_ id: UUID) -> ScreenSharingSurfaceState? {
    surfaces.first { $0.id == id }
  }

  func setOnScreen(_ onScreen: Bool, for id: UUID) {
    guard let index = surfaces.firstIndex(where: { $0.id == id }), surfaces[index].isOnScreen != onScreen else {
      return
    }

    surfaces[index].isOnScreen = onScreen
    if !onScreen { forgetOpen(by: id) }
    surfacesChanged()
  }

  func setSize(_ size: ScreenSharingSurfaceSize?, for id: UUID) {
    guard let index = surfaces.firstIndex(where: { $0.id == id }), surfaces[index].size != size else { return }

    surfaces[index].size = size
  }

  func detach(_ id: UUID) {
    guard let index = surfaces.firstIndex(where: { $0.id == id }) else { return }

    surfaces.remove(at: index)
    forgetOpen(by: id)
    surfacesChanged()
  }

  func openRequested(by id: UUID) {
    guard surface(id) != nil, state != .live else { return }

    pendingOpen = (id, clock.now())
    handle(.openRequested)
  }

  func retryRequested() { handle(.retryRequested) }

  private func surfacesChanged() {
    handle(.surfacesChanged(attached: !surfaces.isEmpty, visible: surfaces.contains(where: \.isOnScreen)))
  }

  private func forgetOpen(by id: UUID) {
    if pendingOpen?.surface == id { pendingOpen = nil }
  }

  private var hasPendingOpen: Bool {
    guard let pendingOpen, surface(pendingOpen.surface)?.isOnScreen == true else { return false }

    return clock.now() - pendingOpen.at <= ScreenSharingConnectionDeadlines.pendingOpen
  }

  private func handle(_ event: ScreenSharingConnectionStateMachine.Event) {
    if hasStayedLive { _ = transitions.handle(.stayedLive) }
    let wasLive = state == .live
    let wasUnseen = transitions.unseen
    let command = transitions.handle(event, openPending: hasPendingOpen)
    if state != transitions.state { state = transitions.state }
    if isEnded != transitions.isEnded { isEnded = transitions.isEnded }
    if !wasLive, state == .live { liveSince = clock.now() }
    if state == .live || command?.opens == true { pendingOpen = nil }
    run(command)
    if transitions.unseen != wasUnseen { restartUnseenTimer() }
  }

  private func run(_ command: ScreenSharingConnectionStateMachine.Command?) {
    switch command {
    case .start(let intent, let wait, let asksWhyItEnded):
      if asksWhyItEnded { host.sessionDropped() }
      start(.init(intent: intent, preferredDisplayId: preferredDisplayId), after: wait)
    case .stop:
      stop()
    case nil:
      break
    }
  }

  private var hasStayedLive: Bool {
    guard state == .live, let liveSince else { return false }

    return clock.now() - liveSince >= ScreenSharingConnectionDeadlines.stableLive
  }

  private func start(_ plan: ScreenSharingAttempt.Plan, after wait: Duration) {
    cancelAttempt()
    let id = UUID()
    let task = Task { [weak self, clock] in
      if wait > .zero { try? await clock.sleep(wait) }
      guard !Task.isCancelled else { return }

      await self?.run(plan, id: id)
    }
    attempt = (id, nil, task)
  }

  private func run(_ plan: ScreenSharingAttempt.Plan, id: UUID) async {
    guard attempt?.id == id else { return }

    let runner = ScreenSharingAttempt(machine: machine, host: host, clock: clock, plan: plan) { [weak self] in
      self?.receive($0, from: id)
    }
    attempt?.runner = runner
    guard let end = await runner.run(), attempt?.id == id else { return }

    handle(.attemptEnded(end))
  }

  private func receive(_ report: ScreenSharingAttempt.Report, from id: UUID) {
    guard attempt?.id == id else { return }

    switch report {
    case .takingLong:
      isTakingLong = true
    case .firstFrameDecoded:
      isTakingLong = false
      handle(.firstFrameDecoded)
    case .transport(.entered(let stage)):
      handle(.stepEntered(stage))
    case .transport(.opened(let session)):
      self.session = session
    case .transport(.notice(let notice)):
      if hostNotice != notice { hostNotice = notice }
    case .transport(.sharing(let display, let displays)):
      if let display, self.display != display { self.display = display }
      if self.displays != displays { self.displays = displays }
    }
  }

  private func stop() {
    cancelAttempt()
    display = nil
    guard let owner = host.takeStarted() else { return }

    Task { [host] in await host.stop(owner) }
  }

  private func cancelAttempt() {
    attempt?.task.cancel()
    attempt?.runner?.close()
    attempt = nil
    session = nil
    if isTakingLong { isTakingLong = false }
    if hostNotice != nil { hostNotice = nil }
  }

  private func restartUnseenTimer() {
    unseenTimer?.cancel()
    unseenTimer = nil
    guard let unseen = transitions.unseen else { return }

    let lingers = unseen == .lingering
    let wait = lingers ? ScreenSharingConnectionDeadlines.linger : ScreenSharingConnectionDeadlines.unseenDebounce
    unseenTimer = Task { [weak self, clock] in
      guard (try? await clock.sleep(wait)) != nil else { return }

      self?.handle(lingers ? .lingerElapsed : .unseenBrieflyElapsed)
    }
  }
}
