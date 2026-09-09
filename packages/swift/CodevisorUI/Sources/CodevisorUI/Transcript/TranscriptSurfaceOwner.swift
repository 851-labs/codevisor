import CodevisorCore
import CoreGraphics
import StreamMarkdown
import TranscriptKit

/// Access to the shared state from native side effects. Yielding the stored
/// value avoids copy-on-write copies when an adapter mutates a ledger.
@MainActor
public protocol TranscriptSurfaceOwner: AnyObject {
  var surfaceController: TranscriptSurfaceController { get }
}

public extension TranscriptSurfaceOwner {
  var streamingTextFrameClock: StreamingTextAnimationFrameClock {
    surfaceController.streamingTextFrameClock
  }
  var rowSet: TranscriptRowSet {
    _read { yield surfaceController.rowSet }
    _modify { yield &surfaceController.rowSet }
  }
  var virtualLayout: VirtualTranscriptLayout {
    _read { yield surfaceController.virtualLayout }
    _modify { yield &surfaceController.virtualLayout }
  }
  var measurements: TranscriptMeasurementLedger {
    _read { yield surfaceController.measurements }
    _modify { yield &surfaceController.measurements }
  }
  var measurementCache: SessionMeasurementCacheStore {
    _read { yield surfaceController.measurementCache }
    _modify { yield &surfaceController.measurementCache }
  }
  var layoutFingerprint: Int {
    _read { yield surfaceController.layoutFingerprint }
    _modify { yield &surfaceController.layoutFingerprint }
  }
  var virtualWindowHandoff: TranscriptVirtualWindowHandoff {
    _read { yield surfaceController.virtualWindowHandoff }
    _modify { yield &surfaceController.virtualWindowHandoff }
  }
  var pendingWindowScrollDelta: CGFloat {
    _read { yield surfaceController.pendingWindowScrollDelta }
    _modify { yield &surfaceController.pendingWindowScrollDelta }
  }
  var initialPresentationGate: TranscriptInitialPresentationGate {
    _read { yield surfaceController.initialPresentationGate }
    _modify { yield &surfaceController.initialPresentationGate }
  }
  var initialBottomPin: TranscriptInitialBottomPin {
    _read { yield surfaceController.initialBottomPin }
    _modify { yield &surfaceController.initialBottomPin }
  }
  var bottomJumpGate: TranscriptBottomJumpGate {
    _read { yield surfaceController.bottomJumpGate }
    _modify { yield &surfaceController.bottomJumpGate }
  }
  var lockedRestoreDistance: CGFloat? {
    _read { yield surfaceController.lockedRestoreDistance }
    _modify { yield &surfaceController.lockedRestoreDistance }
  }
  var initialPositionConfigured: Bool {
    _read { yield surfaceController.initialPositionConfigured }
    _modify { yield &surfaceController.initialPositionConfigured }
  }
  var initialPositionApplied: Bool {
    _read { yield surfaceController.initialPositionApplied }
    _modify { yield &surfaceController.initialPositionApplied }
  }
  var followsLatest: Bool {
    _read { yield surfaceController.followsLatest }
    _modify { yield &surfaceController.followsLatest }
  }
  var displayFrameRequested: Bool {
    _read { yield surfaceController.displayFrameRequested }
    _modify { yield &surfaceController.displayFrameRequested }
  }
  var modelPresentationFrameRequested: Bool {
    _read { yield surfaceController.modelPresentationFrameRequested }
    _modify { yield &surfaceController.modelPresentationFrameRequested }
  }
  var mountedRowsUpdateRequested: Bool {
    _read { yield surfaceController.mountedRowsUpdateRequested }
    _modify { yield &surfaceController.mountedRowsUpdateRequested }
  }
}
