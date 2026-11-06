import CodevisorCore
import SwiftUI

struct FloatingPaneView: View {
  let group: PaneGroupModel
  let focus: TerminalFocusController
  let title: (PaneDescriptorState) -> String
  let onCommand: (PaneGroupCommand) -> Bool
  let onReturn: () -> Void

  var body: some View {
    PaneGroupContent(group: group)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        HostWindowCapture { [weak focus] window in
          focus?.hostWindow = window
        }
        .frame(width: 0, height: 0)
      )
      .navigationTitle(group.state.selectedPane.map(title) ?? "")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Return to Workspace", systemImage: "pip.exit", action: onReturn)
            .help("Return to Workspace")
        }
      }
      .onAppear(perform: startHandlingInput)
      .onDisappear { focus.stopTypeToFocus() }
  }

  private func startHandlingInput() {
    focus.workspaceCommandHandler = onCommand
    focus.centerGroup = group
    focus.canFocusChat = { [weak group] chatId in
      group?.state.selectedPane?.chatSessionId == chatId
    }
    focus.startTypeToFocus()
  }
}
