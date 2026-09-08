import CodevisorCore
import SwiftUI

/// Settings ▸ Updates: a summary with the fleet-wide action on top, then one
/// section per machine listing what it can update (its server, then its
/// agents and plugins). The iOS twin of macOS's UpdateCenterView — the app
/// itself is App Store-managed here, so its row simply never exists.
struct UpdatesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment

  private var center: UpdateCenter { environment.updateCenter }

  var body: some View {
    List {
      summarySection
      ForEach(center.machineGroups) { group in
        Section {
          if let codevisor = group.codevisor,
            codevisor.updateAvailable || codevisor.phase != .idle
          {
            row(for: codevisor)
          } else if group.components.isEmpty {
            Text("Everything is up to date.")
              .foregroundStyle(.secondary)
          }
          ForEach(group.components) { component in
            row(for: component)
          }
        } header: {
          Text(group.machineName)
            .textCase(nil)
        }
      }
    }
    .navigationTitle("Updates")
    .refreshable { await center.refresh(force: true) }
    .task { await center.refresh(force: true) }
  }

  private var summarySection: some View {
    Section {
      HStack(spacing: 10) {
        if center.isRefreshing || center.isUpdatingAll {
          ProgressView()
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(summaryTitle)
            .font(.headline)
          if let refreshed = center.lastRefreshedAt {
            Text("Last checked \(refreshed.formatted(date: .omitted, time: .shortened))")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      if center.availableCount > 0 {
        Button(center.isUpdatingAll ? "Updating…" : "Update All") {
          Task { await center.updateAll() }
        }
        .disabled(center.isUpdatingAll)
      }
    } footer: {
      if let notice = center.updateAllNotice {
        Label(notice, systemImage: "exclamationmark.triangle")
      }
    }
  }

  private var summaryTitle: String {
    if center.isUpdatingAll { return "Updating…" }
    switch center.availableCount {
    case 0: return center.isRefreshing ? "Checking for updates…" : "Everything is up to date"
    case 1: return "1 update available"
    case let count: return "\(count) updates available"
    }
  }

  private func row(for component: UpdateComponent) -> some View {
    HStack(spacing: 10) {
      if component.kind == .app || component.kind == .server {
        Image("CodevisorMark")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.secondary)
          .frame(width: 15, height: 15)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(component.title)
        Text(component.detailText)
          .font(.footnote)
          .foregroundStyle(component.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
          .lineLimit(1)
          .truncationMode(.tail)
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
          .accessibilityLabel("Up to date")
      }
    }
  }
}
