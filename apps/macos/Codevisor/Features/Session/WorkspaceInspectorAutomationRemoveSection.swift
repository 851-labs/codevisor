import SwiftUI

struct WorkspaceInspectorAutomationRemoveSection: View {
  let remove: () async -> Bool
  @State private var isConfirming = false
  @State private var isRemoving = false
  @State private var removeFailed = false

  var body: some View {
    Section {
      Button(role: .destructive) {
        isConfirming = true
      } label: {
        Text("Remove Automation…")
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.red)
      .disabled(isRemoving)
    } footer: {
      if removeFailed {
        Label("Couldn't remove this automation.", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    }
    .confirmationDialog("Remove this automation?", isPresented: $isConfirming) {
      Button("Remove Automation", role: .destructive, action: requestRemove)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The agent won't be woken by it again.")
    }
  }

  private func requestRemove() {
    isRemoving = true
    removeFailed = false
    Task {
      guard await remove() else {
        isRemoving = false
        removeFailed = true
        return
      }
    }
  }
}
