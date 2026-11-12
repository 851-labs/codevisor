#if os(macOS)
  import CoreFoundation
  import CoreGraphics

  enum ScreenSharingSymbolicHotKeys {
    private static let noKey = 65535

    private enum Screenshot: Int, CaseIterable {
      case screenToFile = 28, screenToClipboard = 29, areaToFile = 30, areaToClipboard = 31
      case options = 184, touchBarToFile = 181, touchBarToClipboard = 182

      var standard: ScreenSharingShortcut {
        switch self {
        case .screenToFile: .init(keyCode: 20, [.maskShift, .maskCommand])
        case .screenToClipboard: .init(keyCode: 20, [.maskControl, .maskShift, .maskCommand])
        case .areaToFile: .init(keyCode: 21, [.maskShift, .maskCommand])
        case .areaToClipboard: .init(keyCode: 21, [.maskControl, .maskShift, .maskCommand])
        case .options: .init(keyCode: 23, [.maskShift, .maskCommand])
        case .touchBarToFile: .init(keyCode: 22, [.maskShift, .maskCommand])
        case .touchBarToClipboard: .init(keyCode: 22, [.maskControl, .maskShift, .maskCommand])
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
        case .screenshots:
          shortcuts.formUnion(
            Screenshot.allCases.compactMap { shortcut(hotKeys?[String($0.rawValue)], or: $0.standard) })
        }
      }
    }

    private static func shortcut(_ entry: Any?, or standard: ScreenSharingShortcut) -> ScreenSharingShortcut? {
      guard let entry = entry as? [String: Any] else { return standard }
      guard entry["enabled"] as? Bool != false else { return nil }
      guard let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int],
        parameters.count >= 3
      else { return standard }
      guard parameters[1] != noKey, let keyCode = UInt16(exactly: parameters[1]),
        let modifiers = UInt64(exactly: parameters[2])
      else { return nil }
      return .init(keyCode: keyCode, modifiers: modifiers)
    }
  }
#endif
