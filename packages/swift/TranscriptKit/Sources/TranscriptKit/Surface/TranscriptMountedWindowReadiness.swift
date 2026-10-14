import CoreGraphics
import Foundation

public enum TranscriptMountedWindowReadiness {
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
