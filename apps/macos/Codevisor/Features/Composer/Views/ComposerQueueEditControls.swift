import SwiftUI

struct ComposerQueueEditControls: View {
  let canSave: Bool
  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    Spacer(minLength: 0)
    HStack(spacing: 4) {
      ComposerNavigationButton(
        systemImage: "xmark",
        help: "Cancel — keep the queued message as it was (esc)",
        accessibilityLabel: "Cancel editing",
        weight: .bold,
        action: onCancel
      )
      ComposerSubmitButton(
        systemImage: "checkmark",
        isEnabled: canSave,
        help: "Save queued message (↩)",
        accessibilityLabel: "Save queued message",
        action: onSave
      )
    }
  }
}
