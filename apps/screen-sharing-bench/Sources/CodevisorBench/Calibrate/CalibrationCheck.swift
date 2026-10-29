@MainActor
protocol CalibrationCheck {
  func run() async throws
}

struct CalibrationFailed: Error, CustomStringConvertible {
  let check: String

  var description: String {
    "\(check) did not pass; the JSON result says why"
  }
}
