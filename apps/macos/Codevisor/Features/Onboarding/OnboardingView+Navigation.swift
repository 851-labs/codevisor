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
    case .localNetwork where environment.localNetworkAccess != .requested:
      return skipLocalNetwork
    case .project where projectSetup.selectedFolders.isEmpty:
      return {
        commitProjects()
        navigate(to: .computerUse, back: false)
      }
    case .computerUse where !permissions.allGranted:
      return skipComputerUse
    case .fullDiskAccess where !permissions.isFullDiskAccessGranted:
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
    case .analytics: return "Finish"
    default: return "Continue"
    }
  }

  private var isPrimaryDisabled: Bool {
    if isFinishing { return true }
    switch step {
    case .welcome: return false
    case .account: return !environment.cloud.state.isSignedIn
    case .localNetwork: return environment.localNetworkAccess != .requested
    case .harnesses: return !detection.isSettled
    case .project: return projectSetup.selectedFolders.isEmpty
    case .computerUse: return !permissions.allGranted
    case .fullDiskAccess: return !permissions.isFullDiskAccessGranted
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

  private func skipLocalNetwork() {
    environment.setLocalNetworkAccess(.deferred)
    navigate(to: .harnesses, back: false)
  }

  private func skipComputerUse() {
    environment.settings.setPermissionsSetupSkipped(true)
    Task {
      await McpFleet.disableLocally(
        environment.configSync,
        machines: environment.machines,
        name: "Computer Use"
      )
    }
    navigate(to: .fullDiskAccess, back: false)
  }

  private func commitProjects() {
    for project in projectSetup.deselectedClonedProjects {
      environment.projectList.removeProject(project)
    }
    let selected = Set(projectSetup.selectedFolders.map(\.standardizedFileURL.path))
    let dropped = committedProjects.filter { !selected.contains($0.folderURL.standardizedFileURL.path) }
    for project in dropped {
      environment.projectList.removeProject(project)
    }
    committedProjects.removeAll { dropped.contains($0) }
    let existing = Set(environment.projectList.projects.map(\.id))
    let added = projectSetup.selectedFolders.map {
      environment.projectList.addProject(folderURL: $0, serverId: CodevisorMachine.local.id)
    }
    committedProjects += added.filter { !existing.contains($0.id) && !committedProjects.contains($0) }
    firstProject = added.first
  }

  private func advance() {
    switch step {
    case .welcome:
      navigate(to: .account, back: false)
    case .account:
      navigate(to: .localNetwork, back: false)
    case .localNetwork:
      navigate(to: .harnesses, back: false)
    case .harnesses:
      navigate(to: .project, back: false)
      environment.configCache.seedHarnesses(
        harnesses,
        forServer: CodevisorMachine.local.id
      )
      Task { await environment.warmHarnessCapabilities(for: CodevisorMachine.local.id) }
    case .project:
      commitProjects()
      navigate(to: .computerUse, back: false)
    case .computerUse:
      environment.settings.setPermissionsReviewedVersion(AppUpdateModel.bundleVersion())
      environment.settings.setPermissionsSetupSkipped(false)
      navigate(to: .fullDiskAccess, back: false)
    case .fullDiskAccess:
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
      await environment.finishOnboarding(importExternalSessions: false, serverId: CodevisorMachine.local.id)
      onComplete(firstProject)
    }
  }
}
