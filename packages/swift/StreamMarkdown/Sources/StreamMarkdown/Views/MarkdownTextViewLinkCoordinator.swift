#if canImport(AppKit)
  import AppKit

  extension NSAttributedString.Key {
    /// A session-server file reference that looks like a link but remains
    /// owned by the host instead of AppKit's URL-opening machinery.
    static let streamMarkdownServerFileLink = NSAttributedString.Key(
      "com.codevisor.streamMarkdownServerFileLink"
    )
  }

  func markdownUsesServerFileLinkAttribute(_ url: URL) -> Bool {
    let target = url.relativeString
    guard !target.hasPrefix("#"), !target.hasPrefix("//") else { return false }
    return url.isFileURL || url.scheme == nil
  }

  @MainActor
  final class MarkdownTextViewLinkCoordinator: NSObject {
    func install(on textView: TranscriptSelectableTextView, action: MarkdownLinkAction?) {
      textView.linkAction = action
    }
  }

  extension SelectableTextView {
    public func makeCoordinator() -> Coordinator {
      Coordinator()
    }
  }

  extension SelectableTextTableView {
    func updateNSView(_ container: TableBleedContainer, context: Context) {
      container.bleedLimit = bleedLimit
      container.scrollView.tableTextView.linkAction = linkAction
      container.scrollView.tableTextView.update(model: model, renderMemo: renderMemo)
      container.scrollView.setBorderColor(NSColor(model.theme.tableBorderColor))
    }
  }

  @MainActor
  func handleMarkdownLink(_ link: Any, isImage: Bool = false, action: MarkdownLinkAction?) -> Bool {
    guard let url = markdownLinkURL(link), let action else { return false }
    return action.activate(url, isImage: isImage)
  }

  func markdownLinkURL(_ link: Any) -> URL? {
    switch link {
    case let value as URL: value
    case let value as String: URL(string: value)
    default: nil
    }
  }
#endif
