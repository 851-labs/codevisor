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
          McpFleetSection(
            model: model, builtIn: builtIn, onDetails: { _ in }, onEdit: { _ in }, onRemove: { _ in },
            onConnect: { _, _ in },
            icon: { McpEntryIcon(entry: $0) },
            machineExtras: { _, _ in EmptyView() })
        }
      }
      .formStyle(.grouped)
      .task { await model.load(in: environment) }
    }
  }
#endif
