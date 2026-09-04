import ACPKit
import SwiftUI

/// The image tool owns its display even when the model sends no Markdown.
public struct ImageGenerationActivityView: View {
  private let call: ToolCall

  public init(call: ToolCall) { self.call = call }

  public var body: some View {
    VStack(spacing: 12) {
      if call.status == .failed {
        Image(systemName: "exclamationmark.triangle")
        Text("Image generation failed")
      } else if call.status == .cancelled {
        Image(systemName: "photo")
        Text("Image generation cancelled")
      } else {
        ProgressView()
        Text("Generating image…")
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, minHeight: 180)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .combine)
  }
}
