import CoreGraphics

enum WindowSharingStates {
  static func of(_ pid: pid_t) -> [Int] {
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }
      .compactMap { $0[kCGWindowSharingState as String] as? Int }
  }
}
