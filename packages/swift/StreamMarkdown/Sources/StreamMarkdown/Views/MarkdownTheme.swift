import Foundation
import SwiftUI

/// A complete code-block snapshot. `id` remains stable while a streaming block
/// grows so a native highlighter can reuse its previous lexical state.
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

/// Asynchronously turns a fenced code block into a syntax-highlighted
/// attributed string, or nil to keep plain text. Injected by the host app; the
/// markdown package itself remains independent of a highlighting engine.
public typealias CodeHighlighting =
  @Sendable (_ request: CodeHighlightRequest) async -> AttributedString?

/// Lets a host intercept links rendered by StreamMarkdown's native TextKit
/// views. Returning `true` means the host handled the URL; returning `false`
/// preserves the platform's normal URL-opening behavior.
public struct MarkdownLinkAction: @unchecked Sendable {
  private let handler: @MainActor (URL) -> Bool
  /// Host behavior for images the renderer draws inline. Nil treats an
  /// image activation like any other link.
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

  /// Activates a link. An inline image is a different affordance from a
  /// text link to the same file — its primary activation previews — so
  /// image activations go to the image handler first.
  @MainActor
  public func activate(_ url: URL, isImage: Bool) -> Bool {
    if isImage, let images, images.open(url) { return true }
    return handler(url)
  }
}

/// What the host does with an image rendered inline: the primary
/// activation (a preview) and the secondary actions its menu offers.
public struct MarkdownImageActions: @unchecked Sendable {
  public var open: @MainActor (URL) -> Bool
  public var openInNewTab: (@MainActor (URL) -> Void)?
  public var copy: (@MainActor (URL) -> Void)?

  public init(
    open: @escaping @MainActor (URL) -> Bool,
    openInNewTab: (@MainActor (URL) -> Void)? = nil,
    copy: (@MainActor (URL) -> Void)? = nil
  ) {
    self.open = open
    self.openInNewTab = openInNewTab
    self.copy = copy
  }
}

/// Visual styling for markdown rendering, injected through the environment so
/// the host app can customize fonts, spacing, and colors.
public struct MarkdownTheme: Sendable {
  public var bodyFont: Font
  public var codeFont: Font
  /// Primary and secondary prose colors. Native TextKit views cannot inherit
  /// SwiftUI's foreground-style environment, so the host supplies both
  /// semantic colors explicitly with the rest of the markdown theme.
  public var textForeground: Color
  public var secondaryTextForeground: Color
  /// Base foreground for fenced code. Highlighted tokens override this;
  /// uncolored tokens inherit it.
  public var codeForeground: Color
  /// Font for `` `inline code` `` chips: monospaced and a touch smaller
  /// than the body text so chips sit flush in a line of prose.
  public var inlineCodeFont: Font
  public var blockSpacing: CGFloat
  /// Extra vertical breathing room between list items (points).
  public var listItemSpacing: CGFloat
  /// Extra space between wrapped lines within a block (points).
  public var lineSpacing: CGFloat
  public var codeBackground: Color
  /// Background tint for `` `inline code` `` chips.
  public var inlineCodeBackground: Color
  /// Corner radius of the rounded chip background painted behind
  /// `` `inline code` `` runs (clamped to half the chip height at draw
  /// time).
  public var inlineCodeCornerRadius: CGFloat
  public var quoteBarColor: Color
  public var tableBorderColor: Color
  public var codeHighlighter: CodeHighlighting?
  /// A stable identity for the active highlight theme (e.g. its id).
  /// Closures can't be compared, so code blocks watch this to know when a
  /// theme switch requires re-highlighting.
  public var codeThemeKey: String

