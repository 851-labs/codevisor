import Foundation

extension Workspace {
  public var isPlainChat: Bool {
    guard !isArchived, centerTabs.count == 1, case let .group(_, state) = centerTabs[0].root else { return false }

    return state.panes.count == 1 && state.panes[0].kind == .chat
  }
}
