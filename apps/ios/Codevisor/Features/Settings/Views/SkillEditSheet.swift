import CodevisorCore
import SwiftUI

struct SkillEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  let skill: ServerGlobalSkill
  let machineName: String
  let loadContent: () async throws -> String
  let onSave: (String) async throws -> Void

  @State private var content = ""
  @State private var originalContent: String?
  @State private var isLoading = true
  @State private var isSaving = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Machine", value: machineName)
          LabeledContent("Skill", value: skill.name)
        }
        if isLoading {
          ProgressView("Loading skill…")
        } else if originalContent != nil {
          Section("SKILL.md") {
            TextEditor(text: $content)
              .font(.body.monospaced())
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
              .frame(minHeight: 320)
              .accessibilityLabel("Skill content")
          }
        }
        if let errorMessage {
          Section {
            Text(errorMessage).foregroundStyle(.red)
            if originalContent == nil {
              Button("Retry") { Task { await load() } }
            }
          }
        }
      }
      .disabled(isSaving)
      .navigationTitle("Edit Skill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
          } else {
            Button("Save") { Task { await save() } }
              .disabled(isLoading || originalContent == nil || content == originalContent)
          }
        }
      }
    }
    .interactiveDismissDisabled(isSaving)
    .task { await load() }
  }

  private func load() async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      content = try await loadContent()
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
