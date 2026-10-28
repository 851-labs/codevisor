import SwiftUI
import TranscriptKit

public struct TranscriptDeliveryRow: View {
  let delivery: TranscriptDelivery
  let inBotConversation: Bool
  let retry: () -> Void
  let delete: () -> Void

  public init(
    delivery: TranscriptDelivery,
    inBotConversation: Bool,
    retry: @escaping () -> Void,
    delete: @escaping () -> Void
  ) {
    self.delivery = delivery
    self.inBotConversation = inBotConversation
    self.retry = retry
    self.delete = delete
  }

  public var body: some View {
    HStack {
      Spacer(minLength: 0)
      switch delivery {
      case .sending where inBotConversation:
        TranscriptSendProgressBar()
      case .sending:
        Text("Sending…")
          .foregroundStyle(.secondary)
      case let .failed(reason):
        Menu {
          if let reason {
            Text(reason)
          }
          Button("Try Again", systemImage: "arrow.clockwise", action: retry)
          Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        } label: {
          Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    .font(.caption.weight(.medium))
  }
}
