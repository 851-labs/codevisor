import CodevisorCore
import SwiftUI

/// Editing one skill's SKILL.md. The canonical store is fleet-replicated by
/// content hash, so an edit here lands everywhere — the sheet says so rather
/// than naming one machine, which is what the per-machine pages used to do.
/// Shared by both apps: the Mac had no skill editor at all before, even
/// though the endpoint and the phone's sheet already existed.
public struct SkillEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  private let name: String
  private let load: () async throws -> String
  private let onSave: (String) async throws -> Void

  @State private var content = ""
  @State private var originalContent: String?
  @State private var isLoading = true
  @State private var isSaving = false
  @State private var errorMessage: String?

  public init(
    name: String,
    load: @escaping () async throws -> String,
    onSave: @escaping (String) async throws -> Void
  ) {
    self.name = name
    self.load = load
    self.onSave = onSave
  }

  public var body: some View {
    #if os(macOS)
      VStack(spacing: 0) {
        form
        SheetFooter {
          Button("Cancel") { dismiss() }.disabled(isSaving)
          Button("Save") { Task { await save() } }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
      }
      .frame(width: 560, height: 520)
      .task { await reload() }
    #else
      NavigationStack {
        form
          .navigationTitle("Edit Skill")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { dismiss() }.disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
              if isSaving {
                ProgressView()
              } else {
                Button("Save") { Task { await save() } }.disabled(!canSave)
              }
            }
          }
      }
      .interactiveDismissDisabled(isSaving)
      .task { await reload() }
    #endif
  }

  private var canSave: Bool {
    !isLoading && !isSaving && originalContent != nil && content != originalContent
  }

  private var form: some View {
    Form {
      Section {
        LabeledContent("Skill", value: name)
      }
      if isLoading {
        ProgressView("Loading skill…")
      } else if originalContent != nil {
        Section("SKILL.md") {
          TextEditor(text: $content)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .frame(minHeight: 300)
            .accessibilityLabel("Skill content")
        }
      }
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(theme.statusWarn)
          if originalContent == nil {
            Button("Retry") { Task { await reload() } }
          }
        }
      }
    }
    .disabled(isSaving)
    #if os(macOS)
      .formStyle(.grouped)
    #endif
  }

  private func reload() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      content = try await load()
      originalContent = content
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func save() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      try await onSave(content)
      dismiss()
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
