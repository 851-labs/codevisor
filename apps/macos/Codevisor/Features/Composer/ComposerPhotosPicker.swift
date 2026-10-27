import CodevisorCore
import PhotosUI
import SwiftUI

struct ComposerPhotosPicker: ViewModifier {
  @Binding var isPresented: Bool
  let controller: SessionController
  @State private var items: [PhotosPickerItem] = []

  func body(content: Content) -> some View {
    content
      .photosPicker(
        isPresented: $isPresented, selection: $items, matching: .images, preferredItemEncoding: .compatible
      )
      .onChange(of: items) { _, picked in
        guard !picked.isEmpty else { return }
        items = []
        picked.forEach(attach)
      }
  }

  private func attach(_ item: PhotosPickerItem) {
    let type = item.supportedContentTypes.first { $0.conforms(to: .image) } ?? .jpeg
    Task {
      guard let data = try? await item.loadTransferable(type: Data.self) else { return }
      controller.attachments.attachPhotoData(data, mimeType: type.preferredMIMEType ?? "image/jpeg")
    }
  }
}
