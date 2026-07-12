import SwiftUI
import AppKit
import HerdManCore
import UniformTypeIdentifiers
import os

/// First-launch onboarding, presented as a short paginated flow:
/// 1. Welcome, 2. Choose your harnesses, 3. Choose your projects.
/// The project step is a multi-select over suggested folders; completing it
/// adds every selected folder as a project and opens a new chat in the first.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    /// Called when setup finishes, with the project to open a new chat in
    /// (the first of the user's selected folders).
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
    @State private var rescanError: String?
    /// Folders the user has ticked, in selection order — the first one is the
    /// project a new chat opens in after setup.
    @State private var selectedFolders: [URL] = []
    /// Folders added through the open panel (they aren't in `recommendations`
    /// but should render as selectable rows alongside them).
    @State private var customFolders: [URL] = []
    @State private var showingFolderPicker = false
    @State private var isFinishing = false
    @State private var recommendations: [ProjectRecommendation] = []
    @State private var isLoadingRecommendations = true
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
                            .frame(maxWidth: contentMaxWidth)
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
                .frame(maxWidth: 560)
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.3), value: step)
        .task { await detectHarnesses() }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                addPickedFolders(urls)
            }
        }
        .sheet(item: $authenticationHarness) { harness in
            HarnessAuthenticationView(harness: harness) { replaceHarness($0) }
        }
    }

    /// The project step earns extra width for its two-column suggestion grid.
    private var contentMaxWidth: CGFloat {
        step == .project ? 560 : 460
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

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                .accessibilityHidden(true)

            Text("Welcome to HerdMan")
                .font(.system(size: 36, weight: .bold))
                .padding(.top, 22)

            Text("All your coding agents, working in one place.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step header

    private func stepHeader(title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Harnesses

    private var harnessesStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                title: "Choose your harnesses",
                subtitle: "These are the ACP coding agents we found on your Mac. Turn on the ones you'd like to use."
            )

            switch detection {
            case .connecting:
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking agents…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
            case let .unreachable(message):
                VStack(spacing: 12) {
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
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground))
                    Button {
                        Task { await detectHarnesses() }
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                }
            case .loaded:
                if installedHarnesses.isEmpty {
                    noHarnessesContent
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(spacing: 0) {
                            ForEach(Array(installedHarnesses.enumerated()), id: \.element.id) { index, harness in
                                harnessRow(harness)
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
        }
        .frame(maxWidth: .infinity)
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

            if let rescanError {
                Text(rescanError)
                    .font(.callout)
                    .foregroundStyle(theme.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private func harnessRow(_ harness: ServerHarness) -> some View {
        HStack(spacing: 12) {
            HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 18)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardHoverBackground))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name)
                    .fontWeight(.medium)
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
        isLoadingRecommendations = true
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
                // sessions so the project step offers one-click choices.
                recommendations = await environment.recommendedProjects()
                isLoadingRecommendations = false
                return
            }
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        isLoadingRecommendations = false
        detection = .unreachable(serverFailureMessage)
    }

    /// Re-detects on demand after the user installs a CLI; the server
    /// re-resolves its PATH first.
    private func rescanHarnesses() async {
        isRescanning = true
        defer { isRescanning = false }
        do {
            harnesses = try await environment.harnessService.rescanHarnesses()
            rescanError = nil
        } catch {
            Log.onboarding.error("Harness rescan failed: \(String(describing: error), privacy: .public)")
            rescanError = "Couldn't check for installed agents. Make sure the HerdMan server is running, then try again."
        }
    }

    private var serverFailureMessage: String {
        if case let .unavailable(message) = environment.localServer?.state {
            return message
        }
        return "The HerdMan server didn't respond. Try again, or check Settings → General for server status."
    }

    // MARK: - Projects

    /// A selectable folder row: either a recommendation or a custom pick.
    private struct FolderChoice: Identifiable {
        let url: URL
        let title: String
        let subtitle: String
        var id: String { url.standardizedFileURL.path }
    }

    /// Custom picks first (most deliberate), then the suggestions.
    private var folderChoices: [FolderChoice] {
        let custom = customFolders.map { url in
            FolderChoice(
                url: url,
                title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                subtitle: abbreviatedPath(url)
            )
        }
        let suggested = recommendations
            .filter { recommendation in
                !customFolders.contains {
                    $0.standardizedFileURL.path == recommendation.folderURL.standardizedFileURL.path
                }
            }
            .map { recommendation in
                FolderChoice(
                    url: recommendation.folderURL,
                    title: recommendation.name,
                    subtitle: recommendationSubtitle(recommendation)
                )
            }
        return custom + suggested
    }

    private var projectStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                title: "Choose your projects",
                subtitle: "Select the folders you want to work in."
            )

            VStack(alignment: .leading, spacing: 8) {
                if isLoadingRecommendations {
                    // HIG: recommendation discovery has no measurable duration,
                    // so show a small indeterminate activity indicator where
                    // its results will appear. Keep the manual picker available.
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .help("Finding recent projects")
                            .accessibilityLabel("Finding recent projects")
                        Spacer()
                    }
                    .frame(minHeight: 64)
                } else if !folderChoices.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Suggested from your recent sessions")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !selectedFolders.isEmpty {
                            Text(selectionCountLabel)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.tint)
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.2), value: selectedFolders.count)
                        }
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        ForEach(folderChoices) { choice in
                            folderChoiceRow(choice)
                        }
                    }
                }

                addFolderButton
                    .padding(.top, folderChoices.isEmpty ? 0 : 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var selectionCountLabel: String {
        selectedFolders.count == 1 ? "1 selected" : "\(selectedFolders.count) selected"
    }

    private func folderChoiceRow(_ choice: FolderChoice) -> some View {
        let isSelected = isSelected(choice.url)
        return Button {
            toggleSelection(choice.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(choice.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(theme.rowSelectedBackground) : theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(choice.url.standardizedFileURL.path)
        .accessibilityLabel("\(choice.title), \(choice.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.15), value: isSelected)
    }

    private var addFolderButton: some View {
        Button {
            showingFolderPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(folderChoices.isEmpty ? "Choose a folder…" : "Add another folder…")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.cardBackground))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return selectedFolders.contains { $0.standardizedFileURL.path == path }
    }

    private func toggleSelection(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let index = selectedFolders.firstIndex(where: { $0.standardizedFileURL.path == path }) {
            selectedFolders.remove(at: index)
        } else {
            selectedFolders.append(url)
        }
    }

    /// Folders picked in the open panel join the list pre-selected; picks that
    /// match an existing suggestion just select that suggestion's row.
    private func addPickedFolders(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            let isRecommended = recommendations.contains {
                $0.folderURL.standardizedFileURL.path == path
            }
            let isCustom = customFolders.contains { $0.standardizedFileURL.path == path }
            if !isRecommended && !isCustom {
                customFolders.append(url)
            }
            if !isSelected(url) {
                selectedFolders.append(url)
            }
        }
    }

    private func recommendationSubtitle(_ recommendation: ProjectRecommendation) -> String {
        let chats = recommendation.sessionCount == 1 ? "1 chat" : "\(recommendation.sessionCount) chats"
        return "\(chats) · \(abbreviatedPath(recommendation.folderURL))"
    }

    private func abbreviatedPath(_ url: URL) -> String {
        (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Footer

    private var footer: some View {
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
                primaryButton
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { dot in
                Capsule()
                    .fill(dot == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: dot == step ? 18 : 7, height: 7)
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
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
        case .harnesses: return "Continue"
        case .project:
            return selectedFolders.count > 1 ? "Add \(selectedFolders.count) Projects" : "Open Project"
        }
    }

    private var isPrimaryDisabled: Bool {
        if isFinishing { return true }
        switch step {
        case .welcome: return false
        case .harnesses: return detection == .connecting
        case .project: return selectedFolders.isEmpty
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
            // Capability inspection starts agents to discover models/modes and
            // can take a few seconds. Hide that latency behind project choice;
            // onboarding remains interactive and never waits on this warm.
            Task { await environment.warmHarnessCapabilities() }
        case .project:
            finish()
        }
    }

    private func finish() {
        guard !selectedFolders.isEmpty else { return }
        isFinishing = true
        Task {
            // Adds every selected folder as a project; existing agent chats
            // are not imported here (importing stays an explicit action, not
            // an onboarding default). The first selection opens a new chat.
            let project = await environment.finishOnboarding(projectFolders: selectedFolders)
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