  public init(
    bodyFont: Font = .body,
    codeFont: Font = .system(.callout, design: .monospaced),
    textForeground: Color = .primary,
    secondaryTextForeground: Color = .secondary,
    codeForeground: Color = .primary,
    inlineCodeFont: Font = .system(.callout, design: .monospaced),
    blockSpacing: CGFloat = 10,
    listItemSpacing: CGFloat = 4,
    lineSpacing: CGFloat = 3,
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
    self.blockSpacing = blockSpacing
    self.listItemSpacing = listItemSpacing
    self.lineSpacing = lineSpacing
    self.codeBackground = codeBackground
    self.inlineCodeBackground = inlineCodeBackground
    self.inlineCodeCornerRadius = inlineCodeCornerRadius
    self.quoteBarColor = quoteBarColor
    self.tableBorderColor = tableBorderColor
    self.codeHighlighter = codeHighlighter
    self.codeThemeKey = codeThemeKey
  }

  public static let `default` = MarkdownTheme()

  /// Hash of every render-affecting field except the highlighter closure
  /// (closures can't be compared; `codeThemeKey` stands in for it, by the
  /// same contract code blocks rely on). Render memos key on this to
  /// detect theme switches without making the whole theme Equatable.
  public var renderFingerprint: Int {
    var hasher = Hasher()
    hasher.combine(bodyFont)
    hasher.combine(codeFont)
    hasher.combine(textForeground)
    hasher.combine(secondaryTextForeground)
    hasher.combine(codeForeground)
    hasher.combine(inlineCodeFont)
    hasher.combine(blockSpacing)
    hasher.combine(listItemSpacing)
    hasher.combine(lineSpacing)
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
  /// The horizontal padding the host lays around markdown content, which a
  /// too-wide table's horizontal scroller may bleed through (iOS): the
  /// table rests aligned with the text column, but its scroll viewport
  /// extends `markdownTableBleed` points past each side, so scrolling
  /// carries the table all the way to the screen edges instead of stopping
  /// at the text gutter. Zero (the default) keeps tables inside the text
  /// column. Text and every other block keep the host padding untouched.
  var markdownTableBleed: CGFloat {
    get { self[MarkdownTableBleedKey.self] }
    set { self[MarkdownTableBleedKey.self] = newValue }
  }

  /// The farthest a wide table's scroll viewport may extend past the text
  /// column on either side, on every platform. The transcript leaves this
  /// unbounded so tables scroll to the window edges (macOS measures the
  /// gutter, iOS uses `markdownTableBleed`). A bordered container that
  /// hosts markdown — the proposed-plan card — caps it at its own inner
  /// padding so a wide table scrolls inside the card instead of across its
  /// border and out over the transcript gutter.
  var markdownTableBleedLimit: CGFloat {
    get { self[MarkdownTableBleedLimitKey.self] }
    set { self[MarkdownTableBleedLimitKey.self] = newValue }
  }

  var markdownLinkAction: MarkdownLinkAction? {
    get { self[MarkdownLinkActionKey.self] }
    set { self[MarkdownLinkActionKey.self] = newValue }
  }
}

extension EnvironmentValues {
  /// The iOS table bleed after applying the enclosing container's limit.
  var resolvedMarkdownTableBleed: CGFloat {
    max(0, min(markdownTableBleed, markdownTableBleedLimit))
  }
}

public extension EnvironmentValues {
  var markdownTheme: MarkdownTheme {
    get { self[MarkdownThemeKey.self] }
    set { self[MarkdownThemeKey.self] = newValue }
  }
}

public extension View {
  /// Sets the markdown theme for this view hierarchy.
  func markdownTheme(_ theme: MarkdownTheme) -> some View {
    environment(\.markdownTheme, theme)
  }

  /// Handles Markdown links from both native TextKit surfaces and portable
  /// SwiftUI text (used by iOS tables). Unhandled URLs continue to the
  /// operating system.
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

  /// Gives inline images their own activation and menu, independent of
  /// the link handler (either modifier may wrap the other).
  func markdownImageActions(_ actions: MarkdownImageActions) -> some View {
    let unhandled: @MainActor (URL) -> Bool = { _ in false }
    return transformEnvironment(\.markdownLinkAction) { action in
      action = MarkdownLinkAction(action?.linkHandler ?? unhandled, images: actions)
    }
  }
}
