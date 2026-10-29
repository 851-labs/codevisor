struct QuietActivity {
  static let maximumLoad = 2.0

  let load1: Double
  let busyIndexers: [String]

  var isQuiet: Bool {
    load1 <= Self.maximumLoad && busyIndexers.isEmpty
  }
}
