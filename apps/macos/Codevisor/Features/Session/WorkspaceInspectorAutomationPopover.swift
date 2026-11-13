import CodevisorUI
import SwiftUI

struct WorkspaceInspectorAutomationPopover: View {
  private static let width: CGFloat = 300

  let event: SubscribedPluginEvent
  let remove: () async -> Bool
  @State private var isRemoving = false
  @State private var removeFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      WorkspaceInspectorAutomationDetails(event: event)
      actions
    }
    .padding(14)
    .frame(width: Self.width, alignment: .leading)
  }

  private var actions: some View {
    HStack {
      if removeFailed {
        Text("Couldn't remove")
          .font(.callout)
          .foregroundStyle(.red)
      }
      Spacer(minLength: 0)
      Button("Remove", role: .destructive, action: requestRemove)
        .disabled(isRemoving)
    }
    .controlSize(.small)
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

private struct WorkspaceInspectorAutomationDetails: View {
  let event: SubscribedPluginEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let note = event.note {
        Text(note)
          .font(.callout)
      }
      Text(event.explained)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .textSelection(.enabled)
    .fixedSize(horizontal: false, vertical: true)
  }
}
