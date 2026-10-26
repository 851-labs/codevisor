import Foundation

@MainActor
public final class BrowserPageClosing {
  public static let shared = BrowserPageClosing()
  public private(set) var appIsClosingPages = false

  public init() {}

  public func appWillClosePages() { appIsClosingPages = true }

  public func closesTab(whenClosedByPage closedByPage: Bool) -> Bool {
    closedByPage && !appIsClosingPages
  }
}
