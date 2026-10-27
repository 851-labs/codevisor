import SwiftUI
import CodevisorCore
import CodevisorUI

struct PaneTab: View {
  let name: String
  let icon: PaneTabIcon
  let isSelected: Bool
  let isDragging: Bool
  let width: CGFloat
  let canClose: Bool
  let showsTrailingSeparator: Bool
  let shortcutHint: String?
  var isPreview = false
  let onSelect: () -> Void
  let onClose: () -> Void
  var onRename: (() -> Void)? = nil
  var onKeep: (() -> Void)? = nil
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
          if isSelected {
            Color.clear
              .glassEffect(.regular, in: Capsule())
              .glassEffectTransition(.identity)
              .overlay(Capsule().strokeBorder(Color.separatorColor))
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
          .fill(Color.separatorColor)
          .frame(width: 1, height: 14)
          .offset(x: 0.5)
          .opacity(showsTrailingSeparator ? 1 : 0)
          .animation(.easeOut(duration: 0.12), value: showsTrailingSeparator)
      }
      .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: 3, y: 1)
      .contentShape(Rectangle())
      .onTapGesture(perform: onSelect)
      .simultaneousGesture(TapGesture(count: 2).onEnded { onKeep?() }, including: onKeep == nil ? .none : .all)
      .onHover { isHovered = $0 }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(name)
      .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction(.default, onSelect)
      .accessibilityActions {
        if let onRename { Button("Rename", action: onRename) }
        if canClose { Button("Close", action: onClose) }
      }
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
        .italic(isPreview)
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

struct PaneTabIcon: View {
  let kind: PaneKind
  var browserFavicon: NSImage? = nil
  var browserFaviconReference: String? = nil
  var browserFaviconClient: (any BrowserFaviconClienting)? = nil
  var pluginId: String? = nil
  var pluginIconClient: (any CodevisorServerClienting)? = nil
  var pluginIconCacheNamespace = "preview"
  var chatSession: ChatSession? = nil
  var terminalStatus: AgentPaneStatus? = nil
  var subagentHarnessId: String? = nil
  var documentPath: String? = nil
  var store: SessionStore? = nil

  var body: some View {
    if let chatSession {
      ChatSessionLeadingIcon(session: chatSession, store: store, activityColor: .secondary)
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
    }
  }
}
