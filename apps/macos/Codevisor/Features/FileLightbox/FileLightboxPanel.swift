import CodevisorUI
import SwiftUI

struct FileLightboxPanel: View {
  let lightbox: FileLightbox

  private static let cornerRadius: CGFloat = 14
  private static let verticalInset: CGFloat = 36
  private static let maximumWidth: CGFloat = 1500

  var body: some View {
    ZStack {
      Color.black.opacity(0.5)
        .contentShape(Rectangle())
        .onTapGesture { lightbox.dismiss() }
        .accessibilityHidden(true)
      HStack(spacing: 0) {
        FileLightboxPagingButton(direction: .previous, lightbox: lightbox)
        card
        FileLightboxPagingButton(direction: .next, lightbox: lightbox)
      }
      .padding(.vertical, Self.verticalInset)
    }
    .ignoresSafeArea()
    .accessibilityAddTraits(.isModal)
  }

  private var card: some View {
    VStack(spacing: 0) {
      FileLightboxBar(lightbox: lightbox)
      Divider()
      FileLightboxStage(lightbox: lightbox)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: Self.maximumWidth)
    .background(WindowBackgroundMaterial())
    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.separator, lineWidth: 1))
    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
  }
}

private struct FileLightboxPagingButton: View {
  enum Direction {
    case previous
    case next
  }

  let direction: Direction
  let lightbox: FileLightbox

  private static let gutter: CGFloat = 64

  var body: some View {
    ZStack {
      if lightbox.canPage {
        Button(action: page) {
          Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(.regularMaterial, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
      }
    }
    .frame(width: Self.gutter)
  }

  private var symbol: String {
    switch direction {
    case .previous: "chevron.left"
    case .next: "chevron.right"
    }
  }

  private var title: String {
    switch direction {
    case .previous: "Previous"
    case .next: "Next"
    }
  }

  private func page() {
    switch direction {
    case .previous: lightbox.showPrevious()
    case .next: lightbox.showNext()
    }
  }
}
