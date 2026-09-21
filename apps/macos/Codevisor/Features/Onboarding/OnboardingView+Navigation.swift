import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

extension OnboardingView {
  // MARK: - Footer

  var footer: some View {
    // Keep the page control on the window's center axis. Putting it in
    // the navigation HStack centers it only in the space left between
    // unequal Back and primary buttons, which visibly shifts it.
    ZStack {
      pageDots

      HStack {
        if step != .welcome {
          Button("Back") { goBack() }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        Spacer()
        trailingAction
      }
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
    // Swap Set Up Later → Continue in place as the last permission lands.
    .animation(.snappy(duration: 0.2), value: permissions.allGranted)
  }

  private var pageDots: some View {
    HStack(spacing: 6) {
      ForEach(Step.flow, id: \.rawValue) { dot in
        Capsule()
          .fill(dot == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
          .frame(width: dot == step ? 18 : 7, height: 7)
      }
    }
    .animation(.smooth(duration: 0.3), value: step)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(step.position + 1) of \(Step.flow.count)")
  }

  /// One button occupies the trailing slot. Until both permissions are
  /// granted the only way forward is to skip, so that action sits there in
  /// a secondary style; granting them promotes Continue back into place.
  @ViewBuilder
  private var trailingAction: some View {
    if step == .permissions, !permissions.allGranted {
      Button("Set Up Later") { skipPermissions() }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minWidth: 96)
    } else {
      primaryButton
    }
  }

  private var primaryButton: some View {
    Button {
      advance()
    } label: {
      Group {
        if isFinishing {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Setting up…")
          }
        } else {
          Text(primaryTitle)
            .contentTransition(.numericText())
        }
      }
      .frame(minWidth: 96)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .keyboardShortcut(.defaultAction)
    .disabled(isPrimaryDisabled)
    .animation(.snappy(duration: 0.2), value: primaryTitle)
  }

  private var primaryTitle: String {
    switch step {
    case .welcome: return "Get Started"
    case .account: return "Continue"
    case .harnesses: return "Continue"
    case .permissions: return "Continue"
    case .project: return "Continue"
    case .analytics: return "Finish"
    }
  }

  private var isPrimaryDisabled: Bool {
    if isFinishing { return true }
    switch step {
    case .welcome: return false
    // Sign-in is required on the Mac: the fleet the next step shows, and
    // the machines the app connects, belong to an account.
    case .account: return !environment.cloud.state.isSignedIn
    case .harnesses: return !detection.isSettled
    case .permissions: return !permissions.allGranted
    case .project: return projectSetup.selectedFolders.isEmpty
    case .analytics: return false
    }
  }

  // MARK: - Navigation

  /// SwiftUI removes the outgoing step with the transition it was last
  /// rendered with, so the direction has to land one render before `step`
  /// changes. Setting both at once would slide the old step out forwards
  /// while the new one came in backwards.
  private func navigate(to next: Step, back: Bool) {
    guard next != step else { return }
    isNavigatingBack = back
    // Granting Screen Recording asks for a relaunch mid-flow; remember
    // the position so the app comes back here rather than at step one.
    environment.settings.setOnboardingStep(next.rawValue)
    DispatchQueue.main.async { step = next }
  }

  private func goBack() {
    guard let previous = step.previous else { return }
    navigate(to: previous, back: true)
  }

  /// "Set Up Later": Computer Use turns off so nothing half-works, and the
  /// Computer Use toggle in Settings re-enters this setup inline.
  private func skipPermissions() {
    environment.settings.setPermissionsSetupSkipped(true)
    // Per-machine truth: skipping permissions disables Computer Use
    // HERE, never across the fleet.
    Task {
      await McpFleet.disableLocally(
        environment.configSync,
        machines: environment.machines,
        name: "Computer Use"
      )
    }
    navigate(to: .project, back: false)
  }

  private func advance() {
    switch step {
    case .welcome:
      navigate(to: .account, back: false)
    case .account:
      // Continue is disabled until signed in; the harness step reads the
      // account's fleet the moment it appears.
      navigate(to: .harnesses, back: false)
    case .harnesses:
      navigate(to: .permissions, back: false)
      // The shared catalog was seeded when the list rendered. The local
      // catalog is already loaded, so make the first new-chat picker
      // available immediately. The capability warm below replaces this
      // provisional seed with model/mode metadata when it finishes.
      environment.configCache.seedHarnesses(
        harnesses,
        forServer: CodevisorMachine.local.id
      )
      // Capability inspection starts agents to discover models/modes and
      // can take a few seconds. Hide that latency behind the permissions
      // and project steps; onboarding never waits on this warm.
      Task { await environment.warmHarnessCapabilities(for: CodevisorMachine.local.id) }
    case .permissions:
      // Both permissions are granted (Continue is disabled otherwise);
      // record it so an update never re-shows the standalone gate for
      // this version.
      environment.settings.setPermissionsReviewedVersion(AppUpdateModel.bundleVersion())
      environment.settings.setPermissionsSetupSkipped(false)
      navigate(to: .project, back: false)
    case .project:
      navigate(to: .analytics, back: false)
    case .analytics:
      environment.setShareAnalytics(shareAnalytics)
      environment.setShareCrashReports(shareCrashReports)
      finish()
    }
  }

  private func finish() {
    // No empty-selection guard here: the project step's Continue already
    // requires a selection, but a mid-flow relaunch resumes PAST that step
    // with a fresh (empty) in-memory projectSetup — finishing must still
    // work then, just without adding projects.
    guard !isFinishing else { return }
    isFinishing = true
    Task {
      // Cloned projects were registered the moment the clone finished;
      // deselecting one before finishing means "don't keep it" (the
      // checkout stays on disk, only the project entry is removed).
      for project in projectSetup.deselectedClonedProjects {
        environment.projectList.removeProject(project)
      }
      // Adds every selected folder as a project; folders that already
      // exist (a kept clone) are reused, not duplicated. Existing agent
      // chats are not imported here (importing stays an explicit action,
      // not an onboarding default). The first selection opens a new chat.
      let project = await environment.finishOnboarding(
        projectFolders: projectSetup.selectedFolders,
        serverId: CodevisorMachine.local.id
      )
      onComplete(project)
    }
  }
}
