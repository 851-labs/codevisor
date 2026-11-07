import CodevisorCore
import SwiftUI

struct AttachmentDropModifier: ViewModifier {
  let controller: SessionController?
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .activeWorkspaceDropDestination {
        Color.clear.onDrop(
          of: AttachmentDropDelegate.acceptedTypes,
          delegate: AttachmentDropDelegate(attachments: controller?.attachments, isTargeted: $isTargeted)
        )
      }
      .overlay {
        if isTargeted && controller != nil {
          DropToAttachOverlay()
        }
      }
  }
}

extension View {
  func attachmentDropTarget(_ controller: SessionController?) -> some View {
    modifier(AttachmentDropModifier(controller: controller))
  }
}
