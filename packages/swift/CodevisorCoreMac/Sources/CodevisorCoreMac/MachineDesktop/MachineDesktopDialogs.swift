import ComposableArchitecture
import Foundation

enum MachineDesktopDialogs {
  typealias Dialog = ConfirmationDialogState<MachineDesktopSetup.Confirmation>

  static func dialog(_ question: MachineDesktopSetup.Confirmation, on machine: String) -> Dialog {
    switch question {
    case .remove:
      dialog(
        "Remove the desktop on \(machine)?", "This closes everything open in it.",
        button: "Remove Desktop", role: .destructive, answer: question)
    case .stopSharing:
      dialog(
        "Stop sharing the desktop on \(machine)?",
        "It wasn't set up by Codevisor, so it keeps running. Codevisor only forgets it.",
        button: "Stop Sharing", role: nil, answer: question)
    case .replaceOld:
      dialog(
        "An older desktop runs as root on \(machine).", "Replace it? Everything open in it will close.",
        button: "Replace", role: .destructive, answer: question)
    case .replaceUnmanaged:
      dialog(
        "\(machine) has a desktop that Codevisor didn't set up.",
        "Replace it with a new desktop? The other one keeps running but is no longer shared.",
        button: "Replace", role: nil, answer: question)
    }
  }

  private static func dialog(
    _ title: String, _ message: String, button: String, role: ButtonStateRole?,
    answer: MachineDesktopSetup.Confirmation
  ) -> Dialog {
    Dialog(titleVisibility: .visible) {
      TextState(title)
    } actions: {
      ButtonState(role: role, action: answer) { TextState(button) }
      ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
      TextState(message)
    }
  }
}
