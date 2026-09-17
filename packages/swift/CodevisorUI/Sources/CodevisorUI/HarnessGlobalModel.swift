import ACPKit
import CodevisorCore
import Foundation
import Observation

/// Shared state for the harness list and its platform-specific add control.
@MainActor @Observable
public final class HarnessGlobalModel {
  var catalog: [ServerHarness] = []
  var customSpecs: [String: ServerCustomHarnessSpec] = [:]
  var showsPicker = false
  var uninstall: HarnessFleet.Setting?
  var isLoading = true
  var loadFailed = false

  public init() {}

  func add(_ harness: ServerHarness, in environment: AppEnvironment) {
    if let spec = customSpecs[harness.id],
      let data = try? JSONEncoder().encode(spec),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data)
    {
      environment.configSync.set(namespace: "harnesses", key: "custom:\(harness.id)", value: value)
    }
    let setting = HarnessFleet.Setting(
      id: harness.id, name: harness.name,
      symbolName: harness.symbolName, enabled: true, installed: true)
    HarnessFleet.set(setting, in: environment.configSync)
    showsPicker = false
  }

  func loadCatalog(in environment: AppEnvironment) async {
    isLoading = true
    var found: [String: ServerHarness] = [:]
    var loaded = false
    for machine in environment.machines.allMachines {
      let client = environment.machines.client(for: machine.id)
      guard let harnesses = try? await client.listHarnesses() else { continue }
      loaded = true
      for harness in harnesses { found[harness.id] = harness }
      if harnesses.contains(where: { $0.source == "custom" }), let specs = try? await client.listCustomHarnesses() {
        for spec in specs { customSpecs[spec.id] = spec }
      }
    }
    guard !Task.isCancelled else { return }
    catalog = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    loadFailed = !loaded
    isLoading = false
  }
}
