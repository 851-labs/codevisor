#if canImport(AppKit)
    import AppKit

    @MainActor
    final class MarkdownTextViewLinkCoordinator: NSObject, NSTextViewDelegate {
        var linkAction: MarkdownLinkAction?

        func install(on textView: NSTextView, action: MarkdownLinkAction?) {
            linkAction = action
            textView.delegate = self
        }

        func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
            handleMarkdownLink(link, action: linkAction)
        }
    }

    extension SelectableTextView.Coordinator: NSTextViewDelegate {
        func install(on textView: NSTextView, action: MarkdownLinkAction?) {
            linkAction = action
            textView.delegate = self
        }

        public func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
            handleMarkdownLink(link, action: linkAction)
        }
    }

    extension SelectableTextView {
        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }
    }

    extension SelectableTextTableView {
        func updateNSView(_ textView: TableTextView, context: Context) {
            context.coordinator.linkAction = linkAction
            textView.update(model: model, renderMemo: renderMemo)
        }
    }

    @MainActor
    private func handleMarkdownLink(_ link: Any, action: MarkdownLinkAction?) -> Bool {
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
