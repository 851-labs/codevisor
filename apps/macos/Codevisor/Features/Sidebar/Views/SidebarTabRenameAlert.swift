import CodevisorUI
import SwiftUI

struct SidebarTabRename: Equatable {
  let workspaceId: UUID
  let tabId: UUID
  var title: String
}

struct SidebarTabRenameAlert: ViewModifier {
  @Binding var renaming: SidebarTabRename?
  let onRename: (SidebarTabRename) -> Void

  func body(content: Content) -> some View {
    content
      .alert("Rename Tab", isPresented: isPresented, presenting: renaming) { request in
        TextField("Title", text: title)
        Button("Rename") { onRename(request) }
        Button("Cancel", role: .cancel) {}
      }
      .focusesAlertTextField(when: renaming != nil)
  }

  private var isPresented: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }

  private var title: Binding<String> {
    Binding(get: { renaming?.title ?? "" }, set: { renaming?.title = $0 })
  }
}
