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

  static func settings(_ sync: ConfigSync, includingUninstalled: Bool = false) -> [Setting] {
    _ = sync.revisionsByNamespace["harnesses"]
    return sync.entries(namespace: "harnesses").compactMap { entry in
      guard entry.deleted != true, !entry.key.hasPrefix("custom:"),
        case .object(let fields) = entry.value,
        case .bool(let enabled) = fields["enabled"],
        case .bool(let installed) = fields["installed"],
        installed || (includingUninstalled && fields["uninstall"] == .bool(true))
      else { return nil }
      let descriptor = HarnessRegistry.descriptor(for: entry.key)
      let name: String =
        if case .string(let name) = fields["name"], !name.isEmpty { name } else { descriptor.displayName }
      let symbol: String =
        if case .string(let symbol) = fields["symbolName"], !symbol.isEmpty { symbol } else { descriptor.symbolName }
      return Setting(id: entry.key, name: name, symbolName: symbol, enabled: enabled, installed: installed)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  @discardableResult
  static func seed(from harnesses: [ServerHarness], in sync: ConfigSync) -> [String] {
    let authored = Set(settings(sync, includingUninstalled: true).map(\.id))
    var added: [String] = []
    for harness in harnesses where harness.isReady && harness.isDesiredEnabled {
      guard !authored.contains(harness.id) else { continue }
      set(
        Setting(
          id: harness.id, name: harness.name, symbolName: harness.symbolName,
          enabled: true, installed: true),
        in: sync)
      added.append(harness.id)
    }
    return added
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
}
