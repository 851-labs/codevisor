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
        func updateNSView(_ scrollView: TableScrollView, context: Context) {
            scrollView.tableTextView.linkAction = linkAction
            scrollView.tableTextView.update(model: model, renderMemo: renderMemo)
        }
    }

    @MainActor
    func handleMarkdownLink(_ link: Any, action: MarkdownLinkAction?) -> Bool {
        let url: URL?
        switch link {
        case let value as URL:
            url = value
        case let value as String:
            url = URL(string: value)
        default:
            url = nil
        }
        guard let url, let action else { return false }
        return action(url)
    }
#endif
