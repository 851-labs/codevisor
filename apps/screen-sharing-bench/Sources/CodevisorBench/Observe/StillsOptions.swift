@MainActor
struct StillsOptions {
  static let usage = "[--stills <directory> --stills-versions <version>,<version>…]"

  let directory: String
  let versions: Set<Int>

  static func read(from options: BenchOptions, region: ObserverRegion) throws -> StillsOptions? {
    let directory = try options.string("stills")
    let versions = try options.string("stills-versions")
    guard let directory else {
      guard versions == nil else { throw BenchUsageError(message: "--stills-versions needs --stills") }

      return nil
    }
    guard region == .full else { throw BenchUsageError(message: "--stills needs --region full") }

    return StillsOptions(directory: directory, versions: try parse(versions))
  }

  private static func parse(_ text: String?) throws -> Set<Int> {
    let values = (text ?? "").split(separator: ",").map { Int($0) }
    guard !values.isEmpty, values.allSatisfy({ ($0 ?? -1) >= 0 }) else {
      throw BenchUsageError(message: "--stills-versions needs a comma-separated list of versions")
    }

    return Set(values.compactMap(\.self))
  }
}
