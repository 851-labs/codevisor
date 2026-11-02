import StreamMarkdown
import SwiftUI
import TranscriptKit

public struct TranscriptInlineFile<Thumbnail: View>: View {
  @Environment(\.markdownBlockChrome) private var chrome
  private let file: PreviewFile
  private let label: String
  private let showsCaption: Bool
  private let thumbnail: Thumbnail

  public init(
    file: PreviewFile, label: String, showsCaption: Bool = true, @ViewBuilder thumbnail: () -> Thumbnail
  ) {
    self.file = file
    self.label = label
    self.showsCaption = showsCaption
    self.thumbnail = thumbnail()
  }

  public var body: some View {
    if chrome.drawsFrame {
      framed
    } else {
      bubbled
    }
  }

  @ViewBuilder private var framed: some View {
    if file.showsTextPreview {
      TranscriptFilePreview(file: file) { captioned }
    } else {
      captioned
    }
  }

  @ViewBuilder private var bubbled: some View {
    if file.isPatch {
      TranscriptFilePreview(file: file) { captioned }
    } else if let delimiter = file.tableDelimiter {
      TranscriptBotTablePreview(file: file, delimiter: delimiter) { captioned }
    } else {
      captioned
    }
  }

  private var captioned: TranscriptCaptionedThumbnail<Thumbnail> {
    TranscriptCaptionedThumbnail(file: file, label: label, showsCaption: showsCaption, thumbnail: thumbnail)
  }
}
