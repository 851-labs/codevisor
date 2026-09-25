import CodevisorCore
import SwiftUI

/// Settings ▸ Updates: a summary with the fleet-wide action on top, then one
/// section per machine listing what it can update (its server, then its
/// agents and plugins). The iOS twin of macOS's UpdateCenterView — the app
/// itself is App Store-managed here, so its row simply never exists.
/// Opening the screen checks every feed afresh, and the list stays hidden
/// until that check finishes, so nothing installs from a stale list.
struct UpdatesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  /// Whether this visit's opening check has finished.
  @State private var hasCheckedOnOpen = false

  private var center: UpdateCenter { environment.updateCenter }

  private var isChecking: Bool {
    !hasCheckedOnOpen || center.isCheckingForUpdates
  }

  var body: some View {
    List {
      summarySection
      if !isChecking {
        machineSections
      }
    }
    .navigationTitle("Updates")
    .refreshable { await center.refresh(force: true) }
    .task {
      // An update-all in flight is working from its own list: leave it be.
      if !center.isUpdatingAll {
        await center.refresh(force: true)
      }
      hasCheckedOnOpen = true
    }
  }

  private var machineSections: some View {
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

  private var summarySection: some View {
    Section {
      HStack(spacing: 10) {
        if isChecking || center.isUpdatingAll {
          ProgressView()
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(summaryTitle)
            .font(.headline)
          if !isChecking, let refreshed = center.lastRefreshedAt {
            Text("Last checked \(refreshed.formatted(date: .omitted, time: .shortened))")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      if !isChecking, center.availableCount > 0 {
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
    if isChecking { return "Checking for updates…" }
    switch center.availableCount {
    case 0: return "Everything is up to date"
    case 1: return "1 update available"
    case let count: return "\(count) updates available"
    }
  }

  private func row(for component: UpdateComponent) -> some View {
    HStack(spacing: 10) {
      icon(for: component)
        .foregroundStyle(.secondary)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(component.title)
        detail(for: component)
          .font(.footnote)
          .foregroundStyle(component.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      }
      Spacer(minLength: 8)
      trailing(for: component)
    }
  }

  /// One line. With an update pending, the installed version truncates
  /// first so the version being installed always shows. Accessibility text
  /// sizes wrap instead: no single line fits a version there.
  @ViewBuilder
  private func detail(for component: UpdateComponent) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      Text(component.detailText)
    } else if let change = component.pendingVersionChange {
      HStack(spacing: 4) {
        Text(verbatim: change.installed)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(verbatim: "→ \(change.latest)")
          .lineLimit(1)
          .layoutPriority(1)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(change.installed) to \(change.latest)")
    } else {
      Text(component.detailText)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  @ViewBuilder
  private func icon(for component: UpdateComponent) -> some View {
    switch component.kind {
    case .app, .server:
      Image("CodevisorMark")
        .resizable()
        .scaledToFit()
        .frame(width: 15, height: 15)
    case .harness:
      HarnessIconView(harnessId: component.subjectId, fallbackSymbolName: "brain", size: 15)
    case .plugin:
      Image(systemName: "puzzlepiece.extension")
    }
  }

  @ViewBuilder
  private func trailing(for component: UpdateComponent) -> some View {
    switch component.phase {
    case .updating:
      // Measurable progress (a download, a data migration) draws a bar
      // like macOS; otherwise an indeterminate spinner.
      if let progress = component.progress {
        ProgressView(value: progress)
          .progressViewStyle(.linear)
          .frame(width: 72)
      } else {
        ProgressView()
      }
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
