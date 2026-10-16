import CodevisorCore
import SwiftUI

public struct FleetEntryRow<Icon: View, Accessory: View, Actions: View>: View {
  public static var trailingControlWidth: CGFloat { FleetRowMetrics.trailingControlWidth }
  public static var minContentHeight: CGFloat { FleetRowMetrics.minContentHeight }
  public static var iconColumnWidth: CGFloat { FleetRowMetrics.iconColumnWidth }

  private let name: String
  private let caption: String?
  private let isBusy: Bool
  private let isChanging: Bool
  private let isEnabled: Binding<Bool>?
  private let toggleDisabledReason: String?
  private let icon: Icon
  private let accessory: Accessory
  private let actions: Actions

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
          Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      .layoutPriority(1)
      Spacer(minLength: 8)
      accessory
      if isBusy {
        ProgressView().controlSize(.small)
      }
      if let isEnabled {
        Toggle("Enable \(name)", isOn: isEnabled)
          .labelsHidden().toggleStyle(.switch)
          .disabled(isChanging || toggleDisabledReason != nil)
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

public enum FleetRowMetrics {
  public static let trailingControlWidth: CGFloat = 22
  public static let minContentHeight: CGFloat = 24
  public static let iconColumnWidth: CGFloat = 32
}

public extension View {
  @ViewBuilder
  func fleetRowButton() -> some View {
    let styled = buttonStyle(.bordered)
      .fixedSize()
    #if os(iOS)
      styled.controlSize(.small)
    #else
      styled
    #endif
  }
}
