import Foundation

public enum PluginRegistryBrowsing {
  public static func filter(
    _ entries: [ServerPluginRegistryEntry],
    query: String
  ) -> [ServerPluginRegistryEntry] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return entries }
    return entries.filter { entry in
      [entry.id, entry.name, entry.description ?? "", entry.repo]
        .contains { $0.lowercased().contains(needle) }
    }
  }

  public static func isInstalled(
    _ entry: ServerPluginRegistryEntry,
    installedIds: Set<String>
  ) -> Bool {
    installedIds.contains(entry.id)
  }

  public static func owner(of entry: ServerPluginRegistryEntry) -> String {
    entry.repo.split(separator: "/").first.map(String.init) ?? entry.repo
  }

  public static func starsText(for entry: ServerPluginRegistryEntry) -> String {
    "\(entry.stars) star\(entry.stars == 1 ? "" : "s")"
  }

  public static func updatedText(for entry: ServerPluginRegistryEntry) -> String? {
    let parser = ISO8601DateFormatter()
    let date =
      parser.date(from: entry.pushedAt)
      ?? {
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: entry.pushedAt)
      }()
    guard let date else { return nil }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
}
