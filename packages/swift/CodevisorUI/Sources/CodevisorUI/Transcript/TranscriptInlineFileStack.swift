import SwiftUI
import TranscriptKit

public struct TranscriptInlineFileStack<Thumbnail: View>: View {
  private let files: [PreviewFile]
  private let thumbnail: (PreviewFile) -> Thumbnail

  public init(files: [PreviewFile], @ViewBuilder thumbnail: @escaping (PreviewFile) -> Thumbnail) {
    self.files = files
    self.thumbnail = thumbnail
  }

  public var body: some View {
    if !files.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(files) { file in
          TranscriptInlineFile(file: file, label: file.name, showsCaption: false) { thumbnail(file) }
        }
      }
      .padding(.trailing, Self.trailingInset)
    }
  }

  private static var trailingInset: CGFloat { 40 }
}
