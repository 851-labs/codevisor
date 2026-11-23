import Foundation

@MainActor
public enum LayoutAnalytics {
  public static func splitOpened(inBot: Bool, splitCount: Int) {
    Analytics.capture(
      .splitOpened,
      properties: ["in_bot": .boolean(inBot), "split_count": .integer(splitCount)]
    )
  }

  public static func paneOpened(_ kind: PaneKind) {
    guard kind != .newTab else { return }
    Analytics.capture(.paneOpened, properties: ["kind": .string(kind.rawValue)])
  }
}
