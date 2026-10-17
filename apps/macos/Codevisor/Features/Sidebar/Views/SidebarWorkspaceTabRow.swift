import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceTabRow: View {
  let title: String
  let kind: PaneKind
  var browserFavicon: NSImage? = nil
  var pluginId: String? = nil
  var pluginPaneType: String? = nil
  var pluginIconClient: (any CodevisorServerClienting)? = nil
  var pluginIconCacheNamespace = "preview"
  let chatSession: ChatSession?
  var terminalStatus: AgentPaneStatus? = nil
  var subagentHarnessId: String? = nil
  let store: SessionStore?
  let isSelected: Bool
  let isReordering: Bool
  let titleFont: Font
  let onActivate: () -> Void
  let onClose: () -> Void
  var onRename: (() -> Void)? = nil
  @GestureState private var isPressed = false

  var body: some View {
    HoverableRow(
      isSelected: isSelected,
      isHoverEnabled: !isReordering,
      isHoverForced: false
    ) { isHovered in
      HStack(spacing: 7) {
        HStack(spacing: 7) {
          leadingIcon
          Text(title)
            .font(titleFont)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .updating($isPressed) { _, isPressed, _ in
              guard !isPressed else { return }
              isPressed = true
              onActivate()
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onActivate)
        .accessibilityActions {
          if let onRename { Button("Rename", action: onRename) }
          Button("Close", action: onClose)
        }
        if isHovered {
          Button(action: onClose) {
            Image(systemName: "xmark")
              .font(.caption2.weight(.semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Close")
          .accessibilityLabel("Close \(title)")
          .frame(width: 24, height: 14, alignment: .trailing)
        }
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .foregroundStyle(.primary)
    }
    .contextMenu {
      if let onRename {
        Button {
          onRename()
        } label: {
          Label("Rename", systemImage: "pencil")
            .labelStyle(.titleAndIcon)
        }
      }

      if let chatSession {
        ChatSessionUnreadMenuItem(session: chatSession, store: store)
      }

      Button {
        onClose()
      } label: {
        Label("Close", systemImage: "xmark")
          .labelStyle(.titleAndIcon)
      }
    }
  }

  @ViewBuilder
  private var leadingIcon: some View {
    if let chatSession {
      ChatSessionLeadingIcon(session: chatSession, store: store, activityColor: .secondary)
        .foregroundStyle(.secondary)
    } else if let terminalStatus {
      AgentStatusIndicator(status: terminalStatus)
        .frame(width: 18)
    } else if kind == .browser, let browserFavicon {
      Image(nsImage: browserFavicon)
        .resizable()
        .scaledToFit()
        .frame(width: 14, height: 14)
        .frame(width: 18)
        .accessibilityHidden(true)
    } else if kind == .plugin, let pluginId, let pluginIconClient {
      PluginIconView(
        pluginId: pluginId,
        paneType: pluginPaneType,
        iconPath: "server",
        client: pluginIconClient,
        cacheNamespace: pluginIconCacheNamespace
      )
      .frame(width: 14, height: 14)
      .frame(width: 18)
    } else if kind == .subagent {
      HarnessIcon(harnessId: subagentHarnessId ?? "", fallbackSymbolName: kind.tabFallbackSymbolName)
        .frame(width: 18)
        .foregroundStyle(.secondary)
    } else if kind == .document {
      FileIcon(path: title, size: 16).frame(width: 18)
    } else {
      Image(systemName: kind.tabFallbackSymbolName)
        .frame(width: 18)
        .foregroundStyle(.secondary)
    }
  }

}
