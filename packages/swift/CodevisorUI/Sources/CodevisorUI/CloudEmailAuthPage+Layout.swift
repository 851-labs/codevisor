import SwiftUI

extension CloudEmailAuthPage {
  @ViewBuilder
  var platformBody: some View {
    #if os(iOS)
      Form {
        Section {
          fields
          if step == .passwordReset { successMessage }
        } footer: {
          if let subtitle { Text(subtitle) }
          if step == .signUp { termsNotice }
        }
        if hasStatusMessage {
          Section { statusMessages }
        }
        if hasSecondaryActions {
          Section { secondaryButtons }
            .foregroundStyle(.tint)
            .disabled(model.isBusy)
        }
      }
      .buttonStyle(.automatic)
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if step == .signIn { Button("Cancel", action: cancelAction) }
        }
        ToolbarItem(placement: .confirmationAction) {
          if model.isBusy {
            ProgressView().accessibilityLabel("Working")
          } else {
            submitButton.buttonStyle(.borderedProminent)
          }
        }
      }
    #else
      VStack(spacing: 20) {
        Text(title).font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let subtitle {
          Text(subtitle).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        Form { fields }
          .formStyle(.columns)
        if step == .passwordReset { successMessage }
        if hasStatusMessage {
          VStack(alignment: .leading, spacing: 8) { statusMessages }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if hasSecondaryActions {
          macOSSecondaryActions
            .buttonStyle(.link)
            .font(.callout)
            .disabled(model.isBusy)
        }
        if step == .signUp {
          termsNotice.font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
          if model.isBusy { ProgressView().controlSize(.small) }
          Spacer()
          if model.navigationPath.isEmpty {
            Button("Cancel", action: cancelAction)
              .keyboardShortcut(.cancelAction)
          } else {
            Button("Back") { navigate(Array(model.navigationPath.dropLast())) }
              .keyboardShortcut(.cancelAction)
          }
          submitButton.keyboardShortcut(.defaultAction)
        }
      }
      .padding(24)
      .frame(width: 420)
      .themedSurface(.sheet)
    #endif
  }

  #if os(macOS)
    @ViewBuilder
    private var macOSSecondaryActions: some View {
      if step == .signIn {
        HStack {
          Button("Forgot password?") { navigate([.forgotPassword]) }
          Spacer()
          Button("Create an account") { navigate([.signUp]) }
        }
      } else {
        VStack(spacing: 8) { secondaryButtons }
      }
    }
  #endif

  private var hasStatusMessage: Bool { model.errorMessage != nil || model.notice != nil }

}
