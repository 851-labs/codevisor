import SwiftUI

struct SandboxSettingsForm<Content: View>: View {
  @Environment(\.sandboxSheetCancel) private var cancel
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
    }
    .formStyle(.grouped)
    .navigationTitle(title)
    #if os(macOS)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if hasFooter {
          SheetFooter(status: status) { footerButtons }
        }
      }
    #else
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

  #if os(macOS)
    private var hasFooter: Bool {
      actionTitle != nil || cancel != nil
    }

    @ViewBuilder
    private var footerButtons: some View {
      if let cancel {
        Button("Cancel", role: .cancel) { cancel() }
          .keyboardShortcut(.cancelAction)
      }
      if let actionTitle {
        Button(actionTitle, action: onAction)
          .keyboardShortcut(.defaultAction)
          .disabled(!canAct || status != nil)
      }
    }
  #endif
}
