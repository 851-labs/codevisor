import CodevisorCore
import Foundation

public struct PluginAppPresenter: Sendable {
  public let open: @MainActor @Sendable (PluginAppPaneResource, UUID?) -> Bool
  public let close: @MainActor @Sendable (UUID) -> Void

  public init(
    open: @escaping @MainActor @Sendable (PluginAppPaneResource, UUID?) -> Bool,
    close: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
  ) {
    self.open = open
    self.close = close
  }
}
