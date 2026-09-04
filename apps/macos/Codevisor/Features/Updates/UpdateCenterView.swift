import CodevisorCore
import CodevisorUI
import SwiftUI

/// Settings › Updates — the one place updates live: every updatable
/// component across the fleet (app, servers, agents, plugins), grouped by
/// kind, with per-row installs, live progress, and one properly ordered
/// "Update All".
struct UpdateCenterView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme

  private var center: UpdateCenter { environment.updateCenter }

  var body: some View {
    VStack(spacing: 0) {
      // Do not use Form here. On macOS it takes the same AppKit outline-
      // coordinator path as the Settings sidebar List. Updater failures can
      // add a tall, multiline output tail in one transaction, leaving both
      // native scroll views with corrupt state until the app relaunches.
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          updateChannelSection
          componentSections
        }
        .padding(20)
      }
      .scrollContentBackground(.hidden)
      .scrollBounceBehavior(.basedOnSize)
      Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
      footer
    }
    .task { await center.refresh(force: true) }
  }

  private var updateChannelSection: some View {
    updateSection(title: "Update Channel") {
      Toggle(isOn: alphaUpdatesEnabled) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Alpha updates")
          Text("Receive Alpha builds before stable releases.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)
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
    updateSection {
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
      updateSection(title: title) {
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, component in
            if index > 0 {
              Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
            }
            row(for: component)
              .padding(.vertical, 10)
          }
        }
      }
    }
  }

  private func updateSection<Content: View>(
    title: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        Text(title)
          .font(.headline)
      }
      content()
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
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
          DisclosureGroup {
            Text(message)
              .font(.callout)
              .foregroundStyle(theme.statusError)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
              .padding(.top, 4)
          } label: {
            Text("Update failed")
              .font(.callout)
              .foregroundStyle(theme.statusError)
          }
          .tint(theme.statusError)
        } else if component.phase == .updating, let status = component.statusMessage {
          // What the machine is doing right now: draining chats,
          // downloading, restarting.
          Text(status)
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
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
      if let progress = component.progress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .frame(width: 96)
      } else {
        ProgressView()
          .controlSize(.small)
      }
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

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let notice = center.updateAllNotice {
        Text(notice)
          .font(.callout)
          .foregroundStyle(theme.statusError)
          .fixedSize(horizontal: false, vertical: true)
      }
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
