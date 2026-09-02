import CoreGraphics
import Foundation

/// The readiness a mounted row host reports to the virtualizer, independent
/// of whether it is an AppKit or UIKit view. Gates that decide when a window
/// may be promoted or presented consult only this.
@MainActor
public protocol TranscriptPresentableRowHost: AnyObject {
    /// The host's content has completed its first real layout.
    var isPresentationReady: Bool { get }
    /// Every attachment in the row has resolved its geometry.
    var isAttachmentGeometryReady: Bool { get }
}

extension TranscriptPresentableRowHost {
    public var isFullyPresentable: Bool {
        isPresentationReady && isAttachmentGeometryReady
    }
}

extension TranscriptMountedWindowReadiness {
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
