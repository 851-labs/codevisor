import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import UniformTypeIdentifiers
import os
import CodevisorUI

/// First-launch onboarding, presented as a short paginated flow:
/// 1. Welcome, 2. Choose your harnesses, 3. System permissions,
/// 4. Choose your projects, 5. Choose analytics and crash-report sharing.
/// The project step is a multi-select over suggested folders; completing it
/// adds every selected folder as a project and opens a new chat in the first.
struct OnboardingView: View {
    /// A failed harness enable/disable request, pending display in an alert.
    private struct ToggleError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    /// Called when setup finishes, with the project to open a new chat in
    /// (the first of the user's selected folders).
    var onComplete: (Project?) -> Void

    enum Step: Int, CaseIterable {
        case welcome, harnesses, permissions, project, analytics
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

    @State private var step: Step
    /// Which way the current step change is travelling, so the slide matches.
    @State private var isNavigatingBack = false
    /// The full catalog — installed harnesses get toggles, the rest get
    /// install hints.
    @State private var harnesses: [ServerHarness] = []
    @State private var detection: HarnessDetection = .connecting
    @State private var isRescanning = false
    @State private var rescanError: String?
    /// The project step's selection state (suggestions, picks, clones) —
    /// the same model the new-chat empty state uses.
    @State private var projectSetup = ProjectSetupModel()
    @State private var showingFolderPicker = false
    @State private var showingGitClone = false
    @State private var isFinishing = false
    @State private var showsNotInstalled = false
    @State private var authenticationHarness: ServerHarness?
    @State private var toggleError: ToggleError?
    /// Sharing is selected initially, but nothing is persisted or sent until
    /// the user continues past the final onboarding step.
    @State private var shareAnalytics = true
    @State private var shareCrashReports = true
    /// Computer Use permission status; previews auto-grant so the flow is
    /// navigable without touching real TCC state.
    @State private var permissions = ComputerUsePermissionsModel(
        probes: AppPreview.isRunning ? .granted : .live
    )

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
        .onChange(of: environment.harnessCatalogRevision(for: environment.machines.selectedMachineId)) { _, _ in
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
                guard before?.lifecycle?.phase == "installing", before?.isReady != true,
                      harness.auth != nil, !canUse(harness)
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
                client: environment.machines.client(for: environment.machines.selectedMachineId),
                machineName: environment.machines.selectedMachine.name
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .analytics: analyticsStep
        case .harnesses: harnessesStep
        case .project: projectStep
        }
    }

    // MARK: - Permissions

