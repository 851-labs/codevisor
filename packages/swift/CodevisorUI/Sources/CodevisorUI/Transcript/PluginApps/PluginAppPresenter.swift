import CodevisorCore
import Foundation

public struct PluginAppPresenter: Sendable {
  public let open:
    @MainActor @Sendable (PluginAppPaneResource, UUID?, PluginAppPanePlacement) -> PluginAppPanePlacement?
  public let close: @MainActor @Sendable (UUID) -> Void
  public let opensInSplit: Bool

  public init(
    opensInSplit: Bool = false,
    open:
      @escaping @MainActor @Sendable (PluginAppPaneResource, UUID?, PluginAppPanePlacement) -> PluginAppPanePlacement?,
    close: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
  ) {
    self.opensInSplit = opensInSplit
    self.open = open
    self.close = close
  }
}
