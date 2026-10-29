@MainActor
final class BenchOptions {
  private let values: [String: String]
  private let flags: Set<String>
  private var read: Set<String> = []

  init(_ arguments: [String]) throws {
    let parsed = try BenchOptionParser.parse(arguments)
    values = parsed.values
    flags = parsed.flags
  }

  func string(_ name: String) throws -> String? {
    read.insert(name)
    guard !flags.contains(name) else { throw BenchUsageError(message: "--\(name) needs a value") }

    return values[name]
  }

  func string(_ name: String, default fallback: String) throws -> String {
    try string(name) ?? fallback
  }

  func integer(_ name: String, default fallback: Int, in range: ClosedRange<Int> = Int.min...Int.max) throws -> Int {
    guard let text = try string(name) else { return fallback }
    guard let value = Int(text), range.contains(value) else {
      throw BenchUsageError(message: "--\(name) needs an integer in \(range), not \(text)")
    }

    return value
  }

  func flag(_ name: String) throws -> Bool {
    read.insert(name)
    guard values[name] == nil else { throw BenchUsageError(message: "--\(name) takes no value") }

    return flags.contains(name)
  }

  func choice<Choice>(_ name: String, default fallback: Choice) throws -> Choice
  where Choice: RawRepresentable & CaseIterable, Choice.RawValue == String {
    guard let text = try string(name) else { return fallback }
    guard let value = Choice(rawValue: text) else {
      let choices = Choice.allCases.map(\.rawValue).joined(separator: ", ")
      throw BenchUsageError(message: "--\(name) must be one of \(choices), not \(text)")
    }

    return value
  }

  func rejectUnread() throws {
    let unknown = Set(values.keys).union(flags).subtracting(read).sorted()
    guard unknown.isEmpty else {
      throw BenchUsageError(message: "unknown option \(unknown.map { "--\($0)" }.joined(separator: ", "))")
    }
  }
}