    /// Continue unlocks when both Computer Use permissions are granted;
    /// "Set Up Later" skips and turns Computer Use off until the user
    /// re-enters setup from the Computer Use toggle in Settings.
    private var permissionsStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "lock.shield",
                title: "Allow Computer Use",
                subtitle: "Codevisor uses these to operate apps when you ask."
            )

            ComputerUsePermissionRowsView(model: permissions)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 108, height: 108)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                .accessibilityHidden(true)

            Text("Welcome to Codevisor")
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

    // MARK: - Privacy

    /// A compact final-step consent card. Both choices start selected, remain
    /// independent, and are not persisted until the user continues.
    private var analyticsStep: some View {
        VStack(spacing: 0) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Help improve Codevisor")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Share anonymous usage metrics", isOn: $shareAnalytics)
                        .toggleStyle(.checkbox)
                        .fontWeight(.semibold)

                    Text("Shares anonymous product usage so we can understand what’s useful and what to improve.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Send crash and error reports", isOn: $shareCrashReports)
                        .toggleStyle(.checkbox)
                        .fontWeight(.semibold)

                    Text("Shares technical details when Codevisor crashes or encounters an error.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .padding(.top, 24)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Your work stays private")
                        .font(.callout.weight(.semibold))

                    Text("Neither option includes prompts, responses, code, file paths, project names, browser content, or terminal commands.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.top, 12)

            Text("You can change this at any time in Settings → General.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step header

    private func stepHeader(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 18)

            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Harnesses

    private var harnessesStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "terminal",
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
                            Text("Can't reach the Codevisor server").fontWeight(.medium)
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
                // One line, exactly like every other harness row — an errored
                // probe must not make this row taller than its neighbours. The
                // full text stays reachable as a tooltip.
                Text(authStatus(harness))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(authStatus(harness))
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
        // Deliberately plain language, and deliberately not the probe's
        // `detail`: that carries a crashed CLI's stderr, which was rendering
        // here as kilobytes of minified JavaScript. The technical cause is
        // still summarized and persisted server-side for diagnosis.
        case "error": return "Something went wrong starting the CLI"
        default: return "Not signed in"
        }
    }

    private func setHarness(_ harness: ServerHarness, enabled: Bool) async {
        updateHarness(harness.id, enabled: enabled)
        do {
            let updated = try await environment.serverClient.setHarnessEnabled(id: harness.id, enabled: enabled)
            environment.settings.setHarness(harness.id, enabled: updated.enabled)
            replaceHarness(updated)
        } catch {
            replaceHarness(harness)
            Log.server.error("Setting harness \(harness.id, privacy: .public) enabled=\(enabled, privacy: .public) during onboarding failed: \(String(describing: error), privacy: .public)")
            toggleError = ToggleError(
                title: enabled ? "Couldn't turn on \(harness.name)" : "Couldn't turn off \(harness.name)",
                message: ErrorReporter.userFacingMessage(for: error)
            )
        }
    }

    private func updateHarness(_ id: String, enabled: Bool) {
        guard let index = harnesses.firstIndex(where: { $0.id == id }) else { return }
        harnesses[index].enabled = enabled
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
    /// Light refetch (no PATH re-resolve) when a lifecycle event invalidated
    /// the catalog — flips rows through Installing… → installed live.
    private func refreshHarnessList() async {
        guard detection == .loaded else { return }
        if let loaded = try? await environment.harnessService.allHarnesses() {
            harnesses = loaded
        }
    }

    private func detectHarnesses() async {
        detection = .connecting
        projectSetup.isLoadingRecommendations = true
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
                projectSetup.recommendations = await environment.recommendedProjects()
                projectSetup.isLoadingRecommendations = false
                return
            }
            if attempt < 7 {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        projectSetup.isLoadingRecommendations = false
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
            rescanError = "Couldn't check for installed agents. Make sure the Codevisor server is running, then try again."
        }
    }

    private var serverFailureMessage: String {
        if case let .unavailable(message) = environment.localServer?.state {
            return message
        }
        return "The Codevisor server didn't respond. Try again, or check Settings → General for server status."
    }

    // MARK: - Projects

    private var projectStep: some View {
        VStack(spacing: 20) {
            stepHeader(
                symbol: "folder",
                title: "Choose your projects",
                subtitle: "Select the folders you want to work in."
            )

            // The same selection grid the new-chat empty state renders, so
            // both surfaces look and behave identically.
            ProjectSetupSelectionView(
                model: projectSetup,
                isLocalMachine: environment.machines.selectedMachine.isLocal,
                machineName: environment.machines.selectedMachine.name,
                onPickFolder: { showingFolderPicker = true },
                onCloneRepository: { showingGitClone = true }
            )
        }
        .frame(maxWidth: .infinity)
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
        case .permissions: return "Continue"
        case .harnesses: return "Continue"
        case .project: return "Continue"
        case .analytics: return "Continue"
        }
    }

    private var isPrimaryDisabled: Bool {
        if isFinishing { return true }
        switch step {
        case .welcome: return false
        case .permissions: return !permissions.allGranted
        case .harnesses: return detection == .connecting
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
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        navigate(to: previous, back: true)
    }

    /// "Set Up Later": Computer Use turns off so nothing half-works, and the
    /// Computer Use toggle in Settings re-enters this setup inline.
    private func skipPermissions() {
        environment.settings.setPermissionsSetupSkipped(true)
        Task {
            try? await environment.serverClient.setMcpServerEnabled(id: "computer", enabled: false)
        }
        navigate(to: .project, back: false)
    }

    private func advance() {
        switch step {
        case .welcome:
            navigate(to: .harnesses, back: false)
        case .harnesses:
            navigate(to: .permissions, back: false)
            // The catalog is already loaded, so make the first new-chat picker
            // available immediately. The capability warm below replaces this
            // provisional seed with model/mode metadata when it finishes.
            environment.configCache.seedHarnesses(
                harnesses,
                forServer: environment.machines.selectedMachineId
            )
            // Capability inspection starts agents to discover models/modes and
            // can take a few seconds. Hide that latency behind the permissions
            // and project steps; onboarding never waits on this warm.
            Task { await environment.warmHarnessCapabilities() }
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
        guard !projectSetup.selectedFolders.isEmpty else { return }
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
            let project = await environment.finishOnboarding(projectFolders: projectSetup.selectedFolders)
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
