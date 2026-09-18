import CodevisorCore
import SwiftUI

/// The same row in onboarding and the shared list; the accessory slot
/// carries whatever sits between the status and the controls (an attention
/// indicator, a single machine's action).
public struct HarnessSettingsRow<Icon: View, Accessory: View, Actions: View>: View {
  @Environment(\.theme) private var theme
  private let name: String
  private let state: HarnessRowState
  @Binding private var isEnabled: Bool
  private let isChanging: Bool
  private let signIn: () -> Void
  private let icon: Icon
  private let accessory: Accessory
  private let actions: Actions

  public init(
    name: String, state: HarnessRowState, isEnabled: Binding<Bool>, isChanging: Bool = false,
    signIn: @escaping () -> Void,
    @ViewBuilder icon: () -> Icon, @ViewBuilder accessory: () -> Accessory, @ViewBuilder actions: () -> Actions
  ) {
    self.name = name
    self.state = state
    self._isEnabled = isEnabled
    self.isChanging = isChanging
    self.signIn = signIn
    self.icon = icon()
    self.accessory = accessory()
    self.actions = actions()
  }

  public var body: some View {
    HStack(spacing: 10) {
      icon.frame(width: 22).foregroundStyle(.primary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(name)
        if let status = state.status {
          Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      accessory
      if state.isBusy {
        ProgressView().controlSize(.small)
      }
      #if os(macOS)
        if isEnabled && state.needsSignIn && !state.isBusy {
          Button("Sign In…", action: signIn)
            .buttonStyle(.bordered)
            .tint(theme.isSystem ? nil : theme.textPrimary)
            .fixedSize()
        }
      #endif
      Toggle("Enable \(name)", isOn: $isEnabled)
        .labelsHidden().toggleStyle(.switch)
        .disabled(isChanging || state.isBusy)
        #if os(macOS)
          .controlSize(.small)
        #endif
      Menu {
        #if os(iOS)
          if isEnabled && state.needsSignIn && !state.isBusy {
            Button("Sign In…", systemImage: "person.crop.circle.badge.plus", action: signIn)
            Divider()
          }
        #endif
        actions
      } label: {
        Label("\(name) options", systemImage: "ellipsis.circle")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      #if os(macOS)
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      #endif
    }
    .padding(.vertical, 4)
  }
}

extension HarnessSettingsRow where Accessory == EmptyView {
  public init(
    name: String, state: HarnessRowState, isEnabled: Binding<Bool>, isChanging: Bool = false,
    signIn: @escaping () -> Void,
    @ViewBuilder icon: () -> Icon, @ViewBuilder actions: () -> Actions
  ) {
    self.init(
      name: name, state: state, isEnabled: isEnabled, isChanging: isChanging, signIn: signIn,
      icon: icon, accessory: { EmptyView() }, actions: actions)
  }
}
