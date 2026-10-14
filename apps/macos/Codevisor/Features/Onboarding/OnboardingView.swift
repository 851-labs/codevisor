import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

struct OnboardingView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.theme) var theme

  var onComplete: (Project?) -> Void

  enum Step: Int, CaseIterable {
    case welcome, harnesses, permissions, project, analytics, account

    static let flow: [Step] = [.welcome, .account, .harnesses, .permissions, .project, .analytics]

    var position: Int { Self.flow.firstIndex(of: self) ?? 0 }
    var next: Step? { Self.flow.indices.contains(position + 1) ? Self.flow[position + 1] : nil }
    var previous: Step? { position > 0 ? Self.flow[position - 1] : nil }
  }

  enum HarnessDetection: Equatable {
    case connecting
    case syncing
    case unreachable(String)
    case loaded

    var isSettled: Bool {
      switch self {
      case .connecting, .syncing: false
      case .unreachable, .loaded: true
      }
    }
  }

  init(
    initialStep: Step = .welcome,
    onComplete: @escaping (Project?) -> Void
  ) {
    self.onComplete = onComplete
    _step = State(initialValue: initialStep)
  }

  static func resumeStep(from settings: AppSettingsModel) -> Step {
    settings.onboardingStep.flatMap(Step.init(rawValue:)) ?? .welcome
  }

  @State var cloudAuthentication = CloudAuthenticationCoordinator()
  @State var isSigningInToCloud = false
  @State var step: Step
  @State var isNavigatingBack = false
  @State var harnesses: [ServerHarness] = []
  @State var detection: HarnessDetection = .connecting
  @State var viewportHeight: CGFloat = 700
  @State var fleetModel = HarnessGlobalModel()
  @State var fleetPresenter = HarnessFleetPresenter()
  @State var projectSetup = ProjectSetupModel()
  @State var showingFolderPicker = false
  @State var showingGitClone = false
  @State var isFinishing = false
  @State var shareAnalytics = true
  @State var shareCrashReports = true
  @State var permissions = ComputerUsePermissionsModel(
    probes: AppPreview.isRunning ? .granted : .live
  )

  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
              .frame(maxWidth: contentMaxWidth)
              .padding(.horizontal, 40)
              .transition(stepTransition)
              .id(step)
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity)
          .frame(minHeight: geometry.size.height)
          .padding(.vertical, 32)
        }
        .scrollIndicators(.hidden)
        .onChange(of: geometry.size.height, initial: true) { _, height in viewportHeight = height }
      }
      footer
        .frame(maxWidth: 560)
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.smooth(duration: 0.3), value: step)
    .task { await detectHarnesses() }
    .onChange(of: environment.harnessCatalogRevision(for: CodevisorMachine.local.id)) { _, _ in
      Task { await refreshHarnessList() }
    }
    .fileImporter(
      isPresented: $showingFolderPicker,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: true
    ) { result in
      if case let .success(urls) = result {
        projectSetup.addPickedFolders(urls)
      }
    }
    .harnessFleetSheets(fleetPresenter)
    .sheet(isPresented: $showingGitClone) {
      GitCloneSheet(
        client: environment.machines.client(for: CodevisorMachine.local.id),
        machineName: CodevisorMachine.local.name
      ) { project in
        projectSetup.cloneCompleted(project)
      }
    }
  }

  private var contentMaxWidth: CGFloat {
    step == .project || step == .harnesses ? 560 : 460
  }

  private var stepTransition: AnyTransition {
    let incoming: Edge = isNavigatingBack ? .leading : .trailing
    let outgoing: Edge = isNavigatingBack ? .trailing : .leading
    return .asymmetric(
      insertion: .move(edge: incoming).combined(with: .opacity),
      removal: .move(edge: outgoing).combined(with: .opacity)
    )
  }

}

#Preview("Welcome") {
  OnboardingView { _ in }
    .environment(AppEnvironment.preview(hasOnboarded: false))
    .frame(width: 900, height: 700)
}

#Preview("Account") {
  OnboardingView(initialStep: .account) { _ in }
    .environment(AppEnvironment.preview(hasOnboarded: false))
    .frame(width: 900, height: 700)
}

#Preview("Harnesses") {
  OnboardingView(initialStep: .harnesses) { _ in }
    .environment(AppEnvironment.preview(hasOnboarded: false))
    .frame(width: 900, height: 700)
}

#Preview("Project") {
  OnboardingView(initialStep: .project) { _ in }
    .environment(AppEnvironment.preview(hasOnboarded: false))
    .frame(width: 900, height: 700)
}

#Preview("Analytics") {
  OnboardingView(initialStep: .analytics) { _ in }
    .environment(AppEnvironment.preview(hasOnboarded: false))
    .frame(width: 900, height: 700)
}
