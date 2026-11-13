#if os(macOS)
  import CoreFoundation
  import CoreGraphics

  enum ScreenSharingSymbolicHotKeys {
    private static let unset = 65535

    private enum Screenshot: Int, CaseIterable {
      case screenToFile = 28, screenToClipboard = 29, areaToFile = 30, areaToClipboard = 31
      case options = 184, touchBarToFile = 181, touchBarToClipboard = 182

      static let named: [Screenshot] = [.screenToFile, .areaToFile, .options]

      var standard: ScreenSharingNamedShortcut {
        switch self {
        case .screenToFile: .init("3", keyCode: 20, [.maskShift, .maskCommand])
        case .screenToClipboard: .init("3", keyCode: 20, [.maskControl, .maskShift, .maskCommand])
        case .areaToFile: .init("4", keyCode: 21, [.maskShift, .maskCommand])
        case .areaToClipboard: .init("4", keyCode: 21, [.maskControl, .maskShift, .maskCommand])
        case .options: .init("5", keyCode: 23, [.maskShift, .maskCommand])
        case .touchBarToFile: .init("6", keyCode: 22, [.maskShift, .maskCommand])
        case .touchBarToClipboard: .init("6", keyCode: 22, [.maskControl, .maskShift, .maskCommand])
        }
      }
    }

    static func current() -> [String: Any]? {
      CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        as? [String: Any]
    }

    static func shortcuts(
      for groups: Set<ScreenSharingLocalShortcutGroup>, in hotKeys: [String: Any]?
    ) -> Set<ScreenSharingShortcut> {
      groups.reduce(into: []) { shortcuts, group in
        switch group {
        case .screenshots: shortcuts.formUnion(Screenshot.allCases.map { shortcut(for: $0, in: hotKeys).shortcut })
        }
      }
    }

    static func names(for group: ScreenSharingLocalShortcutGroup, in hotKeys: [String: Any]?) -> [String] {
      switch group {
      case .screenshots:
        Screenshot.named.compactMap { shortcut(for: $0, in: hotKeys).name }.reduce(into: []) { names, name in
          if !names.contains(name) { names.append(name) }
        }
      }
    }

    private static func shortcut(for screenshot: Screenshot, in hotKeys: [String: Any]?) -> ScreenSharingNamedShortcut {
      stored(hotKeys?[String(screenshot.rawValue)]) ?? screenshot.standard
    }

    private static func stored(_ entry: Any?) -> ScreenSharingNamedShortcut? {
      guard let entry = entry as? [String: Any], let value = entry["value"] as? [String: Any],
        let parameters = value["parameters"] as? [Int], parameters.count >= 3, parameters[1] != unset,
        let keyCode = UInt16(exactly: parameters[1]), let modifiers = UInt64(exactly: parameters[2])
      else { return nil }
      let character = parameters[0] == unset ? nil : UInt32(exactly: parameters[0]).flatMap(Unicode.Scalar.init)
      return .init(character: character.map(Character.init), shortcut: .init(keyCode: keyCode, modifiers: modifiers))
    }
  }
#endif
