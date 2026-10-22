import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use permissions")
struct ComputerUsePermissionsTests {
  private final class ProbeState: @unchecked Sendable {
    var accessibility = false
    var screenRecording = false
    var fullDiskAccess = false
    var fullDiskAccessAllowed = false
    var accessibilityPrompts = 0
    var screenRecordingPrompts = 0
    var openedPanes: [SystemSettingsPane] = []
  }

  private func probes(_ state: ProbeState) -> ComputerUsePermissionProbes {
    ComputerUsePermissionProbes(
      isAccessibilityGranted: { state.accessibility },
      isScreenRecordingGranted: { state.screenRecording },
      isFullDiskAccessGranted: { state.fullDiskAccess },
      isFullDiskAccessAllowed: { state.fullDiskAccessAllowed },
      promptForAccessibility: { state.accessibilityPrompts += 1 },
      promptForScreenRecording: { state.screenRecordingPrompts += 1 },
      openSettingsPane: { pane in state.openedPanes.append(pane) }
    )
  }

  @Test("Gates launch only for installs that reviewed permissions before and lost them on a new version")
  func gateDecision() {
    #expect(
      !computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: false,
        permissionsReviewedVersion: nil,
        setupSkipped: false,
        reviewInProgress: false,
        currentVersion: "1.2.0",
        allGranted: false
      ))
    #expect(
      !computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: true,
        permissionsReviewedVersion: nil,
        setupSkipped: false,
        reviewInProgress: false,
        currentVersion: "1.2.0",
        allGranted: true
      ))
    #expect(
      !computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: true,
        permissionsReviewedVersion: nil,
        setupSkipped: false,
        reviewInProgress: false,
        currentVersion: "1.2.0",
        allGranted: false
      ))
    #expect(
      computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: true,
        permissionsReviewedVersion: "1.1.0",
        setupSkipped: false,
        reviewInProgress: false,
        currentVersion: "1.2.0",
        allGranted: false
      ))
    #expect(
      !computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: true,
        permissionsReviewedVersion: "1.2.0",
        setupSkipped: false,
        reviewInProgress: false,
        currentVersion: "1.2.0",
        allGranted: false
      ))
    #expect(
      !computerUsePermissionsGateNeeded(
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
    #expect(
      computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: true,
        permissionsReviewedVersion: nil,
        setupSkipped: false,
        reviewInProgress: true,
        currentVersion: "1.2.0",
        allGranted: true
      ))
    #expect(
      computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: true,
        permissionsReviewedVersion: "1.2.0",
        setupSkipped: false,
        reviewInProgress: true,
        currentVersion: "1.2.0",
        allGranted: false
      ))
    #expect(
      !computerUsePermissionsGateNeeded(
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
    #expect(model.screenRecordingGrantedThisRun)

    let preGranted = ComputerUsePermissionsModel(probes: probes(state))
    preGranted.refresh()
    #expect(!preGranted.screenRecordingGrantedThisRun)
  }

  @Test("Full Disk Access tracks live status without gating Computer Use")
  @MainActor
  func fullDiskAccessIsOptional() {
    let state = ProbeState()
    state.accessibility = true
    state.screenRecording = true
    let model = ComputerUsePermissionsModel(probes: probes(state))

    #expect(!model.isFullDiskAccessGranted)
    #expect(model.allGranted)

    model.requestFullDiskAccess()
    #expect(state.openedPanes == [.fullDiskAccess])

    state.fullDiskAccess = true
    model.refresh()
    #expect(model.isFullDiskAccessGranted)

    model.requestFullDiskAccess()
    #expect(state.openedPanes == [.fullDiskAccess])
  }

  @Test("Full Disk Access allowed after launch asks for a restart instead of Set Up")
  @MainActor
  func fullDiskAccessAllowedMidRunNeedsRestart() {
    let state = ProbeState()
    let model = ComputerUsePermissionsModel(probes: probes(state))
    #expect(!model.isFullDiskAccessAllowed)
    #expect(!model.fullDiskAccessNeedsRestart)

    state.fullDiskAccessAllowed = true
    model.refresh()
    #expect(!model.isFullDiskAccessGranted)
    #expect(model.isFullDiskAccessAllowed)
    #expect(model.fullDiskAccessNeedsRestart)

    model.requestFullDiskAccess()
    #expect(state.openedPanes.isEmpty)

    state.fullDiskAccess = true
    let relaunched = ComputerUsePermissionsModel(probes: probes(state))
    #expect(relaunched.isFullDiskAccessGranted)
    #expect(!relaunched.fullDiskAccessNeedsRestart)
  }

  @Test("Full Disk Access probe reports only a successful open as granted")
  func fullDiskAccessProbeReadsFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fda-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let readable = dir.appendingPathComponent("TCC.db").path
    FileManager.default.createFile(atPath: readable, contents: Data())
    #expect(fullDiskAccessProbe(path: readable))

    #expect(!fullDiskAccessProbe(path: dir.appendingPathComponent("missing.db").path))
    let unreadable = dir.appendingPathComponent("locked.db").path
    FileManager.default.createFile(atPath: unreadable, contents: Data(), attributes: [.posixPermissions: 0o000])
    #expect(!fullDiskAccessProbe(path: unreadable))
  }

  @Test("Requests prompt once, then fall back to the System Settings pane")
  @MainActor
  func requestsPromptOnceThenOpenSettings() {
    let state = ProbeState()
    let model = ComputerUsePermissionsModel(probes: probes(state))

    model.requestAccessibility()
    #expect(state.accessibilityPrompts == 1)
    #expect(state.openedPanes.isEmpty)

    model.requestAccessibility()
    #expect(state.accessibilityPrompts == 1)
    #expect(state.openedPanes == [.accessibility])

    model.requestScreenRecording()
    #expect(state.screenRecordingPrompts == 1)
    model.requestScreenRecording()
    #expect(state.screenRecordingPrompts == 1)
    #expect(state.openedPanes == [.accessibility, .screenRecording])

    state.accessibility = true
    model.refresh()
    model.requestAccessibility()
    #expect(state.accessibilityPrompts == 1)
    #expect(state.openedPanes == [.accessibility, .screenRecording])
  }

  @Test("Privacy pane deep links match the System Settings URL scheme")
  func paneDeepLinks() {
    #expect(
      SystemSettingsPane.accessibility.url?.absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    #expect(
      SystemSettingsPane.screenRecording.url?.absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    #expect(
      SystemSettingsPane.fullDiskAccess.url?.absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
  }
}
