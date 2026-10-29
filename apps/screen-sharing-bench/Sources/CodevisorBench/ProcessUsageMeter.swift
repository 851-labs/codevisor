import Darwin
import ScreenSharingBench

struct ProcessUsageMeter {
  private let start = try? BenchProcessUsage.sample(pid: getpid())

  func loadSinceStart() -> BenchProcessLoad? {
    guard let start, let now = try? BenchProcessUsage.sample(pid: getpid()) else { return nil }

    return BenchProcessLoad(from: start, to: now)
  }
}
