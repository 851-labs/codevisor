public enum BenchInputRegion: String, CaseIterable, Sendable, Codable {
  case large
  case small

  var points: Int {
    switch self {
    case .large: 400
    case .small: 16
    }
  }
}
