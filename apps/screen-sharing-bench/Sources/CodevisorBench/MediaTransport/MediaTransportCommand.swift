import CodevisorNet
import Foundation

/// The engine v2 transport bench (851-3815) inside the signed app, where macOS lets it reach the other Mac. The
/// `viewer`, `host`, `loopback` and `send-cost` roles run `codevisor_media::bench` in Rust; `ffi-cost` times the
/// per-frame hand-off across the Swift–Rust boundary.
struct MediaTransportCommand: BenchCommand {
  enum Role: String, CaseIterable {
    case viewer, host, loopback
    case sendCost = "send-cost"
    case ffiCost = "ffi-cost"
  }

  static let name = "media-transport"
  static let summary = "Measure the engine v2 transport (codevisor-media) over iroh and plain UDP, or its FFI hand-off"
  static let usage =
    "--role viewer|host|loopback|send-cost|ffi-cost [--network N0…N7] [--rows all|0,3] [--seconds <s>] "
    + "[--bind <addr> --udp-bind <addr> --secret <hex> --idle-exit-s <s>] "
    + "[--peer-id <id> | --peer-secret <hex>, --peer <addr> --udp-peer <addr> --connect-patience-s <s>] "
    + "[--network-label <text>] [--json <path>] [--frames <n>]"

  private static let passedThrough = [
    "network", "network-label", "rows", "seconds", "bind", "udp-bind", "secret", "idle-exit-s", "peer-id",
    "peer-secret", "peer", "udp-peer", "connect-patience-s", "json",
  ]

  let presentsWindows = false
  private let role: Role
  private let arguments: [String]
  private let frames: Int

  init(options: BenchOptions) throws {
    role = try options.choice("role", default: Role.loopback)
    frames = try options.integer("frames", default: 300, in: 10...10_000)
    var arguments = [role.rawValue]
    for name in Self.passedThrough {
      if let value = try options.string(name) { arguments += ["--\(name)", value] }
    }
    if role == .sendCost { arguments += ["--frames", String(frames)] }
    self.arguments = arguments
  }

  func run() async throws {
    let report =
      role == .ffiCost ? try await MediaHandOff.measure(frames: frames) : try await mediaBenchRun(args: arguments)
    FileHandle.standardOutput.write(Data(report.utf8))
  }
}
