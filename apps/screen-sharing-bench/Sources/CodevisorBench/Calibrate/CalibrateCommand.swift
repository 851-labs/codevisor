struct CalibrateCommand: BenchCommand {
  enum Check: String, CaseIterable {
    case c1
    case c2
    case c6
    case onGlass = "on-glass"
  }

  static let name = "calibrate"
  static let summary =
    "Measure the instrument: c1 observer agreement, c2 clock offset, c6 local input-to-photon floor, on-glass estimate"
  static let usage = """
    --check c1 [--duration <seconds>] \(DisplayOption.usage) \(BarcodeOptions.usage)
      calibrate --check c2 --serve [--port <port>] [--duration <seconds>] [--idle-exit <seconds>]
      calibrate --check c2 --responder <ipv4> [--port <port>] [--duration <seconds>] [--interval <seconds>]
        [--output <exchanges.jsonl>]
      calibrate --check c6 [--events <count>] [--seed <n>] [--target window|frontmost] \(DisplayOption.usage)
        \(BarcodeOptions.usage)
      calibrate --check on-glass [--duration <seconds>] \(DisplayOption.usage)
    """

  private let check: any CalibrationCheck

  init(options: BenchOptions) throws {
    switch try Self.check(from: options) {
    case .c1: check = try ObserverAgreementCheck(options: options)
    case .c2: check = try ClockProbeCheck.make(options: options)
    case .c6: check = try InputFloorCheck(options: options)
    case .onGlass: check = try OnGlassCheck(options: options)
    }
  }

  var presentsWindows: Bool {
    check.presentsWindows
  }

  func run() async throws {
    try await check.run()
  }

  private static func check(from options: BenchOptions) throws -> Check {
    guard let name = try options.string("check") else { throw BenchUsageError(message: "--check is required") }
    guard let check = Check(rawValue: name) else {
      throw BenchUsageError(message: "--check must be one of \(Check.allCases.map(\.rawValue)), not \(name)")
    }

    return check
  }
}
