import CodevisorCore
import SwiftUI

struct SkillImportSheet: View {
  @Environment(\.dismiss) private var dismiss
  let machineName: String
  let discover: (String) async throws -> [ServerRemoteSkillCandidate]
  let onImport: (String, [String]) async throws -> Void

  @State private var source = ""
  @State private var candidates: [ServerRemoteSkillCandidate]?
  @State private var selection: Set<String> = []
  @State private var isWorking = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Machine", value: machineName)
          TextField(
            "Source", text: $source,
            prompt: Text(verbatim: "owner/repo or a URL")
          )
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .disabled(candidates != nil)
          .onSubmit { Task { await find() } }
        } footer: {
          Text("Enter a GitHub or GitLab repository, a git URL, or a website that publishes skills.")
        }
        if let candidates {
          Section("Skills Found (\(candidates.count))") {
            if candidates.isEmpty {
              Text("No skills found at this source.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(candidates) { candidate in
                candidateRow(candidate)
              }
            }
          }
          let selectable = candidates.filter { !$0.alreadyExists }
          if !selectable.isEmpty {
            Section {
              Button(selection.count == selectable.count ? "Deselect All" : "Select All") {
                selection = selection.count == selectable.count ? [] : Set(selectable.map(\.directoryName))
              }
            }
          }
        }
        if let errorMessage {
          Section {
            Text(errorMessage).foregroundStyle(.red)
          }
        }
      }
      .disabled(isWorking)
      .navigationTitle("Import Skill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if candidates == nil {
            Button("Cancel") { dismiss() }
              .disabled(isWorking)
          } else {
            Button("Back") {
              candidates = nil
              selection = []
              errorMessage = nil
            }
            .disabled(isWorking)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if isWorking {
            ProgressView()
          } else if candidates == nil {
            Button("Find") { Task { await find() } }
              .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          } else {
            Button("Import (\(selection.count))") { Task { await runImport() } }
              .disabled(selection.isEmpty)
          }
        }
      }
    }
    .interactiveDismissDisabled(isWorking)
  }

  private func candidateRow(_ candidate: ServerRemoteSkillCandidate) -> some View {
    Button {
      if selection.contains(candidate.directoryName) {
        selection.remove(candidate.directoryName)
      } else {
        selection.insert(candidate.directoryName)
      }
    } label: {
      HStack(spacing: 12) {
        Image(
          systemName: candidate.alreadyExists || selection.contains(candidate.directoryName)
            ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(candidate.alreadyExists ? Color.secondary : Color.accentColor)
        VStack(alignment: .leading, spacing: 3) {
          Text(candidate.name).foregroundStyle(.primary)
          if let description = candidate.description, !description.isEmpty {
            Text(description)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          if candidate.alreadyExists {
            Text("Already added")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .disabled(candidate.alreadyExists)
    .accessibilityValue(
      candidate.alreadyExists
        ? "Already added"
        : selection.contains(candidate.directoryName)
          ? "Selected" : "Not selected")
  }

  private func find() async {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isWorking, candidates == nil, !trimmed.isEmpty else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      let found = try await discover(trimmed)
      candidates = found
      selection = Set(found.filter { !$0.alreadyExists }.map(\.directoryName))
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func runImport() async {
    guard !isWorking, !selection.isEmpty else { return }
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
    do {
      try await onImport(source.trimmingCharacters(in: .whitespacesAndNewlines), selection.sorted())
      dismiss()
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
