public struct PluginAppContextAction {
  let title: String
  let systemImage: String
  let perform: @MainActor () -> Void
}
