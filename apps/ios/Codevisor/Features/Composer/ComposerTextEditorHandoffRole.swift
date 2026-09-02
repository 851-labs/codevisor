/// The role a composer's UIKit text editor plays in first-send promotion:
/// `.none` for ordinary composers, or the source/destination of the
/// keyboard-preserving handoff (see `ComposerTextViewHandoffRegistry`).
enum ComposerTextEditorHandoffRole {
  case none
  case promotionSource
  case promotionDestination
}
