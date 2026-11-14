import CodevisorCoreMac

final class ScreenSharingOnScreenReporter {
  private static let hiddenConfirmation: Duration = .milliseconds(150)

  var report: (Bool) -> Void = { _ in }
  private weak var probe: ScreenSharingOnScreenProbe?
  private var reported = false
  private var settling: Task<Void, Never>?

  func follow(_ probe: ScreenSharingOnScreenProbe, report: @escaping (Bool) -> Void) {
    self.probe = probe
    self.report = report
    probe.onChange = { [weak self] _ in self?.settle() }
  }

  private var isOnScreen: Bool { probe?.isOnScreen ?? false }

  private func settle() {
    settling?.cancel()
    settling = Task {
      if !self.isOnScreen { try? await Task.sleep(for: Self.hiddenConfirmation) }
      guard !Task.isCancelled else { return }

      self.deliver()
    }
  }

  private func deliver() {
    let onScreen = isOnScreen
    guard onScreen != reported else { return }

    reported = onScreen
    report(onScreen)
  }
}
