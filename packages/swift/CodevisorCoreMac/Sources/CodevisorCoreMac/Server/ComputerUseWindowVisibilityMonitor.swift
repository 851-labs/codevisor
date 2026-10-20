import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class ComputerUseWindowVisibilityMonitor {
  struct Target: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
  }

  struct Reading: Equatable {
    let visibility: ComputerUseWindowVisibility
    let becameVisible: Bool
  }

  struct Dependencies {
    var isOnScreen: (CGWindowID) -> Bool?
    var appIsHidden: (pid_t) -> Bool
    var isMinimized: (Target) -> Bool
    var isOnAnySpace: (CGWindowID) -> Bool

    static var live: Dependencies {
      Dependencies(
        isOnScreen: computerUseWindowIsOnScreen,
        appIsHidden: { NSRunningApplication(processIdentifier: $0)?.isHidden == true },
        isMinimized: { computerUseWindowIsMinimized(pid: $0.pid, windowID: $0.windowID) },
        isOnAnySpace: computerUseWindowIsOnAnySpace)
    }
  }

  private struct Glance: Equatable {
    let target: Target
    let isOnScreen: Bool?
    let appIsHidden: Bool
  }

  private let dependencies: Dependencies
  private var latest: [String: (glance: Glance, visibility: ComputerUseWindowVisibility)] = [:]

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
  }

  func read(_ targets: [String: Target]) -> [String: Reading] {
    latest = latest.filter { targets[$0.key] != nil }
    var readings: [String: Reading] = [:]
    for (sessionID, target) in targets {
      readings[sessionID] = read(sessionID: sessionID, target: target)
    }
    return readings
  }

  private func read(sessionID: String, target: Target) -> Reading {
    let glance = Glance(
      target: target,
      isOnScreen: dependencies.isOnScreen(target.windowID),
      appIsHidden: dependencies.appIsHidden(target.pid))
    let previous = latest[sessionID]
    let visibility = previous.flatMap { $0.glance == glance ? $0.visibility : nil } ?? classify(glance)
    latest[sessionID] = (glance, visibility)
    let wasHidden = previous.map { $0.visibility != .visible } ?? false
    return Reading(visibility: visibility, becameVisible: wasHidden && visibility == .visible)
  }

  private func classify(_ glance: Glance) -> ComputerUseWindowVisibility {
    .classify(
      isOnScreen: glance.isOnScreen,
      appIsHidden: { glance.appIsHidden },
      isMinimized: { dependencies.isMinimized(glance.target) },
      isOnAnySpace: { dependencies.isOnAnySpace(glance.target.windowID) })
  }
}

private let minimizedReadTimeout: Float = 0.25

func computerUseWindowIsMinimized(pid: pid_t, windowID: CGWindowID) -> Bool {
  let application = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(application, minimizedReadTimeout)
  guard
    let window = elementsAttribute(application, kAXWindowsAttribute)
      .first(where: { computerUseWindowID(for: $0) == windowID })
  else { return false }
  return copyAttribute(window, kAXMinimizedAttribute) as? Bool == true
}
