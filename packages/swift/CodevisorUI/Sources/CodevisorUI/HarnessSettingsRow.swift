import CodevisorCore
import SwiftUI

/// The same row in onboarding and the shared list; the accessory slot
/// carries whatever sits between the status and the controls (an attention
/// indicator, a single machine's action).
public struct HarnessSettingsRow<Icon: View, Accessory: View, Actions: View>: View {
  /// The trailing column every row ends in: the harness row's menu button,
  /// a machine row's status mark. One width so marks sit exactly under the
  /// menu button they follow.
  public static var trailingControlWidth: CGFloat { 22 }
  /// Rows are one height whether they carry a toggle, a bordered button, or
  /// a bare mark, so nested machine rows read as an indented continuation.
  public static var minContentHeight: CGFloat { 24 }
  /// The space the icon column takes; machine rows indent by it.
  public static var iconColumnWidth: CGFloat { 32 }

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
          .lineLimit(1)
        if let status = state.status {
          Text(status).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(2)
        }
      }
      // The name is the row's identity: it keeps its width and the
      // controls after it take what remains, not the other way round.
      .layoutPriority(1)
      Spacer(minLength: 8)
      accessory
      if state.isBusy {
        ProgressView().controlSize(.small)
      }
      if isEnabled && state.needsSignIn && !state.isBusy {
        Button("Sign In…", action: signIn)
          .harnessRowButton(theme)
      }
      Toggle("Enable \(name)", isOn: $isEnabled)
        .labelsHidden().toggleStyle(.switch)
        .disabled(isChanging || state.isBusy)
        #if os(macOS)
          .controlSize(.small)
        #endif
      #if os(macOS)
        Menu {
          actions
        } label: {
          Label("\(name) options", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: Self.trailingControlWidth)
      #endif
    }
    .frame(minHeight: Self.minContentHeight)
    .padding(.vertical, 4)
    #if os(iOS)
      // A phone row can't fit a name, a button, a switch, and a menu. The
      // rare actions (edit, uninstall) go where iOS lists keep them.
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        actions
      }
    #endif
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
  /// A row's bordered action. Regular on the Mac; small on the phone, where
  /// the same row also has to fit a toggle and a menu beside the name.
  @ViewBuilder
  func harnessRowButton(_ theme: Theme) -> some View {
    let styled = buttonStyle(.bordered)
      .tint(theme.isSystem ? nil : theme.textPrimary)
      .fixedSize()
    #if os(iOS)
      styled.controlSize(.small)
    #else
      styled
    #endif
  }
}
