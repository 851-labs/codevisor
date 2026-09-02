import CodevisorCore

extension SessionController {
  @MainActor
  static func runTargetPlaceholder(
    serverId: String,
    environment: AppEnvironment
  ) -> SessionController {
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: serverId),
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults,
      composerDefaultsScope: .newWorkspace(serverId: serverId),
      serverClient: environment.machines.client(for: serverId)
    )
    controller.applyComposerDefaults()
    return controller
  }
}
