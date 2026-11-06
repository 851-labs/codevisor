import SwiftUI
import TranscriptKit

public struct TranscriptDeliveryRow: View {
  static let awaitingStepTitle = "Waiting on tool"
  static let awaitingStepSymbol = "hourglass.circle.fill"

  let delivery: TranscriptDelivery
  let retry: () -> Void
  let delete: () -> Void
  let sendNow: () -> Void

  public init(
    delivery: TranscriptDelivery,
    retry: @escaping () -> Void,
    delete: @escaping () -> Void,
    sendNow: @escaping () -> Void
  ) {
    self.delivery = delivery
    self.retry = retry
    self.delete = delete
    self.sendNow = sendNow
  }

  public var body: some View {
    HStack {
      Spacer(minLength: 0)
      ZStack(alignment: .topTrailing) {
        notDeliveredLabel.hidden()
        switch delivery {
        case .sending:
          TranscriptSendProgressBar()
        case .failed:
          TranscriptDeliveryMenu {
            Button(action: retry) { menuLabel("Try Again", "arrow.clockwise") }
            Button(role: .destructive, action: delete) { menuLabel("Delete", "trash") }
          } label: {
            notDeliveredLabel
          }
        case .awaitingStep:
          TranscriptDeliveryMenu {
            Button(action: sendNow) { menuLabel("Send Now", "arrow.turn.right.up") }
            Button(role: .destructive, action: delete) { menuLabel("Delete", "trash") }
          } label: {
            Label(Self.awaitingStepTitle, systemImage: Self.awaitingStepSymbol)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .font(.caption.weight(.medium))
  }

  private var notDeliveredLabel: some View {
    Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
      .foregroundStyle(.red)
  }

  private func menuLabel(_ title: String, _ systemImage: String) -> some View {
    Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
  }
}

private struct TranscriptDeliveryMenu<Items: View, MenuLabel: View>: View {
  @ViewBuilder let items: () -> Items
  @ViewBuilder let label: () -> MenuLabel

  var body: some View {
    Menu(content: items, label: label)
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
  }
}
