import CodevisorCore
import CodevisorUI
import SwiftUI

/// Reviews the exact staged candidate before applying its short-lived plan.
struct PluginUpdateSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  let plan: ServerPluginUpdatePlan
  let onApply: () async throws -> Void
  @State private var isWorking = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      Form {
        overview
        commands(title: "Current Commands", review: plan.current)
        commands(title: "Update Commands", review: plan.candidate)
        requirements
        changes
        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(theme.statusError)
          }
          .listRowBackground(themedFormRowBackground)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
      .disabled(isWorking)
      Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .settingsActionTint(theme)
          .keyboardShortcut(.cancelAction)
          .disabled(isWorking)
        if isWorking {
          ProgressView()
            .controlSize(.small)
            .tint(theme.isSystem ? nil : theme.accent)
            .padding(.horizontal, 12)
        } else {
          Button("Update Plugin") { Task { await apply() } }
            .settingsActionTint(theme)
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding()
      .themedSurface(.sheet)
    }
    .frame(width: 540, height: 620)
    .themedSurface(.sheet)
  }

  private var overview: some View {
    Section {
      VStack(alignment: .leading, spacing: 5) {
        Text(plan.name).font(.headline)
        Text("\(plan.current.version) → \(plan.candidate.version)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      LabeledContent("Plugin", value: plan.pluginId)
      VStack(alignment: .leading, spacing: 2) {
        Text("Resolved commit")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text(verbatim: plan.resolvedCommit)
          .font(.footnote.monospaced())
          .textSelection(.enabled)
      }
      .padding(.vertical, 1)
    } header: {
      Text("Review Update")
    } footer: {
      Text(
        "Codevisor will apply these exact staged bytes. If the plan expires or the installed plugin changes, you’ll review a new plan."
      )
    }
    .listRowBackground(themedFormRowBackground)
  }

  private func commands(title: String, review: ServerPluginUpdateReview) -> some View {
    Section(title) {
      if review.setupCommands.isEmpty {
        LabeledContent("Setup", value: "None")
      } else {
        ForEach(Array(review.setupCommands.enumerated()), id: \.offset) { index, command in
          commandRow(title: "Setup \(index + 1)", command: command)
        }
      }
      commandRow(title: "Run", command: review.runCommand)
    }
    .listRowBackground(themedFormRowBackground)
  }

  @ViewBuilder
  private var requirements: some View {
    let executables = plan.candidate.requirements?.executables ?? []
    Section("Requirements") {
      if executables.isEmpty {
        Text("None declared").foregroundStyle(.secondary)
      } else {
        ForEach(executables) { requirement in
          VStack(alignment: .leading, spacing: 3) {
            Text(requirement.name).font(.callout.monospaced())
            if let hint = requirement.installHint {
              Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            if let rawUrl = requirement.helpUrl, let url = URL(string: rawUrl) {
              Link("Setup instructions", destination: url).font(.footnote)
            }
          }
          .padding(.vertical, 1)
        }
      }
    }
    .listRowBackground(themedFormRowBackground)
  }

  private var changes: some View {
    Section("Capability Changes") {
      changeRows(label: "Pane", changes: plan.paneChanges)
      changeRows(label: "Tool", changes: plan.toolChanges)
    }
    .listRowBackground(themedFormRowBackground)
  }

  @ViewBuilder
  private func changeRows(label: String, changes: ServerPluginNamedChanges) -> some View {
    if changes.added.isEmpty, changes.removed.isEmpty, changes.changed.isEmpty {
      LabeledContent(label, value: "No changes")
    } else {
      ForEach(changes.added, id: \.self) { name in
        Label("Add \(label.lowercased()) “\(name)”", systemImage: "plus.circle")
          .foregroundStyle(theme.statusOK)
      }
      ForEach(changes.changed, id: \.self) { name in
        Label("Change \(label.lowercased()) “\(name)”", systemImage: "arrow.triangle.2.circlepath")
          .foregroundStyle(theme.statusWarn)
      }
      ForEach(changes.removed, id: \.self) { name in
        Label("Remove \(label.lowercased()) “\(name)”", systemImage: "minus.circle")
          .foregroundStyle(theme.statusError)
      }
    }
  }

  private func commandRow(title: String, command: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.footnote).foregroundStyle(.secondary)
      Text(verbatim: command)
        .font(.footnote.monospaced())
        .textSelection(.enabled)
    }
    .padding(.vertical, 1)
  }

  private var themedFormRowBackground: Color? {
    theme.isSystem ? nil : theme.cardQuietBackground
  }

  private func apply() async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await onApply()
      dismiss()
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
