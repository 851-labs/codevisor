struct BenchOptionParser {
  struct Parsed {
    var values: [String: String] = [:]
    var flags: Set<String> = []
  }

  private static let prefix = "--"

  static func parse(_ arguments: [String]) throws -> Parsed {
    var parser = BenchOptionParser(remaining: arguments[...])
    while let argument = parser.remaining.popFirst() {
      try parser.take(argument)
    }
    return parser.parsed
  }

  private var remaining: ArraySlice<String>
  private var parsed = Parsed()

  private init(remaining: ArraySlice<String>) {
    self.remaining = remaining
  }

  private mutating func take(_ argument: String) throws {
    guard argument.hasPrefix(Self.prefix), argument.count > Self.prefix.count else {
      throw BenchUsageError(message: "expected an option, not \(argument)")
    }

    let body = argument.dropFirst(Self.prefix.count)
    let name = String(body.prefix { $0 != "=" })
    guard parsed.values[name] == nil, !parsed.flags.contains(name) else {
      throw BenchUsageError(message: "--\(name) is given twice")
    }

    record(name, value: inlineValue(of: body) ?? nextValue())
  }

  private mutating func record(_ name: String, value: String?) {
    guard let value, !value.isEmpty else {
      parsed.flags.insert(name)
      return
    }

    parsed.values[name] = value
  }

  private func inlineValue(of body: Substring) -> String? {
    guard let equals = body.firstIndex(of: "=") else { return nil }

    return String(body[body.index(after: equals)...])
  }

  private mutating func nextValue() -> String? {
    guard let next = remaining.first, !next.hasPrefix(Self.prefix) else { return nil }

    return remaining.removeFirst()
  }
}
