import ScreenSharingBench

@MainActor
enum ClockProbeCheck {
  static let defaultPort = 47_592
  static let durations = 1...7200

  private static let ports = 1...65_535

  static func make(options: BenchOptions) throws -> any CalibrationCheck {
    let port = UInt16(try options.integer("port", default: defaultPort, in: ports))
    let serves = try options.flag("serve")
    let host = try options.string("responder")
    guard serves != (host != nil) else { throw BenchUsageError(message: "pass exactly one of --serve and --responder") }
    guard let host else { return try ClockResponderCheck(options: options, port: port) }

    return try ClockProberCheck(options: options, responder: try responder(host, port: port))
  }

  private static func responder(_ host: String, port: UInt16) throws -> BenchUDPAddress {
    do {
      return try BenchUDPAddress(host: host, port: port)
    } catch {
      throw BenchUsageError(message: "--responder needs an IPv4 address, not \(host)")
    }
  }
}
