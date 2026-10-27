import CodevisorUI
import SwiftUI

struct ComposerSlimBar<Field: View>: View {
  private static var fieldShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: ComposerSlimCircleButton.diameter / 2)
  }

  let field: Field
  let action: ComposerSlimAction
  let glassNamespace: Namespace.ID?
  let onAttach: () -> Void
  let onStop: () -> Void
  let onSend: () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      ComposerSlimCircleButton(
        systemImage: "plus", help: "Attach files", accessibilityLabel: "Attach files", action: onAttach)
      field
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .composerGlassSurface(shape: Self.fieldShape, id: .composer, in: glassNamespace)
      trailingButton
    }
  }

  @ViewBuilder
  private var trailingButton: some View {
    switch action {
    case let .stop(isCancelling):
      ComposerSlimCircleButton(
        systemImage: "stop.fill", isBusy: isCancelling, help: "Stop", accessibilityLabel: "Stop", action: onStop)
    case let .send(isEnabled, isBusy, help):
      ComposerSlimCircleButton(
        systemImage: "arrow.up", isProminent: isEnabled, isEnabled: isEnabled, isBusy: isBusy, help: help,
        accessibilityLabel: "Send", action: onSend)
    }
  }
}
