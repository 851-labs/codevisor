import Foundation
@testable import CodevisorCoreMac

@MainActor
final class RegistryPane {
  let runner = FakeViewerRunner()
  let share: ScreenSharingViewerRegistry.Share
  let log = ScreenSharingEventLog()
  private var consumer: Task<Void, Never>?

  init(
    _ registry: ScreenSharingViewerRegistry, machine: String = "studio", role: ScreenSharingViewerRole = .tab
  ) {
    share = registry.share(machineId: machine, paneId: UUID(), role: role, runner: runner)
  }

  func show(_ display: String = "display", visible: Bool = true, switching: Bool = false) {
    share.setVisible(visible)
    let stream = share.connect(display, switching: switching)
    consumer = Task { @MainActor [log] in
      for await event in stream { log.append(event) }
      log.finish()
    }
  }

  func leave() async {
    consumer?.cancel()
    await consumer?.value
  }
}
