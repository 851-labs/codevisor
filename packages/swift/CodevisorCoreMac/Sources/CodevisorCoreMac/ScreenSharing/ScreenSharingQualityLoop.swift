import Foundation
import ScreenSharing

@MainActor
enum ScreenSharingQualityLoop {
  static let fullQualityBitrate = 6_000_000
  static let estimateWarmUp: TimeInterval = 5

  static func run(
    base: () -> ScreenSharingVideoConfiguration?,
    isViewing: () -> Bool,
    statistics: () async -> [String: String],
    apply: (ScreenSharingVideoConfiguration, _ level: Int) async -> Bool
  ) async {
    guard var current = base() else { return }
    var quality = adaptive(current)
    while !Task.isCancelled {
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let latest = base() else { return }
      if latest != current {
        current = latest
        quality = adaptive(latest)
      }
      guard isViewing() else { continue }
      let statistics = await statistics()
      guard !Task.isCancelled, let settled = base() else { return }
      guard settled == current, isViewing() else { continue }
      let bandwidth = statistics.first { $0.key.hasSuffix(".availableOutgoingBitrate") }.flatMap { Double($0.value) }
      guard let configuration = quality.update(availableBitrate: bandwidth, now: ProcessInfo.processInfo.systemUptime)
      else { continue }
      guard await apply(configuration, quality.level) else { return }
    }
  }

  private static func adaptive(_ configuration: ScreenSharingVideoConfiguration) -> ScreenSharingAdaptiveQuality {
    ScreenSharingAdaptiveQuality(
      configuration: configuration, fullQualityBitrate: fullQualityBitrate, warmUp: estimateWarmUp)
  }
}
