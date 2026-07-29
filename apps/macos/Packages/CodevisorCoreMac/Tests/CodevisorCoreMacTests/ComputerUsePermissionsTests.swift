import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use permissions")
struct ComputerUsePermissionsTests {
    private final class ProbeState: @unchecked Sendable {
        var accessibility = false
        var screenRecording = false
        var accessibilityPrompts = 0
        var screenRecordingPrompts = 0
        var openedPanes: [SystemSettingsPane] = []
    }

    private func probes(_ state: ProbeState) -> ComputerUsePermissionProbes {
        ComputerUsePermissionProbes(
            isAccessibilityGranted: { state.accessibility },
            isScreenRecordingGranted: { state.screenRecording },
            promptForAccessibility: { state.accessibilityPrompts += 1 },
            promptForScreenRecording: { state.screenRecordingPrompts += 1 },
            openSettingsPane: { pane in state.openedPanes.append(pane) }
        )
    }

    @Test("Gates launch only for onboarded installs missing permissions on a new version")
    func gateDecision() {
        // Fresh installs go through onboarding instead.
        #expect(!computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: false,
            permissionsReviewedVersion: nil,
            setupSkipped: false,
            reviewInProgress: false,
            currentVersion: "1.2.0",
            allGranted: false
        ))
        // Everything granted: no gate regardless of history.
        #expect(!computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: nil,
            setupSkipped: false,
            reviewInProgress: false,
            currentVersion: "1.2.0",
            allGranted: true
        ))
        // Updated (or first launch of a gated build) with permissions missing.
        #expect(computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: nil,
            setupSkipped: false,
            reviewInProgress: false,
            currentVersion: "1.2.0",
            allGranted: false
        ))
        #expect(computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: "1.1.0",
            setupSkipped: false,
            reviewInProgress: false,
            currentVersion: "1.2.0",
            allGranted: false
        ))
        // The same version asks at most once, even if permissions were later
        // revoked in System Settings.
        #expect(!computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: "1.2.0",
            setupSkipped: false,
            reviewInProgress: false,
            currentVersion: "1.2.0",
            allGranted: false
        ))
        // "Set Up Later" suppresses the gate on every version; the Settings
        // toggle is the way back in.
        #expect(!computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: "1.1.0",
            setupSkipped: true,
            reviewInProgress: false,
            currentVersion: "1.2.0",
            allGranted: false
        ))
    }

    @Test("Keeps an open review on screen across the Screen Recording restart")
    func gateSurvivesMidReviewRestart() {
        // The user granted Screen Recording and macOS relaunched the app.
        // Everything is granted now, but the review they started has to come
        // back so they can see it worked and close it themselves.
        #expect(computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: nil,
            setupSkipped: false,
            reviewInProgress: true,
            currentVersion: "1.2.0",
            allGranted: true
        ))
        // Even a version already marked reviewed keeps an open review up.
        #expect(computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: "1.2.0",
            setupSkipped: false,
            reviewInProgress: true,
            currentVersion: "1.2.0",
            allGranted: false
        ))
        // Set Up Later still wins: it ends the review outright.
        #expect(!computerUsePermissionsGateNeeded(
            hasCompletedOnboarding: true,
            permissionsReviewedVersion: nil,
            setupSkipped: true,
            reviewInProgress: true,
            currentVersion: "1.2.0",
            allGranted: false
        ))
    }

    @Test("Tracks live grant status and flags a mid-run Screen Recording grant")
    @MainActor
    func modelTracksGrants() {
        let state = ProbeState()
        let model = ComputerUsePermissionsModel(probes: probes(state))

        #expect(!model.isAccessibilityGranted)
        #expect(!model.isScreenRecordingGranted)
        #expect(!model.allGranted)
        #expect(!model.screenRecordingGrantedThisRun)

        state.accessibility = true
        state.screenRecording = true
        model.refresh()

        #expect(model.allGranted)
        // Granted after this process started: captures may need a relaunch.
        #expect(model.screenRecordingGrantedThisRun)

        // Granted before the model existed: no relaunch nudge.
        let preGranted = ComputerUsePermissionsModel(probes: probes(state))
        preGranted.refresh()
        #expect(!preGranted.screenRecordingGrantedThisRun)
    }

    @Test("Requests prompt once, then fall back to the System Settings pane")
    @MainActor
    func requestsPromptOnceThenOpenSettings() {
        let state = ProbeState()
        let model = ComputerUsePermissionsModel(probes: probes(state))

        model.requestAccessibility()
        #expect(state.accessibilityPrompts == 1)
        #expect(state.openedPanes.isEmpty)

        // The one-time system dialog is spent; go straight to the pane.
        model.requestAccessibility()
        #expect(state.accessibilityPrompts == 1)
        #expect(state.openedPanes == [.accessibility])

        model.requestScreenRecording()
        #expect(state.screenRecordingPrompts == 1)
        model.requestScreenRecording()
        #expect(state.screenRecordingPrompts == 1)
        #expect(state.openedPanes == [.accessibility, .screenRecording])

        // Granted permissions never re-prompt or open panes.
        state.accessibility = true
        model.refresh()
        model.requestAccessibility()
        #expect(state.accessibilityPrompts == 1)
        #expect(state.openedPanes == [.accessibility, .screenRecording])
    }

    @Test("Privacy pane deep links match the System Settings URL scheme")
    func paneDeepLinks() {
        #expect(SystemSettingsPane.accessibility.url?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(SystemSettingsPane.screenRecording.url?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
