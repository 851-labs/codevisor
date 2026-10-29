import Foundation

struct ResultsPreflight: Decodable {
  struct Quiet: Decodable {
    let load1: Double
    let settledSeconds: Int
  }

  let problems: [String]
  let quiet: Quiet?

  static func read(_ path: String?) throws -> ResultsPreflight? {
    guard let path else { return nil }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(ResultsPreflight.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  var description: String {
    guard problems.isEmpty else { return "**not quiet**: " + problems.joined(separator: "; ") }

    return quiet.map { String(format: "quiet (load %.2f after %d s)", $0.load1, $0.settledSeconds) } ?? "passed"
  }
}
