import SwiftUI

struct SandboxSettingsForm<Content: View>: View {
  @Environment(\.sandboxSheetCancel) private var cancel
  @Environment(\.sandboxSheetBack) private var back
  let title: String
  var actionTitle: String?
  var canAct = true
  var status: String?
  var errorMessage: String?
  var onAction: () -> Void = {}
  @ViewBuilder let content: Content

  var body: some View {
    #if os(macOS)
      SetupSheet(
        symbol: nil, title: title, primaryTitle: actionTitle, cancelTitle: "Cancel",
        canContinue: canAct && status == nil, status: status, onCancel: { cancel?() },
        onBack: back.map { back in { back() } }, onContinue: onAction, stepsInCard: false
      ) {
        SandboxSheetFields(errorMessage: errorMessage) { content }
      }
    #else
      Form {
        SandboxSheetError(message: errorMessage)
        content
      }
      .formStyle(.grouped)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if let cancel {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { cancel() }
          }
        }
        if let actionTitle {
          SheetConfirmToolbarItem(actionTitle, isEnabled: canAct && status == nil, action: onAction)
        }
      }
      .sheetStatus(status)
    #endif
  }
}
