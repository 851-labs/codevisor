import CodevisorCore
import CodevisorUI
import SwiftUI

/// The one place updates live: every updatable component across the fleet
/// (app, servers, agents, plugins), grouped by kind, with per-row installs
/// and one properly ordered "Update All".
struct UpdateCenterView: View {
    enum Context {
        case sheet
        case settings
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let context: Context

    init(context: Context = .sheet) {
        self.context = context
    }

    private var center: UpdateCenter { environment.updateCenter }

    var body: some View {
        Group {
            switch context {
            case .sheet:
                sheetContent
            case .settings:
                settingsContent
            }
        }
        .task { await center.refresh(force: true) }
    }

    private var sheetContent: some View {
        VStack(spacing: 0) {
            Form {
                componentSections
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
            footer(showsDoneButton: true)
                .themedSurface(.sheet)
        }
        .frame(width: 560, height: 480)
        .themedSurface(.sheet)
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            Form {
                updateChannelSection
                componentSections
            }
            .settingsPaneFormStyle(theme)
            Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
            footer(showsDoneButton: false)
        }
    }

    private var updateChannelSection: some View {
        Section {
            Toggle(isOn: alphaUpdatesEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Alpha updates")
                    Text("Receive Alpha builds before stable releases.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        } header: {
            Text("Update Channel")
        }
    }

    @ViewBuilder
    private var componentSections: some View {
        if center.components.isEmpty {
            emptySection
        } else {
            section(titled: "App", kind: .app)
            section(titled: "Servers", kind: .server)
            section(titled: "Harnesses", kind: .harness)
            section(titled: "Plugins", kind: .plugin)
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 8) {
                Image(
                    systemName: center.isRefreshing
                        ? "arrow.triangle.2.circlepath" : "checkmark.circle"
                )
                .font(.title2)
                .foregroundStyle(.secondary)
                Text(center.isRefreshing ? "Checking for updates…" : "Everything is up to date.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    @ViewBuilder
    private func section(titled title: String, kind: UpdateComponent.Kind) -> some View {
        let rows = center.components.filter { $0.kind == kind }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { component in
                    row(for: component)
                }
            }
        }
    }

    private func row(for component: UpdateComponent) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.title)
                HStack(spacing: 6) {
                    Text(component.machineName)
                    if component.updateAvailable,
                        let installed = component.installedVersion,
                        let latest = component.latestVersion
                    {
                        Text("\(installed) → \(latest)")
                    } else if let installed = component.installedVersion {
                        Text(installed)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if case let .failed(message) = component.phase {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(theme.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing(for: component)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func trailing(for component: UpdateComponent) -> some View {
        switch component.phase {
        case .updating:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button("Try Again") { Task { await center.update(component) } }
                .controlSize(.small)
                .disabled(center.isUpdatingAll)
        case .idle:
            if component.updateAvailable {
                Button("Update") { Task { await center.update(component) } }
                    .controlSize(.small)
                    .disabled(center.isUpdatingAll)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func footer(showsDoneButton: Bool) -> some View {
        HStack(spacing: 10) {
            if center.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if let refreshed = center.lastRefreshedAt {
                Text("Checked \(refreshed.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check Again") { Task { await center.refresh(force: true) } }
                .settingsActionTint(theme)
                .disabled(center.isRefreshing || center.isUpdatingAll)
            if center.availableCount > 0 {
                Button(center.isUpdatingAll ? "Updating…" : "Update All") {
                    Task { await center.updateAll() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(center.isUpdatingAll)
            }
            if showsDoneButton {
                Button("Done") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
    }

    private var alphaUpdatesEnabled: Binding<Bool> {
        Binding(
            get: { environment.settings.alphaUpdatesEnabled },
            set: { enabled in
                environment.setAlphaUpdatesEnabled(enabled)
                Task { await environment.appUpdate.checkForUpdates() }
            }
        )
    }
}
