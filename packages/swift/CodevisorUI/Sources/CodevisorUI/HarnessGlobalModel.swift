import CodevisorCore
import Observation

/// Shared state for the harness list and its platform-specific add control.
@MainActor @Observable
public final class HarnessGlobalModel {
  var showsPicker = false
  var uninstall: HarnessFleet.Setting?

  public init() {}

  func add(_ harness: HarnessFleet.CatalogEntry, in environment: AppEnvironment) {
    let setting = HarnessFleet.Setting(
      id: harness.id, name: harness.name,
      symbolName: harness.symbolName, enabled: true, installed: true)
    HarnessFleet.set(setting, in: environment.configSync)
    showsPicker = false
  }
}
