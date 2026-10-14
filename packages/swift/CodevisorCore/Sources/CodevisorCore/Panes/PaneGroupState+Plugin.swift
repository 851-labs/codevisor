import Foundation

struct LenientPaneDescriptorState: Decodable {
  let pane: PaneDescriptorState?

  init(from decoder: Decoder) throws {
    pane = try? PaneDescriptorState(from: decoder)
  }
}

extension PaneGroupState {
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
