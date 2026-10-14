import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

extension OnboardingView {
  var footer: some View {
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
    .animation(.snappy(duration: 0.2), value: permissions.allGranted)
    .animation(.snappy(duration: 0.2), value: projectSetup.selectedFolders.isEmpty)
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

  @ViewBuilder
  private var trailingAction: some View {
    if let setUpLater = setUpLaterAction {
      Button("Set Up Later", action: setUpLater)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minWidth: 96)
    } else {
      primaryButton
    }
  }

  private var setUpLaterAction: (() -> Void)? {
    switch step {
    case .permissions where !permissions.allGranted:
      return skipPermissions
    case .project where projectSetup.selectedFolders.isEmpty:
      return { navigate(to: .analytics, back: false) }
    default:
      return nil
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
    case .account: return !environment.cloud.state.isSignedIn
    case .harnesses: return !detection.isSettled
    case .permissions: return !permissions.allGranted
    case .project: return projectSetup.selectedFolders.isEmpty
    case .analytics: return false
    }
  }

  private func navigate(to next: Step, back: Bool) {
    guard next != step else { return }
    isNavigatingBack = back
    environment.settings.setOnboardingStep(next.rawValue)
    DispatchQueue.main.async { step = next }
  }

  private func goBack() {
    guard let previous = step.previous else { return }
    navigate(to: previous, back: true)
  }

  private func skipPermissions() {
    environment.settings.setPermissionsSetupSkipped(true)
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
      navigate(to: .harnesses, back: false)
    case .harnesses:
      navigate(to: .permissions, back: false)
      environment.configCache.seedHarnesses(
        harnesses,
        forServer: CodevisorMachine.local.id
      )
      Task { await environment.warmHarnessCapabilities(for: CodevisorMachine.local.id) }
    case .permissions:
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
    guard !isFinishing else { return }
    isFinishing = true
    Task {
      for project in projectSetup.deselectedClonedProjects {
        environment.projectList.removeProject(project)
      }
      let project = await environment.finishOnboarding(
        projectFolders: projectSetup.selectedFolders,
        serverId: CodevisorMachine.local.id
      )
      onComplete(project)
    }
  }
}
