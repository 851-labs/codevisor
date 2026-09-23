#if os(macOS)
  import SwiftUI

  /// Sheet size classes, chosen by a sheet's **structure** — never by which
  /// harness it happens to be showing. A sheet is not "the OpenCode sheet";
  /// it is a browser-shaped sheet, and OpenCode happens to need one.
  ///
  /// macOS sheets are not user-resizable, so SwiftUI resolves to `ideal`
  /// unless the content demands otherwise, then clamps to `min`/`max`. That
  /// is content-driven sizing *within bounds* — which is what a grouped
  /// `Form` needs, because its ideal height is unbounded (an unframed sheet
  /// is a postage stamp when empty and taller than the display with a dozen
  /// rows).
  ///
  /// The `min` values are deliberately set above the tallest *common* state
  /// of each class so that moving between common states — loading, empty
  /// invitation, populated list — does not resize the window at all.
  public enum SheetMetrics {
    /// One focused task: one instruction, one input, two or three actions.
    case step
    /// A list of things plus its actions. The default for this family.
    case list
    /// Source list plus detail pane.
    case browser

    /// `min` equals `ideal` deliberately. A grouped `Form` reports a small
    /// ideal width, so SwiftUI resolves the frame to `min` and a lower
    /// minimum silently shrinks every sheet (measured: `.list` came out at
    /// 520 rather than 560). Pinning the floor to the designed width keeps
    /// it, while `max` still lets a long unbreakable line widen the sheet
    /// instead of forcing a tall narrow column.
    var width: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
      switch self {
      case .step: (440, 440, 520)
      case .list: (560, 560, 680)
      case .browser: (760, 760, 900)
      }
    }

    var height: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
      switch self {
      case .step: (240, 320, 560)
      case .list: (400, 460, 680)
      case .browser: (460, 540, 720)
      }
    }
  }

  extension View {
    /// Bounds a sheet to one of the structural size classes. Apply at the
    /// outermost level, before `.themedSurface(.sheet)`.
    public func sheetSize(_ metrics: SheetMetrics) -> some View {
      frame(
        minWidth: metrics.width.min, idealWidth: metrics.width.ideal, maxWidth: metrics.width.max,
        minHeight: metrics.height.min, idealHeight: metrics.height.ideal, maxHeight: metrics.height.max)
    }
  }
#endif
