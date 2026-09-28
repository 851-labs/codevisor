import CodevisorCore
import SwiftUI

/// Settings ▸ Updates: a summary with the fleet-wide action on top, then one
/// section per machine listing what it can update (its server, then its
/// agents and plugins). The iOS twin of macOS's UpdateCenterView — the app
/// itself is App Store-managed here, so its row simply never exists.
/// The screen shows what the last sweep found — the same list behind the
/// Settings badge — the moment it opens; opening it checks nothing. Pull to
/// refresh checks every feed afresh, and a sweep landing while the screen
/// is open updates rows in place without hiding them.
struct UpdatesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment

  private var center: UpdateCenter { environment.updateCenter }

  /// A sweep has finished at least once, so there is a list to show.
  private var hasLoaded: Bool { center.lastRefreshedAt != nil }

  /// Background activity worth a spinner in the summary. A pull-to-refresh
  /// check already shows the system's own indicator.
  private var showsActivity: Bool {
    !hasLoaded || center.isUpdatingAll
      || (center.isRefreshing && !center.isCheckingForUpdates)
  }

  var body: some View {
    List {
      summarySection
      if hasLoaded {
        machineSections
      }
    }
    .navigationTitle("Updates")
    .animation(.default, value: center.components.map(\.id))
    .refreshable {
      // Nothing re-checks while an update runs, so the list stays put.
      guard !center.hasUpdateInFlight else { return }
      await center.refresh(force: true)
    }
    .task {
      // Opened before the launch sweep finished: join it (or start one)
      // so there is something to show. Otherwise the last sweep stands.
      if !hasLoaded { await center.refresh() }
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
        if showsActivity {
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
      if hasLoaded, center.availableCount > 0 {
        Button(center.isUpdatingAll ? "Updating…" : "Update All") {
          Task { await center.updateAll() }
        }
        .disabled(center.isUpdatingAll || center.isCheckingForUpdates)
      }
    } footer: {
      if let notice = center.updateAllNotice {
        Label(notice, systemImage: "exclamationmark.triangle")
      }
    }
  }

  private var summaryTitle: String {
    if center.isUpdatingAll { return "Updating…" }
    if !hasLoaded { return "Checking for updates…" }
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

  /// Versions are never truncated. A pending update reads "installed →
  /// latest" on one line when it fits and otherwise breaks at the arrow, one
  /// version per line. In-flight and failure status stays on one line.
  @ViewBuilder
  private func detail(for component: UpdateComponent) -> some View {
    if let change = component.pendingVersionChange {
      ViewThatFits(in: .horizontal) {
        Text(component.detailText)
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: "\(change.installed) →")
          Text(verbatim: change.latest)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(change.installed) to \(change.latest)")
    } else if component.phase == .idle {
      Text(component.detailText)
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
