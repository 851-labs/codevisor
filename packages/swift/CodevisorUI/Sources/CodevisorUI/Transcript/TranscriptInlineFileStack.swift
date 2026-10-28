import SwiftUI
import TranscriptKit

public struct TranscriptInlineFileStack<Thumbnail: View>: View {
  private let files: [PreviewFile]
  private let alignment: HorizontalAlignment
  private let thumbnail: (PreviewFile) -> Thumbnail

  public init(
    files: [PreviewFile], alignment: HorizontalAlignment = .leading,
    @ViewBuilder thumbnail: @escaping (PreviewFile) -> Thumbnail
  ) {
    self.files = files
    self.alignment = alignment
    self.thumbnail = thumbnail
  }

  public var body: some View {
    if !files.isEmpty {
      VStack(alignment: alignment, spacing: 8) {
        ForEach(files) { file in
          TranscriptInlineFile(file: file, label: file.name, showsCaption: false) { thumbnail(file) }
        }
      }
      .padding(alignment == .trailing ? .leading : .trailing, Self.inset)
    }
  }

  private static var inset: CGFloat { 40 }
}
