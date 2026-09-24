import CodevisorCore
import SwiftUI

/// The same row in onboarding and the shared list. The chrome is
/// `FleetEntryRow`, shared with the MCP, skills, and plugin pages; the
/// "Sign In…" button and the status caption are what a harness adds to it.
public struct HarnessSettingsRow<Icon: View, Accessory: View, Actions: View>: View {
  public static var trailingControlWidth: CGFloat { FleetRowMetrics.trailingControlWidth }
  public static var minContentHeight: CGFloat { FleetRowMetrics.minContentHeight }
  public static var iconColumnWidth: CGFloat { FleetRowMetrics.iconColumnWidth }

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
    @ViewBuilder icon: () -> Icon, @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder actions: () -> Actions
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
    FleetEntryRow(
      name: name,
      caption: state.status,
      isBusy: state.isBusy,
      isChanging: isChanging,
      isEnabled: $isEnabled,
      icon: { icon },
      accessory: {
        accessory
        if isEnabled && state.needsSignIn && !state.isBusy {
          Button("Sign In…", action: signIn)
            .fleetRowButton(theme)
        }
      },
      actions: { actions })
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

extension View {
  /// Retained spelling of the shared row button so harness call sites (and
  /// the auth sheets that match them) keep reading in harness terms.
  @ViewBuilder
  func harnessRowButton(_ theme: Theme) -> some View {
    fleetRowButton(theme)
  }
}
