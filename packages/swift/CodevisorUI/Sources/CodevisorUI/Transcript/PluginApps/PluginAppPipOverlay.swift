import CodevisorCore
import SwiftUI

public struct PluginAppPipOverlay: View {
  @Environment(AppEnvironment.self) private var environment
  private let chatSessionId: UUID?
  private let registry: PluginAppDisplayRegistry

  public init(chatSessionId: UUID?) {
    self.chatSessionId = chatSessionId
    self.registry = .shared
  }

  public var body: some View {
    if let model = registry.pip, let chatSessionId, model.chatSessionId == chatSessionId {
      GeometryReader { proxy in
        PluginAppPipWindow(model: model, container: proxy.size)
      }
      .environment(environment)
      .id(model.key)
    }
  }
}
