import Foundation

public struct PluginAppDisplay: Equatable, Sendable {
  public enum Platform: String, Sendable {
    case desktop, mobile
  }

  public var isDark: Bool
  public var platform: Platform
  public var locale: String
  public var mode: PluginAppDisplayMode
  public var hostModes: [PluginAppDisplayMode]

  public init(
    isDark: Bool, platform: Platform, locale: String, mode: PluginAppDisplayMode = .inline,
    hostModes: [PluginAppDisplayMode] = [.inline]
  ) {
    self.isDark = isDark
    self.platform = platform
    self.locale = locale
    self.mode = mode
    self.hostModes = hostModes
  }

  public static var currentPlatform: Platform {
    #if os(iOS)
      .mobile
    #else
      .desktop
    #endif
  }

  public static var currentLocale: String {
    Locale.current.identifier(.bcp47)
  }

  var theme: String { isDark ? "dark" : "light" }

  var queryItems: [URLQueryItem] {
    [
      URLQueryItem(name: "theme", value: theme),
      URLQueryItem(name: "displayMode", value: mode.rawValue),
      URLQueryItem(name: "modes", value: hostModes.map(\.rawValue).joined(separator: ",")),
      URLQueryItem(name: "platform", value: platform.rawValue),
      URLQueryItem(name: "locale", value: locale),
    ]
  }
}
