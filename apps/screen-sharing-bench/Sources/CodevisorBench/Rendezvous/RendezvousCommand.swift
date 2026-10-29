import ScreenSharingBench

struct RendezvousCommand: BenchCommand {
  static let name = "rendezvous"
  static let summary = "Meet the other Mac at a named barrier (Tier 2 host and viewer jobs)"
  static let usage = """
    --serve [--port <port>] [--duration <seconds>]
      rendezvous --host <ipv4> --barrier <name> --party host|viewer [--status ok|<reason>] [--agree] [--port <port>]
        [--duration <seconds>]
    """

  static let defaultPort: UInt16 = 47_595
  private static let durations = 1...86_400
  private static let ports = 1...65_535

  let presentsWindows = false
  private let port: UInt16
  private let duration: Duration
  private let arrival: RendezvousArrival?
  private let host: String?
  private let agree: Bool

  init(options: BenchOptions) throws {
    port = UInt16(try options.integer("port", default: Int(Self.defaultPort), in: Self.ports))
    duration = .seconds(try options.integer("duration", default: 14_400, in: Self.durations))
    let serves = try options.flag("serve")
    host = try options.string("host")
    agree = try options.flag("agree")
    arrival = try RendezvousArrival(options: options)
    guard serves == (host == nil), serves == (arrival == nil) else {
      throw BenchUsageError(message: "pass either --serve, or --host with --barrier and --party")
    }
  }

  func run() async throws {
    guard let host, let arrival else { return try await RendezvousServer.serve(port: port, for: duration) }

    let meeting = try await RendezvousClient.meet(host: host, port: port, arrival: arrival, timeout: duration)
    try BenchOutput.print(meeting)
    guard agree ? meeting.allAgree : meeting.allReady else { throw RendezvousNotReady(meeting: meeting) }
  }
}

struct RendezvousNotReady: Error, CustomStringConvertible {
  let meeting: RendezvousMeeting

  var description: String {
    "\(meeting.barrier): \(meeting.statuses)"
  }
}
