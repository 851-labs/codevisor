import Foundation
import MarkdownCore
import SwiftUI

public struct CodeHighlightRequest: Sendable {
  public let id: String
  public let code: String
  public let language: String?
  public let isComplete: Bool

  public init(id: String, code: String, language: String?, isComplete: Bool) {
    self.id = id
    self.code = code
    self.language = language
    self.isComplete = isComplete
  }
}

public typealias CodeHighlighting =
  @Sendable (_ request: CodeHighlightRequest) async -> AttributedString?

public struct MarkdownLinkAction: @unchecked Sendable {
  private let handler: @MainActor (URL) -> Bool
  public var images: MarkdownImageActions?

  public init(_ handler: @escaping @MainActor (URL) -> Bool, images: MarkdownImageActions? = nil) {
    self.handler = handler
    self.images = images
  }

  @MainActor
  public func callAsFunction(_ url: URL) -> Bool {
    handler(url)
  }

  var linkHandler: @MainActor (URL) -> Bool { handler }

  @MainActor
  public func activate(
    _ url: URL,
    isImage: Bool,
    imagePreparing: (Task<Void, Never>) -> Void = { _ in }
  ) -> Bool {
    if isImage, let images, let preparing = images.open(url) {
      imagePreparing(preparing)
      return true
    }
    return handler(url)
  }
}

public struct MarkdownImageActions: @unchecked Sendable {
  public var open: @MainActor (URL) -> Task<Void, Never>?
  public var openInNewTab: (@MainActor (URL) -> Void)?
  public var copy: (@MainActor (URL) -> Void)?

  public init(
    open: @escaping @MainActor (URL) -> Task<Void, Never>?,
    openInNewTab: (@MainActor (URL) -> Void)? = nil,
    copy: (@MainActor (URL) -> Void)? = nil
  ) {
    self.open = open
    self.openInNewTab = openInNewTab
    self.copy = copy
  }
}

public struct MarkdownTheme: Sendable {
  public var bodyFont: Font
  public var codeFont: Font
  public var textForeground: Color
  public var secondaryTextForeground: Color
  public var codeForeground: Color
  public var inlineCodeFont: Font
  public var spacing: MarkdownSpacing
  public var codeBackground: Color
  public var inlineCodeBackground: Color
  public var inlineCodeCornerRadius: CGFloat
  public var quoteBarColor: Color
  public var tableBorderColor: Color
  public var codeHighlighter: CodeHighlighting?
  public var codeThemeKey: String

  public init(
    bodyFont: Font = .body,
    codeFont: Font = .system(.callout, design: .monospaced),
    textForeground: Color = .primary,
    secondaryTextForeground: Color = .secondary,
    codeForeground: Color = .primary,
    inlineCodeFont: Font = .system(.callout, design: .monospaced),
    spacing: MarkdownSpacing = MarkdownSpacing(),
    codeBackground: Color = Color.secondary.opacity(0.12),
    inlineCodeBackground: Color = Color.secondary.opacity(0.18),
    inlineCodeCornerRadius: CGFloat = 4,
    quoteBarColor: Color = Color.secondary.opacity(0.4),
    tableBorderColor: Color = Color.secondary.opacity(0.25),
    codeHighlighter: CodeHighlighting? = nil,
    codeThemeKey: String = "default"
  ) {
    self.bodyFont = bodyFont
    self.codeFont = codeFont
    self.textForeground = textForeground
    self.secondaryTextForeground = secondaryTextForeground
    self.codeForeground = codeForeground
    self.inlineCodeFont = inlineCodeFont
    self.spacing = spacing
    self.codeBackground = codeBackground
    self.inlineCodeBackground = inlineCodeBackground
    self.inlineCodeCornerRadius = inlineCodeCornerRadius
    self.quoteBarColor = quoteBarColor
    self.tableBorderColor = tableBorderColor
    self.codeHighlighter = codeHighlighter
    self.codeThemeKey = codeThemeKey
  }

  public static let `default` = MarkdownTheme()

  public var renderFingerprint: Int {
    var hasher = Hasher()
    hasher.combine(bodyFont)
    hasher.combine(codeFont)
    hasher.combine(textForeground)
    hasher.combine(secondaryTextForeground)
    hasher.combine(codeForeground)
    hasher.combine(inlineCodeFont)
    hasher.combine(spacing)
    hasher.combine(codeBackground)
    hasher.combine(inlineCodeBackground)
    hasher.combine(inlineCodeCornerRadius)
    hasher.combine(quoteBarColor)
    hasher.combine(tableBorderColor)
    hasher.combine(codeThemeKey)
    return hasher.finalize()
  }
}

private struct MarkdownThemeKey: EnvironmentKey {
  static let defaultValue = MarkdownTheme.default
}

private struct MarkdownTableBleedKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

private struct MarkdownTableBleedLimitKey: EnvironmentKey {
  static let defaultValue: CGFloat = .greatestFiniteMagnitude
}

private struct MarkdownLinkActionKey: EnvironmentKey {
  static let defaultValue: MarkdownLinkAction? = nil
}

public extension EnvironmentValues {
  var markdownTableBleed: CGFloat {
    get { self[MarkdownTableBleedKey.self] }
    set { self[MarkdownTableBleedKey.self] = newValue }
  }

  var markdownTableBleedLimit: CGFloat {
    get { self[MarkdownTableBleedLimitKey.self] }
    set { self[MarkdownTableBleedLimitKey.self] = newValue }
  }

  var markdownLinkAction: MarkdownLinkAction? {
    get { self[MarkdownLinkActionKey.self] }
    set { self[MarkdownLinkActionKey.self] = newValue }
  }
  internal var resolvedMarkdownTableBleed: CGFloat {
    max(0, min(markdownTableBleed, markdownTableBleedLimit))
  }
  var markdownTheme: MarkdownTheme {
    get { self[MarkdownThemeKey.self] }
    set { self[MarkdownThemeKey.self] = newValue }
  }
}

public extension View {
  func markdownTheme(_ theme: MarkdownTheme) -> some View {
    environment(\.markdownTheme, theme)
  }

  func markdownLinkHandler(
    _ handler: @escaping @MainActor (URL) -> Bool
  ) -> some View {
    let action = MarkdownLinkAction(handler)
    return transformEnvironment(\.markdownLinkAction) { current in
      current = MarkdownLinkAction(handler, images: current?.images)
    }
    .environment(
      \.openURL,
      OpenURLAction { url in
        action(url) ? .handled : .systemAction
      }
    )
  }

  func markdownImageActions(_ actions: MarkdownImageActions) -> some View {
    let unhandled: @MainActor (URL) -> Bool = { _ in false }
    return transformEnvironment(\.markdownLinkAction) { action in
      action = MarkdownLinkAction(action?.linkHandler ?? unhandled, images: actions)
    }
  }
}
