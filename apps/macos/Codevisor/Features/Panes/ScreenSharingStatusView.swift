import ScreenSharingConnection
import SwiftUI

struct ScreenSharingStatusView: View {
  enum Size { case pane, card }

  enum Content: Equatable {
    case progress(title: String, details: [String])
    case failure(sentence: String, action: ScreenSharingFailureAction?)
  }

  let content: Content
  let size: Size
  let onAction: (ScreenSharingFailureAction) -> Void

  var body: some View {
    VStack(spacing: size == .pane ? 12 : 8) {
      switch content {
      case .progress(let title, let details): progress(title, details)
      case .failure(let sentence, let action): failure(sentence, action)
      }
    }
    .padding(size == .pane ? 24 : 16)
  }

  @ViewBuilder
  private func progress(_ title: String, _ details: [String]) -> some View {
    ProgressView().controlSize(.small)
    Text(title)
      .font(size == .pane ? .body : .callout)
      .foregroundStyle(size == .pane ? .primary : .secondary)
      .multilineTextAlignment(.center)
    ForEach(details, id: \.self) { detail in
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
  }

  @ViewBuilder
  private func failure(_ sentence: String, _ action: ScreenSharingFailureAction?) -> some View {
    Image(systemName: "display.trianglebadge.exclamationmark")
      .font(size == .pane ? .largeTitle : .title2)
      .foregroundStyle(.secondary)
    Text(sentence)
      .font(size == .pane ? .body : .callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: size == .pane ? 380 : nil)
    if let action {
      Button(Self.label(action)) { onAction(action) }
        .controlSize(size == .pane ? .regular : .small)
    }
  }

  private static func label(_ action: ScreenSharingFailureAction) -> String {
    switch action {
    case .viewHere: "View here"
    case .connect: "Connect"
    case .retry: "Retry"
    }
  }
}
