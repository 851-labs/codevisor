import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct UpdateCenterView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var failureDetailsId: String?

  @State private var majorUpdate: UpdateComponent?

  private var center: UpdateCenter { environment.updateCenter }

  private func requestUpdate(_ component: UpdateComponent) {
    if component.notes == nil {
      Task { await center.update(component) }
    } else {
      majorUpdate = component
    }
  }

  private var hasLoaded: Bool { center.lastRefreshedAt != nil }

  private var isChecking: Bool {
    center.isRefreshing || center.isCheckingForUpdates
  }

  var body: some View {
    Form {
      summarySection
      if hasLoaded {
        ForEach(center.machineGroups) { group in
          machineSection(group)
        }
      }
    }
    .formStyle(.grouped)
    .majorUpdateConfirmation($majorUpdate) { component in Task { await center.update(component) } }
    .animation(.default, value: center.components.map(\.id))
    .task {
      if !hasLoaded { await center.refresh() }
    }
  }

  private var summarySection: some View {
    Section {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(summaryTitle)
          Text(summaryDetail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Button {
          Task { await center.refresh(force: true) }
        } label: {
          BusyButtonLabel(title: "Check Again", isBusy: isChecking)
        }
        .disabled(isChecking || center.hasUpdateInFlight)
        if hasLoaded, center.availableCount > 0 {
          Button {
            Task { await center.updateAll() }
          } label: {
            BusyButtonLabel(title: "Update All", isBusy: center.isUpdatingAll)
          }
          .buttonStyle(.borderedProminent)
          .disabled(center.isUpdatingAll || center.isCheckingForUpdates)
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
    if !hasLoaded { return "Checking for updates…" }
    switch center.availableCount {
    case 0: return "Everything is up to date"
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

  private func machineSection(_ group: UpdateMachineGroup) -> some View {
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
    }
  }

  private func row(for component: UpdateComponent) -> some View {
    HStack(spacing: 12) {
      icon(for: component)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(component.title)
        detail(for: component)
          .font(.callout)
          .foregroundStyle(
            component.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
          )
          .help(component.detailText)
      }
      Spacer(minLength: 12)
      trailing(for: component)
        .frame(minWidth: 96, alignment: .trailing)
    }
    .padding(.vertical, 2)
  }

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
      CodevisorSymbol.codevisorMark.image
        .font(.system(size: 15))
        .accessibilityHidden(true)
    case .harness:
      HarnessIcon(harnessId: component.subjectId, fallbackSymbolName: "brain", size: 15)
    case .plugin:
      Image(systemName: "puzzlepiece.extension")
    }
  }

  @ViewBuilder
  private func trailing(for component: UpdateComponent) -> some View {
    switch component.phase {
    case .updating where component.canCancel:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Button("Cancel") { Task { await center.cancel(component) } }
      }
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
          .popover(isPresented: failureDetailsBinding(for: component.id), arrowEdge: .bottom) {
            UpdateFailureDetails(component: component, message: message)
          }
        Button("Try Again") { Task { await center.update(component) } }
          .disabled(center.isUpdatingAll)
      }
    case .idle:
      if component.updateAvailable {
        Button("Update") { requestUpdate(component) }
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
}

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
  environment.appUpdate.checkHandler = {}
  environment.appUpdate.reportAvailable(version: "0.2.0", releasePageURL: nil)
  environment.appUpdate.reportFailure(
    (1...40).map { "line \($0): ld: symbol(s) not found for architecture arm64" }
      .joined(separator: "\n")
  )
  return UpdateCenterView()
    .environment(environment)
    .frame(width: 620, height: 480)
}
