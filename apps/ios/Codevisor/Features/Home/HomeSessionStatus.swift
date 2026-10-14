import Foundation

enum HomeSessionStatus: Int, Comparable {
  case error = 0
  case actionRequired = 1
  case unread = 2
  case inProgress = 3
  case idle = 4

  static func < (left: Self, right: Self) -> Bool {
    left.rawValue < right.rawValue
  }
}
