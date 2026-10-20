import StreamMarkdown
import SwiftUI
import TranscriptKit

public struct TranscriptFilePreview<Fallback: View>: View {
  @Environment(\.attachmentImages) private var attachmentImages
  @State private var loaded: FileTextPreview?
  @State private var layoutWaitExpired = false
  private let file: PreviewFile
  private let fallback: Fallback

  public init(file: PreviewFile, @ViewBuilder fallback: () -> Fallback) {
    self.file = file
    self.fallback = fallback()
  }

  public var body: some View {
    content
      .task(id: loadID) { await load() }
      .task(id: loadID) { await expireLayoutWait() }
      .preference(key: ContentLayoutReadinessPreferenceKey.self, value: holdsLayout ? 1 : 0)
  }

  @ViewBuilder private var content: some View {
    switch preview {
    case let .text(excerpt): TranscriptFileCodeBlock(file: file, excerpt: excerpt)
    case let .diff(diff, isTruncated): TranscriptDiffPreview(file: file, diff: diff, isTruncated: isTruncated)
    case .missing: TranscriptMissingFileRow(file: file)
    case .binary, .unavailable: fallback
    case nil: TranscriptFileLoadingRow(file: file)
    }
  }

  private var preview: FileTextPreview? {
    if attachmentImages == nil { return .unavailable }
    return loaded ?? attachmentImages.flatMap { FileTextPreviews.shared.cached(file, in: $0) }
  }

  private var holdsLayout: Bool { preview == nil && !layoutWaitExpired }

  private var loadID: TranscriptFilePreviewLoadID {
    TranscriptFilePreviewLoadID(file: file, store: attachmentImages)
  }

  private func load() async {
    guard let attachmentImages, preview == nil else { return }
    let result = await FileTextPreviews.shared.load(file, from: attachmentImages)
    guard !Task.isCancelled else { return }
    loaded = result
  }

  private func expireLayoutWait() async {
    try? await Task.sleep(for: .milliseconds(Self.layoutWaitMilliseconds))
    guard !Task.isCancelled else { return }
    layoutWaitExpired = true
  }

  private static var layoutWaitMilliseconds: Int { 600 }
}

private struct TranscriptFilePreviewLoadID: Hashable {
  let fileID: String
  let storeID: ObjectIdentifier?

  init(file: PreviewFile, store: AttachmentImageStore?) {
    fileID = file.id
    storeID = store.map { ObjectIdentifier($0) }
  }
}
