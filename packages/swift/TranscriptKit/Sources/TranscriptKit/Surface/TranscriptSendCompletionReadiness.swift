import Foundation

/// A send reveal owns the whole tail below its user bubble. A replacement
/// host being mounted, or having a carried height, is insufficient: its
/// content must be ready and every reported height must have committed.
public enum TranscriptSendCompletionReadiness {
  @MainActor
  public static func isReady(
    userMessageID: UUID,
    rows: [TranscriptPresentationRow],
    measurements: TranscriptMeasurementLedger,
    hasPendingMeasurement: (String) -> Bool,
    hosts: [String: some TranscriptPresentableRowHost]
  ) -> Bool {
    let targetKey = TranscriptPresentationRow.ID.message(userMessageID).layoutKey
    guard let targetIndex = rows.firstIndex(where: { $0.layoutKey == targetKey }) else { return false }
    return rows[targetIndex...].allSatisfy { row in
      row.id == .bottomSpacer
        || TranscriptMountedWindowReadiness.isPromotable(
          key: row.layoutKey,
          measurements: measurements,
          hasPendingMeasurement: hasPendingMeasurement(row.layoutKey),
          host: hosts[row.layoutKey]
        )
    }
  }
}
