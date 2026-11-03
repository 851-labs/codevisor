import CodevisorCore

public struct PluginAppContextAction {
  let title: String
  let systemImage: String
  let perform: @MainActor () -> Void

  static func blockTitle(for subject: PluginModerationSubject) -> String? {
    guard !subject.isCustom else { return nil }
    return "Block \(subject.name)…"
  }
}
