import SwiftUI
import CodevisorCore
import CodevisorUI

/// One native-style tab segment in the workspace tab strip.
struct PaneTab: View {
  @Environment(\.theme) private var theme
  let name: String
  let icon: PaneTabIcon
  let isSelected: Bool
  let isDragging: Bool
  let width: CGFloat
  let canClose: Bool
  let showsTrailingSeparator: Bool
  let shortcutHint: String?
  let onSelect: () -> Void
  let onClose: () -> Void
  @State private var isHovered = false
  @State private var isCloseHovered = false

  private var showsHint: Bool { shortcutHint != nil && width >= 90 }
  private var fitsCloseButton: Bool { width >= 64 }
  private var showsIcon: Bool { width >= 48 }
  private var isSliver: Bool { width < 48 }

  private var contentSideReserve: CGFloat {
    if width >= 90 { return 30 }
    if canClose && fitsCloseButton { return 24 }
    return 0
  }

  private var contentPadding: CGFloat { 8 }
  private var capsuleInset: CGFloat { 2 }
  private var barHeight: CGFloat { PaneTabStripStyle.barHeight }
  private var capsuleHeight: CGFloat { barHeight - 2 * capsuleInset }

  var body: some View {
    capsuleContent
      .background {
        Group {
          if isSelected && theme.isSystem {
            Color.clear
              .glassEffect(.regular, in: Capsule())
              .glassEffectTransition(.identity)
              .overlay(Capsule().strokeBorder(theme.border))
          } else if isSelected {
            Capsule()
              .fill(theme.rowSelectedBackground)
              .overlay(Capsule().strokeBorder(theme.border))
          } else {
            Capsule().fill(Color.primary.opacity(isHovered ? 0.06 : 0))
          }
        }
        .transaction { $0.animation = nil }
      }
      .overlay(alignment: .leading) {
        if canClose && isHovered && fitsCloseButton {
          closeButton
            .padding(.leading, capsuleInset + 5)
            .transition(.opacity)
        }
      }
      .overlay(alignment: .trailing) {
        if showsHint, let shortcutHint {
          Text(shortcutHint)
            .font(.caption)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.trailing, capsuleInset + 8)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
      }
      .animation(.easeOut(duration: 0.12), value: showsHint)
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .padding(.horizontal, capsuleInset)
      .frame(width: width, height: barHeight)
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(theme.separator)
          .frame(width: 1, height: 14)
          .offset(x: 0.5)
          .opacity(showsTrailingSeparator ? 1 : 0)
          .animation(.easeOut(duration: 0.12), value: showsTrailingSeparator)
      }
      .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 3, y: 1)
      .contentShape(Rectangle())
      .onTapGesture(perform: onSelect)
      .onHover { isHovered = $0 }
  }

  private var capsuleContent: some View {
    HStack(spacing: 4) {
      if showsIcon {
        icon
          .font(.system(size: Typography.IconSize.chrome, weight: .medium))
          .foregroundStyle(
            isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
          )
          .help(icon.help)
      }
      Text(name)
        .font(.tabLabel())
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
    .padding(.horizontal, isSliver ? 5 : contentPadding)
    .padding(.horizontal, contentSideReserve)
    .frame(maxWidth: .infinity, alignment: isSliver ? .leading : .center)
    .frame(height: capsuleHeight)
  }

  private var closeButton: some View {
    Button(action: onClose) {
      Image(systemName: "xmark")
        .font(.system(size: Typography.IconSize.compact, weight: .bold))
        .foregroundStyle(isCloseHovered ? .primary : .secondary)
        .frame(width: 16, height: 16)
        .background(
          Circle()
            .fill(Color.primary.opacity(isCloseHovered ? 0.14 : 0))
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { isCloseHovered = $0 }
    .help("Close tab")
    .accessibilityLabel("Close \(name)")
  }
}

/// A tab's leading glyph. A chat tab borrows the chat's live status icon and
/// a terminal running an agent shows the working indicator while it works;
/// everything else shows its kind (or its page's or plugin's own artwork).
struct PaneTabIcon: View {
  let kind: PaneKind
  var isAgentOwned = false
  var browserFavicon: NSImage? = nil
  /// A plugin pane's identity, so the tab shows the plugin's own artwork
  /// (fetched through `pluginIconClient`) instead of the generic glyph.
  var pluginId: String? = nil
  var pluginPaneType: String? = nil
  var pluginIconClient: (any CodevisorServerClienting)? = nil
  var pluginIconCacheNamespace = "preview"
  /// The chat a chat tab shows, when it is still known to the session list.
  var chatSession: ChatSession? = nil
  var terminalStatus: AgentPaneStatus? = nil
  /// A subagent tab's harness (its chat's), for the harness icon.
  var subagentHarnessId: String? = nil
  /// A document tab's path, for its file-type icon.
  var documentPath: String? = nil
  var store: SessionStore? = nil

  var body: some View {
    if let chatSession {
      ChatSessionLeadingIcon(session: chatSession, store: store, activityColor: .secondary)
    } else if let terminalStatus {
      AgentStatusIndicator(status: terminalStatus)
        .frame(width: 18)
    } else if kind == .browser, let browserFavicon {
      Image(nsImage: browserFavicon)
        .resizable()
        .scaledToFit()
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    } else if kind == .plugin, let pluginId, let pluginIconClient {
      PluginIconView(
        pluginId: pluginId,
        paneType: pluginPaneType,
        iconPath: "server",
        client: pluginIconClient,
        cacheNamespace: pluginIconCacheNamespace
      )
      .frame(width: 12, height: 12)
    } else if kind == .subagent {
      HarnessIcon(harnessId: subagentHarnessId ?? "", fallbackSymbolName: systemImage)
    } else if kind == .document, let documentPath {
      FileIcon(path: documentPath, size: 14)
    } else {
      Image(systemName: systemImage)
    }
  }

  private var systemImage: String {
    switch kind {
    case .chat: "text.bubble"
    case .terminal: isAgentOwned ? "server.rack" : "terminal"
    case .newTab: "square.dashed"
    case .plugin: "puzzlepiece.extension"
    case .document: "text.document"
    case .browser: "globe"
    case .screenSharing: "display"
    case .simulator: "iphone"
    case .subagent: "wand.and.sparkles"
    case .review: "plusminus"
    }
  }

  var help: String {
    switch kind {
    case .chat: "Chat"
    case .terminal: isAgentOwned ? "Agent background process" : "Terminal"
    case .newTab: "New tab"
    case .plugin: "Plugin pane"
    case .document: "Document"
    case .browser: "Browser"
    case .screenSharing: "Screen sharing"
    case .simulator: "Simulator"
    case .subagent: "Subagent"
    case .review: "Review"
    }
  }
}
