import Foundation

public struct QuestionOptionLabel: Equatable, Sendable {
  private static let recommendedMarker = "(recommended)"

  public let title: String
  public let isRecommended: Bool

  public init(_ label: String) {
    guard let marker = label.range(of: Self.recommendedMarker, options: .caseInsensitive) else {
      self.init(title: label, isRecommended: false)
      return
    }
    let title = label.replacingCharacters(in: marker, with: "").trimmingCharacters(in: .whitespaces)
    self.init(title: title.isEmpty ? label : title, isRecommended: !title.isEmpty)
  }

  private init(title: String, isRecommended: Bool) {
    self.title = title
    self.isRecommended = isRecommended
  }
}
