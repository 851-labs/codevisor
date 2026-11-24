import SwiftUI

public struct AttachmentChipIcon: View {
  public init() {}

  public var body: some View {
    Image(systemName: "doc")
      .foregroundStyle(.secondary)
      .frame(width: 18, height: 18)
  }
}
