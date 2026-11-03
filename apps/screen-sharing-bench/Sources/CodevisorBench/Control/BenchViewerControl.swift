import AppKit
import ScreenSharing
import ScreenSharingBench

@MainActor
final class BenchViewerControl {
  private static let heartbeatInterval = Duration.seconds(1)
  private static let pollInterval = Duration.milliseconds(20)

  private let channel: any ScreenSharingMessageChannel<ScreenSharingControlMessage>
  private let surface: ScreenSharingVideoSurface
  private let forwarder: ScreenSharingInputForwarder
  private let request = UUID()
  private let requestedNs = BenchMachClock.nowNs()
  private var log = BenchViewerControlLog()
  private var heartbeat: Task<Void, Never>?
  private let clickProbe = BenchClickProbe()
  private var clickProbeInstalled = false

  static func acquire(
    over channel: any ScreenSharingMessageChannel<ScreenSharingControlMessage>, surface: ScreenSharingVideoSurface,
    timeout: Duration
  ) async throws -> BenchViewerControl {
    let deadline = ContinuousClock.now + timeout
    try await waitUntil(deadline) { channel.isAvailable }
    let control = BenchViewerControl(channel: channel, surface: surface)
    channel.send(.request(id: control.request))
    try await waitUntil(deadline) { control.log.answered }
    if let denial = control.log.denial { throw BenchControlError.denied(denial) }

    return control
  }

  private init(
    channel: any ScreenSharingMessageChannel<ScreenSharingControlMessage>, surface: ScreenSharingVideoSurface
  ) {
    self.channel = channel
    self.surface = surface
    forwarder = ScreenSharingInputForwarder(send: { [weak channel] in channel?.send($0) ?? false })
    channel.onMessage = { [weak self] in self?.receive($0) }
    surface.onInput = { [weak self] in self?.forward($0) }
    surface.onInputReleased = { [weak self] in self?.inputReleased() }
    forwarder.onLost = { [weak self] in self?.log.losses.append($0 ?? "the input sequence ran out") }
  }

  var summary: BenchViewerControlSummary {
    log.summary(
      capturesSystemShortcuts: surface.capturesSystemShortcuts,
      clickProbe: clickProbe.summary(installed: clickProbeInstalled))
  }

  func stop() {
    channel.onMessage = nil
    heartbeat?.cancel()
    clickProbe.stop()
    surface.endInput()
    if let lease = forwarder.lease { channel.send(.release(lease: lease)) }
    forwarder.end()
  }

  private func receive(_ message: ScreenSharingControlMessage) {
    switch message {
    case .grant(let request, let lease) where request == self.request: begin(lease)
    case .denied(let request, let reason) where request == self.request: log.denial = reason
    case .revoked(let lease, let reason) where lease == forwarder.lease: revoked(reason)
    default: break
    }
  }

  private func begin(_ lease: UUID) {
    log.grantedAfterMs = Double(BenchMachClock.nowNs() - requestedNs) / 1_000_000
    forwarder.begin(lease: lease)
    surface.window?.makeFirstResponder(surface)
    if !surface.beginInput() { log.losses.append(surface.inputFailureMessage ?? "input did not begin") }
    clickProbeInstalled = clickProbe.start()
    heartbeat = Task { [weak self] in await self?.beat(lease) }
  }

  private func revoked(_ reason: String) {
    log.losses.append(reason)
    heartbeat?.cancel()
    forwarder.end()
    surface.endInput()
  }

  private func forward(_ event: ScreenSharingInputEvent) {
    log.forwardedEvents += 1
    var stamp = BenchInputStamp(event, ns: BenchMachClock.nowNs(), source: NSApp.currentEvent)
    if stamp.kind == .click {
      stamp.mouseCoalescing = NSEvent.isMouseCoalescingEnabled
      if stamp.down == false { NSEvent.isMouseCoalescingEnabled.toggle() }
    }
    log.forwarded.append(stamp)
    forwarder.forward(event)
  }

  private func inputReleased() {
    log.inputReleases += 1
    log.losses.append("the surface released input: \(surface.inputFailureMessage ?? "focus left the video")")
  }

  private func beat(_ lease: UUID) async {
    while !Task.isCancelled {
      do { try await Task.sleep(for: Self.heartbeatInterval) } catch { return }
      channel.send(.heartbeat(lease: lease))
    }
  }

  private static func waitUntil(_ deadline: ContinuousClock.Instant, _ condition: () -> Bool) async throws {
    while !condition() {
      guard ContinuousClock.now < deadline else { throw BenchControlError.timedOut }

      try await Task.sleep(for: pollInterval)
    }
  }
}

enum BenchControlError: Error, CustomStringConvertible {
  case denied(String)
  case timedOut
  case noInputSurface

  var description: String {
    switch self {
    case .denied(let reason): "the host denied control: \(reason)"
    case .timedOut: "the host never answered the control request"
    case .noInputSurface: "this presentation has no input surface; use --present arrival"
    }
  }
}
