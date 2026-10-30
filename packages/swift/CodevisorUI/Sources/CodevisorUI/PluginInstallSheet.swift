import CodevisorCore
import SwiftUI

public struct PluginInstallSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let entry: ServerPluginCatalogEntry
  let client: any CodevisorServerClienting
  let install: ([String: ServerConfigFieldValue]) async throws -> Void
  @State private var draft: ConfigFieldDraft
  @State private var working = false
  @State private var errorMessage: String?

  public init(
    entry: ServerPluginCatalogEntry,
    client: any CodevisorServerClienting,
    install: @escaping ([String: ServerConfigFieldValue]) async throws -> Void
  ) {
    self.entry = entry
    self.client = client
    self.install = install
    _draft = State(initialValue: ConfigFieldDraft(fields: entry.installFields))
  }

  private var subject: PluginModerationSubject { PluginModerationSubject(catalogEntry: entry) }

  public var body: some View {
    #if os(macOS)
      form
        .frame(width: 480)
        .frame(maxHeight: 640)
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    #else
      NavigationStack { form }
    #endif
  }

  private var form: some View {
    let restriction = environment.pluginAccess.restriction(for: subject)
    return Form {
      PluginInstallSummary(entry: entry, client: client, subject: subject, restriction: restriction)
      if !draft.fields.isEmpty {
        Section("Configuration") {
          ConfigFieldForm(draft: $draft)
        }
      }
      Section {
        PluginConsentNotice(name: entry.name)
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }
      #if os(iOS)
        if !subject.isFirstParty { PluginModerationSection(subject: subject) }
      #endif
    }
    .formStyle(.grouped)
    .disabled(working)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }.disabled(working)
      }
      ToolbarItem(placement: .confirmationAction) {
        PluginInstallButton(isWorking: working, isEnabled: draft.isComplete && restriction == nil) {
          Task { await submit() }
        }
      }
    }
    .interactiveDismissDisabled(working)
    .task { try? await environment.pluginAccess.refresh() }
  }

  private func submit() async {
    working = true
    defer { working = false }
    do {
      try await install(draft.submittedValues)
      dismiss()
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}

private struct PluginInstallSummary: View {
  let entry: ServerPluginCatalogEntry
  let client: any CodevisorServerClienting
  let subject: PluginModerationSubject
  let restriction: String?

  var body: some View {
    Section {
      SheetHeaderCard(title: entry.name, subtitle: entry.description, subtitleLineLimit: nil) {
        PluginCatalogIcon(entry: entry, client: client, side: 40)
      }
      if !entry.capabilities.isEmpty { PluginCapabilityChips(capabilities: entry.capabilities) }
      #if os(iOS)
        PluginAgeRatingRow(subject: subject)
      #endif
    } footer: {
      if let restriction { Text(restriction) }
    }
  }
}

private struct PluginInstallButton: View {
  let isWorking: Bool
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    #if os(macOS)
      Button(action: action) {
        Text("Install")
          .opacity(isWorking ? 0 : 1)
          .overlay {
            if isWorking { ProgressView().controlSize(.small) }
          }
      }
      .accessibilityLabel(isWorking ? "Installing…" : "Install")
      .disabled(isWorking || !isEnabled)
    #else
      if isWorking {
        ProgressView()
      } else {
        Button("Install", action: action).disabled(!isEnabled)
      }
    #endif
  }
}
