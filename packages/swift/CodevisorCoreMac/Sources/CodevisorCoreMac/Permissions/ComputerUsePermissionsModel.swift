import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

public enum SystemSettingsPane: String, Sendable {
  case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
  case fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

  public var url: URL? { URL(string: rawValue) }
}

public struct ComputerUsePermissionProbes: Sendable {
  public var isAccessibilityGranted: @Sendable () -> Bool
  public var isScreenRecordingGranted: @Sendable () -> Bool
  public var isFullDiskAccessGranted: @Sendable () -> Bool
  public var isFullDiskAccessAllowed: @Sendable () -> Bool
  public var promptForAccessibility: @Sendable () -> Void
  public var promptForScreenRecording: @Sendable () -> Void
  public var openSettingsPane: @MainActor @Sendable (SystemSettingsPane) -> Void

  public init(
    isAccessibilityGranted: @escaping @Sendable () -> Bool,
    isScreenRecordingGranted: @escaping @Sendable () -> Bool,
    isFullDiskAccessGranted: @escaping @Sendable () -> Bool,
    isFullDiskAccessAllowed: @escaping @Sendable () -> Bool,
    promptForAccessibility: @escaping @Sendable () -> Void,
    promptForScreenRecording: @escaping @Sendable () -> Void,
    openSettingsPane: @escaping @MainActor @Sendable (SystemSettingsPane) -> Void
  ) {
    self.isAccessibilityGranted = isAccessibilityGranted
    self.isScreenRecordingGranted = isScreenRecordingGranted
    self.isFullDiskAccessGranted = isFullDiskAccessGranted
    self.isFullDiskAccessAllowed = isFullDiskAccessAllowed
    self.promptForAccessibility = promptForAccessibility
    self.promptForScreenRecording = promptForScreenRecording
    self.openSettingsPane = openSettingsPane
  }

  public static let live = ComputerUsePermissionProbes(
    isAccessibilityGranted: { AXIsProcessTrusted() },
    isScreenRecordingGranted: { CGPreflightScreenCaptureAccess() },
    isFullDiskAccessGranted: { fullDiskAccessProbe() },
    isFullDiskAccessAllowed: { TCCPreflight.isAllowed("kTCCServiceSystemPolicyAllFiles") },
    promptForAccessibility: {
      _ = AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      )
    },
    promptForScreenRecording: {
      DispatchQueue.global(qos: .userInitiated).async {
        _ = CGRequestScreenCaptureAccess()
      }
    },
    openSettingsPane: { pane in
      guard let url = pane.url else { return }
      NSWorkspace.shared.open(url)
    }
  )

  public static let granted = ComputerUsePermissionProbes(
    isAccessibilityGranted: { true },
    isScreenRecordingGranted: { true },
    isFullDiskAccessGranted: { true },
    isFullDiskAccessAllowed: { true },
    promptForAccessibility: {},
    promptForScreenRecording: {},
    openSettingsPane: { _ in }
  )
}

let fullDiskAccessProtectedFiles = [
  NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
  "/Library/Application Support/com.apple.TCC/TCC.db",
  NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
  NSHomeDirectory() + "/Library/Messages/chat.db",
]

func fullDiskAccessProbe(paths: [String] = fullDiskAccessProtectedFiles) -> Bool {
  paths.contains(where: canOpen)
}

private func canOpen(_ path: String) -> Bool {
  let fd = open(path, O_RDONLY)
  guard fd >= 0 else { return false }
  close(fd)
  return true
}

@MainActor
@Observable
public final class ComputerUsePermissionsModel {
  public private(set) var isAccessibilityGranted: Bool
  public private(set) var isScreenRecordingGranted: Bool
  public private(set) var isFullDiskAccessGranted = false
  public private(set) var isFullDiskAccessAllowed = false
  public private(set) var screenRecordingGrantedThisRun = false

  private let probes: ComputerUsePermissionProbes
  private let screenRecordingGrantedAtStart: Bool
  private var promptedAccessibility = false
  private var promptedScreenRecording = false

  public init(probes: ComputerUsePermissionProbes = .live) {
    self.probes = probes
    let accessibility = probes.isAccessibilityGranted()
    let screenRecording = probes.isScreenRecordingGranted()
    isAccessibilityGranted = accessibility
    isScreenRecordingGranted = screenRecording
    screenRecordingGrantedAtStart = screenRecording
    refreshFullDiskAccess()
  }

  public var allGranted: Bool {
    isAccessibilityGranted && isScreenRecordingGranted
  }

  public var fullDiskAccessNeedsRestart: Bool {
    isFullDiskAccessAllowed && !isFullDiskAccessGranted
  }

  public func refresh() {
    isAccessibilityGranted = probes.isAccessibilityGranted()
    isScreenRecordingGranted = probes.isScreenRecordingGranted()
    refreshFullDiskAccess()
    if isScreenRecordingGranted, !screenRecordingGrantedAtStart {
      screenRecordingGrantedThisRun = true
    }
  }

  private func refreshFullDiskAccess() {
    isFullDiskAccessGranted = probes.isFullDiskAccessGranted()
    isFullDiskAccessAllowed = isFullDiskAccessGranted || probes.isFullDiskAccessAllowed()
  }

  public func requestAccessibility() {
    guard !isAccessibilityGranted else { return }
    if promptedAccessibility {
      probes.openSettingsPane(.accessibility)
      return
    }
    promptedAccessibility = true
    probes.promptForAccessibility()
    openPaneUnlessGranted(.accessibility) { [weak self] in
      self?.isAccessibilityGranted ?? true
    }
  }

  public func requestScreenRecording() {
    guard !isScreenRecordingGranted else { return }
    if promptedScreenRecording {
      probes.openSettingsPane(.screenRecording)
      return
    }
    promptedScreenRecording = true
    probes.promptForScreenRecording()
    openPaneUnlessGranted(.screenRecording) { [weak self] in
      self?.isScreenRecordingGranted ?? true
    }
  }

  public func requestFullDiskAccess() {
    guard !isFullDiskAccessAllowed else { return }
    probes.openSettingsPane(.fullDiskAccess)
  }

  private func openPaneUnlessGranted(
    _ pane: SystemSettingsPane,
    granted: @escaping @MainActor () -> Bool
  ) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self else { return }
      self.refresh()
      if !granted() {
        self.probes.openSettingsPane(pane)
      }
    }
  }
}
