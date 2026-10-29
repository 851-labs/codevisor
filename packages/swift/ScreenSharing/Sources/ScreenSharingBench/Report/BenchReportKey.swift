struct BenchReportKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }

  static func snakeCase(_ path: [any CodingKey]) -> any CodingKey {
    let key = path[path.count - 1]
    guard key.intValue == nil else { return key }

    let words = key.stringValue.map { $0.isUppercase ? "_" + $0.lowercased() : String($0) }
    return BenchReportKey(stringValue: words.joined())
  }

  static func camelCase(_ path: [any CodingKey]) -> any CodingKey {
    let key = path[path.count - 1]
    guard key.intValue == nil else { return key }

    let words = key.stringValue.split(separator: "_", omittingEmptySubsequences: false)
    let rest = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
    return BenchReportKey(stringValue: ([String(words.first ?? "")] + rest).joined())
  }
}
