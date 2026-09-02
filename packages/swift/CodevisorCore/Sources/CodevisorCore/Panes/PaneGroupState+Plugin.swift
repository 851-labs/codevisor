import Foundation

/// Wrapper making pane-array decoding element-lenient: an element that fails
/// to decode (a pane kind from a NEWER build) yields nil instead of throwing,
/// so one unknown pane never nukes a whole persisted group.
struct LenientPaneDescriptorState: Decodable {
  let pane: PaneDescriptorState?

  init(from decoder: Decoder) throws {
    pane = try? PaneDescriptorState(from: decoder)
  }
}

extension PaneGroupState {
  /// Builds a plugin pane descriptor for `convertNewTabPane`. Nil when the
  /// plugin identity is incomplete (a plugin pane without its plugin is
  /// unrenderable).
  static func pluginPane(
    id: UUID,
    name: String?,
    pluginId: String?,
    pluginPaneType: String?
  ) -> PaneDescriptorState? {
    guard let pluginId, !pluginId.isEmpty, let pluginPaneType, !pluginPaneType.isEmpty
    else { return nil }
    return PaneDescriptorState(
      id: id,
      kind: .plugin,
      name: name ?? "Plugin",
      terminalKey: id.uuidString,
      pluginId: pluginId,
      pluginPaneType: pluginPaneType
    )
  }
}
