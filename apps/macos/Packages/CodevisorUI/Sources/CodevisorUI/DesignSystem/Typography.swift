import SwiftUI

/// Central typography tokens for both apps, grounded in the Apple Human
/// Interface Guidelines "Typography" chapter.
///
/// Two rules this file exists to enforce:
/// 1. Text never renders below the platform's minimum legible size
///    (HIG: 11 pt on iOS/iPadOS, 10 pt on macOS).
/// 2. Recurring "magic" point sizes live here under one name instead of
///    being copy-pasted at call sites, so hierarchy stays consistent and a
///    future change lands everywhere at once.
///
/// Prefer the system text styles (`.body`, `.headline`, `.caption`, …) for
/// anything readable — they support Dynamic Type on iOS and keep the
/// hierarchy consistent on macOS. Reach for these tokens only where a text
/// style genuinely doesn't fit (SF Symbol glyph sizing, display-scale hero
/// titles, and deliberately compact chrome).
public enum Typography {
    // MARK: Platform floors (HIG "Ensuring legibility")

    /// The HIG minimum legible text size for the current platform.
    /// iOS/iPadOS: 11 pt · macOS: 10 pt. Nothing readable may go below this.
    public static let minimumTextSize: CGFloat = {
        #if os(macOS)
            return 10
        #else
            return 11
        #endif
    }()

    /// The HIG default body text size for the current platform.
    /// iOS/iPadOS: 17 pt · macOS: 13 pt.
    public static let defaultTextSize: CGFloat = {
        #if os(macOS)
            return 13
        #else
            return 17
        #endif
    }()

    // MARK: SF Symbol glyph sizes

    /// Point sizes for `Image(systemName:)` glyphs in app chrome. These are
    /// glyph sizes, not text sizes — but they are still tokens so the same
    /// role always renders at the same size.
    public enum IconSize {
        /// Disclosure chevrons in settings rows.
        public static let disclosure: CGFloat = 10
        /// The smallest allowed glyph: close/remove badges, picker
        /// indicators, and other compact overlay controls. Matches the
        /// macOS 10 pt legibility floor — never size a glyph below this.
        public static let compact: CGFloat = 10
        /// Small chrome glyphs: tab icons, "+" buttons, chip icons,
        /// prev/next arrows.
        public static let chrome: CGFloat = 12
        /// Toolbar-weight glyphs: attach button, overflow ellipsis,
        /// provider icons.
        public static let toolbar: CGFloat = 13
        /// Hero/empty-state symbols above a title (onboarding steps,
        /// migration screens, failure states).
        public static let hero: CGFloat = 34
    }

    // MARK: Display sizes (macOS)

    /// Display-scale sizes that intentionally exceed the built-in text
    /// styles. Use through the `Font` extensions below.
    public enum DisplaySize {
        /// Onboarding welcome hero title.
        public static let heroTitle: CGFloat = 36
        /// Onboarding step / consent screen title.
        public static let stepTitle: CGFloat = 28
        /// Empty-state hero title. Matches macOS `.largeTitle` (26 pt);
        /// prefer `.largeTitle` where the semantic style is available.
        public static let emptyStateTitle: CGFloat = 26
    }

    // MARK: Compact chrome (macOS)

    /// Pane/workspace tab labels — the deliberate "between `.subheadline`
    /// (11 pt) and `.callout` (12 pt)" size used across the tab system.
    public static let tabLabelSize: CGFloat = 11.5
}

// MARK: - Semantic fonts

extension Font {
    /// Onboarding welcome hero title (36 pt bold display size).
    public static let heroTitle = Font.system(
        size: Typography.DisplaySize.heroTitle, weight: .bold
    )

    /// Onboarding step / consent screen title (28 pt bold display size).
    public static let stepTitle = Font.system(
        size: Typography.DisplaySize.stepTitle, weight: .bold
    )

    /// Empty-state hero title (26 pt semibold — the macOS `.largeTitle`
    /// size with the app's hero weight).
    public static let emptyStateTitle = Font.system(
        size: Typography.DisplaySize.emptyStateTitle, weight: .semibold
    )

    /// Pane/workspace tab label (11.5 pt).
    public static func tabLabel(weight: Font.Weight = .regular) -> Font {
        .system(size: Typography.tabLabelSize, weight: weight)
    }
}
