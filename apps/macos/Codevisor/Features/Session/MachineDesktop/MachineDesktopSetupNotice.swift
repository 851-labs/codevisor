import SwiftUI

struct MachineDesktopSetupNotice: View {
  struct Offer {
    let title: String
    let action: () -> Void
  }

  let symbol: String
  let sentence: String
  let offer: Offer?
  let size: MachineDesktopSetupStatus.Size

  var body: some View {
    Image(systemName: symbol)
      .font(size == .pane ? .largeTitle : .title2)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
    Text(sentence)
      .font(size == .pane ? .body : .callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: size == .pane ? 380 : nil)
      .textSelection(.enabled)
    if let offer {
      Button(offer.title, action: offer.action)
        .controlSize(size == .pane ? .regular : .small)
    }
  }
}
