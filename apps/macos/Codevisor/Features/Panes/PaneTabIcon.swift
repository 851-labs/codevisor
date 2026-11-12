import SwiftUI
import CodevisorCore
import CodevisorUI

struct PaneTabIcon: View {
  let kind: PaneKind
  var browserFavicon: NSImage? = nil
  var browserFaviconReference: String? = nil
  var browserFaviconClient: (any BrowserFaviconClienting)? = nil
  var pluginId: String? = nil
  var pluginIconClient: (any CodevisorServerClienting)? = nil
  var pluginIconCacheNamespace = "preview"
  var chatSession: ChatSession? = nil
  var isQuietChat = false
  var terminalStatus: AgentPaneStatus? = nil
  var subagentHarnessId: String? = nil
  var documentPath: String? = nil
  var store: SessionStore? = nil

  var body: some View {
    if let chatSession {
      ChatSessionLeadingIcon(session: chatSession, store: store, activityColor: .secondary, isQuiet: isQuietChat)
    } else if let terminalStatus {
      AgentStatusIndicator(status: terminalStatus)
        .frame(width: 18)
    } else if kind == .browser, let browserFavicon {
      favicon(Image(nsImage: browserFavicon))
    } else if kind == .browser {
      BrowserFaviconImage(reference: browserFaviconReference, client: browserFaviconClient) { image in
        favicon(image)
      } placeholder: {
        Image(systemName: systemImage)
      }
    } else if kind == .plugin, let pluginId, let pluginIconClient {
      PluginIconView(
        pluginId: pluginId,
        client: pluginIconClient,
        cacheNamespace: pluginIconCacheNamespace,
        side: 12
      )
      .frame(width: 12, height: 12)
    } else if kind == .subagent {
      HarnessIcon(
        harnessId: subagentHarnessId ?? "", fallbackSymbolName: systemImage, size: Typography.IconSize.chrome,
        weight: .medium)
    } else if kind == .document, let documentPath {
      FileIcon(path: documentPath, size: 14)
    } else {
      Image(systemName: systemImage)
    }
  }

  private func favicon(_ image: Image) -> some View {
    image
      .resizable()
      .scaledToFit()
      .frame(width: 14, height: 14)
      .accessibilityHidden(true)
  }

  private var systemImage: String {
    switch kind {
    case .chat: "text.bubble"
    case .terminal: "terminal"
    case .newTab: "square.dashed"
    case .plugin: "puzzlepiece.extension"
    case .document: "text.document"
    case .browser: "globe"
    case .screenSharing: "display"
    case .simulator: "iphone"
    case .subagent: "wand.and.sparkles"
    case .review: "plusminus"
    case .transcript: "text.page"
    case .childAgent: "text.bubble"
    }
  }

  var help: String {
    switch kind {
    case .chat: "Chat"
    case .terminal: "Terminal"
    case .newTab: "New tab"
    case .plugin: "Plugin pane"
    case .document: "Document"
    case .browser: "Browser"
    case .screenSharing: "Screen sharing"
    case .simulator: "Simulator"
    case .subagent: "Subagent"
    case .review: "Review"
    case .transcript: "Full transcript"
    case .childAgent: "Child agent"
    }
  }
}

extension PaneTabIcon {
  @MainActor
  static func workspaceTab(
    _ descriptor: PaneDescriptorState?,
    title: String,
    serverId: String,
    environment: AppEnvironment,
    store: SessionStore
  ) -> PaneTabIcon {
    let chatSession = descriptor.flatMap { pane -> ChatSession? in
      guard pane.kind == .chat || pane.kind == .childAgent, let id = pane.chatSessionId else { return nil }
      return environment.projectList.session(id, serverId: pane.chatMachineId(hostedOn: serverId))
    }
    let subagentHarnessId = descriptor.flatMap { pane -> String? in
      guard pane.kind == .subagent, let ownerId = pane.ownerChatSessionId else { return nil }
      return environment.projectList.session(ownerId, serverId: serverId)?.harnessId
    }
    return PaneTabIcon(
      kind: descriptor?.kind ?? .newTab,
      browserFavicon: descriptor.flatMap {
        $0.kind == .browser ? store.localBrowserModel(paneId: $0.id)?.favicon : nil
      },
      browserFaviconReference: descriptor?.browserFavicon,
      browserFaviconClient: environment.machines.client(for: serverId),
      pluginId: descriptor?.pluginId,
      pluginIconClient: environment.machines.client(for: serverId),
      pluginIconCacheNamespace: serverId,
      chatSession: chatSession,
      isQuietChat: descriptor?.kind == .childAgent,
      terminalStatus: descriptor?.terminalAgentStatus,
      subagentHarnessId: subagentHarnessId,
      documentPath: title,
      store: store
    )
  }
}
