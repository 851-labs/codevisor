import CoreGraphics
import Foundation

/// Which rows of a planned window are fully presentable. Used by the bottom
/// jump, initial presentation, and window promotion gates.
public enum TranscriptMountedWindowReadiness {
  /// The keys whose measurement is committed (present and not stale) and
  /// whose host reports ready.
  public static func resolvedKeys(
    required: Set<String>,
    measurements: TranscriptMeasurementLedger,
    isHostReady: (String) -> Bool
  ) -> Set<String> {
    Set(
      required.filter { key in
        measurements[key] != nil
          && !measurements.isStale(key)
          && isHostReady(key)
      })
  }

  /// Whether one mounted row may be treated as final: measured, not stale,
  /// not awaiting a commit, and fully presentable.
  @MainActor
  public static func isPromotable(
    key: String,
    measurements: TranscriptMeasurementLedger,
    hasPendingMeasurement: Bool,
    host: (any TranscriptPresentableRowHost)?
  ) -> Bool {
    guard let host else { return false }
    return measurements[key] != nil
      && !measurements.isStale(key)
      && !hasPendingMeasurement
      && host.isFullyPresentable
  }

  /// `resolvedKeys(required:measurements:isHostReady:)` over a host table.
  @MainActor
  public static func resolvedKeys(
    required: Set<String>,
    measurements: TranscriptMeasurementLedger,
    hosts: [String: some TranscriptPresentableRowHost]
  ) -> Set<String> {
    resolvedKeys(required: required, measurements: measurements) { key in
      hosts[key]?.isFullyPresentable == true
    }
  }
}
