import ScreenSharingBench
import Synchronization

final class VersionRelay: Sendable {
  private let sender: BenchVersionSender
  private let latest = Mutex(0)

  init(target: BenchUDPAddress) throws {
    sender = try BenchVersionSender(target: target)
  }

  @MainActor
  static func target(from options: BenchOptions) throws -> BenchUDPAddress? {
    guard let text = try options.string("relay") else { return nil }

    let parts = text.split(separator: ":")
    guard parts.count == 2, let port = UInt16(parts[1]),
      let target = try? BenchUDPAddress(host: String(parts[0]), port: port)
    else { throw BenchUsageError(message: "--relay needs <ipv4>:<port>, not \(text)") }

    return target
  }

  func forward(_ observation: BenchObservation) {
    guard let version = observation.version, isNew(version) else { return }

    try? sender.send(BenchVersionMessage(version: version, hostOnGlassNs: observation.ptsNs))
  }

  private func isNew(_ version: Int) -> Bool {
    latest.withLock { latest in
      guard version > latest else { return false }

      latest = version
      return true
    }
  }
}
