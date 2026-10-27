import CodevisorCore

struct ComposerSandboxPicks {
  let enabled: Bool
  let selectedProfileId: String?
  let load: @MainActor (SandboxProfileCatalog) async -> Void
  let onPick: (SandboxProfileChoice) -> Void
  let onManage: () -> Void
}
