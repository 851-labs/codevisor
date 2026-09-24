import CodevisorCore
import SwiftUI

/// The row every fleet page's top level is made of: one entry as the fleet
/// wants it, with the machines that carry it nested underneath. Harnesses,
/// MCP servers, skills, and plugins all render this, so the four pages read
/// as one design.
///
/// `isEnabled` is optional because not every plane has a wish to express —
/// skills are either in the fleet's canonical store or not, and a toggle
/// would be a control with nothing behind it.
public struct FleetEntryRow<Icon: View, Accessory: View, Actions: View>: View {
  /// The trailing column every row ends in: the entry row's menu button, a
  /// machine row's status mark. One width so marks sit exactly under the
  /// menu button they follow.
  public static var trailingControlWidth: CGFloat { FleetRowMetrics.trailingControlWidth }
  /// Rows are one height whether they carry a toggle, a bordered button, or
  /// a bare mark, so nested machine rows read as an indented continuation.
  public static var minContentHeight: CGFloat { FleetRowMetrics.minContentHeight }
  /// The space the icon column takes; machine rows indent by it.
  public static var iconColumnWidth: CGFloat { FleetRowMetrics.iconColumnWidth }

  @Environment(\.theme) private var theme
  private let name: String
  private let caption: String?
  private let isBusy: Bool
  private let isChanging: Bool
  private let isEnabled: Binding<Bool>?
  private let toggleDisabledReason: String?
  private let icon: Icon
  private let accessory: Accessory
  private let actions: Actions

  /// - Parameters:
  ///   - caption: the secondary line under the name; nil renders one line.
  ///   - isEnabled: the fleet's wish. Nil renders no toggle.
  ///   - toggleDisabledReason: when non-nil the toggle is disabled and this
  ///     is its help text — Computer Use cannot be turned on before its
  ///     permissions are granted, and the row has to say why.
  public init(
    name: String,
    caption: String? = nil,
    isBusy: Bool = false,
    isChanging: Bool = false,
    isEnabled: Binding<Bool>? = nil,
    toggleDisabledReason: String? = nil,
    @ViewBuilder icon: () -> Icon,
    @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder actions: () -> Actions
  ) {
    self.name = name
    self.caption = caption
    self.isBusy = isBusy
    self.isChanging = isChanging
    self.isEnabled = isEnabled
    self.toggleDisabledReason = toggleDisabledReason
    self.icon = icon()
    self.accessory = accessory()
    self.actions = actions()
  }

  public var body: some View {
    HStack(spacing: 10) {
      icon.frame(width: 22).foregroundStyle(.primary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(name).lineLimit(1)
        if let caption {
          Text(caption).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(2)
        }
      }
      // The name is the row's identity: it keeps its width and the controls
      // after it take what remains, not the other way round.
      .layoutPriority(1)
      Spacer(minLength: 8)
      accessory
      if isBusy {
        ProgressView().controlSize(.small)
      }
      if let isEnabled {
        Toggle("Enable \(name)", isOn: isEnabled)
          .labelsHidden().toggleStyle(.switch)
          .disabled(isChanging || isBusy || toggleDisabledReason != nil)
          .help(toggleDisabledReason ?? "")
          #if os(macOS)
            .controlSize(.small)
          #endif
      }
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

public extension FleetEntryRow where Accessory == EmptyView {
  init(
    name: String,
    caption: String? = nil,
    isBusy: Bool = false,
    isChanging: Bool = false,
    isEnabled: Binding<Bool>? = nil,
    toggleDisabledReason: String? = nil,
    @ViewBuilder icon: () -> Icon,
    @ViewBuilder actions: () -> Actions
  ) {
    self.init(
      name: name, caption: caption, isBusy: isBusy, isChanging: isChanging,
      isEnabled: isEnabled, toggleDisabledReason: toggleDisabledReason,
      icon: icon, accessory: { EmptyView() }, actions: actions)
  }
}

/// The layout metrics nested rows indent by, without naming a generic.
public enum FleetRowMetrics {
  public static let trailingControlWidth: CGFloat = 22
  public static let minContentHeight: CGFloat = 24
  public static let iconColumnWidth: CGFloat = 32
}

public extension View {
  /// A row's bordered action. Regular on the Mac; small on the phone, where
  /// the same row also has to fit a toggle and a menu beside the name.
  @ViewBuilder
  func fleetRowButton(_ theme: Theme) -> some View {
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
