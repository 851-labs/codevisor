import CodevisorCore
import SwiftUI

enum AIDataSharingConsent {
  // Increase this when the disclosed data or recipients change materially.
  static let currentVersion = 1
  static let preferenceKey = "ios.aiDataSharing.consentVersion"
  static let privacyPolicyURL = URL(string: "https://www.codevisor.dev/privacy")!
}

struct AIDataSharingConsentScreen: View {
  /// Omitted when reviewing the disclosure in Settings.
  var onAgree: (() -> Void)?

  var body: some View {
    ScrollView {
      VStack(spacing: 32) {
        VStack(spacing: 20) {
          Image(systemName: "lock.fill")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: 80, height: 80)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))
            .accessibilityHidden(true)

          Text("Where your data goes")
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 24) {
          disclosureRow(
            symbol: "doc.text",
            question: "What is shared?",
            answer: "Prompts, relevant chat history, code, attachments, and tool results."
          )
          disclosureRow(
            symbol: "building.2",
            question: "Who receives it?",
            answer: "OpenAI, Anthropic, Google, Cursor, or xAI, depending on the agents and models you choose."
          )
          disclosureRow(
            symbol: "sparkles",
            question: "Why is it shared?",
            answer: "To process your requests and run your agents."
          )
        }
      }
      .frame(maxWidth: 480)
      .padding(.horizontal, 28)
      .padding(.top, 28)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity)
    }
    .background(Color(.systemBackground))
    .navigationBarTitleDisplayMode(.inline)
    .toolbarVisibility(.visible, for: .navigationBar)
    .safeAreaInset(edge: .bottom) {
      if let onAgree {
        VStack(spacing: 12) {
          Button("Continue", action: onAgree)
            .buttonStyle(OnboardingFilledButtonStyle(background: .accentColor, foreground: .white))
            .accessibilityIdentifier("aiConsent.agree")

          Text("By continuing, you agree to share this data with your selected AI providers.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
      }
    }
  }

  private func disclosureRow(symbol: String, question: String, answer: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text(question)
          .font(.subheadline.weight(.semibold))
        Text(answer)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
