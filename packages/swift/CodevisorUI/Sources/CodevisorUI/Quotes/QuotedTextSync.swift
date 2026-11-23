import Foundation
import TranscriptKit
#if canImport(AppKit)
  import AppKit

  public typealias TextStorageEditActions = NSTextStorageEditActions
#elseif canImport(UIKit)
  import UIKit

  public typealias TextStorageEditActions = NSTextStorage.EditActions
#endif

public final class QuotedTextSync: NSObject, NSTextStorageDelegate {
  public private(set) var revision = 0
  private var badges: [Int] = []
  private var orphanMarkers: [Int] = []
  private var cached: TranscriptQuotedPrompt?

  public var isStale: Bool { cached == nil }

  public func observe(_ storage: NSTextStorage) {
    guard storage.delegate !== self else { return }

    storage.delegate = self
    badges = []
    orphanMarkers = []
    record(markersIn: NSRange(location: 0, length: storage.length), of: storage)
    edited()
  }

  public func prompt(of storage: NSTextStorage) -> TranscriptQuotedPrompt {
    if let cached { return cached }

    let prompt = orphanMarkers.isEmpty ? promptFromBadges(of: storage) : TranscriptQuoteBadgeText.prompt(in: storage)
    cached = prompt
    return prompt
  }

  public func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: TextStorageEditActions, range editedRange: NSRange,
    changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }

    let replaced = NSRange(location: editedRange.location, length: editedRange.length - delta)
    Self.shift(&badges, replacing: replaced, by: delta)
    Self.shift(&orphanMarkers, replacing: replaced, by: delta)
    record(markersIn: editedRange, of: textStorage)
    edited()
  }

  private func edited() {
    revision &+= 1
    cached = nil
  }

  private func promptFromBadges(of storage: NSTextStorage) -> TranscriptQuotedPrompt {
    let utf8 = storage.mutableString.data(using: String.Encoding.utf8.rawValue) ?? Data()
    let text = String(decoding: utf8, as: UTF8.self)
    let quotes = badges.compactMap { Self.badge(in: storage, at: $0)?.quote }
    return TranscriptQuotedPrompt(text: text, quotes: quotes)
  }

  private func record(markersIn range: NSRange, of storage: NSTextStorage) {
    let characters = storage.mutableString
    var found: [Int] = []
    var orphans: [Int] = []
    var searched = range
    while searched.length > 0 {
      let hit = characters.range(of: TranscriptQuotedPrompt.quoteMarker, options: .literal, range: searched)
      guard hit.location != NSNotFound else { break }
      if Self.badge(in: storage, at: hit.location) == nil {
        orphans.append(hit.location)
      } else {
        found.append(hit.location)
      }
      searched = NSRange(location: NSMaxRange(hit), length: NSMaxRange(searched) - NSMaxRange(hit))
    }
    badges = (badges + found).sorted()
    orphanMarkers = (orphanMarkers + orphans).sorted()
  }

  private static func badge(in storage: NSTextStorage, at location: Int) -> TranscriptQuoteBadgeAttachment? {
    guard location < storage.length else { return nil }
    return storage.attribute(.attachment, at: location, effectiveRange: nil) as? TranscriptQuoteBadgeAttachment
  }

  private static func shift(_ locations: inout [Int], replacing replaced: NSRange, by delta: Int) {
    guard !locations.isEmpty else { return }
    locations = locations.compactMap { location in
      if location < replaced.location { return location }
      if location < NSMaxRange(replaced) { return nil }
      return location + delta
    }
  }
}
