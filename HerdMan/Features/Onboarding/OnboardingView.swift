import SwiftUI
import HerdManCore
import ACPAgents
import UniformTypeIdentifiers

/// First-launch onboarding, presented as a short paginated flow:
/// 1. Welcome, 2. Choose your harnesses, 3. Open a project folder.
/// Completing the last step opens a new chat in the chosen project.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Called when setup finishes, with the workspace for the chosen folder.
    var onComplete: (Workspace?) -> Void

    enum Step: Int, CaseIterable {
        case welcome, harnesses, project
    }

    init(onComplete: @escaping (Workspace?) -> Void, debugInitialStep: Step = .welcome) {
        self.onComplete = onComplete
        _step = State(initialValue: debugInitialStep)
    }

    @State private var step: Step
    @State private var harnesses: [DiscoveredAgent] = []
    @State private var isDetecting = true
    @State private var importExisting = false
    @State private var projectFolder: URL?
    @State private var showingFolderPicker = false
    @State private var isFinishing = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .frame(maxWidth: 440)
                .padding(.horizontal, 40)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(step)
            Spacer(minLength: 0)
            footer
                .frame(maxWidth: 440)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: step)
        .task {
            harnesses = await environment.agentService.discoverAgents()
            isDetecting = false
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                projectFolder = url
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .harnesses: harnessesStep
        case .project: projectStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to HerdMan")
                .font(.system(size: 38, weight: .bold))
            Text("HerdMan runs your local ACP coding agents in one place. Let's get you set up in a few quick steps.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var harnessesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose your harnesses")
                    .font(.system(size: 28, weight: .bold))
                Text("These are the ACP harnesses we found on your computer. Turn on the ones you'd like to use.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDetecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for installed harnesses…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if harnesses.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No harnesses found").fontWeight(.medium)
                        Text("Install Claude Code, Codex, or another ACP agent, then reopen Settings to detect it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(harnesses.enumerated()), id: \.element.id) { index, harness in
                        harnessToggle(harness)
                        if index < harnesses.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            }

            Toggle(isOn: $importExisting) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import existing chats").fontWeight(.medium)
                    Text("Show sessions you've already created in these harnesses.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func harnessToggle(_ harness: DiscoveredAgent) -> some View {
        Toggle(isOn: Binding(
            get: { environment.settings.isHarnessEnabled(harness.id) },
            set: { environment.settings.setHarness(harness.id, enabled: $0) }
        )) {
            Text(harness.name)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .padding(.vertical, 10)
    }

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Open a project")
                    .font(.system(size: 28, weight: .bold))
                Text("Pick a folder to work in. HerdMan opens a new chat scoped to this project.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                showingFolderPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: projectFolder == nil ? "folder.badge.plus" : "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(projectFolder?.lastPathComponent ?? "Choose a folder…")
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        if let projectFolder {
                            Text(projectFolder.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            pageDots
            Spacer()
            primaryButton
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { dot in
                Circle()
                    .fill(dot == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
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
                }
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isPrimaryDisabled)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .harnesses: return "Continue"
        case .project: return "Finish"
        }
    }

    private var isPrimaryDisabled: Bool {
        if isFinishing { return true }
        switch step {
        case .welcome: return false
        case .harnesses: return isDetecting
        case .project: return projectFolder == nil
        }
    }

    // MARK: - Navigation

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func advance() {
        switch step {
        case .welcome:
            step = .harnesses
        case .harnesses:
            step = .project
        case .project:
            finish()
        }
    }

    private func finish() {
        guard let folder = projectFolder else { return }
        isFinishing = true
        let shouldImport = !harnesses.isEmpty && importExisting
        Task {
            let workspace = await environment.finishOnboarding(
                importExternalSessions: shouldImport,
                projectFolder: folder
            )
            onComplete(workspace)
        }
    }
}

#Preview("Welcome") {
    OnboardingView { _ in }
        .environment(AppEnvironment.preview(hasOnboarded: false))
        .frame(width: 900, height: 700)
}

#Preview("Harnesses") {
    OnboardingView(onComplete: { _ in }, debugInitialStep: .harnesses)
        .environment(AppEnvironment.preview(hasOnboarded: false))
        .frame(width: 900, height: 700)
}

#Preview("Project") {
    OnboardingView(onComplete: { _ in }, debugInitialStep: .project)
        .environment(AppEnvironment.preview(hasOnboarded: false))
        .frame(width: 900, height: 700)
}
