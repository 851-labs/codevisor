import AppKit
import CodevisorUI
import MarkdownCore
import StreamMarkdown
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  enum RowRenderer {
    case markdown
    case botBubble
    case botImage
    case hosted
  }

  enum NativeBotPart {
    case bubble(messageID: String, content: TranscriptBotMessageContent, layout: TranscriptBotBubbleLayout)
    case image(source: String, alt: String)
  }

  func renderer(for row: TranscriptVirtualRow) -> RowRenderer {
    if usesNativeMarkdownHost(for: row) { return .markdown }
    switch nativeBotPart(for: row) {
    case .bubble: return .botBubble
    case .image: return .botImage
    case nil: return .hosted
    }
  }

  func renderer(of host: TranscriptMountedRowHost) -> RowRenderer {
    if host is TranscriptMarkdownRowHost { return .markdown }
    if host is TranscriptBotBubbleRowHost { return .botBubble }
    if host is TranscriptBotImageRowHost { return .botImage }
    return .hosted
  }

  func nativeBotPart(for row: TranscriptVirtualRow) -> NativeBotPart? {
    guard case let .botMessage(message, content, _) = row.content,
      message.sender == .bot, message.app == nil, content.files.isEmpty
    else { return nil }

    if case let .image(source, alt) = content.partStyle { return .image(source: source, alt: alt) }
    guard let layout = TranscriptBotBubbleLayout.forPart(content.partStyle), rendersNatively(content) else {
      return nil
    }

    return .bubble(messageID: message.id, content: content, layout: layout)
  }

  func mountNativeBotPart(
    _ part: NativeBotPart, row: TranscriptVirtualRow, at index: Int, requiresImmediatePresentation: Bool
  ) -> Bool {
    let key = row.layoutKey
    let host = takeHost(for: part, key: key)
    host.prepareForMountedRow()
    host.onHeightChange = { [weak self] height in
      self?.recordMeasuredHeight(height, for: key)
    }
    transcriptDocumentView.addSubview(host)
    mountedHosts[key] = host
    position(host: host, at: index)
    show(part, in: host, knownHeight: settledMeasuredHeight(of: row))
    if requiresImmediatePresentation, !host.isPresentationReady {
      host.prepareForImmediatePresentation()
    }
    sendTransitions.hostDidMount(host, key: key)
    return true
  }

  func refreshNativeBotPart(_ host: TranscriptMountedRowHost, for row: TranscriptVirtualRow) {
    guard let part = nativeBotPart(for: row) else { return }

    show(part, in: host, knownHeight: settledMeasuredHeight(of: row))
  }

  func storeDetachedBotPart(_ host: TranscriptMountedRowHost, for key: String) {
    let keepsHost = host.isPresentationReady && rowByKey[key] != nil
    if let bubble = host as? TranscriptBotBubbleRowHost {
      store(bubble, for: key, keepsHost: keepsHost, in: &hostPool.bubbles)
    } else if let image = host as? TranscriptBotImageRowHost {
      store(image, for: key, keepsHost: keepsHost, in: &hostPool.images)
    }
  }

  private func store<Host: TranscriptMountedRowHost>(
    _ host: Host, for key: String, keepsHost: Bool, in shelf: inout TranscriptKeyedHostShelf<Host>
  ) {
    guard keepsHost else {
      shelf.recycle(host)
      return
    }

    shelf.park(host, for: key)
  }

  private func rendersNatively(_ content: TranscriptBotMessageContent) -> Bool {
    !content.text.isEmpty && !content.blocks.isEmpty
      && !MarkdownLayoutPolicy.requiresBackgroundTextLayout(content.blocks)
  }

  private func takeHost(for part: NativeBotPart, key: String) -> TranscriptMountedRowHost {
    switch part {
    case .bubble: hostPool.bubbles.take(for: key) { TranscriptBotBubbleRowHost(frame: .zero) }
    case .image: hostPool.images.take(for: key) { TranscriptBotImageRowHost(frame: .zero) }
    }
  }

  private func show(_ part: NativeBotPart, in host: TranscriptMountedRowHost, knownHeight: CGFloat?) {
    switch part {
    case let .bubble(messageID, content, layout):
      (host as? TranscriptBotBubbleRowHost)?.setContent(
        content, messageID: messageID, layout: layout, style: markdownRowStyle, linkAction: markdownLinkAction,
        imageLoader: markdownImageLoader, knownHeight: knownHeight)
    case let .image(source, alt):
      (host as? TranscriptBotImageRowHost)?.setContent(
        source: source, alt: alt, linkAction: markdownLinkAction, imageLoader: markdownImageLoader,
        knownHeight: knownHeight)
    }
  }
}
