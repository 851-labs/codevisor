import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Settings › Updates — the one place updates live. Software Update's
/// shape: a summary with the fleet-wide actions on top, then one section per
/// machine listing what that machine can update (its Codevisor, then its
/// harnesses and plugins), then the channel preference.
///
/// Every row keeps the same two-line geometry in every state — available,
/// updating, failed — so a live update never reflows the pane, and failure
/// output opens in a popover instead of expanding inline. Both are the
/// difference between this and the layout that used to blank the window.
struct UpdateCenterView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  /// The component whose failure details popover is open.
  @State private var failureDetailsId: String?

  private var center: UpdateCenter { environment.updateCenter }

  var body: some View {
    Form {
      summarySection
      ForEach(center.machineGroups) { group in
        machineSection(group)
      }
      channelSection
    }
    .settingsPaneFormStyle(theme)
    .background {
      if !theme.isSystem { theme.windowBackground }
    }
    .task { await center.refresh(force: true) }
  }

  // MARK: - Summary

  private var summarySection: some View {
    Section {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(summaryTitle)
            .font(.headline)
          Text(summaryDetail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        // Activity lives inside the button that started it, at the button's
        // resting width, so a check or an update never shifts the row.
        Button {
          Task { await center.refresh(force: true) }
        } label: {
          BusyButtonLabel(title: "Check Again", isBusy: center.isRefreshing)
        }
        .settingsActionTint(theme)
        .disabled(center.isRefreshing || center.isUpdatingAll)
        if center.availableCount > 0 {
          Button {
            Task { await center.updateAll() }
          } label: {
            BusyButtonLabel(title: "Update All", isBusy: center.isUpdatingAll)
          }
          .buttonStyle(.borderedProminent)
          .disabled(center.isUpdatingAll)
        }
      }
      .padding(.vertical, 4)
    } footer: {
      if let notice = center.updateAllNotice {
        Label(notice, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .font(.callout)
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

  private var summaryDetail: String {
    guard let refreshed = center.lastRefreshedAt else {
      return "Checking every machine's Codevisor, harnesses, and plugins."
    }
    return "Last checked \(refreshed.formatted(date: .omitted, time: .shortened))"
  }

  // MARK: - Machines

  /// A machine's section: the header IS the machine's Codevisor — name,
  /// version line, and its update control — and the rows are the harnesses
  /// and plugins on it.
  private func machineSection(_ group: UpdateMachineGroup) -> some View {
    Section {
      if group.components.isEmpty {
        Text("Harnesses and plugins are up to date.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(group.components) { component in
          row(for: component)
        }
      }
    } header: {
      machineHeader(group)
    }
  }

  private func machineHeader(_ group: UpdateMachineGroup) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(group.isLocal ? "\(group.machineName) (This Mac)" : group.machineName)
        if let codevisor = group.codevisor {
          Text(codevisorDetail(codevisor))
            .font(.callout)
            .fontWeight(.regular)
            .foregroundStyle(
              codevisor.isFailed ? AnyShapeStyle(theme.statusError) : AnyShapeStyle(.secondary)
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .help(codevisorDetail(codevisor))
        }
      }
      Spacer(minLength: 12)
      if let codevisor = group.codevisor {
        trailing(for: codevisor)
          .font(.body)
          .fontWeight(.regular)
      }
    }
    .padding(.bottom, 2)
  }

  /// "Codevisor 0.1.99", "Codevisor 0.1.99 → 0.2.0", "Codevisor · Downloading… 42%",
  /// or the failure line as is.
  private func codevisorDetail(_ component: UpdateComponent) -> String {
    switch component.phase {
    case .idle: "Codevisor \(component.detailText)"
    case .updating: "Codevisor · \(component.detailText)"
    case .failed: component.detailText
    }
  }

  private func row(for component: UpdateComponent) -> some View {
    HStack(spacing: 12) {
      icon(for: component)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(component.title)
        Text(component.detailText)
          .font(.callout)
          .foregroundStyle(
            component.isFailed ? AnyShapeStyle(theme.statusError) : AnyShapeStyle(.secondary)
          )
          .lineLimit(1)
          .truncationMode(.tail)
          .help(component.detailText)
      }
      Spacer(minLength: 12)
      trailing(for: component)
        .frame(minWidth: 96, alignment: .trailing)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func icon(for component: UpdateComponent) -> some View {
    switch component.kind {
    case .app, .server:
      // Never a row: a machine's Codevisor is its section header.
      EmptyView()
    case .harness:
      HarnessIcon(harnessId: component.subjectId, fallbackSymbolName: "brain", size: 15)
    case .plugin:
      Image(systemName: "puzzlepiece.extension")
    }
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
    case let .failed(message):
      HStack(spacing: 8) {
        Button("Details…") { failureDetailsId = component.id }
          .settingsActionTint(theme)
          .popover(isPresented: failureDetailsBinding(for: component.id), arrowEdge: .bottom) {
            UpdateFailureDetails(component: component, message: message)
          }
        Button("Try Again") { Task { await center.update(component) } }
          .settingsActionTint(theme)
          .disabled(center.isUpdatingAll)
      }
    case .idle:
      if component.updateAvailable {
        Button("Update") { Task { await center.update(component) } }
          .settingsActionTint(theme)
          .disabled(center.isUpdatingAll)
      } else {
        Image(systemName: "checkmark.circle")
          .foregroundStyle(.secondary)
          .help("Up to date")
          .accessibilityLabel("Up to date")
      }
    }
  }

  private func failureDetailsBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: { failureDetailsId == id },
      set: { presented in
        if !presented, failureDetailsId == id { failureDetailsId = nil }
      }
    )
  }

  // MARK: - Channel

  private var channelSection: some View {
    Section {
      Toggle("Alpha updates", isOn: alphaUpdatesEnabled)
        .toggleStyle(.switch)
    } header: {
      Text("Update Channel")
    } footer: {
      Text("Receive Alpha builds of Codevisor and its servers before they reach the stable channel.")
    }
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

/// A button label that swaps its title for a spinner while its action runs,
/// keeping the title's width so the control never resizes.
private struct BusyButtonLabel: View {
  let title: String
  let isBusy: Bool

  var body: some View {
    ZStack {
      Text(title)
        .opacity(isBusy ? 0 : 1)
      if isBusy {
        ProgressView()
          .controlSize(.small)
      }
    }
    .accessibilityLabel(isBusy ? "\(title), in progress" : title)
  }
}

/// The full output of a failed update, in a popover: selectable, copyable,
/// and bounded — so a long updater log never dictates the row's height.
private struct UpdateFailureDetails: View {
  let component: UpdateComponent
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(component.title) couldn’t update")
          .font(.headline)
        Text(component.machineName)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      ScrollView {
        Text(message)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 220)
      HStack {
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(message, forType: .string)
        }
      }
    }
    .padding(16)
    .frame(width: 400)
  }
}

#Preview("Updates — failed with long output") {
  let environment = AppEnvironment.preview()
  environment.appUpdate.checkHandler = { _ in }
  environment.appUpdate.reportAvailable(version: "0.2.0", releasePageURL: nil)
  environment.appUpdate.reportFailure(
    (1...40).map { "line \($0): ld: symbol(s) not found for architecture arm64" }
      .joined(separator: "\n")
  )
  return UpdateCenterView()
    .environment(environment)
    .frame(width: 620, height: 480)
}
