import Foundation

public enum PluginAppDisplayMode: String, CaseIterable, Hashable, Sendable {
  case inline, fullscreen, pip

  static func parse(_ value: Any?) -> PluginAppDisplayMode? {
    (value as? String).flatMap(PluginAppDisplayMode.init(rawValue:))
  }
}
