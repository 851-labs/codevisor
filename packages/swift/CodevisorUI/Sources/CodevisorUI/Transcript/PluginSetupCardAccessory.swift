import SwiftUI

struct PluginSetupCardAccessory: View {
  enum State: Equatable {
    case action(String, isEnabled: Bool)
    case working
    case done(String)
    case unavailable
  }

  let state: State
  let perform: () -> Void

  var body: some View {
    switch state {
    case let .action(title, isEnabled):
      Button(title, action: perform)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!isEnabled)
    case .working:
      ProgressView().controlSize(.small).frame(minWidth: 56)
    case let .done(title):
      Label(title, systemImage: "checkmark")
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
    case .unavailable:
      Text("Unavailable")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}
