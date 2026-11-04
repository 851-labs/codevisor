import UIKit

extension UIWindow {
  static var codevisorKeyWindow: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
    return scenes.lazy.flatMap(\.windows).first(where: \.isKeyWindow)
      ?? scenes.first?.keyWindow
  }
}
