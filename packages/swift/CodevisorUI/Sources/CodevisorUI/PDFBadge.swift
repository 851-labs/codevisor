import SwiftUI

public struct PDFBadge: View {
  public init() {}

  public var body: some View {
    Text("PDF")
      .font(.caption2.weight(.bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
      .padding(4)
      .allowsHitTesting(false)
  }
}
