import CodevisorCore

struct ComposerSandboxPicks {
  let choices: [SandboxProfileChoice]
  let selectedProfileId: String?
  let isCheckingSelection: Bool
  let loadKey: SandboxProfilesLoadKey
  let load: @MainActor () async -> Void
  let onPick: (SandboxProfileChoice) -> Void
  let onManage: () -> Void
}
