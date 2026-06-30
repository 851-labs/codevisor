import SwiftUI
import AppKit
import HerdManCore

/// The active session screen: a streaming transcript with the composer floating
/// over the bottom of the history (no divider), and enough bottom inset that the
/// last message can scroll clear of the composer.
struct SessionScreen: View {
    @Bindable var controller: SessionController
    @State private var isAtBottom = true
    @State private var composerHeight: CGFloat = 96
    private let bottomID = "session-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(controller.conversation) { item in
                        ConversationItemView(item: item)
                    }
                    if let error = controller.errorMessage {
                        errorBanner(error)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, composerHeight + 24)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Distance from the visible bottom to the end of the content.
                geometry.contentSize.height - geometry.visibleRect.maxY
            } action: { _, distance in
                // At the bottom once only the composer-clearance padding remains.
                isAtBottom = distance <= composerHeight + 8
            }
            .onChange(of: streamFingerprint) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    scrollToBottomButton(proxy)
                        .padding(.bottom, composerHeight + 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .overlay(alignment: .bottom) { composerOverlay }
            .animation(.snappy(duration: 0.2), value: isAtBottom)
        }
    }

    private func scrollToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Scroll to bottom")
    }

    private var composerOverlay: some View {
        VStack(spacing: 6) {
            ComposerCard(controller: controller, placeholder: "Ask for follow-up changes")
            statusLabel
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
        .padding(.top, 24)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0),
                    Color(nsColor: .windowBackgroundColor).opacity(0.9),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status {
        case let .connecting(message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
            .font(.callout)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.1)))
    }

    private var streamFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(controller.conversation.count)
        if case let .assistant(message) = controller.conversation.last {
            hasher.combine(message.turn.entries.count)
            hasher.combine(message.turn.isThinking)
            if case let .text(_, markdown) = message.turn.finalText {
                hasher.combine(markdown.count)
            }
        }
        return hasher.finalize()
    }
}

#if DEBUG
#Preview("Conversation") {
    SessionScreen(controller: .preview(model: .preview()))
        .frame(width: 900, height: 680)
}
#endif
