import Foundation
import TranscriptKit

public enum FileTextPreview: Equatable, Sendable {
  case text(FileTextExcerpt)
  case diff(UnifiedDiff, isTruncated: Bool)
  case missing
  case binary
  case unavailable

  public init(data: Data, isPatch: Bool = false) {
    guard let excerpt = FileTextExcerpt(data: data) else {
      self = .binary
      return
    }
    guard isPatch, let diff = UnifiedDiff(parsing: excerpt.content) else {
      self = .text(excerpt)
      return
    }
    self = .diff(diff, isTruncated: excerpt.isTruncated)
  }
}
