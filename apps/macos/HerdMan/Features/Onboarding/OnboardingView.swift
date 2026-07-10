import SwiftUI
import HerdManCore
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

    /// Where harness detection stands. Distinguishes "the server isn't up
    /// yet / can't be reached" from "reachable, but nothing installed" — the
    /// two used to collapse into a false "No harnesses found".
    enum HarnessDetection: Equatable {
        case connecting
        case unreachable(String)
        case loaded
    }

    init(onComplete: @escaping (Project?) -> Void, debugInitialStep: Step = .welcome) {
        self.onComplete = onComplete
        _step = State(initialValue: debugInitialStep)
    }

    @State private var step: Step
    /// The full catalog — installed harnesses get toggles, the rest get
    /// install hints.
    @State private var harnesses: [ServerHarness] = []
    @State private var detection: HarnessDetection = .connecting
    @State private var isRescanning = false
    @State private var projectFolder: URL?
    @State private var showingFolderPicker = false
    @State private var isFinishing = false
    @State private var recommendations: [ProjectRecommendation] = []
    @State private var showsNotInstalled = false
    @State private var authenticationHarness: ServerHarness?

    private var installedHarnesses: [ServerHarness] { harnesses.filter(\.isReady) }
    private var notInstalledHarnesses: [ServerHarness] { harnesses.filter { !$0.isReady } }

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
        .task { await detectHarnesses() }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                projectFolder = url
            }
        }
        .sheet(item: $authenticationHarness) { harness in
            HarnessAuthenticationView(harness: harness) { replaceHarness($0) }
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

            switch detection {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting HerdMan…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            case let .unreachable(message):
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Can't reach the HerdMan server").fontWeight(.medium)
                            Text(message)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.statusWarn)
                    }
                    Button {
                        Task { await detectHarnesses() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
                .padding(.vertical, 4)
            case .loaded:
                if installedHarnesses.isEmpty {
                    noHarnessesContent
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(installedHarnesses.enumerated()), id: \.element.id) { index, harness in
                            harnessToggle(harness)
                            if index < installedHarnesses.count - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))

                    if !notInstalledHarnesses.isEmpty {
                        DisclosureGroup(isExpanded: $showsNotInstalled) {
                            notInstalledList
                                .padding(.top, 8)
                        } label: {
                            Text("Not installed (\(notInstalledHarnesses.count))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The "nothing installed" empty state: every known harness with an
    /// install hint, plus a rescan that picks up a fresh install in place —
    /// the server re-resolves its PATH, so no relaunch is needed.
    private var noHarnessesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No harnesses found").fontWeight(.medium)
                    Text("Install one below, then detect again — no restart needed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.statusWarn)
            }

            notInstalledList

            Button {
                Task { await rescanHarnesses() }
            } label: {
                if isRescanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Detecting…")
                    }
                } else {
                    Label("Detect again", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRescanning)
        }
    }

    private var notInstalledList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(notInstalledHarnesses.enumerated()), id: \.element.id) { index, harness in
                HarnessInstallHintRow(harness: harness)
                    .padding(.vertical, 8)
                if index < notInstalledHarnesses.count - 1 { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
    }

    private func harnessToggle(_ harness: ServerHarness) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name)
                Text(authStatus(harness))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if harness.auth != nil && !canUse(harness) {
                Button("Sign In…") { authenticationHarness = harness }
            } else {
                if harness.auth?.supportsMultipleAccounts == true {
                    Button("Accounts…") { authenticationHarness = harness }
                }
                Toggle("Enable \(harness.name)", isOn: Binding(
                    get: { harness.enabled },
                    set: { enabled in Task { await setHarness(harness, enabled: enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, 10)
    }

    private func canUse(_ harness: ServerHarness) -> Bool {
        harness.auth?.state == "authenticated" || harness.auth?.state == "notRequired"
    }

    private func authStatus(_ harness: ServerHarness) -> String {
        guard let auth = harness.auth else { return "Sign-in status unavailable" }
        let account = auth.accounts.first(where: { $0.id == auth.activeAccountId }) ?? auth.accounts.first
        switch auth.state {
        case "authenticated": return account?.email.map { "Signed in as \($0)" } ?? "Signed in"
        case "notRequired": return "No sign-in required"
        case "checking": return "Checking sign-in…"
        case "expired": return "Sign-in expired"
        case "error": return account?.detail ?? "Couldn't check sign-in"
        default: return "Not signed in"
        }
    }

    private func setHarness(_ harness: ServerHarness, enabled: Bool) async {
        do {
            let updated = try await environment.serverClient.setHarnessEnabled(id: harness.id, enabled: enabled)
            environment.settings.setHarness(harness.id, enabled: updated.enabled)
            replaceHarness(updated)
        } catch {
            replaceHarness(harness)
        }
    }

    private func replaceHarness(_ harness: ServerHarness) {
        guard let index = harnesses.firstIndex(where: { $0.id == harness.id }) else { return }
        harnesses[index] = harness
    }

    // MARK: - Detection

    /// Waits for the local server, then loads the harness catalog with a
    /// short retry tail. Onboarding shows on first launch — exactly when the
    /// server is cold-starting — so querying immediately used to hit a closed
    /// port and misreport "No harnesses found".
    private func detectHarnesses() async {
        detection = .connecting
        if !AppPreview.isRunning {
            // Joins the root view's in-flight server start (ensureRunning
            // dedups concurrent callers) instead of racing ahead of it.
            await environment.prepareSelectedMachine()
        }
        // Safety net past the health wait: a handful of quick retries, not
        // one instantly-failing shot.
        for attempt in 0..<8 {
            if let loaded = try? await environment.harnessService.rescanHarnesses() {
                harnesses = loaded
                detection = .loaded
                // Suggest project folders from the user's most recent harness
                // sessions so the project step can offer a one-click choice.
                recommendations = await environment.recommendedProjects()
                return
            }
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        detection = .unreachable(serverFailureMessage)
    }

    /// Re-detects on demand after the user installs a CLI; the server
    /// re-resolves its PATH first.
    private func rescanHarnesses() async {
        isRescanning = true
        defer { isRescanning = false }
        if let loaded = try? await environment.harnessService.rescanHarnesses() {
            harnesses = loaded
        }
    }

    private var serverFailureMessage: String {
        if case let .unavailable(message) = environment.localServer?.state {
            return message
        }
        return "The HerdMan server didn't respond. Try again, or check Settings → General for server status."
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
                    Image(systemName: isCustomFolderSelected ? "folder.fill" : "folder.badge.plus")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isCustomFolderSelected
                             ? (projectFolder?.lastPathComponent ?? "")
                             : "Choose a folder…")
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

            if !recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested workspaces")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        ForEach(recommendations) { recommendation in
                            recommendationRow(recommendation)
                        }
                    }
                }
            }
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
        case .harnesses: return detection == .connecting
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
            // Adds the project; existing agent chats are not imported here
            // (importing stays an explicit action, not an onboarding default).
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
