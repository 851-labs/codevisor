import SwiftUI

public struct LaunchMark: View {
  public init() {}

  public var body: some View {
    CodevisorSymbol.codevisorMark.image
      .resizable()
      .scaledToFit()
      .frame(height: Self.height)
      .foregroundStyle(.primary)
      .accessibilityHidden(true)
  }

  private static var height: CGFloat {
    #if os(macOS)
      46
    #else
      56
    #endif
  }
}
