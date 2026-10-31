import CodevisorCore
import CodevisorUI
import SwiftUI

struct AttachmentImageStoreHost: ViewModifier {
  let controller: SessionController?
  @State private var store: AttachmentImageStore?

  func body(content: Content) -> some View {
    content
      .onChange(of: StoreIdentity(controller), initial: true) {
        store = controller.map(Self.makeStore)
      }
      .transformEnvironment(\.attachmentImages) { inherited in
        if let store { inherited = store }
      }
  }

  private static func makeStore(for controller: SessionController) -> AttachmentImageStore {
    AttachmentImageStore(
      namespace: controller.previewCacheNamespace,
      fetch: { [weak controller] source in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.fileData(for: source)
      },
      fetchPreview: { [weak controller] source in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.filePreview(for: source)
      },
      fetchPrefix: { [weak controller] source, length in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.filePrefix(for: source, length: length)
      },
      version: { [weak controller] source in
        guard let controller else { throw SessionControllerError.serverUnavailable }
        return try await controller.fileVersion(for: source)
      }
    )
  }

  private struct StoreIdentity: Equatable {
    let controller: ObjectIdentifier?
    let namespace: String?

    init(_ controller: SessionController?) {
      self.controller = controller.map(ObjectIdentifier.init)
      namespace = controller?.previewCacheNamespace
    }
  }
}

extension View {
  func attachmentImageStore(_ controller: SessionController?) -> some View {
    modifier(AttachmentImageStoreHost(controller: controller))
  }
}
