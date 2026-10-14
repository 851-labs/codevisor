import CodevisorCore
import SwiftUI

struct ComposerAttachmentRow: View {
  @Bindable var controller: SessionController

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(controller.composerAttachments) { attachment in
          ComposerAttachmentThumb(
            attachment: attachment,
            onRemove: { controller.attachments.removeAttachment(id: attachment.id) },
            onRetry: { controller.attachments.retryAttachment(id: attachment.id) }
          )
        }
      }
    }
  }
}
