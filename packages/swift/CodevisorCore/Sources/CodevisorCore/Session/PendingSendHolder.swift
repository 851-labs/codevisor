import Foundation

@MainActor
public final class PendingSendHolder {
  private struct Key: Hashable {
    let serverId: String
    let sessionId: UUID
  }

  private struct Held {
    let controller: SessionController
    weak var owner: AnyObject?
  }

  private var held: [Key: Held] = [:]

  public init() {}

  public func track(_ controller: SessionController, ownedBy owner: AnyObject) {
    controller.onPendingSendsChange = { [weak self, weak controller, weak owner] in
      guard let self, let controller else { return }
      update(controller, owner: owner)
    }
    update(controller, owner: owner)
  }

  public func adopt(serverId: String, sessionId: UUID, by owner: AnyObject) -> SessionController? {
    let key = Key(serverId: serverId, sessionId: sessionId)
    guard let entry = held[key], entry.owner == nil || entry.owner === owner else { return nil }
    return entry.controller
  }

  private func update(_ controller: SessionController, owner: AnyObject?) {
    guard let sessionId = controller.serverSession?.id else { return }
    let key = Key(serverId: controller.project.serverId, sessionId: sessionId)
    if controller.hasPendingSends {
      held[key] = Held(controller: controller, owner: owner)
    } else if held[key]?.controller === controller {
      held[key] = nil
    }
  }
}
