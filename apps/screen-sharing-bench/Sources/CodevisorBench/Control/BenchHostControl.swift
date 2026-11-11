import ApplicationServices
import CoreGraphics
import ScreenSharing
import ScreenSharingBench

@MainActor
final class BenchHostControl {
  private static let deadlineCheck = Duration.milliseconds(250)

  private let control: ScreenSharingHostControl
  private let log = BenchHostControlLog()
  private var watchdog: Task<Void, Never>?

  init(channel: any ScreenSharingMessageChannel<ScreenSharingControlMessage>, displayID: CGDirectDisplayID) {
    let injector = ScreenSharingInputInjector(displayBounds: { CGDisplayBounds(displayID) })
    control = ScreenSharingHostControl(
      availability: { Self.unavailableReason(injector) },
      inject: { [log] event in
        let injectedNs = BenchMachClock.nowNs()
        injector.post(event)
        log.injectedEvents += 1
        log.injected.append(BenchInputStamp(event, ns: injectedNs))
      },
      send: { [log] message in
        log.record(sent: message)
        return channel.send(message)
      })
    channel.onMessage = { [weak self] in self?.receive($0) }
    channel.onAvailabilityChanged = { [weak control] available in
      if !available { control?.revoke("The control channel closed.") }
    }
    watchdog = Task { [weak control] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: Self.deadlineCheck) } catch { return }
        control?.checkDeadline()
      }
    }
  }

  var summary: BenchHostControlSummary {
    log.summary
  }

  func stop() {
    watchdog?.cancel()
    control.revoke("Sharing ended.")
  }

  private func receive(_ message: ScreenSharingControlMessage) {
    if case .request = message { log.requests += 1 }
    control.receive(message)
  }

  private static func unavailableReason(_ injector: ScreenSharingInputInjector) -> String? {
    guard injector.isAvailable else { return "Native input is unavailable on this Mac." }
    guard AXIsProcessTrusted() else { return "CodevisorBench has no Accessibility grant on the host." }

    return nil
  }
}
