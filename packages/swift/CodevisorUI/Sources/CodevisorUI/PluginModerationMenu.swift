#if os(iOS)
  import CodevisorCore
  import SwiftUI

  public struct PluginModerationMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var reporting = false
    @State private var confirmingBlock = false
    let subject: PluginModerationSubject

    public init(subject: PluginModerationSubject) {
      self.subject = subject
    }

    public var body: some View {
      Menu {
        Button("Report…") { reporting = true }
        PluginBlockMenuItem(subject: subject) { confirmingBlock = true }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("More")
      .sheet(isPresented: $reporting) {
        PluginReportSheet(subject: subject).environment(environment)
      }
      .pluginBlockConfirmation(subject: subject, isPresented: $confirmingBlock)
    }
  }
#endif
