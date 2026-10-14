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
