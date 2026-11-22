import Foundation
import SwiftUI
import TranscriptKit
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

@MainActor
final class TranscriptQuotedMessageTextCache {
  static let shared = TranscriptQuotedMessageTextCache()

  private struct Key: Hashable {
    let prompt: String
    let font: OSFont
    let color: Color
  }

  private var entries: [Key: NSAttributedString] = [:]
  private var order: [Key] = []

  func text(for prompt: TranscriptQuotedPrompt, font: OSFont, color: Color) -> NSAttributedString {
    let key = Key(prompt: prompt.promptText, font: font, color: color)
    if let cached = entries[key] { return cached }

    let text = TranscriptQuoteBadgeText.attributedString(
      prompt, attributes: [.font: font, .foregroundColor: OSColor(color)], linksQuotes: true)
    store(text, for: key)
    return text
  }

  private func store(_ text: NSAttributedString, for key: Key) {
    entries[key] = text
    order.append(key)
    guard order.count > Self.limit else { return }
    entries.removeValue(forKey: order.removeFirst())
  }

  private static let limit = 128
}
