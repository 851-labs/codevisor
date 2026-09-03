import CodevisorCore
import SwiftUI

/// Settings ▸ Updates: every updatable component across the fleet, grouped
/// by kind, with per-row installs and one ordered "Update All". The iOS
/// twin of macOS's UpdateCenterView — the app itself is App Store-managed
/// here, so its row simply never exists.
struct UpdatesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment

  private var center: UpdateCenter { environment.updateCenter }

  var body: some View {
    List {
      if center.components.isEmpty {
        emptySection
      } else {
        if center.availableCount > 1 {
          updateAllSection
        }
        section(titled: "Servers", kind: .server)
        section(titled: "Agents", kind: .harness)
        section(titled: "Plugins", kind: .plugin)
      }
    }
    .navigationTitle("Updates")
    .refreshable { await center.refresh(force: true) }
    .task { await center.refresh(force: true) }
  }

  private var emptySection: some View {
    Section {
      HStack {
        Spacer()
        VStack(spacing: 8) {
          Image(
            systemName: center.isRefreshing
              ? "arrow.triangle.2.circlepath" : "checkmark.circle"
          )
          .font(.title2)
          .foregroundStyle(.secondary)
          Text(
            center.isRefreshing
              ? "Checking for updates…" : "Everything is up to date."
          )
          .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        Spacer()
      }
    }
  }

  private var updateAllSection: some View {
    Section {
      if let notice = center.updateAllNotice {
        Text(notice)
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button {
        Task { await center.updateAll() }
      } label: {
        HStack {
          Spacer()
          if center.isUpdatingAll {
            ProgressView()
              .padding(.trailing, 6)
            Text("Updating…")
          } else {
            Text("Update All")
          }
          Spacer()
        }
      }
      .disabled(center.isUpdatingAll)
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
        .font(.footnote)
        .foregroundStyle(.secondary)
        if case let .failed(message) = component.phase {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if component.phase == .updating, let status = component.statusMessage {
          // What the machine is doing right now: draining chats,
          // installing, restarting.
          Text(status)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
        }
      }
      Spacer(minLength: 8)
      trailing(for: component)
    }
  }

  @ViewBuilder
  private func trailing(for component: UpdateComponent) -> some View {
    switch component.phase {
    case .updating:
      ProgressView()
    case .failed:
      Button("Retry") { Task { await center.update(component) } }
        .buttonStyle(.bordered)
        .disabled(center.isUpdatingAll)
    case .idle:
      if component.updateAvailable {
        Button("Update") { Task { await center.update(component) } }
          .buttonStyle(.bordered)
          .disabled(center.isUpdatingAll)
      } else {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(.secondary)
      }
    }
  }
}
