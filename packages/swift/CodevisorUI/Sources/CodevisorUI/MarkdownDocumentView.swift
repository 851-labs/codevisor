import CodevisorCore
import StreamMarkdown
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// A complete document rendered with the same theme and Markdown engine as chat.
public struct MarkdownDocumentView: View {
  private let openLink: ((URL) -> Bool)?
  @Environment(\.theme) private var theme
  @Environment(\.codeHighlightTheme) private var codeHighlightTheme
  @State private var document: MarkdownDocumentModel

  public init(
    path: String,
    sessionId: UUID,
    client: any CodevisorServerClienting,
    openLink: ((URL) -> Bool)? = nil
  ) {
    self.init(
      document: MarkdownDocumentModel(path: path, sessionId: sessionId, client: client),
      openLink: openLink
    )
  }

  public init(document: MarkdownDocumentModel, openLink: ((URL) -> Bool)? = nil) {
    _document = State(initialValue: document)
    self.openLink = openLink
  }

  public var body: some View {
    Group {
      if let error = document.failure {
        ContentUnavailableView {
          Label(error.title, systemImage: "doc.questionmark")
        } description: {
          Text(error.message)
            .frame(maxWidth: 420)
        } actions: {
          Button("Try Again") {
            document.refresh()
          }
        }
      } else if let content = document.content {
        ScrollView {
          documentContent(content)
            .frame(maxWidth: 860, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .markdownLinkHandler { url in openLink?(url) ?? false }
        .environment(
          \.markdownTheme,
          makeMarkdownTheme(
            theme: theme, highlight: codeHighlightTheme.map { ($0.key, $0.json) }
          )
        )
      } else {
        Color.clear
          .overlay(alignment: .top) {
            if document.showsLoadingProgress {
              ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Loading document")
            }
          }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { document.refresh() }
    .onDisappear { document.cancelLoading() }
  }

  @ViewBuilder
  private func documentContent(_ content: MarkdownDocumentModel.Content) -> some View {
    #if canImport(AppKit)
      if !content.blocks.isEmpty {
        NativeMarkdownDocument(blocks: content.blocks, documentID: document.path)
      }
    #else
      StreamingMarkdownView(content.text)
    #endif
  }
}

#if canImport(AppKit)
  private struct NativeMarkdownDocument: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let documentID: String
    @Environment(\.markdownTheme) private var theme
    @Environment(\.markdownLinkAction) private var linkAction

    func makeNSView(context: Context) -> SettledMarkdownView {
      SettledMarkdownView()
    }

    func updateNSView(_ view: SettledMarkdownView, context: Context) {
      view.setContent(blocks: blocks, theme: theme, streamID: documentID, linkAction: linkAction)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView: SettledMarkdownView, context: Context
    ) -> CGSize? {
      let width = max(1, proposal.width ?? 860)
      return CGSize(width: width, height: ceil(nsView.contentHeight(forWidth: width)))
    }
  }
#endif
