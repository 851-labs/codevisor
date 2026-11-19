import CodevisorCore
import CodevisorCoreMac
import Foundation

@MainActor
enum DeviceDataDeletion {
  static func relaunchIntoDeletion() {
    do {
      try wipe.schedule()
    } catch {
      ErrorReporter.shared.report(
        .persistenceWriteFailed,
        title: "Couldn't Delete Codevisor Data",
        message: error.localizedDescription
      )
      return
    }
    AppRelauncher.relaunch()
  }

  static var isPending: Bool {
    wipe.isPending
  }

  static func finishIfPending() {
    let wipe = wipe
    guard wipe.isPending else { return }

    wipe.erase()
  }

  private static var wipe: DeviceDataWipe {
    DeviceDataWipe(scope: MacDeviceDataScope.current(preservingDefaults: [SandboxMode.defaultsKey]))
  }
}
