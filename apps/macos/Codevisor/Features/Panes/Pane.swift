import Foundation
import SwiftUI
import CodevisorCore
import CodevisorCoreMac
import CodevisorCloud

struct PaneContext {
  let paneId: UUID
  let sessionId: UUID?
  let terminalKey: String
  let machine: CodevisorMachine
  let session: ChatSession?
  let project: Project
  var workspaceRootDirectory: String? = nil
  var workspaceId: UUID? = nil
  var client: (any CodevisorServerClienting)? = nil
  var resolveHTTPBaseURL: (@MainActor () async -> URL?)? = nil
  var resolveServerConfig: (@MainActor () -> CodevisorServerConfig)? = nil
  var openTunnelMedia: ScreenSharingViewerBackend.TunnelMediaProvider? = nil
  var openTunnelRoute: (@MainActor () async -> CloudTunnelMediaRoute?)? = nil
}

enum PaneGroupCommand {
  case previousTab
  case nextTab
  case previousTabInWorkspace
  case nextTabInWorkspace
  case newTab
  case selectTab(Int)
  case previousWorkspace
  case nextWorkspace
  case split(SplitEdge)
  case focusSplit(SplitEdge)
  case previousSplit
  case nextSplit
  case closeTab
  case reopenClosedPane
}

@MainActor
protocol Pane: AnyObject {
  var id: UUID { get }
  var kind: PaneKind { get }

  var onGroupCommand: ((PaneGroupCommand) -> Void)? { get set }

  var onFocusChanged: ((Bool) -> Void)? { get set }

  func makeView() -> AnyView

  func focus()

  func visibilityChanged(_ visible: Bool)

  func willDelete() async

  func detach()
}
