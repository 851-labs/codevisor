import CodevisorCore
import CodevisorUI
import SwiftUI

struct MachineSettingsRowLabel: View {
  let name: String
  let sandbox: CloudEphemeralOrigin?
  let icon: Image
  let connection: MachineConnectionPresentation
  let keyChanged: Bool
  let onTrustKey: () -> Void

  var body: some View {
    Label {
      MachineNameText(name: name, sandbox: sandbox)
      status
    } icon: {
      icon.foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(keyChanged ? .isButton : [])
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture {
      if keyChanged { onTrustKey() }
    }
  }

  @ViewBuilder
  private var status: some View {
    if keyChanged {
      Text("\(Image(systemName: "exclamationmark.shield.fill")) Key Changed")
        .foregroundStyle(.orange)
    } else {
      connectionText
    }
  }

  private var connectionText: Text {
    let dot = Text(Image(systemName: "circlebadge.fill"))
      .font(.caption2)
      .foregroundStyle(connection.indicator == .connected ? Color.green : .gray)
    return Text("\(dot) \(connection.label())")
  }
}
