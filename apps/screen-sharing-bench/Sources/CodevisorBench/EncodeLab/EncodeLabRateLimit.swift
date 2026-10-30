struct EncodeLabRateLimit: Sendable, Codable, Equatable {
  let megabitsPerSecond: Double
  let windowSeconds: Double

  var bytesPerWindow: Int { Int(megabitsPerSecond * 1_000_000 / 8 * windowSeconds) }
}
