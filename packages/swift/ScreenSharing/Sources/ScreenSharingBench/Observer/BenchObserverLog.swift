import Foundation

public struct BenchObserverLog: Sendable, Equatable {
  public var header: BenchObserverHeader
  public var observations: [BenchObservation]

  public init(header: BenchObserverHeader, observations: [BenchObservation]) {
    self.header = header
    self.observations = observations
  }

  public init(jsonLines: Data) throws {
    let lines = jsonLines.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    guard let first = lines.first else { throw BenchObserverLogError.missingHeader }

    let decoder = Self.decoder
    header = try decoder.decode(BenchObserverHeader.self, from: Data(first))
    guard header.schema == BenchObserverHeader.currentSchema else {
      throw BenchObserverLogError.unsupportedSchema(header.schema)
    }

    observations = try lines.dropFirst().map { try decoder.decode(BenchObservation.self, from: Data($0)) }
  }

  public func jsonLines() throws -> Data {
    let encoder = Self.encoder
    var data = try encoder.encode(header)
    for observation in observations {
      data.append(UInt8(ascii: "\n"))
      data.append(try encoder.encode(observation))
    }
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public var versions: BenchObservedVersions {
    BenchObservedVersions(observations)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .custom(BenchReportKey.snakeCase)
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom(BenchReportKey.camelCase)
    return decoder
  }
}

public enum BenchObserverLogError: Error, Equatable {
  case missingHeader
  case unsupportedSchema(String)
}
