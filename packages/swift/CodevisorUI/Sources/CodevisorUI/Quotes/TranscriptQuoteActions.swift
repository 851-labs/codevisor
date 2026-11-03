import CodevisorCore
import SwiftUI
import TranscriptKit

@MainActor
public struct TranscriptQuoteActions {
  public let reveal: @MainActor (TranscriptQuote) -> Void
  public let addImage: @MainActor (PreviewFile) -> Void
  public let addRemoteImage: @MainActor (URL) -> Void
  public let addText: (@MainActor (String) -> Void)?

  public init(controller: SessionController, row: TranscriptPresentationRow? = nil) {
    reveal = { [weak controller] quote in controller?.revealQuote(quote) }
    addImage = { [weak controller] file in controller?.addTranscriptImage(file) }
    addRemoteImage = { [weak controller] url in controller?.addRemoteImage(url) }
    addText = Self.addText(to: controller, from: row)
  }

  private static func addText(
    to controller: SessionController, from row: TranscriptPresentationRow?
  ) -> (@MainActor (String) -> Void)? {
    guard let row, TranscriptQuote.messageID(forRowKey: row.layoutKey) != nil else { return nil }
    return { [weak controller] text in
      guard let quote = TranscriptQuote(text: text, row: row) else { return }
      controller?.addQuote(quote)
    }
  }

  public func addImage(at url: URL) {
    if let file = documentImagePreviewFile(url.relativeString) { return addImage(file) }
    guard ["http", "https"].contains(url.scheme?.lowercased()) else { return }
    addRemoteImage(url)
  }
}

extension EnvironmentValues {
  @Entry public var transcriptQuoteActions: TranscriptQuoteActions? = nil
}
