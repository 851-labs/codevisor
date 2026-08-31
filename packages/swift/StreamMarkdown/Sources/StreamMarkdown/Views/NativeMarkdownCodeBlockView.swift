#if canImport(AppKit)
    import AppKit
    import SwiftUI

    @MainActor
    final class NativeMarkdownCodeBlockView: NativeMarkdownContentView {
        /// SwiftUI's caption2 header is 15pt tall after control fitting plus
        /// 6pt vertical padding on each side.
        private static let headerHeight: CGFloat = 27
        private static let dividerHeight: CGFloat = 1
        private static let contentInset: CGFloat = 10

        private let id: String
        private let language: String?
        private let code: String
        private let theme: MarkdownTheme
        private let languageLabel = NSTextField(labelWithString: "")
        private let copyButton = NSButton()
        private let divider = NSBox()
        private let scrollView = TranscriptHorizontalScrollView()
        private let codeTextView = NSTextView(usingTextLayoutManager: true)
        private var highlightTask: Task<Void, Never>?
        private var copyResetTask: Task<Void, Never>?
        private var contentSize = CGSize(width: 1, height: 1)

        init(id: String, language: String?, code: String, theme: MarkdownTheme) {
            self.id = id
            self.language = language
            self.code = code
            self.theme = theme
            super.init(frame: .zero)
            configureChrome()
            configureTextView()
            installInitialText()
            beginHighlightingIfNeeded()
        }

        deinit {
            highlightTask?.cancel()
            copyResetTask?.cancel()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func contentHeight(forWidth _: CGFloat) -> CGFloat {
            Self.headerHeight + Self.dividerHeight + contentSize.height
        }

        override func layout() {
            super.layout()
            let header = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
            languageLabel.sizeToFit()
            languageLabel.frame.origin = NSPoint(
                x: Self.contentInset,
                y: floor((header.height - languageLabel.frame.height) / 2)
            )
            copyButton.sizeToFit()
            copyButton.frame.origin = NSPoint(
                x: max(Self.contentInset, bounds.width - Self.contentInset - copyButton.frame.width),
                y: floor((header.height - copyButton.frame.height) / 2)
            )
            divider.frame = NSRect(
                x: 0,
                y: header.maxY,
                width: bounds.width,
                height: Self.dividerHeight
            )
            scrollView.frame = NSRect(
                x: 0,
                y: divider.frame.maxY,
                width: bounds.width,
                height: contentSize.height
            )
            codeTextView.frame = NSRect(origin: .zero, size: contentSize)
        }

        private func configureChrome() {
            wantsLayer = true
            layer?.backgroundColor = NSColor(theme.codeBackground).cgColor
            layer?.cornerRadius = 8
            layer?.masksToBounds = true

            languageLabel.stringValue = language?.uppercased() ?? "CODE"
            languageLabel.font = .systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .semibold
            )
            languageLabel.textColor = .secondaryLabelColor

            copyButton.title = "Copy"
            copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            copyButton.imagePosition = .imageLeading
            copyButton.isBordered = false
            copyButton.font = .preferredFont(forTextStyle: .caption2)
            copyButton.contentTintColor = .secondaryLabelColor
            copyButton.target = self
            copyButton.action = #selector(copyCode)
            copyButton.toolTip = "Copy code"

            divider.boxType = .separator
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.horizontalScrollElasticity = .automatic
            scrollView.verticalScrollElasticity = .none
            scrollView.documentView = codeTextView

            addSubview(languageLabel)
            addSubview(copyButton)
            addSubview(divider)
            addSubview(scrollView)
        }

        private func configureTextView() {
            codeTextView.isEditable = false
            codeTextView.isSelectable = true
            codeTextView.isRichText = true
            codeTextView.drawsBackground = false
            codeTextView.textContainerInset = NSSize(
                width: Self.contentInset,
                height: Self.contentInset
            )
            codeTextView.isHorizontallyResizable = true
            codeTextView.isVerticallyResizable = true
            codeTextView.minSize = .zero
            codeTextView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            codeTextView.focusRingType = .none
            codeTextView.textContainer?.lineFragmentPadding = 0
            codeTextView.textContainer?.widthTracksTextView = false
        }

        private func installInitialText() {
            let key = CodeHighlightResultCache.Key(
                themeKey: theme.codeThemeKey,
                language: language,
                code: code
            )
            let text = CodeHighlightResultCache.shared.value(for: key) ?? AttributedString(code)
            install(text)
        }

        private func beginHighlightingIfNeeded() {
            guard let highlighter = theme.codeHighlighter else { return }
            let key = CodeHighlightResultCache.Key(
                themeKey: theme.codeThemeKey,
                language: language,
                code: code
            )
            guard CodeHighlightResultCache.shared.value(for: key) == nil else { return }
            let request = CodeHighlightRequest(
                id: id,
                code: code,
                language: language,
                isComplete: true
            )
            highlightTask = Task { @MainActor [weak self] in
                guard let highlighted = await highlighter(request), !Task.isCancelled else { return }
                CodeHighlightResultCache.shared.store(highlighted, for: key)
                self?.install(highlighted)
            }
        }

        private func install(_ text: AttributedString) {
            let native = Self.nativeText(text, foreground: NSColor(theme.codeForeground))
            codeTextView.textStorage?.setAttributedString(native)
            let bounds = native.boundingRect(
                with: NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            contentSize = CGSize(
                width: max(1, ceil(bounds.width) + Self.contentInset * 2),
                height: max(1, ceil(bounds.height) + Self.contentInset * 2)
            )
            needsLayout = true
            needsDisplay = true
        }

        private static func nativeText(
            _ text: AttributedString,
            foreground: NSColor
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let font = NSFont.monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                weight: .regular
            )
            for run in text.runs {
                result.append(
                    NSAttributedString(
                        string: String(text[run.range].characters),
                        attributes: [
                            .font: font,
                            .foregroundColor: run.foregroundColor.map(NSColor.init) ?? foreground,
                        ]
                    )
                )
            }
            return result
        }

        @objc private func copyCode() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            copyButton.title = "Copied"
            copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            copyResetTask?.cancel()
            copyResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.copyButton.title = "Copy"
                self?.copyButton.image = NSImage(
                    systemSymbolName: "doc.on.doc",
                    accessibilityDescription: nil
                )
            }
        }
    }
#endif
