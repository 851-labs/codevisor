#if os(iOS)
  import CodevisorCore
  import SwiftUI

  struct PluginModerationSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var reporting = false
    @State private var confirmingBlock = false
    let subject: PluginModerationSubject

    var body: some View {
      Section {
        Button("Report…") { reporting = true }
        PluginBlockMenuItem(subject: subject) { confirmingBlock = true }
      }
      .sheet(isPresented: $reporting) {
        PluginReportSheet(subject: subject).environment(environment)
      }
      .pluginBlockConfirmation(subject: subject, isPresented: $confirmingBlock)
    }
  }
#endif
