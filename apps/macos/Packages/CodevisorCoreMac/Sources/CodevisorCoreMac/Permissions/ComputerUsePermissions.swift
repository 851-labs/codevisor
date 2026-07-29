import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

/// The System Settings privacy panes Codevisor's Computer Use permissions
/// live in. These are the same deep links the ChatGPT desktop app uses.
public enum SystemSettingsPane: String, Sendable {
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    public var url: URL? { URL(string: rawValue) }
}

/// Injectable TCC probes so views and tests never hard-bind to the real
/// (per-bundle, once-ever-prompting) system APIs.
public struct ComputerUsePermissionProbes: Sendable {
    public var isAccessibilityGranted: @Sendable () -> Bool
    public var isScreenRecordingGranted: @Sendable () -> Bool
    /// Shows the one-time system Accessibility consent dialog (also adds the
    /// app to the Privacy list). No-ops after the first refusal.
    public var promptForAccessibility: @Sendable () -> Void
    /// Shows the one-time system Screen Recording consent dialog. macOS never
    /// re-prompts after a denial, so callers must fall back to the pane.
    public var promptForScreenRecording: @Sendable () -> Void
    public var openSettingsPane: @MainActor @Sendable (SystemSettingsPane) -> Void

    public init(
        isAccessibilityGranted: @escaping @Sendable () -> Bool,
        isScreenRecordingGranted: @escaping @Sendable () -> Bool,
        promptForAccessibility: @escaping @Sendable () -> Void,
        promptForScreenRecording: @escaping @Sendable () -> Void,
        openSettingsPane: @escaping @MainActor @Sendable (SystemSettingsPane) -> Void
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.isScreenRecordingGranted = isScreenRecordingGranted
        self.promptForAccessibility = promptForAccessibility
        self.promptForScreenRecording = promptForScreenRecording
        self.openSettingsPane = openSettingsPane
    }

    /// Real TCC checks. The status probes are the cheap, non-prompting calls
    /// so they are safe to poll.
    public static let live = ComputerUsePermissionProbes(
        isAccessibilityGranted: { AXIsProcessTrusted() },
        isScreenRecordingGranted: { CGPreflightScreenCaptureAccess() },
        promptForAccessibility: {
            _ = AXIsProcessTrustedWithOptions(
                ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            )
        },
        promptForScreenRecording: { _ = CGRequestScreenCaptureAccess() },
        openSettingsPane: { pane in
            guard let url = pane.url else { return }
            NSWorkspace.shared.open(url)
        }
    )

    /// Everything granted; for previews and UI tests.
    public static let granted = ComputerUsePermissionProbes(
        isAccessibilityGranted: { true },
        isScreenRecordingGranted: { true },
        promptForAccessibility: {},
        promptForScreenRecording: {},
        openSettingsPane: { _ in }
    )
}

/// Whether launch should present the permissions dialog to an already-
/// onboarded user. Fresh installs meet the same content as an onboarding step
/// instead, each app version asks at most once, and a user who chose "Set Up
/// Later" is never nagged — they re-enter through the Computer Use toggle in
/// Settings instead.
public func computerUsePermissionsGateNeeded(
    hasCompletedOnboarding: Bool,
    permissionsReviewedVersion: String?,
    setupSkipped: Bool,
    reviewInProgress: Bool,
    currentVersion: String,
    allGranted: Bool
) -> Bool {
    guard hasCompletedOnboarding, !setupSkipped else { return false }
    // Granting Screen Recording restarts the app mid-review. Coming back to a
    // dismissed dialog would strand the user with no confirmation that the
    // thing they just did worked, so an open review outlives the restart and
    // ends only when the user closes it.
    if reviewInProgress { return true }
    if allGranted { return false }
    return permissionsReviewedVersion != currentVersion
}

/// Observable state for the Computer Use permissions UI. Status comes from
/// cheap non-prompting probes, so views can poll it and refresh on window
/// activation for near-instant updates after a System Settings round trip.
@MainActor
@Observable
public final class ComputerUsePermissionsModel {
    public private(set) var isAccessibilityGranted: Bool
    public private(set) var isScreenRecordingGranted: Bool
    /// True when Screen Recording was granted after this process started.
    /// macOS applies that grant to *new* processes, so captures can fail
    /// until relaunch; the UI offers a restart when this is set.
    public private(set) var screenRecordingGrantedThisRun = false

    private let probes: ComputerUsePermissionProbes
    private let screenRecordingGrantedAtStart: Bool
    /// The one-time system dialogs never re-appear after a refusal, so the
    /// second press of either button goes straight to System Settings.
    private var promptedAccessibility = false
    private var promptedScreenRecording = false

    public init(probes: ComputerUsePermissionProbes = .live) {
        self.probes = probes
        let accessibility = probes.isAccessibilityGranted()
        let screenRecording = probes.isScreenRecordingGranted()
        isAccessibilityGranted = accessibility
        isScreenRecordingGranted = screenRecording
        screenRecordingGrantedAtStart = screenRecording
    }

    public var allGranted: Bool {
        isAccessibilityGranted && isScreenRecordingGranted
    }

    public func refresh() {
        isAccessibilityGranted = probes.isAccessibilityGranted()
        isScreenRecordingGranted = probes.isScreenRecordingGranted()
        if isScreenRecordingGranted, !screenRecordingGrantedAtStart {
            screenRecordingGrantedThisRun = true
        }
    }

    /// First press shows the system consent dialog; if the grant does not
    /// arrive shortly (or the dialog was spent on an earlier refusal), the
    /// Privacy pane opens so the user can flip the switch directly.
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
