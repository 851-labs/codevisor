import Foundation

public extension HarnessFleet {
  struct Setting: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var enabled: Bool
    public var installed: Bool
    public init(id: String, name: String, symbolName: String, enabled: Bool, installed: Bool) {
      self.id = id
      self.name = name
      self.symbolName = symbolName
      self.enabled = enabled
      self.installed = installed
    }
  }

  /// Uninstall directives stay in sync for offline machines, but aren't part of the visible catalog.
  static func settings(_ sync: ConfigSync, includingUninstalled: Bool = false) -> [Setting] {
    _ = sync.revisionsByNamespace["harnesses"]
    return sync.entries(namespace: "harnesses").compactMap { entry in
      guard entry.deleted != true, !entry.key.hasPrefix("custom:"),
        case .object(let fields) = entry.value,
        case .bool(let enabled) = fields["enabled"],
        case .bool(let installed) = fields["installed"],
        installed || (includingUninstalled && fields["uninstall"] == .bool(true))
      else { return nil }
      let name: String = if case .string(let name) = fields["name"] { name } else { entry.key }
      let symbol: String = if case .string(let symbol) = fields["symbolName"] { symbol } else { "terminal" }
      return Setting(id: entry.key, name: name, symbolName: symbol, enabled: enabled, installed: installed)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func pendingChanges(_ sync: ConfigSync, machineKey: String) -> [MachineReadiness] {
    let preferences = Dictionary(uniqueKeysWithValues: settings(sync, includingUninstalled: true).map { ($0.id, $0) })
    return (readiness(sync)[machineKey] ?? []).filter { row in
      if ["blocked", "installing", "uninstalling"].contains(row.state) { return true }
      guard !row.overridden, let wanted = preferences[row.harnessId] else { return false }
      return row.installed != wanted.installed
    }
  }

  static func set(_ setting: Setting, in sync: ConfigSync) {
    sync.set(
      namespace: "harnesses", key: setting.id,
      value: .object([
        "name": .string(setting.name), "symbolName": .string(setting.symbolName),
        "enabled": .bool(setting.enabled), "installed": .bool(setting.installed),
        "uninstall": .bool(!setting.installed),
      ]))
  }

  static func overrideCount(_ sync: ConfigSync, machineKey: String) -> Int {
    readiness(sync)[machineKey]?.filter(\.overridden).count ?? 0
  }
}
