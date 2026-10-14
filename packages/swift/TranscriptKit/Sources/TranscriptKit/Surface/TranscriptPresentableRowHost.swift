import CoreGraphics
import Foundation

@MainActor
public protocol TranscriptPresentableRowHost: AnyObject {
  var isPresentationReady: Bool { get }
  var isAttachmentGeometryReady: Bool { get }
}

extension TranscriptPresentableRowHost {
  public var isFullyPresentable: Bool {
    isPresentationReady && isAttachmentGeometryReady
  }
}
