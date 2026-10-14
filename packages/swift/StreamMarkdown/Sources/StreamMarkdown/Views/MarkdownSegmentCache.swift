import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

@MainActor
public final class MarkdownSegmentCache {
  public static let shared = MarkdownSegmentCache()

  private let parser = MarkdownParser()
  private var entries: [String: [MarkdownSegment]] = [:]
  private var order: [String] = []
  private let limit: Int

  public init(limit: Int = 128) {
    self.limit = max(1, limit)
  }

  public func segments(for text: String) -> [MarkdownSegment] {
    if let cached = entries[text] {
      markUsed(text)
      return cached
    }
    let segments = parse(text)
    store(segments, for: text)
    return segments
  }

  func cachedSegments(for text: String) -> [MarkdownSegment]? {
    guard let cached = entries[text] else { return nil }
    markUsed(text)
    return cached
  }

  public func parse(_ text: String) -> [MarkdownSegment] {
    MarkdownSegment.segments(from: parser.parse(text))
  }

  func store(_ segments: [MarkdownSegment], for text: String) {
    entries[text] = segments
    order.append(text)
    if order.count > limit {
      entries.removeValue(forKey: order.removeFirst())
    }
  }

  private func markUsed(_ text: String) {
    guard order.last != text, let index = order.firstIndex(of: text) else { return }
    order.remove(at: index)
    order.append(text)
  }
}

@MainActor
public final class CodeHighlightResultCache {
  public struct Key: Hashable, Sendable {
    public let themeKey: String
    public let language: String?
    public let code: String

    public init(themeKey: String, language: String?, code: String) {
      self.themeKey = themeKey
      self.language = language
      self.code = code
    }
  }

  public static let shared = CodeHighlightResultCache()

  private var entries: [Key: AttributedString] = [:]
  private var order: [Key] = []
  private let limit: Int

  public init(limit: Int = 100) {
    self.limit = max(1, limit)
  }

  public func value(for key: Key) -> AttributedString? {
    guard let cached = entries[key] else { return nil }
    markUsed(key)
    return cached
  }

  public func store(_ value: AttributedString, for key: Key) {
    if entries[key] == nil {
      order.append(key)
      if order.count > limit {
        entries.removeValue(forKey: order.removeFirst())
      }
    } else {
      markUsed(key)
    }
    entries[key] = value
  }

  private func markUsed(_ key: Key) {
    guard order.last != key, let index = order.firstIndex(of: key) else { return }
    order.remove(at: index)
    order.append(key)
  }
}

#if canImport(AppKit)
  @MainActor
  final class PlainTextRenderCache {
    static let shared = PlainTextRenderCache()

    private final class Entry {
      let value: NSAttributedString
      var lastAccess: UInt64

      init(value: NSAttributedString, lastAccess: UInt64) {
        self.value = value
        self.lastAccess = lastAccess
      }
    }

    private var entries: [PlainTextModel: Entry] = [:]
    private var accessClock: UInt64 = 0
    private let limit: Int

    init(limit: Int = 256) {
      self.limit = max(1, limit)
    }

    func value(for model: PlainTextModel) -> NSAttributedString {
      if let entry = entries[model] {
        entry.lastAccess = tick()
        return entry.value
      }
      let value = model.attributedText
      entries[model] = Entry(value: value, lastAccess: tick())
      evictOldestIfNeeded()
      return value
    }

    private func tick() -> UInt64 {
      accessClock &+= 1
      return accessClock
    }

    private func evictOldestIfNeeded() {
      guard entries.count > limit,
        let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
      else { return }
      entries.removeValue(forKey: oldest.key)
    }
  }

#endif

#if canImport(AppKit) || canImport(UIKit)
  @MainActor
  final class MarkdownTextRunCache {
    struct ColorKey: Hashable {
      let colorSpace: String
      let red: CGFloat
      let green: CGFloat
      let blue: CGFloat
      let alpha: CGFloat

      init(_ color: Color) {
        #if canImport(AppKit)
          let resolved = NSColor(color)
          let rgb = resolved.usingColorSpace(.deviceRGB)
          colorSpace = rgb == nil ? String(describing: resolved) : "deviceRGB"
          red = rgb?.redComponent ?? 0
          green = rgb?.greenComponent ?? 0
          blue = rgb?.blueComponent ?? 0
          alpha = rgb?.alphaComponent ?? resolved.alphaComponent
        #else
          let resolved = UIColor(color)
          var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
          let rgb = resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
          colorSpace = rgb ? "deviceRGB" : String(describing: resolved)
          red = r; green = g; blue = b; alpha = a
        #endif
      }
    }

    struct Key: Hashable {
      let blocks: [MarkdownBlock]
      let themeFingerprint: Int
      let foregroundColor: ColorKey
    }

    static let shared = MarkdownTextRunCache()

    private final class Entry {
      let value: NSAttributedString
      var lastAccess: UInt64

      init(value: NSAttributedString, lastAccess: UInt64) {
        self.value = value
        self.lastAccess = lastAccess
      }
    }

    private var entries: [Key: Entry] = [:]
    private var accessClock: UInt64 = 0
    private let limit: Int

    init(limit: Int = 192) {
      self.limit = max(1, limit)
    }

    func value(for key: Key) -> NSAttributedString? {
      guard let entry = entries[key] else { return nil }
      entry.lastAccess = tick()
      return entry.value
    }

    func store(_ value: NSAttributedString, for key: Key) {
      if let entry = entries[key] {
        entry.lastAccess = tick()
        return
      }
      entries[key] = Entry(value: value, lastAccess: tick())
      evictOldestIfNeeded()
    }

    private func tick() -> UInt64 {
      accessClock &+= 1
      return accessClock
    }

    private func evictOldestIfNeeded() {
      guard entries.count > limit,
        let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
      else { return }
      entries.removeValue(forKey: oldest.key)
    }
  }
#endif
