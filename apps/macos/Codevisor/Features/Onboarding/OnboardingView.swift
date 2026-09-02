import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

/// First-launch onboarding, presented as a short paginated flow:
/// 1. Welcome, 2. Choose your harnesses, 3. System permissions,
/// 4. Choose your projects, 5. Choose analytics and crash-report sharing,
/// 6. Optionally sign in to Codevisor Cloud.
/// The project step is a multi-select over suggested folders; completing it
/// adds every selected folder as a project and opens a new chat in the first.
struct OnboardingView: View {
    /// A failed harness enable/disable request, pending display in an alert.
    struct ToggleError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(AppEnvironment.self) var environment
    @Environment(\.theme) var theme

    /// Called when setup finishes, with the project to open a new chat in
    /// (the first of the user's selected folders).
    var onComplete: (Project?) -> Void

    /// Raw values are persisted as mid-flow resume state, so existing cases
    /// must never be reordered — new steps are appended. Flow order matches
    /// raw-value order (Back navigates via `rawValue - 1`), so `account`
    /// lands last, after analytics.
    enum Step: Int, CaseIterable {
        case welcome, harnesses, permissions, project, analytics, account
    }

    /// Where harness detection stands. Distinguishes "the server isn't up
    /// yet / can't be reached" from "reachable, but nothing installed" — the
    /// two used to collapse into a false "No harnesses found".
    enum HarnessDetection: Equatable {
        case connecting
        case unreachable(String)
        case loaded
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

    @State var step: Step
    /// Which way the current step change is travelling, so the slide matches.
    @State var isNavigatingBack = false
    /// The full catalog — installed harnesses get toggles, the rest get
    /// install hints.
    @State var harnesses: [ServerHarness] = []
    @State var detection: HarnessDetection = .connecting
    @State var isRescanning = false
    @State var rescanError: String?
    /// The project step's selection state (suggestions, picks, clones) —
    /// the same model the new-chat empty state uses.
    @State var projectSetup = ProjectSetupModel()
    @State var showingFolderPicker = false
    @State var showingGitClone = false
    @State var isFinishing = false
    @State var showsNotInstalled = false
    @State var authenticationHarness: ServerHarness?
    @State var toggleError: ToggleError?
    /// Sharing is selected initially, but nothing is persisted or sent until
    /// the user continues past the final onboarding step.
    @State var shareAnalytics = true
    @State var shareCrashReports = true
    /// Computer Use permission status; previews auto-grant so the flow is
    /// navigable without touching real TCC state.
    @State var permissions = ComputerUsePermissionsModel(
        probes: AppPreview.isRunning ? .granted : .live
    )

    var installedHarnesses: [ServerHarness] { harnesses.filter(\.isReady) }
    var notInstalledHarnesses: [ServerHarness] { harnesses.filter { !$0.isReady } }

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
            // row flips from Installing… to installed without "Detect again".
            Task { await refreshHarnessList() }
        }
        .onChange(of: harnesses) { previous, current in
            // Continue the user's intent: an install started here that just
            // finished and needs sign-in opens the auth sheet directly.
            guard authenticationHarness == nil, step == .harnesses else { return }
            for harness in current where harness.isReady {
                let before = previous.first { $0.id == harness.id }
                guard before?.lifecycle?.resolvedPhase == .installing, before?.isReady != true,
                    harness.requiresAuthentication
                else { continue }
                authenticationHarness = harness
                break
            }
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
        .sheet(item: $authenticationHarness) { harness in
            HarnessAuthenticationView(harness: harness) { replaceHarness($0) }
        }
        .sheet(isPresented: $showingGitClone) {
            GitCloneSheet(
                client: environment.machines.client(for: CodevisorMachine.local.id),
                machineName: CodevisorMachine.local.name
            ) { project in
                projectSetup.cloneCompleted(project)
            }
        }
        .alert(
            toggleError?.title ?? "",
            isPresented: Binding(
                get: { toggleError != nil },
                set: { if !$0 { toggleError = nil } }
            ),
            presenting: toggleError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.message)
        }
    }

    /// The project step earns extra width for its two-column suggestion grid.
    private var contentMaxWidth: CGFloat {
        step == .project ? 560 : 460
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

#Preview("Harnesses") {
    OnboardingView(initialStep: .harnesses) { _ in }
        .environment(AppEnvironment.preview(hasOnboarded: false))
        .frame(width: 900, height: 700)
}

#Preview("Analytics") {
    OnboardingView(initialStep: .analytics) { _ in }
        .environment(AppEnvironment.preview(hasOnboarded: false))
        .frame(width: 900, height: 700)
}

#Preview("Project") {
    OnboardingView(initialStep: .project) { _ in }
        .environment(AppEnvironment.preview(hasOnboarded: false))
        .frame(width: 900, height: 700)
}

#Preview("Account") {
    OnboardingView(initialStep: .account) { _ in }
        .environment(AppEnvironment.preview(hasOnboarded: false))
        .frame(width: 900, height: 700)
}
