import CodevisorClient
import Foundation
import OSLog
import ScreenSharing
import ScreenSharingV2

@MainActor
final class ScreenSharingAttempt {
  struct Plan {
    var intent: ScreenSharingStartIntent
    var asksWhyItEnded: Bool
    var preferredDisplayId: String?
    var stopping: Task<Void, Never>?
  }

  enum Report {
    case transport(ScreenSharingTransportEvent)
    case takingLong
    case firstFrameDecoded
  }

  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharingConnection")

  private let machine: ScreenSharingMachine
  private let host: ScreenSharingHostRequests
  private let clock: ScreenSharingConnectionClock
  private let plan: Plan
  private let report: @MainActor (Report) -> Void
  private let frameTap = UUID()
  private var times: ScreenSharingConnectTimes
  private var transport: (any ScreenSharingTransport)?
  private var session: (any ScreenSharingViewingSession)?
  private var decoded: ScreenSharingFrameMailbox?
  private var deadline: ScreenSharingAttemptDeadline?
  private var notice: String?
  private var sawFrame = false
  private var isClosed = false

  init(
    machine: ScreenSharingMachine, host: ScreenSharingHostRequests, clock: ScreenSharingConnectionClock, plan: Plan,
    report: @escaping @MainActor (Report) -> Void
  ) {
    self.machine = machine
    self.host = host
    self.clock = clock
    self.plan = plan
    self.report = report
    times = ScreenSharingConnectTimes(at: clock.now())
  }

  func run() async -> ScreenSharingAttemptEnd? {
    let deadline = ScreenSharingAttemptDeadline(
      clock: clock, isLinkReconnecting: { [host] in host.isLinkReconnecting },
      isHostRestartingCapture: { [weak self] in self?.notice != nil },
      onHint: { [weak self] in self?.hint() })
    self.deadline = deadline
    do {
      let end = try await ScreenSharingRace.value(
        of: { [self] in try await self.work() }, before: { try await deadline.pass() })
      return Task.isCancelled ? nil : end ?? gaveUp()
    } catch {
      return nil
    }
  }

  func close() {
    isClosed = true
    deadline?.meet()
    stopWatchingFrames()
    transport?.close()
    transport = nil
    session = nil
  }

  private func work() async throws -> ScreenSharingAttemptEnd {
    do {
      await plan.stopping?.value
      try checkOpen()
      if plan.asksWhyItEnded, let reason = await host.whyItEnded() { return .refused(reason) }
      try checkOpen()
      let capabilities = try await host.capabilities()
      try checkOpen()
      let transport = try makeTransport(for: capabilities)
      self.transport = transport
      try await transport.open { [weak self] in self?.handle($0) }
      guard let end = await transport.monitor() else { throw CancellationError() }

      return end
    } catch let end as ScreenSharingAttemptEnd {
      return end
    } catch {
      guard !isClosed, !Task.isCancelled, !isTaskCancellation(error) else { throw CancellationError() }

      Self.logger.error("Attempt failed at \(self.times.stage.rawValue, privacy: .public): \(error, privacy: .public)")
      return .dropped(Self.reason(for: error))
    }
  }

  private func checkOpen() throws {
    if isClosed || Task.isCancelled { throw CancellationError() }
  }

  private func makeTransport(for capabilities: ScreenSharingHostReply) throws -> any ScreenSharingTransport {
    let displays = capabilities.base.displays
    report(.transport(.sharing(display: nil, displays: displays)))

    if capabilities.base.provider == "vnc", let makeVNC = machine.makeVNCTransport {
      guard let display = displays.first(where: { $0.id == plan.preferredDisplayId }) ?? displays.first else {
        throw ScreenSharingAttemptEnd.refused(.noDisplay)
      }

      return makeVNC(display.id, capabilities.base.controlLease == true)
    }
    guard capabilities.offersV2 else { throw ScreenSharingAttemptEnd.refused(.updateNeeded) }

    return ScreenSharingMediaSessionTransport(
      host: host, machine: machine, clock: clock,
      plan: .init(capabilities: capabilities, intent: plan.intent, preferredDisplayId: plan.preferredDisplayId))
  }

  private func handle(_ event: ScreenSharingTransportEvent) {
    switch event {
    case .entered(let stage):
      guard !sawFrame, stage != times.stage else { return }

      times.enter(stage, at: clock.now())
    case .opened(let session):
      watchFrames(of: session)
    case .notice(let notice):
      self.notice = notice
    case .sharing:
      break
    }
    report(.transport(event))
  }

  private func watchFrames(of session: any ScreenSharingViewingSession) {
    self.session = session
    let decoded = session.frames.tap(frameTap)
    self.decoded = decoded
    decoded.onFrameAvailable { [weak self] in
      Task { @MainActor in self?.decodedFrame() }
    }
  }

  private func stopWatchingFrames() {
    decoded?.onFrameAvailable(nil)
    decoded = nil
    session?.frames.untap(frameTap)
  }

  private func decodedFrame() {
    guard !sawFrame, session != nil else { return }

    sawFrame = true
    deadline?.meet()
    stopWatchingFrames()
    let summary = times.summary(at: clock.now())
    session?.metrics.label("connectTime", summary)
    Self.logger.notice("First frame decoded in \(summary, privacy: .public)")
    report(.firstFrameDecoded)
  }

  private func hint() {
    guard !sawFrame else { return }

    report(.takingLong)
  }

  private func gaveUp() -> ScreenSharingAttemptEnd {
    let stage = times.stage
    Self.logger.error(
      "Gave up at \(stage.rawValue, privacy: .public) after \(self.times.summary(at: self.clock.now()), privacy: .public)"
    )
    return .dropped(.timedOut(at: stage))
  }

  private static func reason(for error: any Error) -> ScreenSharingFailureReason {
    ServerConnectionLoss.isConnectionLoss(error) ? .cantReach : .unclassified(message: serverErrorMessage(error))
  }
}
