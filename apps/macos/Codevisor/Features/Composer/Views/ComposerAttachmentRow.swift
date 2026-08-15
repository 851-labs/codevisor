import CodevisorCore
import SwiftUI

/// The staged-attachment strip above the composer input: image thumbnails and
/// file chips, each with a hover-revealed remove button and an
/// upload/failed badge.
struct ComposerAttachmentRow: View {
    @Bindable var controller: SessionController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(controller.composerAttachments) { attachment in
                    ComposerAttachmentThumb(
                        attachment: attachment,
                        onRemove: { controller.removeAttachment(id: attachment.id) },
                        onRetry: { controller.retryAttachment(id: attachment.id) }
                    )
                }
            }
        }
    }
}
