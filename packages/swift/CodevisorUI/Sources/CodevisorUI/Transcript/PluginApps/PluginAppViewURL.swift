import Foundation

public enum PluginAppViewURL {
  public static func resolve(launchPath: String, base: URL, display: PluginAppDisplay) -> URL? {
    guard isServerRelative(launchPath) else { return nil }

    let origin = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: origin + launchPath) else { return nil }

    let replaced = Set(display.queryItems.map(\.name))
    let kept = (components.queryItems ?? []).filter { !replaced.contains($0.name) }
    components.queryItems = kept + display.queryItems
    return components.url
  }

  private static func isServerRelative(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.hasPrefix("//")
  }
}
