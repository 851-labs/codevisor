import SwiftUI
import HerdManCore
import ACPAgents
import UniformTypeIdentifiers

/// First-launch onboarding, presented as a short paginated flow:
/// 1. Welcome, 2. Choose your harnesses, 3. Open a project folder.
/// Completing the last step opens a new chat in the chosen project.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    /// Called when setup finishes, with the project for the chosen folder.
    var onComplete: (Project?) -> Void

    enum Step: Int, CaseIterable {
        case welcome, harnesses, project
    }

    init(onComplete: @escaping (Project?) -> Void, debugInitialStep: Step = .welcome) {
        self.onComplete = onComplete
        _step = State(initialValue: debugInitialStep)
    }

    @State private var step: Step
    @State private var harnesses: [DiscoveredAgent] = []
    @State private var isDetecting = true
    @State private var projectFolder: URL?
    @State private var showingFolderPicker = false
    @State private var isFinishing = false
    @State private var recommendations: [ProjectRecommendation] = []

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
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
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                    .padding(.vertical, 32)
                }
                .scrollIndicators(.hidden)
            }
            footer
                .frame(maxWidth: 440)
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
        }
        .frame(minWidth: 640, minHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: step)
        .task {
            harnesses = await environment.agentService.discoverAgents()
            isDetecting = false
            // Suggest project folders from the user's most recent harness
            // sessions so the project step can offer a one-click choice.
            recommendations = await environment.recommendedProjects()
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
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.statusWarn)
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
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
            }

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
                Text("Pick a folder to work in. HerdMan opens a new chat scoped to this project and brings in your existing agent chats.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Based on your recent agent chats")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(recommendations) { recommendation in
                            recommendationRow(recommendation)
                        }
                    }
                }
            }

            Button {
                showingFolderPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isCustomFolderSelected ? "folder.fill" : "folder.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isCustomFolderSelected
                             ? (projectFolder?.lastPathComponent ?? "")
                             : (recommendations.isEmpty ? "Choose a folder…" : "Choose another folder…"))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        if isCustomFolderSelected, let projectFolder {
                            Text(projectFolder.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if isCustomFolderSelected {
                        selectionCheckmark
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the chosen folder came from the folder picker rather than a
    /// recommendation.
    private var isCustomFolderSelected: Bool {
        guard let projectFolder else { return false }
        return !recommendations.contains { $0.folderURL.standardizedFileURL.path == projectFolder.standardizedFileURL.path }
    }

    private func recommendationRow(_ recommendation: ProjectRecommendation) -> some View {
        let isSelected = projectFolder?.standardizedFileURL.path == recommendation.folderURL.standardizedFileURL.path
        return Button {
            projectFolder = recommendation.folderURL
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.name)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(recommendationSubtitle(recommendation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isSelected {
                    selectionCheckmark
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? AnyShapeStyle(theme.rowSelectedBackground) : theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(recommendation.name), \(recommendationSubtitle(recommendation))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectionCheckmark: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
    }

    private func recommendationSubtitle(_ recommendation: ProjectRecommendation) -> String {
        let chats = recommendation.sessionCount == 1 ? "1 chat" : "\(recommendation.sessionCount) chats"
        return "\(chats) · \(recommendation.folderURL.path)"
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
        case .welcome: return "Get started"
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
        Task {
            // Adds the project and imports its existing agent chats by default.
            let project = await environment.finishOnboarding(projectFolder: folder)
            onComplete(project)
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
