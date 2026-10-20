import AppKit
import CoreGraphics
import Foundation

public enum ComputerUseWindowVisibility: String, Equatable, Sendable {
  case visible
  case minimized
  case appHidden
  case otherSpace
  case closed

  public func notice(appName: String) -> String? {
    switch self {
    case .visible: nil
    case .minimized: "Window is minimized"
    case .appHidden: "\(appName) is hidden"
    case .otherSpace: "Window is on another Space"
    case .closed: "Window is closed"
    }
  }

  static func classify(
    isOnScreen: Bool?,
    appIsHidden: () -> Bool,
    isMinimized: () -> Bool,
    isOnAnySpace: () -> Bool
  ) -> Self {
    guard let isOnScreen else { return .closed }
    if isOnScreen { return .visible }
    if appIsHidden() { return .appHidden }
    if isMinimized() { return .minimized }
    if isOnAnySpace() { return .otherSpace }
    return .closed
  }

  static func read(windowID: CGWindowID, pid: pid_t, isMinimized: () -> Bool) -> Self {
    classify(
      isOnScreen: computerUseWindowIsOnScreen(windowID),
      appIsHidden: { NSRunningApplication(processIdentifier: pid)?.isHidden == true },
      isMinimized: isMinimized,
      isOnAnySpace: { computerUseWindowIsOnAnySpace(windowID) })
  }
}

func computerUseWindowIsOnScreen(_ windowID: CGWindowID) -> Bool? {
  guard
    let info = CGWindowListCreateDescriptionFromArray([NSNumber(value: windowID)] as CFArray)
      as? [[String: Any]],
    let window = info.first
  else { return nil }
  return window[kCGWindowIsOnscreen as String] as? Bool == true
}

private let allSpacesMask: Int32 = 7

func computerUseWindowIsOnAnySpace(_ windowID: CGWindowID) -> Bool {
  let windows = [NSNumber(value: windowID)] as CFArray
  guard let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), allSpacesMask, windows) else { return false }
  return (spaces.takeRetainedValue() as? [NSNumber])?.isEmpty == false
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?
