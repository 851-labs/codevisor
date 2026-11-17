import CodevisorCore
import Foundation

public struct PluginAppPresenter: Sendable, Equatable {
  public let open:
    @MainActor @Sendable (PluginAppPaneResource, UUID?, PluginAppPanePlacement) -> PluginAppPanePlacement?
  public let close: @MainActor @Sendable (UUID) -> Void
  public let opensInSplit: Bool
  private let identity: HandlerIdentity

  public init(
    identity: HandlerIdentity,
    opensInSplit: Bool = false,
    open:
      @escaping @MainActor @Sendable (PluginAppPaneResource, UUID?, PluginAppPanePlacement) -> PluginAppPanePlacement?,
    close: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
  ) {
    self.identity = identity
    self.opensInSplit = opensInSplit
    self.open = open
    self.close = close
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity && lhs.opensInSplit == rhs.opensInSplit
  }
}
