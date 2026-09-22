import CodevisorCore
import CodevisorUI
import Foundation

// `WorkspaceSplitLayoutSnapshot` itself lives in CodevisorUI, shared with the
// iPhone Duo split container; only the macOS opening animation state is here.

/// A local split insertion whose geometry is still being presented. The
/// workspace tree is already canonical; this value affects only the entering
/// shell and when its pane content becomes interactive.
struct WorkspaceSplitOpening: Equatable, Identifiable {
  let id = UUID()
  let leafId: UUID
  let edge: SplitEdge
}
