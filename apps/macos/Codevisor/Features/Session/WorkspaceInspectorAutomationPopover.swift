import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorAutomationPopover: View {
  private static let width: CGFloat = 320

  let event: SubscribedPluginEvent
  let serverId: String
  let client: any CodevisorServerClienting
  let remove: () async -> Bool

  var body: some View {
    Form {
      WorkspaceInspectorAutomationTriggerSection(event: event, serverId: serverId, client: client)
      if let note = event.note {
        WorkspaceInspectorAutomationInstructionsSection(note: note)
      }
      WorkspaceInspectorAutomationRemoveSection(remove: remove)
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .scrollDisabled(true)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: Self.width)
  }
}

private struct WorkspaceInspectorAutomationInstructionsSection: View {
  private static let maxNoteHeight: CGFloat = 240

  let note: String

  var body: some View {
    Section("Instructions") {
      ScrollView {
        Text(note)
          .font(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: Self.maxNoteHeight)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
