import ACPKit
import CodevisorCore
import StreamMarkdown
import SwiftUI
import TranscriptKit

/// Text replaces its lightweight snapshot as this row enters the viewport.
/// There is no second disclosure or page navigation surface.
public struct TranscriptInlineTextPageView: View {
  let page: TranscriptInlineTextPage
  var userMessage: ((UserMessage) -> AnyView)?
  @Environment(\.transcriptController) private var controller
  @Environment(\.transcriptInvalidateRowMeasurement) private var invalidateMeasurement
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.theme) private var theme
  @State private var model = TranscriptInlineTextModel()
  private var text: String? { model.content?.displayText }
  private var markdownPrefix: String { model.content?.markdownPrefix ?? "" }
  @State private var retry = 0

  public init(page: TranscriptInlineTextPage, userMessage: ((UserMessage) -> AnyView)? = nil) {
    self.page = page
    self.userMessage = userMessage
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let message = page.userMessage, let userMessage {
        userMessage(
          UserMessage(
            id: message.id, text: text ?? page.preview,
            attachments: page.isLast ? message.attachments : []))
      } else if page.isPlan {
        PlanDocumentView(markdown: markdownPrefix + (text ?? page.preview))
      } else if !(text ?? page.preview).isEmpty {
        StreamingMarkdownView(
          markdownPrefix + (text ?? page.preview), isComplete: true,
          foregroundColor: theme.textPrimary, animationEnabled: false)
      }
      if let error = model.errorMessage {
        HStack {
          Text(error).font(.caption).foregroundStyle(.secondary)
          Button("Retry") { retry += 1 }
        }
      } else if text == nil {
        ProgressView().controlSize(.small).padding(.vertical, 8)
      }
    }
    .environment(\.transcriptCopyResource, page.resource)
    .environment(\.markdownImageLoader, attachmentImages?.markdownImageLoader ?? .remote)
    .task(
      id:
        "\(page.resource.itemId):\(page.resource.entryKey):\(page.position):\(page.generation):\(page.isLast ? page.revision : 0):\(retry)"
    ) {
      guard let controller else { return }
      model.load(page, using: controller)
    }
    .onChange(of: model.content?.displayText) { _, _ in invalidateMeasurement?() }
    .onDisappear { model.cancel() }
  }
}

/// Nested subagent transcripts use a bounded scroll viewport. Main transcript
/// pages are individual native virtual rows through TranscriptRowContentView.
public struct TranscriptInlineTextView: View {
  let resource: ToolDetailResource
  let preview: String
  public init(resource: ToolDetailResource, preview: String = "") {
    self.resource = resource
    self.preview = preview
  }

  public var body: some View {
    let positions = TranscriptInlineTextPage.positions(for: resource)
    if positions.count == 1 {
      TranscriptInlineTextPageView(page: .init(resource: resource, position: 0, preview: preview))
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(positions, id: \.self) { position in
            TranscriptInlineTextPageView(
              page: .init(
                resource: resource, position: position,
                preview: position == 0 ? preview : ""))
          }
        }
      }.frame(maxHeight: 600)
    }
  }
}
