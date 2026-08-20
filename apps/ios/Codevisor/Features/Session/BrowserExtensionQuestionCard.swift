import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Touch-native Chrome extension setup. The extension belongs on the
/// computer running the Codevisor server, not on the phone, so iOS opens the
/// desktop installer remotely and turns the composer into a clear waiting
/// surface. The server auto-resolves the held question when Chrome connects.
struct BrowserExtensionQuestionCard: View {
    @Bindable var controller: SessionController
    let question: QuestionSpec

    @State private var didOpenSetup = false
    @State private var isOpeningSetup = false
    @State private var errorMessage: String?

    private var isWaiting: Bool {
        question.presentation == .browserExtensionWaiting || didOpenSetup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isWaiting {
                waitingContent
            } else {
                setupContent
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Chrome setup failed. \(errorMessage)")
            }

            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isWaiting ? "Finish Chrome setup" : "Connect Chrome")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Add Codevisor to Chrome", systemImage: "puzzlepiece.extension")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Button {
                Task { await controller.cancelQuestion() }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .scaledFrame(width: 28, height: 28, relativeTo: .caption)
                    .expandedHitTarget(base: 28)
            }
            .buttonStyle(HoverIconButtonStyle(shape: .circle))
            .accessibilityLabel("Dismiss Chrome setup")
        }
    }

    private var setupContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Continue on your computer")
                    .font(.subheadline.weight(.medium))
                Text(
                    "Chrome’s Extensions page and the Codevisor extension folder will open on the computer running this chat."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            openSetupButton(title: "Open Chrome Setup", prominent: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.5))
        )
    }

    private var waitingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Waiting for Chrome…")
                    .font(.subheadline.weight(.medium))
                Text(
                    "On your computer, turn on Developer mode, choose Load unpacked, and select the Codevisor extension folder. This card closes when Chrome connects."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            openSetupButton(title: "Open Setup Again", prominent: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill).opacity(0.5))
        )
    }

    @ViewBuilder
    private func openSetupButton(title: String, prominent: Bool) -> some View {
        if prominent {
            setupButton(title: title)
                .buttonStyle(.borderedProminent)
        } else {
            setupButton(title: title)
                .buttonStyle(.bordered)
        }
    }

    private func setupButton(title: String) -> some View {
        Button {
            openSetup()
        } label: {
            HStack(spacing: 8) {
                if isOpeningSetup {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "macwindow.on.rectangle")
                }
                Text(isOpeningSetup ? "Opening…" : title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(isOpeningSetup)
        .accessibilityHint("Opens Chrome and Finder on the computer running this chat")
    }

    private var footer: some View {
        HStack {
            if let backOptionLabel = question.backOptionLabel {
                Button {
                    Task {
                        await controller.answerQuestion(answers: [
                            question.id: QuestionAnswerEntry(answers: [backOptionLabel])
                        ])
                    }
                } label: {
                    Label("Back", systemImage: "arrow.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .expandedHitTarget(base: 34)
                .accessibilityHint("Returns to browser selection")
            }
            Spacer(minLength: 0)
        }
    }

    private func openSetup() {
        guard !isOpeningSetup else { return }
        isOpeningSetup = true
        errorMessage = nil
        Task {
            do {
                try await controller.openBrowserExtensionInstaller()
                didOpenSetup = true
            } catch {
                errorMessage = ErrorReporter.userFacingMessage(for: error)
            }
            isOpeningSetup = false
        }
    }
}
