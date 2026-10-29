import Foundation

enum BenchOutput {
  static func print(_ result: some Encodable) throws {
    let encoder = encoder(pretty: true)
    FileHandle.standardOutput.write(try encoder.encode(result) + newline)
  }

  static func writeLines(_ values: [some Encodable], to path: String) throws {
    let encoder = encoder(pretty: false)
    let lines = try values.map { try encoder.encode($0) + newline }
    try lines.reduce(Data(), +).write(to: URL(fileURLWithPath: path))
  }

  private static let newline = Data("\n".utf8)

  private static func encoder(pretty: Bool) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
    return encoder
  }
}
