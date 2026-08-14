import CoreGraphics

/// Platform-neutral table sizing shared by the AppKit/TextKit table renderer
/// (macOS) and the portable SwiftUI table renderer (iOS), so the two produce
/// the same cell padding, chrome, and column widths for the same content.
enum MarkdownTableMetrics {
    /// Horizontal padding inside each cell, per edge.
    static let horizontalPadding: CGFloat = 12
    /// Vertical padding inside each cell, per edge.
    static let verticalPadding: CGFloat = 7
    /// Corner radius of the rounded outer border.
    static let cornerRadius: CGFloat = 8
    /// Opacity of the neutral header-row fill, applied over the platform's
    /// label color so it works in light and dark mode.
    static let headerBackgroundOpacity: CGFloat = 0.05

    /// Sizes the columns to fill `width`, mirroring CSS auto table layout:
    ///
    /// - Room to spare → columns grow proportionally to their natural widths.
    /// - Squeezed → the deficit is taken from each column in proportion to its
    ///   slack (natural − minimum), so a column never shrinks below its
    ///   min-content width. One long prose column absorbs nearly all the
    ///   squeeze (and wraps), while short columns like "Swift" or "560" keep
    ///   their content on one line. A pure proportional scale has no such
    ///   floor: a single long cell makes the scale tiny and crushes narrow
    ///   columns to ~one character, wrapping them vertically.
    /// - Even the minimums don't fit → two strategies, chosen by the caller:
    ///   `compressesBelowMinimums: true` (macOS TextKit — no horizontal
    ///   scrolling exists there) scales the minimums down as a last resort;
    ///   `false` (iOS — the table sits in a horizontal scroll view) keeps
    ///   every column at min-content and lets the table overflow its width.
    ///   Compressing below min-content degrades into per-character wrapping —
    ///   on a phone a wide table became thousands of points tall.
    ///
    /// Widths are content widths (padding excluded); `width` is the full table
    /// width (padding included). Nil width → natural widths unchanged.
    static func distribute(
        contentWidths: [CGFloat],
        minimumWidths: [CGFloat],
        toFit width: CGFloat?,
        compressesBelowMinimums: Bool = true
    ) -> [CGFloat] {
        guard let width, width.isFinite, width > 0 else {
            return contentWidths.map { max(1, $0) }
        }
        let naturals = contentWidths.map { max(1, $0) }
        let minimums = zip(minimumWidths, naturals).map { min(max(1, $0), $1) }
        let paddingTotal = horizontalPadding * 2 * CGFloat(naturals.count)
        // Never let the content budget vanish: keep at least 1pt per column even
        // when the proposed width is smaller than the padding alone.
        let contentBudget = max(CGFloat(naturals.count), width - paddingTotal)

        let naturalTotal = naturals.reduce(0, +)
        if naturalTotal <= contentBudget {
            // Room to spare — expand proportionally to fill the width.
            return naturals.map { $0 * (contentBudget / naturalTotal) }
        }

        let minimumTotal = minimums.reduce(0, +)
        if minimumTotal >= contentBudget {
            // Not even the minimums fit.
            guard compressesBelowMinimums else { return minimums }
            // Shrink them proportionally; some wrapping inside unbreakable
            // content is unavoidable here.
            return minimums.map { max(1, $0 * (contentBudget / minimumTotal)) }
        }

        // Squeezed, but every minimum fits: charge the deficit against each
        // column's slack so no column drops below its min-content width.
        let deficit = naturalTotal - contentBudget
        let slackTotal = naturalTotal - minimumTotal  // > 0 in this branch
        return zip(naturals, minimums).map { natural, minimum in
            max(minimum, natural - deficit * ((natural - minimum) / slackTotal))
        }
    }
}
