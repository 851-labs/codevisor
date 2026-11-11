import AppKit
import CodevisorUI
import MarkdownCore
import StreamMarkdown
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  enum RowRenderer {
    case markdown
    case botBubble
    case hosted
  }

  struct NativeBotBubble {
    let messageID: String
    let content: TranscriptBotMessageContent
  }

  func renderer(for row: TranscriptVirtualRow) -> RowRenderer {
    if usesNativeMarkdownHost(for: row) { return .markdown }
    if nativeBotBubble(for: row) != nil { return .botBubble }
    return .hosted
  }

  func renderer(of host: TranscriptMountedRowHost) -> RowRenderer {
    if host is TranscriptMarkdownRowHost { return .markdown }
    if host is TranscriptBotBubbleRowHost { return .botBubble }
    return .hosted
  }

  func nativeBotBubble(for row: TranscriptVirtualRow) -> NativeBotBubble? {
    guard case let .botMessage(message, content, _) = row.content,
      message.sender == .bot, message.app == nil, content.files.isEmpty, content.partStyle == .text,
      !content.text.isEmpty, !content.blocks.isEmpty,
      !MarkdownLayoutPolicy.requiresBackgroundTextLayout(content.blocks)
    else { return nil }

    return NativeBotBubble(messageID: message.id, content: content)
  }

  func mountBotBubbleRow(
    _ row: TranscriptVirtualRow, bubble: NativeBotBubble, at index: Int, requiresImmediatePresentation: Bool
  ) -> Bool {
    let key = row.layoutKey
    let host = hostPool.takeBubble(for: key)
    host.prepareForMountedRow()
    host.onHeightChange = { [weak self] height in
      self?.recordMeasuredHeight(height, for: key)
    }
    transcriptDocumentView.addSubview(host)
    mountedHosts[key] = host
    position(host: host, at: index)
    show(bubble, in: host, knownHeight: settledMeasuredHeight(of: row))
    if requiresImmediatePresentation, !host.isPresentationReady {
      host.prepareForImmediatePresentation()
    }
    sendTransitions.hostDidMount(host, key: key)
    return true
  }

  func refreshBotBubble(_ host: TranscriptBotBubbleRowHost, for row: TranscriptVirtualRow) {
    guard let bubble = nativeBotBubble(for: row) else { return }

    show(bubble, in: host, knownHeight: settledMeasuredHeight(of: row))
  }

  func storeDetachedBubble(_ host: TranscriptBotBubbleRowHost, for key: String) {
    guard host.isPresentationReady, rowByKey[key] != nil else {
      hostPool.recycleBubble(host)
      return
    }

    hostPool.parkBubble(host, for: key)
  }

  private func show(_ bubble: NativeBotBubble, in host: TranscriptBotBubbleRowHost, knownHeight: CGFloat?) {
    host.setContent(
      bubble.content, messageID: bubble.messageID, style: markdownRowStyle, linkAction: markdownLinkAction,
      imageLoader: markdownImageLoader, knownHeight: knownHeight)
  }
}
