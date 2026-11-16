import SwiftUI

struct ChromiumPageDialogView: View {
  let dialog: CVChromiumPageDialog
  let dialogs: ChromiumPageDialogs
  let page: CVChromiumView?

  var body: some View {
    ZStack {
      Color.black.opacity(0.25)
        .contentShape(.rect)
        .onTapGesture {}
      ChromiumPageDialogCard(dialog: dialog, dialogs: dialogs, page: page)
        .padding(24)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }
}

private struct ChromiumPageDialogCard: View {
  let dialog: CVChromiumPageDialog
  let dialogs: ChromiumPageDialogs
  let page: CVChromiumView?
  @State private var text = ""
  @State private var tookPageFocus = false
  @FocusState private var focus: Field?

  private enum Field {
    case card
    case text
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      if !message.isEmpty { ChromiumPageDialogMessage(message: message) }
      if dialog.kind == .prompt {
        TextField("", text: $text)
          .textFieldStyle(.roundedBorder)
          .focused($focus, equals: .text)
          .onSubmit(accept)
      }
      ChromiumPageDialogButtons(kind: dialog.kind, accept: accept, dismiss: dismiss)
    }
    .padding(20)
    .frame(width: 360)
    .background(.background, in: .rect(cornerRadius: 14))
    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    .focusable(dialog.kind != .prompt)
    .focusEffectDisabled()
    .focused($focus, equals: .card)
    .onKeyPress(.return, action: acceptKey)
    .onKeyPress(.escape, action: dismissKey)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .onAppear(perform: takePageFocus)
    .onDisappear(perform: returnPageFocus)
  }

  private var title: String {
    switch dialog.kind {
    case .leavePage: "Leave this page?"
    default: "\(dialog.site) says"
    }
  }

  private var message: String {
    switch dialog.kind {
    case .leavePage: "Changes you made may not be saved."
    default: dialog.message
    }
  }

  private func accept() { dialogs.accept(text: text) }

  private func dismiss() {
    if dialog.kind == .alert { dialogs.accept(text: "") } else { dialogs.dismiss() }
  }

  private func acceptKey() -> KeyPress.Result {
    accept()
    return .handled
  }

  private func dismissKey() -> KeyPress.Result {
    dismiss()
    return .handled
  }

  private func takePageFocus() {
    text = dialog.defaultText
    guard page?.hasPageFocus == true else { return }

    tookPageFocus = true
    focus = dialog.kind == .prompt ? .text : .card
  }

  private func returnPageFocus() {
    guard tookPageFocus else { return }

    page?.focusPage()
  }
}

private struct ChromiumPageDialogMessage: View {
  let message: String

  var body: some View {
    ScrollView {
      Text(message)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 220)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct ChromiumPageDialogButtons: View {
  let kind: CVChromiumPageDialogKind
  let accept: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack {
      Spacer()
      if kind != .alert { Button(cancelTitle, role: .cancel, action: dismiss) }
      Button(acceptTitle, action: accept)
        .buttonStyle(.borderedProminent)
    }
  }

  private var acceptTitle: String {
    switch kind {
    case .leavePage: "Leave"
    default: "OK"
    }
  }

  private var cancelTitle: String {
    switch kind {
    case .leavePage: "Stay"
    default: "Cancel"
    }
  }
}
