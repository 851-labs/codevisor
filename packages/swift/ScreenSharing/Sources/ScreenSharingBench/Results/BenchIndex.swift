import Foundation

public enum BenchIndex {
  public static let nightlyTrigger = "nightly"

  public static func line(_ entry: BenchIndexEntry) throws -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .custom(BenchReportKey.snakeCase)
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(entry) + Data("\n".utf8)
  }

  public static func entries(_ data: Data) throws -> [BenchIndexEntry] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom(BenchReportKey.camelCase)
    decoder.dateDecodingStrategy = .iso8601
    return try data.split(separator: UInt8(ascii: "\n")).map { try decoder.decode(BenchIndexEntry.self, from: $0) }
  }

  public static func nightlies(like run: BenchRun, in entries: [BenchIndexEntry]) -> [BenchIndexEntry] {
    entries.filter { $0.run.trigger == nightlyTrigger && $0.run.tier == run.tier && $0.run.method == run.method }
  }

  public static func baseline(for cell: BenchCell, in nightlies: [BenchIndexEntry]) -> [BenchGateSample] {
    nightlies.compactMap { entry in entry.cells.first { $0.cell == cell }.map(BenchGateSample.init) }
  }
}
