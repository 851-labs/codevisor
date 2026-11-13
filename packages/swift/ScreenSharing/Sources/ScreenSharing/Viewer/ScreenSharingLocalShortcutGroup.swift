#if os(macOS)
  public enum ScreenSharingLocalShortcutGroup: Hashable, Sendable, CaseIterable {
    case screenshots

    public var shortcutNames: [String] {
      ScreenSharingSymbolicHotKeys.names(for: self, in: ScreenSharingSymbolicHotKeys.current())
    }
  }
#endif
