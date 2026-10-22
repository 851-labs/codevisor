#if canImport(AppKit)
  import AppKit

  @MainActor
  public protocol TranscriptTextSurface: NSView {
    var transcriptText: NSAttributedString { get }
    var transcriptSelectionHighlight: NSRange? { get set }
    var transcriptFindHighlights: TranscriptFindHighlights? { get set }
    var acceptsTranscriptSelection: Bool { get }
    func transcriptCharacterIndex(at viewPoint: NSPoint) -> Int
    func transcriptTextRects(for range: NSRange) -> [NSRect]
  }

  extension TranscriptTextSurface {
    public var transcriptString: String { transcriptText.string }

    public var transcriptTextLength: Int { transcriptText.length }

    public func transcriptPlainText(in range: NSRange) -> String {
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: transcriptText.length))
      guard clamped.length > 0 else { return "" }
      return (transcriptText.string as NSString).substring(with: clamped)
    }
  }
#endif
