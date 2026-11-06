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
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
          } label: {
            notDeliveredLabel
          }
        case .awaitingStep:
          TranscriptDeliveryMenu {
            Button("Send Now", systemImage: "arrow.turn.right.up", action: sendNow)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
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
