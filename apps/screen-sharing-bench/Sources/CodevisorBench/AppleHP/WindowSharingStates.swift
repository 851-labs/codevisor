import CoreGraphics
import Foundation

enum WindowSharingStates {
  static func of(_ pid: pid_t) -> [Int] {
    windows(of: pid, options: [.optionAll]).compactMap { $0[kCGWindowSharingState as String] as? Int }
  }

  static func coversScreen(_ pid: pid_t, screen: CGRect) -> Bool {
    windows(of: pid, options: [.optionOnScreenOnly, .excludeDesktopElements]).contains { window in
      (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.size
        == screen.size
    }
  }

  private static func windows(of pid: pid_t, options: CGWindowListOption) -> [[String: Any]] {
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }
  }
}
