import CoreGraphics

enum MarkdownTableMetrics {
  static let horizontalPadding: CGFloat = 12
  static let verticalPadding: CGFloat = 7
  static let cornerRadius: CGFloat = 8
  static let headerBackgroundOpacity: CGFloat = 0.05

  static func minimumTableWidth(columnMinimumWidths: [CGFloat]) -> CGFloat {
    columnMinimumWidths.reduce(0) { $0 + max(1, $1) }
      + horizontalPadding * 2 * CGFloat(columnMinimumWidths.count)
  }

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
    let contentBudget = max(CGFloat(naturals.count), width - paddingTotal)

    let naturalTotal = naturals.reduce(0, +)
    if naturalTotal <= contentBudget {
      return naturals.map { $0 * (contentBudget / naturalTotal) }
    }

    let minimumTotal = minimums.reduce(0, +)
    if minimumTotal >= contentBudget {
      guard compressesBelowMinimums else { return minimums }
      return minimums.map { max(1, $0 * (contentBudget / minimumTotal)) }
    }

    let deficit = naturalTotal - contentBudget
    let slackTotal = naturalTotal - minimumTotal
    return zip(naturals, minimums).map { natural, minimum in
      max(minimum, natural - deficit * ((natural - minimum) / slackTotal))
    }
  }
}
