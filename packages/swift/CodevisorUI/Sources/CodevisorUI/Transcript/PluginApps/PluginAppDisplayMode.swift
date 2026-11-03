import Foundation

public enum PluginAppDisplayMode: String, CaseIterable, Hashable, Sendable {
  case inline, fullscreen, pip

  static var hostShowsPip: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }

  static func parse(_ value: Any?) -> PluginAppDisplayMode? {
    (value as? String).flatMap(PluginAppDisplayMode.init(rawValue:))
  }
}
