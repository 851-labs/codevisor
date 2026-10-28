import SwiftUI

struct SandboxSettingsForm<Content: View>: View {
  let title: String
  var actionTitle: String?
  var canAct = true
  var status: String?
  var errorMessage: String?
  var onAction: () -> Void = {}
  @ViewBuilder let content: Content

  var body: some View {
    Form {
      SandboxSheetError(message: errorMessage)
      content
      #if os(macOS)
        if let actionTitle {
          Section {
          } footer: {
            HStack(spacing: 8) {
              Spacer()
              if let status {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
              }
              Button(actionTitle, action: onAction)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAct || status != nil)
            }
          }
        }
      #endif
    }
    .formStyle(.grouped)
    .navigationTitle(title)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if let actionTitle {
          SheetConfirmToolbarItem(actionTitle, isEnabled: canAct && status == nil, action: onAction)
        }
      }
      .sheetStatus(status)
    #endif
  }
}
