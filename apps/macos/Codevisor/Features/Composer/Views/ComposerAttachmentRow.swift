import CodevisorCore
import CodevisorUI
import SwiftUI

struct ComposerAttachmentRow: View {
  @Bindable var controller: SessionController
  @Environment(\.fileOpener) private var fileOpener

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
    .environment(\.attachmentImages, SessionAttachmentImages.store(for: controller))
    .environment(\.fileOpener, composerFileOpener)
  }

  private var composerFileOpener: FileOpener? {
    let attachments = controller.composerAttachments
    guard var opener = fileOpener?.scoped(to: attachments.map(\.id)) else { return nil }

    opener.siblings = { _ in attachments.compactMap(ViewableFile.init) }
    opener.poster = { _ in nil }
    opener.addToChat = nil
    return opener
  }
}
