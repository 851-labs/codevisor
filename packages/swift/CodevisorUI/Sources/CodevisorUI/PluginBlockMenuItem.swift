import CodevisorCore
import SwiftUI

public struct PluginBlockMenuItem: View {
  @Environment(AppEnvironment.self) private var environment
  let subject: PluginModerationSubject
  let action: () -> Void

  public init(subject: PluginModerationSubject, action: @escaping () -> Void) {
    self.subject = subject
    self.action = action
  }

  public var body: some View {
    Button(isBlocked ? "Unblock Publisher…" : "Block Publisher…", action: action)
  }

  private var isBlocked: Bool { environment.pluginAccess.isBlocked(publisher: subject.publisher) }
}
