#if DEBUG
  import CodevisorCore
  import CodevisorUI
  import SwiftUI

  struct BentoMcpSection: View {
    let title: String
    let builtIn: Bool

    @Environment(AppEnvironment.self) private var environment
    @State private var model = McpGlobalModel()

    var body: some View {
      Form {
        Section(title) {
          McpFleetSection(model: model, builtIn: builtIn) { entry in
            McpFleetEntryLabel(entry: entry, model: model) { McpEntryIcon(entry: entry) }
          }
        }
      }
      .formStyle(.grouped)
      .task { await model.load(in: environment) }
    }
  }
#endif
