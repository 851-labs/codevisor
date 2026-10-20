import SwiftUI
import CodevisorCore
import CodevisorUI

struct ErrorBannerLayer: View {
  var reporter: ErrorReporter = .shared

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      ForEach(reporter.entries) { entry in
        ErrorBannerView(entry: entry) {
          reporter.dismiss(entry.id)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .padding(.top, 12)
    .padding(.trailing, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    .animation(.snappy(duration: 0.25), value: reporter.entries)
    .allowsHitTesting(!reporter.entries.isEmpty)
  }
}

private struct ErrorBannerView: View {
  private var cardStyle = ComposerCardStyle()
  let entry: ErrorReporter.Entry
  let onDismiss: () -> Void
  @State private var isHovered = false

  init(entry: ErrorReporter.Entry, onDismiss: @escaping () -> Void) {
    self.entry = entry
    self.onDismiss = onDismiss
  }

  private var isNotice: Bool { entry.kind == .notice }
  private var symbolName: String { isNotice ? "info.circle.fill" : "exclamationmark.triangle.fill" }
  private var tint: Color { isNotice ? .accentColor : .red }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbolName)
        .font(.caption)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.title)
          .font(.caption.weight(.semibold))
        if let message = entry.message, !message.isEmpty {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
      .opacity(isHovered ? 1 : 0.6)
      .help("Dismiss")
      .accessibilityLabel("Dismiss")
    }
    .foregroundStyle(tint)
    .padding(ComposerCardStyle.contentPadding)
    .frame(width: 360, alignment: .leading)
    .background {
      ZStack {
        cardStyle.shape.fill(Color.windowBackgroundColor)
        cardStyle.shape.fill(tint.opacity(0.08))
      }
    }
    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isStaticText)
  }
}

#if DEBUG
  #Preview("Error banners") {
    let reporter = ErrorReporter()
    reporter.report(
      "Couldn't save your settings",
      message: "The disk may be full. Free up space and try again."
    )
    reporter.report(
      "Couldn't delete the session on the server",
      message: "It may reappear the next time this list refreshes."
    )
    reporter.notify(
      "Claude is now signed in through Codevisor on all your machines. Claude Code on this Mac was signed out."
    )
    return ZStack {
      Color(nsColor: .windowBackgroundColor)
      ErrorBannerLayer(reporter: reporter)
    }
    .frame(width: 700, height: 400)
  }
#endif
