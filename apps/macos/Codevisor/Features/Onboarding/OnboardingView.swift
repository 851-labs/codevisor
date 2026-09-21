import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

/// First-launch onboarding, presented as a short paginated flow:
/// 1. Welcome, 2. Sign in with GitHub, 3. Choose your harnesses,
/// 4. System permissions, 5. Choose your projects, 6. Analytics and
/// crash-report sharing.
/// Signing in comes before harnesses on purpose: the harness step shows the
/// account's shared fleet, so a second Mac sees what will sync to it
/// (and what it adds) instead of a list that looks like a first install.
/// The project step is a multi-select over suggested folders; completing it
/// adds every selected folder as a project and opens a new chat in the first.
struct OnboardingView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.theme) var theme

  /// Called when setup finishes, with the project to open a new chat in
  /// (the first of the user's selected folders).
  var onComplete: (Project?) -> Void

  /// Raw values are persisted as mid-flow resume state, so existing cases
  /// must never be reordered or renumbered — new steps are appended. The
  /// order the user walks is `flow`, which is free to change.
  enum Step: Int, CaseIterable {
    case welcome, harnesses, permissions, project, analytics, account

    /// The order steps are shown in.
    static let flow: [Step] = [.welcome, .account, .harnesses, .permissions, .project, .analytics]

    var position: Int { Self.flow.firstIndex(of: self) ?? 0 }
    var next: Step? { Self.flow.indices.contains(position + 1) ? Self.flow[position + 1] : nil }
    var previous: Step? { position > 0 ? Self.flow[position - 1] : nil }
  }

  /// Where the harness step stands. Distinguishes "the server isn't up
  /// yet / can't be reached" from "reachable, but nothing installed" — the
  /// two used to collapse into a false "No harnesses found" — and the
  /// fleet convergence that runs before the list may render.
  enum HarnessDetection: Equatable {
    case connecting
    /// Pulling the account's shared state from its other machines. The
    /// list waits: shown early, a second Mac looks exactly like a first.
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

  /// Where onboarding should open: the step a mid-flow relaunch left off
  /// on, or the beginning.
  static func resumeStep(from settings: AppSettingsModel) -> Step {
    settings.onboardingStep.flatMap(Step.init(rawValue:)) ?? .welcome
  }

  @State var cloudAuthentication = CloudAuthenticationCoordinator()
  @State var isSigningInToCloud = false
  @State var step: Step
  /// Which way the current step change is travelling, so the slide matches.
  @State var isNavigatingBack = false
  /// This Mac's catalog, as its server reports it. Seeds the shared fleet
  /// and the first new-chat picker.
  @State var harnesses: [ServerHarness] = []
  @State var detection: HarnessDetection = .connecting
  /// The page's height, so the harness step can size its own scrolling list.
  @State var viewportHeight: CGFloat = 700
  /// The same list model and sheets Settings › Harnesses uses.
  @State var fleetModel = HarnessGlobalModel()
  @State var fleetPresenter = HarnessFleetPresenter()
  /// The project step's selection state (suggestions, picks, clones) —
  /// the same model the new-chat empty state uses.
  @State var projectSetup = ProjectSetupModel()
  @State var showingFolderPicker = false
  @State var showingGitClone = false
  @State var isFinishing = false
  /// Sharing is selected initially, but nothing is persisted or sent until
  /// the user continues past the final onboarding step.
  @State var shareAnalytics = true
  @State var shareCrashReports = true
  /// Computer Use permission status; previews auto-grant so the flow is
  /// navigable without touching real TCC state.
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
      // Install progress events invalidate the catalog — refetch so the
      // seed and the first new-chat picker see what just landed.
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
    .harnessFleetSheets(fleetPresenter, model: fleetModel)
    .sheet(isPresented: $showingGitClone) {
      GitCloneSheet(
        client: environment.machines.client(for: CodevisorMachine.local.id),
        machineName: CodevisorMachine.local.name
      ) { project in
        projectSetup.cloneCompleted(project)
      }
    }
  }

  /// The project step earns extra width for its two-column suggestion grid;
  /// the harness step for the Settings form it embeds.
  private var contentMaxWidth: CGFloat {
    step == .project || step == .harnesses ? 560 : 460
  }

  /// Steps slide the way the user is travelling: forward pulls the next
  /// step in from the trailing edge, Back pulls the previous one in from
  /// the leading edge.
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
