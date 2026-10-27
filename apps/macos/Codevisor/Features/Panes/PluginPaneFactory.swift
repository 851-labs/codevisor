import CodevisorCore

@MainActor
enum PluginPaneFactory {
  static func make(
    context: PaneContext, descriptor: PaneDescriptorState, onTitleChange: @escaping (String) -> Void
  ) -> any Pane {
    guard descriptor.pluginApp == nil else { return PluginAppPane(context: context, descriptor: descriptor) }

    let plugin = PluginPane(context: context, descriptor: descriptor)
    plugin.onTitleChange = onTitleChange
    return plugin
  }
}
