import Darwin
import Foundation

@MainActor
final class PlayerCPUClock {
  private var origin: (cpu: Double, wall: Double)?

  func start() {
    origin = Self.now()
  }

  func percentOfOneCore() -> Double {
    guard let origin else { return 0 }

    let end = Self.now()
    let wall = end.wall - origin.wall
    return wall > 0 ? (end.cpu - origin.cpu) / wall * 100 : 0
  }

  private static func now() -> (cpu: Double, wall: Double) {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return (seconds(usage.ru_utime) + seconds(usage.ru_stime), ProcessInfo.processInfo.systemUptime)
  }

  private static func seconds(_ time: timeval) -> Double {
    Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
  }
}
