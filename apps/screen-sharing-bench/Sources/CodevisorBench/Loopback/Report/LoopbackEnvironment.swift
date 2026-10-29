import Darwin
import Foundation
import ScreenSharingBench

enum LoopbackEnvironment {
  static let link = "in-process UDP relay"

  static func current(_ settings: LoopbackSettings) async throws -> BenchEnvironment {
    let host = BenchMachine(
      name: BenchHostName.current, chip: chip, os: operatingSystem,
      display: display(settings), load1AtStart: loadAverage,
      thermal: thermal, spotlightBusy: !(try await QuietMachine.busyIndexers().isEmpty))
    return BenchEnvironment(host: host, link: link)
  }

  private static func display(_ settings: LoopbackSettings) -> String {
    let canvas = settings.canvas
    let source = settings.source == .ownWindow ? "own window on the \(settings.display.rawValue) display" : "synthetic"
    return "\(canvas.pixelWidth)x\(canvas.pixelHeight) \(canvas.scale)x, \(source), \(settings.endpoint.rawValue)"
  }

  private static var chip: String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }

    var text = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &text, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: text.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }

  private static var operatingSystem: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion)"
  }

  private static var loadAverage: Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : 0
  }

  private static var thermal: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
