import UIKit

extension UIView {
  func firstDescendant(where predicate: (UIView) -> Bool) -> UIView? {
    for subview in subviews {
      if predicate(subview) { return subview }
      if let match = subview.firstDescendant(where: predicate) { return match }
    }
    return nil
  }
}
