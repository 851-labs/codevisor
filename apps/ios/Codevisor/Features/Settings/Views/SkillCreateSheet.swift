import CodevisorCore
import SwiftUI

struct SkillCreateSheet: View {
  @Environment(\.dismiss) private var dismiss
  let machineName: String
  let onCreate: (String, String, String?) async throws -> Void

  @State private var name = ""
  @State private var skillDescription = ""
  @State private var content = ""
  @State private var isSaving = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Machine", value: machineName)
          TextField("Name", text: $name)
          TextField("Description", text: $skillDescription, axis: .vertical)
            .lineLimit(2...4)
        }
        Section {
          TextEditor(text: $content)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(minHeight: 220)
            .accessibilityLabel("Skill content")
        } header: {
          Text("Instructions")
        } footer: {
          Text("Write instructions or paste a complete SKILL.md. Leave blank to start from a template.")
        }
        if let errorMessage {
          Section {
            Text(errorMessage).foregroundStyle(.red)
          }
        }
      }
      .disabled(isSaving)
      .navigationTitle("New Skill")
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
            Button("Create") { Task { await save() } }
              .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
    .interactiveDismissDisabled(isSaving)
  }

  private func save() async {
    guard !isSaving else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      try await onCreate(name, skillDescription, trimmed.isEmpty ? nil : trimmed)
      dismiss()
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
