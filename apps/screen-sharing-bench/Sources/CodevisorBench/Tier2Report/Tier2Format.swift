enum Tier2Format {
  static func number(_ value: Double?) -> String {
    guard let value else { return "–" }

    return String(format: abs(value) >= 100 ? "%.0f" : "%.1f", value)
  }

  static func list(_ values: [Double]) -> String {
    values.map { number($0) }.joined(separator: ", ")
  }
}
