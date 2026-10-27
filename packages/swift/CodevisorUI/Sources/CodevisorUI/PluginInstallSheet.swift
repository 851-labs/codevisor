import CodevisorCore
import SwiftUI

public struct PluginInstallSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let entry: ServerPluginCatalogEntry
  let install: ([String: ServerConfigFieldValue]) async throws -> Void
  @State private var draft: ConfigFieldDraft
  @State private var working = false
  @State private var errorMessage: String?

  public init(
    entry: ServerPluginCatalogEntry,
    install: @escaping ([String: ServerConfigFieldValue]) async throws -> Void
  ) {
    self.entry = entry
    self.install = install
    _draft = State(initialValue: ConfigFieldDraft(fields: entry.installFields))
  }

  private var subject: PluginModerationSubject { PluginModerationSubject(catalogEntry: entry) }

  public var body: some View {
    let restriction = environment.pluginAccess.restriction(for: subject)
    NavigationStack {
      Form {
        PluginInstallSummary(entry: entry, subject: subject, restriction: restriction)
        if !draft.fields.isEmpty {
          Section("Configuration") {
            ConfigFieldForm(draft: $draft)
          }
        }
        Section {
          PluginConsentNotice(name: entry.name)
          if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
      }
      .formStyle(.grouped)
      .disabled(working)
      .navigationTitle("Install \(entry.name)")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(working)
        }
        ToolbarItem(placement: .confirmationAction) {
          if working {
            ProgressView()
          } else {
            Button("Install") { Task { await submit() } }
              .disabled(!draft.isComplete || restriction != nil)
          }
        }
      }
    }
    #if os(macOS)
      .frame(width: 480, height: 440)
    #endif
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
  let subject: PluginModerationSubject
  let restriction: String?

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.publisher).font(.caption).foregroundStyle(.secondary)
        Text(entry.description)
        PluginCapabilityChips(capabilities: entry.capabilities)
      }
      PluginAgeRatingRow(subject: subject)
    } footer: {
      if let restriction { Text(restriction) }
    }
  }
}
