import CodevisorCore
import Foundation

public struct PluginCatalogSection: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let entries: [ServerPluginCatalogEntry]

  static let ordered: [(source: String, title: String)] = [
    ("first-party", "Codevisor"), ("popular", "Popular"), ("registry", "MCP Registry"),
  ]

  static func sections(
    from entries: [ServerPluginCatalogEntry], searching: Bool, hiding blockedPublishers: Set<String>
  ) -> [PluginCatalogSection] {
    let visible = entries.filter { !blockedPublishers.contains(PluginModerationSubject.publisher(ofCatalogId: $0.id)) }
    return ordered.compactMap { source, title in
      guard searching || source != "registry" else { return nil }
      let matching = visible.filter { ($0.source ?? "first-party") == source }
      return matching.isEmpty ? nil : PluginCatalogSection(id: source, title: title, entries: matching)
    }
  }
}
