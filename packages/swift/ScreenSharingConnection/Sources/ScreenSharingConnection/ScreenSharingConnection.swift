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
  public private(set) var unavailableDisplays: [ServerScreenSharingUnavailableDisplay] = []
  public private(set) var hostNotice: String?
  public private(set) var surfaces: [ScreenSharingSurfaceState] = []
  public private(set) var isEnded = false
  public private(set) var displaySwitch: ScreenSharingDisplaySwitch?
  public var preferredDisplayId: String?
  public let machineId: String
  public let target: String?
  @ObservationIgnored public var onSessionOpened: (@MainActor (any ScreenSharingViewingSession) -> Void)?

  @ObservationIgnored private let machine: ScreenSharingMachine
  @ObservationIgnored private let clock: ScreenSharingConnectionClock
  @ObservationIgnored private let host: ScreenSharingHostRequests
  @ObservationIgnored private let log: ScreenSharingConnectionLog
  @ObservationIgnored private var transitions = ScreenSharingConnectionStateMachine()
  @ObservationIgnored private var attempt: (id: UUID, runner: ScreenSharingAttempt?, task: Task<Void, Never>)?
  @ObservationIgnored private var pendingOpen: (surface: UUID, at: ContinuousClock.Instant)?
  @ObservationIgnored private var unseenTimer: Task<Void, Never>?
  @ObservationIgnored private var liveSince: ContinuousClock.Instant?
  @ObservationIgnored private var pendingSwitch: ScreenSharingReconnectSwitch?
  @ObservationIgnored private var returnTo: String?
  @ObservationIgnored private var reconnectsToSwitch = false

  init(machine: ScreenSharingMachine, clock: ScreenSharingConnectionClock) {
    self.machine = machine
    self.clock = clock
    machineId = machine.id
    target = machine.target
    host = ScreenSharingHostRequests(machine: machine, clock: clock)
    log = ScreenSharingConnectionLog(machineId: machine.id, target: machine.target)
  }

  public func attach(_ kind: ScreenSharingSurfaceKind) -> ScreenSharingSurface {
    let surface = ScreenSharingSurface(id: UUID(), kind: kind, connection: self)
    surfaces.append(ScreenSharingSurfaceState(id: surface.id, kind: kind))
    surfacesChanged()
    return surface
  }

  public func machineCameOnline() { handle(.machineCameOnline) }

  public func targetAppeared() { handle(.targetAppeared) }

  public func systemWoke() { handle(.systemWoke) }

  public func restart() {
    machine.userAsked()
    handle(.restartRequested)
  }

  public func switchDisplay(to displayId: String) {
    guard target == nil, !switchByReconnecting(to: displayId), !switchInSession(to: displayId) else { return }
    guard preferredDisplayId != displayId else { return }

    preferredDisplayId = displayId
    returnTo = nil
  }

  func end() { handle(.ended) }

  private var wantedDisplayId: String? { pendingSwitch?.displayId ?? returnTo ?? preferredDisplayId }

  private var picksByReconnecting: Bool {
    state.isConnecting || state == .reconnecting || (state == .live && reconnectsToSwitch)
  }

  private var isOnScreen: Bool { surfaces.contains(where: \.isOnScreen) }

  private func switchByReconnecting(to displayId: String) -> Bool {
    guard picksByReconnecting else { return false }
    guard (pendingSwitch?.displayId ?? display?.id) != displayId else { return true }

    pendingSwitch = ScreenSharingReconnectSwitch(displayId: displayId, returnTo: pendingSwitch?.returnTo ?? display?.id)
    machine.userAsked()
    handle(.displayPicked)
    displaySwitch = switching(to: displayId, .switching)
    return true
  }

  private func switchInSession(to displayId: String) -> Bool {
    guard state == .live, let runner = attempt?.runner else { return false }
    guard displaySwitch?.phase == .switching || display?.id != displayId else { return false }
    guard runner.switchDisplay(to: displayId) else { return false }

    displaySwitch = switching(to: displayId, .switching)
    return true
  }

  private func switching(to displayId: String, _ phase: ScreenSharingDisplaySwitch.Phase) -> ScreenSharingDisplaySwitch
  {
    let name = displays.first { $0.id == displayId }?.name ?? unavailableDisplays.first { $0.id == displayId }?.name
    return ScreenSharingDisplaySwitch(displayId: displayId, name: name, phase: phase)
  }

  private func problem(of displayId: String) -> String? {
    unavailableDisplays.first { $0.id == displayId }?.problem
  }

  private func settle(_ result: ScreenSharingDisplaySwitch) {
    guard let pending = displaySwitch, pending.displayId == result.displayId, pending.phase == .switching else {
      return
    }

    displaySwitch = pending.with(result.phase)
    if result.phase == .confirmed { preferredDisplayId = result.displayId }
  }

  private func settlePendingSwitch(showing shown: ServerScreenSharingDisplay) {
    returnTo = nil
    guard let pending = pendingSwitch, shown.id != pending.displayId else { return }

    pendingSwitch = nil
    displaySwitch = switching(to: pending.displayId, .unavailable(message: problem(of: pending.displayId)))
  }

  private func confirmPendingSwitch() {
    guard let pending = pendingSwitch, display?.id == pending.displayId else { return }

    pendingSwitch = nil
    displaySwitch = switching(to: pending.displayId, .confirmed)
    preferredDisplayId = pending.displayId
  }

  private func returnFromPendingSwitch() -> Bool {
    guard let pending = pendingSwitch else { return false }

    pendingSwitch = nil
    returnTo = pending.returnTo
    displaySwitch = switching(to: pending.displayId, .unavailable(message: problem(of: pending.displayId)))
    display = displays.first { $0.id == pending.returnTo }
    return true
  }

  private func abandonPendingSwitch() {
    guard let pending = pendingSwitch else { return }

    pendingSwitch = nil
    returnTo = nil
    displaySwitch = switching(to: pending.displayId, .unavailable(message: nil))
  }

  private func confirmLateSwitch(showing display: ServerScreenSharingDisplay) {
    guard let pending = displaySwitch, pending.displayId == display.id, case .unavailable = pending.phase else {
      return
    }

    displaySwitch = pending.with(.confirmed)
    preferredDisplayId = display.id
  }

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
    machine.userAsked()
    handle(.openRequested)
  }

  func retryRequested() {
    machine.userAsked()
    handle(.retryRequested)
  }

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
    let wasUnreachable = state == .failed(.cantReach)
    let wasUnseen = transitions.unseen
    let before = state
    let command = transitions.handle(event, openPending: hasPendingOpen)
    if state != transitions.state { state = transitions.state }
    log.note(event, from: before, to: state, then: command)
    if transitions.unseen == .lingering, wasUnseen != .lingering { log.lingering() }
    if isEnded != transitions.isEnded { isEnded = transitions.isEnded }
    if !wasLive, state == .live { liveSince = clock.now() }
    if state == .live || command?.opens == true { pendingOpen = nil }
    run(command)
    if transitions.unseen != wasUnseen { restartUnseenTimer() }
    if !wasUnreachable, state == .failed(.cantReach), machine.isReady() { handle(.machineStillReady) }
  }

  private func run(_ command: ScreenSharingConnectionStateMachine.Command?) {
    switch command {
    case .start(let intent, let wait, let asksWhyItEnded):
      if asksWhyItEnded { host.sessionDropped() }
      start(.init(intent: intent, wantedDisplayId: wantedDisplay), after: wait)
    case .restart:
      stopOnHost()
      start(.init(intent: .attach, wantedDisplayId: wantedDisplay), after: .zero)
    case .stop:
      stop()
      abandonPendingSwitch()
    case .stopAndTryQuietly(let wait):
      stop()
      start(.init(intent: .attach, wantedDisplayId: wantedDisplay), after: wait)
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
    guard returnFromPendingSwitch(), isOnScreen, end != .dropped(.cantReach) else {
      return handle(.attemptEnded(end))
    }

    handle(.displayPicked)
  }

  private func receive(_ report: ScreenSharingAttempt.Report, from id: UUID) {
    guard attempt?.id == id else { return }

    switch report {
    case .takingLong:
      isTakingLong = true
    case .unavailable(let unavailable):
      if unavailableDisplays != unavailable { unavailableDisplays = unavailable }
    case .switchesDisplayByReconnecting(let reconnects):
      reconnectsToSwitch = reconnects
    case .firstFrameDecoded:
      isTakingLong = false
      handle(.firstFrameDecoded)
      confirmPendingSwitch()
    case .transport(.entered(let stage)):
      handle(.stepEntered(stage))
    case .transport(.opened(let session)):
      self.session = session
      onSessionOpened?(session)
    case .transport(.notice(let notice)):
      if hostNotice != notice { hostNotice = notice }
    case .transport(.sharing(let display, let displays)):
      if let display, self.display != display { self.display = display }
      if self.displays != displays { offer(displays) }
      if let display { settlePendingSwitch(showing: display) }
      if let display { confirmLateSwitch(showing: display) }
    case .transport(.displaySwitch(let result)):
      settle(result)
    }
  }

  private func offer(_ offered: [ServerScreenSharingDisplay]) {
    displays = offered
    let ids = Set(offered.map(\.id))
    guard unavailableDisplays.contains(where: { ids.contains($0.id) }) else { return }

    unavailableDisplays.removeAll { ids.contains($0.id) }
  }

  private var wantedDisplay: @MainActor () -> String? {
    { [weak self] in self?.wantedDisplayId }
  }

  private func stop() {
    cancelAttempt()
    if !unavailableDisplays.isEmpty { unavailableDisplays = [] }
    returnTo = nil
    display = nil
    stopOnHost()
  }

  private func stopOnHost() {
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
    if let pending = displaySwitch, pending.phase == .switching, pending.displayId != pendingSwitch?.displayId {
      displaySwitch = pending.with(.unavailable(message: nil))
    }
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
