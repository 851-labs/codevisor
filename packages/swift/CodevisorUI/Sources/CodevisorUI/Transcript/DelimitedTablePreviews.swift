import Foundation
import TranscriptKit

@MainActor
final class DelimitedTablePreviews {
  enum Result: Equatable {
    case table(DelimitedTablePreview)
    case unreadable
  }

  static let shared = DelimitedTablePreviews()
  private var results: [String: Result] = [:]

  func cached(_ file: PreviewFile) -> Result? {
    results[file.id]
  }

  func load(_ file: PreviewFile, delimiter: Character, from store: AttachmentImageStore) async -> Result {
    if let cached = results[file.id] { return cached }
    let data = try? await store.data(for: file.source)
    let result = await Self.parse(data, delimiter: delimiter)
    results[file.id] = result
    return result
  }

  @concurrent
  private nonisolated static func parse(_ data: Data?, delimiter: Character) async -> Result {
    guard let data, let table = DelimitedTablePreview(data: data, delimiter: delimiter) else { return .unreadable }
    return .table(table)
  }
}
