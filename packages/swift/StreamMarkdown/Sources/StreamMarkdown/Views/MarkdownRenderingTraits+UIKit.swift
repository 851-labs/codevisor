#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI
  import UIKit

  /// Immutable traits captured for an isolated text-preparation operation.
  /// Dynamic Type and dynamic colors must match the requesting view even
  /// when UIKit's thread-local current traits differ on the worker.
  struct MarkdownRenderingTraits: Sendable {
    private let traits: UITraitCollection

    @MainActor init(dynamicTypeSize: DynamicTypeSize, colorScheme: ColorScheme) {
      let category: UIContentSizeCategory =
        switch dynamicTypeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        default: .large
        }
      traits = UITraitCollection {
        $0.preferredContentSizeCategory = category
        $0.userInterfaceStyle = colorScheme == .dark ? .dark : .light
      }
    }

    func perform<T>(_ operation: () throws -> T) throws -> T {
      var result: Result<T, Error>?
      traits.performAsCurrent { result = Result(catching: operation) }
      return try result!.get()
    }
  }
#endif
