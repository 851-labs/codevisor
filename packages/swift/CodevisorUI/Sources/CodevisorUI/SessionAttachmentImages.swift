import CodevisorCore
import Foundation

@MainActor
public enum SessionAttachmentImages {
  private static let stores = NSMapTable<SessionController, AttachmentImageStore>.weakToStrongObjects()

  public static func store(for chat: SessionController) -> AttachmentImageStore {
    let controller = chat.fileSource ?? chat
    let namespace = controller.previewCacheNamespace
    if let store = stores.object(forKey: controller), store.namespace == namespace { return store }
    let store = makeStore(reading: controller, namespace: namespace)
    stores.setObject(store, forKey: controller)
    return store
  }

  private static func makeStore(reading controller: SessionController, namespace: String) -> AttachmentImageStore {
    AttachmentImageStore(
      namespace: namespace,
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
}
