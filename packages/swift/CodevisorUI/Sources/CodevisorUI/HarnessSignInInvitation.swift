import CodevisorTheming
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// A consistent entry point for an account or provider list with no credentials.
public struct HarnessSignInInvitation<Action: View>: View {
  @Environment(\.theme) private var theme
  #if os(iOS)
    /// iOS resolves the accent against the background to keep the tinted
    /// call-to-action legible; macOS uses the native prominent style.
    @Environment(\.self) private var environment
  #endif

  let harnessId: String
  let harnessName: String
  let errorMessage: String?
  let action: Action

  public init(
    harnessId: String, harnessName: String, errorMessage: String? = nil,
    @ViewBuilder action: () -> Action
  ) {
    self.harnessId = harnessId
    self.harnessName = harnessName
    self.errorMessage = errorMessage
    self.action = action()
  }

  public var body: some View {
    ViewThatFits(in: .vertical) {
      content
      ScrollView { content.frame(maxWidth: .infinity) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var content: some View {
    VStack(spacing: 20) {
      icon
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .frame(width: 44, height: 44)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)

      Text("Connect \(harnessName)")
        .font(.title2.weight(.semibold))
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      action
        .labelStyle(InvitationActionLabelStyle())
        #if os(macOS)
          .menuStyle(.button)
          .buttonBorderShape(.roundedRectangle)
        #else
          .tint(actionTint)
        #endif
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(theme.textSecondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: 320)
    .padding(24)
  }

  private var icon: Image {
    let name = "harness-\(harnessId)"
    #if os(macOS)
      if let image = NSImage(named: name) { return Image(nsImage: image) }
    #else
      if let image = UIImage(named: name) { return Image(uiImage: image) }
    #endif
    return Image(systemName: "terminal")
  }

  #if os(iOS)
    private var actionTint: Color {
      let resolved = environment.theme.accent.resolve(in: environment)
      let accent = RGBA(r: Double(resolved.red) * 255, g: Double(resolved.green) * 255, b: Double(resolved.blue) * 255)
      let black = RGBA(r: 0, g: 0, b: 0)
      let minimumRatio = environment.colorSchemeContrast == .increased ? 7.0 : 4.5

      // Preserve the theme's hue while keeping the white label legible.
      for step in 0...20 {
        let candidate = accent.mixed(with: black, weight: 1 - Double(step) / 20)
        if ColorMath.contrastRatio(candidate.relativeLuminance, 1) >= minimumRatio {
          return Color(rgba: candidate)
        }
      }
      return .black
    }
  #endif
}

private struct InvitationActionLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.title
      #if os(macOS)
        .frame(minWidth: 96)
      #else
        .frame(minWidth: 160)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
      #endif
  }
}
