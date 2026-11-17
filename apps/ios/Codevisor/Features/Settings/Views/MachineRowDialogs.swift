import CodevisorCore
import SwiftUI

struct MachineRowDialogs: ViewModifier {
  let presence: CloudMachine?
  let cloud: CloudAccountController
  @Binding var removing: CloudMachine?
  @Binding var trusting: CloudMachine?

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Disconnect “\(removing?.name ?? "")”?",
        isPresented: isShowing($removing),
        titleVisibility: .visible,
        presenting: removing
      ) { machine in
        Button("Disconnect Machine", role: .destructive) {
          Task { await cloud.remove(deviceId: machine.deviceId) }
        }
        Button("Cancel", role: .cancel) {}
      } message: { machine in
        Text(
          "“\(machine.name)” will be signed out of your account. Nothing on the machine itself is changed — run codevisor auth login there to reconnect it."
        )
      }
      .confirmationDialog(
        "Trust the new key for “\(trusting?.name ?? "")”?",
        isPresented: isShowing($trusting),
        titleVisibility: .visible,
        presenting: trusting
      ) { machine in
        Button("Trust New Key", role: .destructive) {
          cloud.trustChangedMachineKey(deviceId: machine.deviceId)
        }
        Button("Cancel", role: .cancel) {}
      } message: { machine in
        Text(
          "“\(machine.name)” is presenting a different encryption key than the one this device remembers. That happens if the machine was re-provisioned — but it can also mean something between you and the machine is intercepting traffic. Only trust the new key if you expected this change."
        )
      }
  }

  private func isShowing(_ target: Binding<CloudMachine?>) -> Binding<Bool> {
    Binding(
      get: { presence != nil && target.wrappedValue?.deviceId == presence?.deviceId },
      set: { if !$0 { target.wrappedValue = nil } }
    )
  }
}
