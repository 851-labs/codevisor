struct PluginCapabilityItem: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let detail: String?
  var isApp = false
}
