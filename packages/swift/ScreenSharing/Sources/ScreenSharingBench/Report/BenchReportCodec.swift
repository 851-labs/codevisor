import Foundation

public enum BenchReportCodec {
  public static func encode(_ report: BenchReport) throws -> Data {
    try requireValid(report)
    return try encoder.encode(report)
  }

  public static func decode(_ data: Data) throws -> BenchReport {
    let report = try decoder.decode(BenchReport.self, from: data)
    try requireValid(report)
    return report
  }

  public static func write(_ report: BenchReport, to url: URL) throws {
    try encode(report).write(to: url, options: .atomic)
  }

  private static func requireValid(_ report: BenchReport) throws {
    let issues = report.validationIssues
    guard issues.isEmpty else { throw BenchReportError.invalid(issues) }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .custom(BenchReportKey.snakeCase)
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom(BenchReportKey.camelCase)
    decoder.dateDecodingStrategy = .custom(decodeDate)
    return decoder
  }

  private static func decodeDate(from decoder: any Decoder) throws -> Date {
    let text = try decoder.singleValueContainer().decode(String.self)
    let formats = [Date.ISO8601FormatStyle(), Date.ISO8601FormatStyle(includingFractionalSeconds: true)]
    guard let date = formats.lazy.compactMap({ try? $0.parse(text) }).first else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "\(text) is not ISO 8601"))
    }

    return date
  }
}

public enum BenchReportError: Error, Equatable {
  case invalid([String])
}
