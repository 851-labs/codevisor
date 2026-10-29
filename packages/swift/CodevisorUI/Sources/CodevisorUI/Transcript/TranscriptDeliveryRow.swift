import SwiftUI
import TranscriptKit

public struct TranscriptDeliveryRow: View {
  let delivery: TranscriptDelivery
  let retry: () -> Void
  let delete: () -> Void

  public init(
    delivery: TranscriptDelivery,
    retry: @escaping () -> Void,
    delete: @escaping () -> Void
  ) {
    self.delivery = delivery
    self.retry = retry
    self.delete = delete
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
          Menu {
            Button("Try Again", systemImage: "arrow.clockwise", action: retry)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
          } label: {
            notDeliveredLabel
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .menuIndicator(.hidden)
          .fixedSize()
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
