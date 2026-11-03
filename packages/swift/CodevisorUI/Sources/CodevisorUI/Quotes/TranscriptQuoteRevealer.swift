import CodevisorCore
import TranscriptKit

@MainActor
public protocol TranscriptQuoteRevealTarget: AnyObject {
  var isWaitingToRevealQuote: Bool { get }
  func revealQuote(_ quote: TranscriptQuote) -> Bool
  func waitToRevealQuote(_ quote: TranscriptQuote)
  func cancelPendingQuoteReveal()
  func showQuoteNotFound()
}

@MainActor
public struct TranscriptQuoteRevealer {
  private static let maximumOlderPages = 20
  private static let projectionWait: Duration = .milliseconds(150)
  private static let projectionWaitAttempts = 10

  let controller: SessionController
  let target: any TranscriptQuoteRevealTarget
  let presentsBotConversation: Bool

  public init(controller: SessionController, target: any TranscriptQuoteRevealTarget, presentsBotConversation: Bool) {
    self.controller = controller
    self.target = target
    self.presentsBotConversation = presentsBotConversation
  }

  public func reveal(_ quote: TranscriptQuote) async {
    if target.revealQuote(quote) { return }

    target.waitToRevealQuote(quote)
    for _ in 0..<Self.maximumOlderPages {
      guard await loadOlderPage() else { break }
      if await projectionRevealed() { return }
    }
    target.cancelPendingQuoteReveal()
    target.showQuoteNotFound()
  }

  private func loadOlderPage() async -> Bool {
    guard controller.hasOlderHistory(presentingBotConversation: presentsBotConversation) else { return false }
    return await controller.loadOlderHistory(presentingBotConversation: presentsBotConversation) > 0
  }

  private func projectionRevealed() async -> Bool {
    for _ in 0..<Self.projectionWaitAttempts {
      guard target.isWaitingToRevealQuote else { return true }
      try? await Task.sleep(for: Self.projectionWait)
    }
    return !target.isWaitingToRevealQuote
  }
}
