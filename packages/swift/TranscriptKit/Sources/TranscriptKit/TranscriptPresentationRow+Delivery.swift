import Foundation

extension TranscriptPresentationRow {
  static let deliveryGap: CGFloat = 2

  static func delivery(
    _ id: UUID, _ delivery: TranscriptDelivery, inBotConversation: Bool, spacingAfter: CGFloat? = nil
  ) -> TranscriptPresentationRow {
    .init(
      id: .delivery(id),
      content: .delivery(id, delivery, inBotConversation: inBotConversation),
      estimatedHeight: 20,
      measurementRevision: delivery == .sending ? 0 : 1,
      spacingAfter: spacingAfter
    )
  }

  func spaced(_ spacingAfter: CGFloat) -> TranscriptPresentationRow {
    .init(
      id: id,
      content: content,
      estimatedHeight: estimatedHeight,
      measurementRevision: measurementRevision,
      spacingAfter: spacingAfter,
      workedSection: workedSection,
      finishedResponseItemId: finishedResponseItemId
    )
  }
}
