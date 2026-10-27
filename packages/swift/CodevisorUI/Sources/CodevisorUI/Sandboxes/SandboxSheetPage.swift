import SwiftUI

struct SandboxSheetPage<Content: View>: View {
  let title: String
  var confirmTitle: String?
  var canConfirm = true
  var status: String?
  var showsCancel = true
  let onCancel: () -> Void
  var onConfirm: () -> Void = {}
  @ViewBuilder let content: Content

  var body: some View {
    #if os(macOS)
      VStack(spacing: 0) {
        content
        SheetFooter(status: status) {
          Button("Cancel", role: .cancel, action: onCancel)
            .keyboardShortcut(.cancelAction)
            .disabled(status != nil)
          if let confirmTitle {
            Button(confirmTitle, action: onConfirm)
              .keyboardShortcut(.defaultAction)
              .disabled(!canConfirm || status != nil)
          }
        }
      }
      .navigationTitle(title)
    #else
      content
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if showsCancel {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", systemImage: "xmark", role: .cancel, action: onCancel)
                .labelStyle(.iconOnly)
                .disabled(status != nil)
            }
          }
          if let confirmTitle {
            SheetConfirmToolbarItem(confirmTitle, isEnabled: canConfirm && status == nil, action: onConfirm)
          }
        }
        .sheetStatus(status)
    #endif
  }
}
